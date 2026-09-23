/*
Copyright (c) 2023-2026 Andrea Fontana

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
*/

module serverino.daemon;

import serverino.common;
import serverino.communicator;
import serverino.config;
import serverino.tls;
import serverino.databuffer : DataBuffer;

import std.stdio : File;
import std.conv : to;
import std.experimental.logger : log, info, warning, error;
import std.process : ProcessPipes;

import std.format : format;
import std.socket : Socket, SocketSet, SocketType, AddressFamily, SocketShutdown, TcpSocket, SocketOption, SocketOptionLevel, SocketException, socket_t, socketPair;
import std.algorithm : filter;
import std.datetime : SysTime, Clock, seconds;

import core.thread : ThreadBase, Thread, ThreadGroup;

static if (serverino.common.Backend == BackendType.EPOLL) import core.sys.linux.epoll;

version(Posix) import std.socket : UnixAddress;

// The class WorkerInfo is used to keep track of the workers.
package class WorkerInfo
{
   enum State
   {
      IDLING = 0, // Worker is waiting for a request.
      PROCESSING, // Worker is processing a request.
      STOPPED     // Worker is stopped.
   }

   enum Type
   {
      STATIC = 0, // Worker is static, always running
      DYNAMIC     // Worker is wake up if needed (high load)
   }

   override string toString()
   {
      string s;
      s ~= "PID: " ~ pi.id.to!string ~ "\n";
      s ~= "STATE: " ~ status.to!string ~ "\n";
      s ~= "STATUS CHANGED AT: " ~ statusChangedAt.to!string ~ "\n";
      s ~= "RELOAD REQUESTED: " ~ reloadRequested.to!string ~ "\n";
      return s;
   }

   // New worker instances are set to STOPPED
   this()
   {
      instances ~= this;
      backlog.length = backlogDepth + 1;
      backlogSizes.length = backlogDepth + 1;

      status = State.STOPPED;
      statusChangedAt = now;
   }

   // Initialize the worker.
   void reinit(Type workerType)
   {
      assert(status == State.STOPPED);

      isDynamic = workerType == Type.DYNAMIC;

      // Set default status.
      clear();

      import std.process : pipeProcess, Redirect, Config;
      import std.uuid : randomUUID;

      // Create a new socket and bind it to a random address.
      Socket s = new Socket(AddressFamily.UNIX, SocketType.STREAM);

      auto uuid = "serverino-" ~ randomUUID().toString()[$-12..$] ~ ".sock";

      // We use a unix socket on both linux and macos/windows but ...
      version(linux) auto socketAddress = new UnixAddress("\0%s".format(uuid));
      else
      {
         import std.path : buildPath;
         import std.file : tempDir;
         auto socketAddress = new UnixAddress(buildPath(tempDir, uuid));
      }

      s.bind(socketAddress);
      s.listen(1);

      // We start a new process and pass the socket address to it.
      auto env = Daemon.workerEnvironment.dup;
      env["SERVERINO_SOCKET"] = uuid;
      env["SERVERINO_DYNAMIC_WORKER"] = isDynamic?"1":"0";

      reloadRequested = false;
      import std.range : repeat;
      import std.array : array;

      version(Posix) const pname = [exePath, cast(char[])(' '.repeat(30).array)];
      else const pname = exePath;

      auto pipes = pipeProcess(pname, Redirect.stdin, env, Config.detached);

      Socket accepted = s.accept();
      this.pi = new ProcessInfo(pipes.pid.processID);
      this.unixSocket = accepted;
      this.unixSocketHandle = accepted.handle;

      accepted.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDBUF, SOCKET_BUFFER_SIZE);
      accepted.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, SOCKET_BUFFER_SIZE);

      version(Windows) { }
      else accepted.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVLOWAT, 1);


      // Wait for the worker to wake up.
      ubyte[1] data;
      accepted.receive(data);

      static if (serverino.common.Backend == BackendType.EPOLL)
         Daemon.epollAddSocket(unixSocketHandle, EPOLLIN, cast(void*) this);
      else static if (serverino.common.Backend == BackendType.KQUEUE)
         Daemon.addKqueueChange(unixSocketHandle, EVFILT_READ, EV_ADD | EV_ENABLE, cast(void*) this);

      setStatus(WorkerInfo.State.IDLING);
   }

   // NOTE: no destructor here, on purpose.
   //
   // WorkerInfo lives in `instances`, which is thread local: when the daemon thread
   // ends, every worker becomes garbage and is finalized at process teardown. A
   // finalizer can't touch another GC reference (`pi`, `unixSocket`) nor the event
   // loop (`Daemon.changeList` is GC memory too): by then they may already be gone.
   // On kqueue that's a write into freed memory, which is why macOS was segfaulting
   // right after the goodbye message. Resources are released by clear(), called
   // explicitly when the daemon shuts down.

   void clear()
   {
      assert(status == State.STOPPED);

      if (this.pi) this.pi.kill();

      if (this.unixSocket)
      {
         static if (serverino.common.Backend == BackendType.EPOLL)
            Daemon.epollRemoveSocket(unixSocketHandle);
         else static if (serverino.common.Backend == BackendType.KQUEUE)
            Daemon.addKqueueChange(unixSocketHandle, EVFILT_READ, EV_DELETE | EV_DISABLE, null);

         unixSocket.shutdown(SocketShutdown.BOTH);
         unixSocket.close();
         unixSocket = null;
         unixSocketHandle = socket_t.max;
      }

      communicator = null;
      responseStarted();

      backlog[] = null;
      backlogSizes[] = 0;
      backlogHead = 0;
      backlogCount = 0;
      backlogBytes = 0;
      backlogPartial.clear();
   }

   pragma(inline, true)
   void setStatus(State s)
   {
      import std.conv : to;
      assert(s!=status || s == State.PROCESSING, " > Trying to change WorkerInfo status from " ~ status.to!string ~ " to " ~ s.to!string ~ "\n" ~ this.toString());
      status = s;
      statusChangedAt = now;

      if (Daemon.suspended && s == State.STOPPED)
      {
         // If the daemon is suspended, we kill the workers.
         log("Killing worker " ~ pi.id.to!string  ~ ". [REASON: suspended]");
         pi.kill();

         clear();
      }
      else if (s == State.STOPPED)
      {
         // Automatically reinit the worker if it's stopped and it's not dynamic.
         if (isDynamic) clear();
         else if (!Daemon.exitRequested) reinit(Type.STATIC);
      }
      // If a reload is requested we kill the worker when it's idling.
      else if (s == State.IDLING && reloadRequested)
      {
         log("Killing worker " ~ pi.id.to!string  ~ ". [REASON: reloading]");
         pi.kill();
         setStatus(WorkerInfo.State.STOPPED);
      }
   }

   void onReadAvailable()
   {
      if (backlogDepth > 0)
      {
         onReadAvailableWithBacklog();
         return;
      }

      // Nobody is waiting for this worker and it's not working on anything: it's leaving.
      if (communicator is null && status != WorkerInfo.State.PROCESSING)
      {
         debug log("Worker #" ~ pi.id.to!string  ~ " stopped.");
         pi.kill();
         setStatus(WorkerInfo.State.STOPPED);
         return;
      }

      ubyte[DEFAULT_BUFFER_SIZE] buffer = void;
      auto bytes = unixSocket.receive(buffer);

      if (bytes > 0)
      {
         // Counted before handing the data over: the communicator could let the worker go.
         if (responseExpected == 0)
         {
            WorkerPayload wp = void;
            (cast(ubyte*)&wp)[0..WorkerPayload.sizeof] = buffer[0..WorkerPayload.sizeof];
            responseExpected = WorkerPayload.sizeof + wp.contentLength;
         }

         responseReceived += bytes;

         // Nobody is waiting for this response anymore: once it's all here, the worker
         // is free again.
         if (communicator is null)
         {
            if (responseCompleted) setStatus(WorkerInfo.State.IDLING);
            return;
         }

         if (communicator.responseLength == 0) deliver(communicator, buffer[0..bytes]);
         else communicator.write(cast(char[])buffer[0..bytes]);
      }
      else
      {
         // The worker is gone. If it went while serving a request, the client is
         // still waiting: it deserves an answer rather than a dropped connection.
         if (bytes < 0) debug warning("Worker #" ~ pi.id.to!string  ~ " exited/terminated/killed (socket error).");

         if (communicator !is null)
         {
            if (status == WorkerInfo.State.PROCESSING) communicator.sendServerError();
            communicator.reset();
         }

         setStatus(WorkerInfo.State.STOPPED);
      }
   }

   // With the backlog the worker can have several requests in flight: the responses come
   // back in order on the same stream, each one framed by its WorkerPayload.
   private void onReadAvailableWithBacklog()
   {
      ubyte[DEFAULT_BUFFER_SIZE] buffer = void;
      auto bytes = unixSocket.receive(buffer);

      if (bytes <= 0)
      {
         if (bytes < 0) debug warning("Worker #" ~ pi.id.to!string  ~ " exited/terminated/killed (socket error).");

         // The worker is gone and every request queued on it with it. Their clients
         // are still waiting: they deserve an answer rather than a dropped connection.
         while (backlogCount > 0)
         {
            auto c = dequeue();
            if (c is null) continue;

            c.sendServerError();
            c.reset();
         }

         setStatus(WorkerInfo.State.STOPPED);
         return;
      }

      ubyte[] input = buffer[0..bytes];

      // The beginning of this response came with the previous read
      if (backlogPartial.length > 0)
      {
         backlogPartial.append(input);
         input = backlogPartial.array;
      }

      size_t used = 0;
      size_t incomplete = 0;

      while (input.length - used >= WorkerPayload.sizeof)
      {
         auto rest = input[used..$];

         WorkerPayload wp = void;
         (cast(ubyte*)&wp)[0..WorkerPayload.sizeof] = rest[0..WorkerPayload.sizeof];

         immutable frame = WorkerPayload.sizeof + wp.contentLength;

         if (rest.length < frame)
         {
            incomplete = frame;
            break;
         }

         // A response nobody asked for: the worker is out of sync, we can't trust it.
         if (backlogCount == 0)
         {
            warning("Worker #" ~ pi.id.to!string  ~ " sent an unexpected response. Killing it.");
            pi.kill();
            setStatus(WorkerInfo.State.STOPPED);
            return;
         }

         // A null communicator is a client that left while waiting: drop its response.
         auto c = dequeue();
         if (c !is null) deliver(c, rest[0..frame]);

         used += frame;
      }

      // Keep what is left for the next read: the beginning of the next response
      immutable left = input.length - used;

      if (input.ptr is backlogPartial.array.ptr)
      {
         if (used > 0)
         {
            import core.stdc.string : memmove;
            memmove(input.ptr, input.ptr + used, left);
            backlogPartial.length = left;
         }
      }
      else if (left > 0) backlogPartial.append(input[used..$]);

      // Not here yet: make room for all of it at once. (Not earlier: `input` could
      // point to this very buffer)
      if (incomplete > 0) backlogPartial.reserve(incomplete);

      if (backlogCount == 0 && status == WorkerInfo.State.PROCESSING)
         setStatus(WorkerInfo.State.IDLING);
   }

   // Queue a communicator whose request (of `size` bytes) has just been sent to this worker.
   void enqueue(Communicator c, size_t size)
   {
      assert(backlogCount < backlog.length);
      immutable idx = (backlogHead + backlogCount) % backlog.length;
      backlog[idx] = c;
      backlogSizes[idx] = size;
      backlogBytes += size;
      backlogCount++;
   }

   private Communicator dequeue()
   {
      auto c = backlog[backlogHead];
      backlog[backlogHead] = null;
      backlogBytes -= backlogSizes[backlogHead];
      backlogSizes[backlogHead] = 0;
      backlogHead = (backlogHead + 1) % backlog.length;
      backlogCount--;
      return c;
   }

   // The client of this communicator is gone: its response, when it comes, is dropped.
   void orphan(Communicator c)
   {
      foreach(i; 0..backlogCount)
      {
         immutable idx = (backlogHead + i) % backlog.length;
         if (backlog[idx] is c) backlog[idx] = null;
      }
   }

   // Has the worker sent the whole response to the request it's serving? (backlog disabled)
   pragma(inline, true)
   bool responseCompleted() { return responseExpected > 0 && responseReceived >= responseExpected; }

   // A new request has been sent to the worker (backlog disabled)
   pragma(inline, true)
   void responseStarted() { responseExpected = 0; responseReceived = 0; }

   // Can this worker take one more request of `size` bytes?
   pragma(inline, true)
   bool canQueue(size_t size)
   {
      return status == State.PROCESSING && !reloadRequested && backlogCount < backlog.length
         && backlogBytes + size <= MAX_BACKLOG_BYTES;
   }

   // Hand a response (or its first chunk) to the communicator that asked for it.
   private void deliver(Communicator communicator, ubyte[] payload)
   {
      // Copied out: with the backlog the payload can start anywhere in the buffer.
      WorkerPayload wp = void;
      (cast(ubyte*)&wp)[0..WorkerPayload.sizeof] = payload[0..WorkerPayload.sizeof];
      auto data = cast(char[])payload[WorkerPayload.sizeof..$];

      if (wp.flags & WorkerPayload.Flags.DAEMON_SHUTDOWN) Daemon.shutdown();
      else if (wp.flags & WorkerPayload.Flags.DAEMON_SUSPEND) Daemon.suspend();

      version(serverino_disable_websockets)
      {
         // Nothing to do here.
      }
      else static if(__VERSION__ < 2102)
      {
         pragma(msg, "-----------------------------------------------------------------------------------");
         pragma(msg, "Warning: DMD 2.102 or later is required to use the websocket feature.");
         pragma(msg, "Please upgrade your DMD compiler or build using `serverino_disable_websockets` version");
         pragma(msg, "-----------------------------------------------------------------------------------");
      }
      else
      {
         if(wp.flags & WorkerPayload.Flags.WEBSOCKET_UPGRADE)
         {
            // OK, we have a websocket upgrade request.
            import std.string : indexOf, strip, split;
            import std.path : buildPath;
            import std.file : tempDir;

            auto idx = data.indexOf("x-serverino-websocket:");
            auto hdrs = data[0..idx] ~ "\r\n";
            auto metadata = data[idx..$].split("\r\n");

            // Extract the UUID and the PID from the headers. We need them to communicate with the new process.
            auto uuid = metadata[0]["x-serverino-websocket:".length..$].strip;
            auto pid = metadata[1]["x-serverino-websocket-pid:".length..$].strip;

            // Create a new socket and bind it to a random address.
            Socket webs = new Socket(AddressFamily.UNIX, SocketType.STREAM);

            // We use a unix socket on both linux and macos/windows but ...
            version(linux) auto socketAddress = new UnixAddress("\0%s".format(uuid));
            else auto socketAddress = new UnixAddress(buildPath(tempDir, uuid));

            webs.connect(socketAddress);

            // Send socket to websocket
            socket_t toSend;

            version(serverino_enable_https)
            {
               if (communicator.tlsStream !is null)
               {
                  auto pair = socketPair();
                  communicator.proxySkt = pair[0];
                  communicator.proxySktHandle = pair[0].handle;
                  communicator.proxySkt.blocking = false;
                  toSend = pair[1].release();

                  communicator.status = Communicator.State.WEBSOCKET;

                  static if (serverino.common.Backend == BackendType.EPOLL)
                     Daemon.epollAddSocket(communicator.proxySktHandle, EPOLLIN, cast(void*) communicator);
                  else static if (serverino.common.Backend == BackendType.KQUEUE)
                     Daemon.addKqueueChange(communicator.proxySktHandle, EVFILT_READ, EV_ADD | EV_ENABLE, cast(void*) communicator);

               }
               else
               {
                  toSend = communicator.clientSkt.release();

                  // We must remove the socket from the epoll/kqueue before sending it to the websocket.
                  static if (serverino.common.Backend == BackendType.EPOLL) Daemon.epollRemoveSocket(toSend);
                  else static if (serverino.common.Backend == BackendType.KQUEUE)
                  {
                     Daemon.addKqueueChange(toSend, EVFILT_READ, EV_DELETE | EV_DISABLE, null);
                     Daemon.addKqueueChange(toSend, EVFILT_WRITE, EV_DELETE | EV_DISABLE, null);
                  }
               }
            }
            else
            {
               toSend = communicator.clientSkt.release();

               // We must remove the socket from the epoll/kqueue before sending it to the websocket.
               static if (serverino.common.Backend == BackendType.EPOLL) Daemon.epollRemoveSocket(toSend);
               else static if (serverino.common.Backend == BackendType.KQUEUE)
               {
                  Daemon.addKqueueChange(toSend, EVFILT_READ, EV_DELETE | EV_DISABLE, null);
                  Daemon.addKqueueChange(toSend, EVFILT_WRITE, EV_DELETE | EV_DISABLE, null);
               }
            }

            version(Posix) auto sent = socketTransferSend(toSend, webs, pid.to!int);
            else version(Windows)
            {
               WSAPROTOCOL_INFOW wi;
               WSADuplicateSocketW(toSend, pid.to!int, &wi);
               auto sent = webs.send((cast(ubyte*)&wi)[0..wi.sizeof]) > 0;
            }

            if (!sent)
            {
               log("Error sending socket to websocket.");
               webs.shutdown(SocketShutdown.BOTH);
               webs.close();

               // MACOS-HANDOFF: experimental, trying to fix the intermittent websocket failure on macOS CI.
               // (this close was missing anyway: keep it even if the rest is reverted)
               version(Posix)
               {
                  import core.sys.posix.unistd : close;
                  close(toSend);
               }
            }
            else
            {
               // Send address family (AF_INET or AF_INET6)
               ushort[1] addressFamily = [cast(ushort)communicator.clientSkt.addressFamily];
               webs.send(addressFamily);

               // Send worker http upgrade response
               webs.send(hdrs);

               // MACOS-HANDOFF: experimental, trying to fix the intermittent websocket failure on macOS CI.
               // Revert: replace the line below with the close(toSend) of the error branch above.
               // Don't close our copy yet: the socket could still be in flight.
               // (see checkPendingHandoffs)
               version(Posix) addPendingHandoff(toSend, webs);
            }

            // The websocket lives on its own process now: the worker is free again.
            // (in the TLS case the communicator stays alive to pump the encrypted side,
            // so it doesn't go through reset() and nobody else would unset the worker)
            if (communicator.status != Communicator.State.WEBSOCKET) communicator.reset();
            else communicator.unsetWorker();

            return;
         }
      }

      communicator.isKeepAlive = (wp.flags & WorkerPayload.Flags.HTTP_KEEP_ALIVE) != 0;
      communicator.isSendFile = (wp.flags & WorkerPayload.Flags.HTTP_RESPONSE_FILE) != 0;

      if (communicator.isSendFile)
      {
         auto deleteOnClose = (wp.flags & WorkerPayload.Flags.HTTP_RESPONSE_FILE_DELETE) != 0;
         communicator.writeFile(data, deleteOnClose);
      }
      else
      {
         communicator.setResponseLength(wp.contentLength);
         communicator.write(data);
      }
   }

   // A lazy list of busy workers.
   pragma(inline, true)
   static auto ref alive() { return WorkerInfo.instances.filter!(x => x.status != WorkerInfo.State.STOPPED); }

   // A lazy list of workers we can reuse.
   pragma(inline, true)
   static auto ref dead() { return WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.STOPPED); }

   private shared static this() {
      exePath = thisExePathWithFallback();

      // Automatically kill when the main daemon process is terminated
      version(linux)
      {
         import std.process : environment;
         if (environment.get("SERVERINO_DAEMON_CHILD") == "1" && environment.get("SERVERINO_COMPONENT") != "WK")
         {
            import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
            import core.sys.posix.signal : SIGTERM, SIGINT;
            auto rc = prctl(PR_SET_PDEATHSIG, SIGTERM | SIGINT, 0, 0, 0);
            assert(rc == 0, "prctl(PR_SET_PDEATHSIG) failed");
         }
      }
   }

package:

   Socket                  listener;
   ProcessInfo             pi;

   CoarseTime              statusChangedAt;

   State                   status            = State.STOPPED;
   Socket                  unixSocket        = null;
   socket_t                unixSocketHandle  = socket_t.max;

   Communicator            communicator      = null;
   size_t                  responseExpected  = 0;  // Bytes of the current response, WorkerPayload included
   size_t                  responseReceived  = 0;  // Of those, how many have been received

   // Worker backlog (see ServerinoConfig.enableWorkerBacklog). The communicators whose
   // request has been sent to this worker, in the order their responses will come back.
   // A null entry is a client that left while waiting.
   Communicator[]          backlog;
   size_t                  backlogHead       = 0;
   size_t                  backlogCount      = 0;
   size_t[]                backlogSizes;     // Bytes of each request in flight
   size_t                  backlogBytes      = 0;  // Their sum: they could still be in the socket buffer
   DataBuffer!ubyte        backlogPartial;   // A response split across two reads
   static size_t           backlogDepth      = 0;

   // Buffers of the unix socket between the daemon and a worker.
   enum SOCKET_BUFFER_SIZE = 64*1024;

   // On a unix stream socket the bytes the worker hasn't read yet count against our send
   // buffer: once it's full, send() blocks the whole daemon. The kernel doubles the size we
   // ask for, but it also charges each message its own overhead (up to ~1 KiB, more than a
   // small request): half of the requested size keeps the requests in flight well within it.
   enum MAX_BACKLOG_BYTES = SOCKET_BUFFER_SIZE / 2;

   bool                    reloadRequested   = false;
   bool                    isDynamic         = false;

   static WorkerInfo[]     instances;
   shared static string    exePath;

}

version(Posix)
{
   extern(C) void serverino_exit_handler(int num) nothrow @nogc @system
   {
      import core.stdc.stdlib : exit;
      if (Daemon.exitRequested) exit(-1);
      else Daemon.exitRequested = true;
   }

   extern(C) void serverino_reload_handler(int num) nothrow @nogc @system
   {
      Daemon.reloadRequested = true;

      // Propagate the same signal to child daemon processes if this is the main daemon
      import core.sys.posix.signal : kill;
      foreach (pid; Daemon.childDaemonPids)
         kill(pid, num);
   }

   version(serverino_enable_https)
   extern(C) void serverino_reload_certificates_handler(int num) nothrow @nogc @system
   {
      // Just bump the generation: the actual reload is done by the event loops.
      import core.atomic : atomicOp;
      atomicOp!"+="(Daemon.certificatesGeneration, 1);

      import core.sys.posix.signal : kill;
      foreach (pid; Daemon.childDaemonPids)
         kill(pid, num);
   }
}

version(serverino_enable_https)
{
   import serverino.config : Https;

   // Identity of a certificate set: listeners sharing it share their TLS context.
   package string tlsContextKey(const(Https.Certificate)[] certificates) @safe
   {
      import std.array : appender;

      auto key = appender!string;
      foreach(certificate; certificates)
      {
         key ~= certificate.certPath;
         key ~= "\0";
         key ~= certificate.keyPath;
         key ~= "\0";
      }

      return key.data;
   }
}

// The Daemon class is the core of serverino.
struct Daemon
{

static:

   /// Is serverino ready to accept requests?
   bool bootCompleted() @safe @nogc nothrow { return ready; }

   /++ Did serverino give up starting? (invalid configuration, or a return code
    + set from `@onServerInit`)
    +
    + It matters with `ServerinoBackground`: the daemon runs on its own thread, so
    + a failed boot can't reach your `main()` as a return code. Without checking
    + this, a `while(!Daemon.bootCompleted)` loop would wait forever.
    + ---
    + while(!Daemon.bootCompleted && !Daemon.bootFailed) Thread.sleep(10.msecs);
    + if (Daemon.bootFailed) { stderr.writeln(Daemon.bootError); return 1; }
    + ---
   +/
   bool bootFailed() @safe @nogc nothrow { return bootFailure; }

   /// Why the boot failed. Empty if it didn't.
   string bootError() @trusted nothrow { return cast(string)bootErrorMessage; }

   // Called by wakeServerino() when serverino gives up before the daemon starts.
   package void setBootFailure(string message) @trusted nothrow
   {
      bootErrorMessage = message;
      bootFailure = true;
   }

   /// Reload all workers
   void reload() @safe @nogc nothrow { reloadRequested = true; }

   version(serverino_enable_https)
   {
      /++ Reload the TLS certificates from disk, without restarting the daemon.
       + Every listener rebuilds its TLS context within a second; connections already
       + established keep using the certificate they were built with.
       + If the new certificates can't be loaded, the previous ones stay in use.
       +
       + Sending SIGHUP to the daemon does the same thing. Call it from the daemon
       + process (that's the one propagating the reload to its children).
       + ---
       + // After renewing a certificate with certbot/acme
       + Daemon.reloadCertificates();
       + ---
      +/
      void reloadCertificates() @trusted nothrow
      {
         import core.atomic : atomicOp;
         atomicOp!"+="(certificatesGeneration, 1);

         version(Posix)
         {
            import core.sys.posix.signal : kill, SIGHUP;
            foreach (pid; childDaemonPids) kill(pid, SIGHUP);
         }
      }
   }

   /// Shutdown the serverino daemon.
   void shutdown() {
      exitRequested = true;

      // Wait until all daemon event loops finished (prevents tear-down races)
      while(isDaemonRunning)
         Thread.yield();

      (cast(ThreadGroup)Daemon.threadGroup).joinAll();
   }

   /// Suspend the daemon.
   void suspend() @safe @nogc nothrow { suspended = true; }

   /// Resume the daemon.
   void resume()  @safe @nogc nothrow { suspended = false; }

   /// Check if the daemon is running.
   bool isRunning() @nogc nothrow { return !suspended && !exitRequested; }

   bool isSuspended() @safe @nogc nothrow { return suspended; }

   bool isExiting() @safe @nogc nothrow { return exitRequested; }

   string buildId() {

      static string id;

      if (id.length == 0)
      {
         try {
            import std.file : getTimes;
            SysTime ignored, creation;
            WorkerInfo.exePath.getTimes(ignored, creation);
            id = simpleNotSecureCompileTimeHash(creation.toISOExtString);
         }
         catch (Exception e) {
            warning("Can't get the current serverino build id.");
            id = "N/A";
         }
      }

      return id;
   }
package:

   void wake(Modules...)(DaemonConfigPtr config, WorkerConfigPtr workerConfig)
   {
      import core.atomic : atomicFetchAdd, atomicFetchSub;
      import serverino.interfaces : Request;
      import std.process : environment, thisProcessID;
      import std.file : tempDir, exists, remove;
      import std.path : buildPath, baseName;
      import std.digest.sha : sha256Of;
      import std.digest : toHexString;
      import std.ascii : LetterCase;
      import core.runtime : Runtime;
      import std.base64 : Base64;
      import std.string : join, representation;

      immutable daemonPid = thisProcessID.to!string;

      isDaemonRunning = true;
      immutable argsBkp = Base64.encode(Runtime.args.join("\0").representation);

      environment["SERVERINO_COMPONENT"] = "D";

      version(Posix)
      {
         auto base = baseName(Runtime.args[0]);
         const bool isChild = environment.get("SERVERINO_DAEMON_CHILD") == "1";
         auto daemonIndex = isChild ? environment.get("SERVERINO_DAEMON_INDEX", "?") : "0";

         setProcessName
         (
            [
               base ~ " / daemon-" ~ daemonIndex ~ " [PID: " ~ daemonPid ~ "]",
               base ~ " / daemon",
               base ~ " [D]"
            ]
         );
      }

      // Initialize worker environment once (thread-safe)
      {
         import core.atomic : cas;
         if (cas(&workerEnvInit, 0, 1))
         {
            workerEnvironment = environment.toAA();
            workerEnvironment["SERVERINO_DAEMON_PID"] = daemonPid;
            workerEnvironment["SERVERINO_BUILD"] = Daemon.buildId();
            workerEnvironment["SERVERINO_ARGS"] = argsBkp;
            workerEnvironment["SERVERINO_COMPONENT"] = "WK";

            workerEnvironment["SERVERINO_WORKER_CONFIG_MAX_REQUEST_TIME"] = workerConfig.maxRequestTime.total!"msecs".to!string;
            workerEnvironment["SERVERINO_WORKER_CONFIG_MAX_HTTP_WAITING"] = workerConfig.maxHttpWaiting.total!"msecs".to!string;
            workerEnvironment["SERVERINO_WORKER_CONFIG_MAX_WORKER_LIFETIME"] = workerConfig.maxWorkerLifetime.total!"msecs".to!string;
            workerEnvironment["SERVERINO_WORKER_CONFIG_MAX_WORKER_IDLING"] = workerConfig.maxWorkerIdling.total!"msecs".to!string;
            workerEnvironment["SERVERINO_WORKER_CONFIG_MAX_DYNAMIC_WORKER_IDLING"] = workerConfig.maxDynamicWorkerIdling.total!"msecs".to!string;
            workerEnvironment["SERVERINO_WORKER_CONFIG_KEEP_ALIVE"] = workerConfig.keepAlive?"1":"0";
            workerEnvironment["SERVERINO_WORKER_CONFIG_USER"] = workerConfig.user;
            workerEnvironment["SERVERINO_WORKER_CONFIG_GROUP"] = workerConfig.group;
            workerEnvironment["SERVERINO_WORKER_CONFIG_ENABLE_SERVER_SIGNATURE"] = workerConfig.serverSignature?"1":"0";
            workerEnvironment["SERVERINO_WORKER_CONFIG_LOG_LEVEL"] = config.logLevel.to!string;
         }
      }

      version(Posix) {
         // On Posix we don't need to create a canary file.
         // Simply use the SIGUSR1 signal to reload the workers.
         void removeCanary() { }
         void writeCanary() { }
      }
      else
      {
         // On Windows we need to create a canary file.
         // You can delete the file to reload the workers.
         immutable canaryFileName = tempDir.buildPath("serverino-" ~ daemonPid ~ "-" ~ sha256Of(daemonPid).toHexString!(LetterCase.lower) ~ ".canary");
         void removeCanary() { if (exists(canaryFileName)) remove(canaryFileName); }
         void writeCanary() { File(canaryFileName, "w").write("delete this file to reload serverino workers (process id: " ~ daemonPid ~ ")\n"); }

         writeCanary();
         scope(exit) removeCanary();
      }

      bool isMainThread = (cast(ThreadBase)Thread.getThis()).isMainThread;

      Daemon.threadGroup = new ThreadGroup();

      // Reload the workers if the main executable is modified.
      if (isMainThread && config.autoReload)
      {
         (cast(ThreadGroup)Daemon.threadGroup).add(new Thread({

            import std.file : getTimes;

            SysTime ignored, creation;
            WorkerInfo.exePath.getTimes(ignored, creation);

            while(!exitRequested)
            {
               Thread.sleep(1.seconds);

               SysTime _, check;
               WorkerInfo.exePath.getTimes(_, check);

               if (creation != check)
               {
                  creation = check;
                  Daemon.reload();
               }
            }

         }).start());
      }

      if (!isMainThread)
      {
         (cast(ThreadGroup)Daemon.threadGroup).add(Thread.getThis());
      }

      // Multi-process daemon: spawn additional daemon processes on first entry
      // Only the main process (not child daemons) should spawn additional processes
      const bool isChildDaemon = environment.get("SERVERINO_DAEMON_CHILD") == "1";

      if (isMainThread && config.daemonInstances > 1 && !multiProcessStarted && !isChildDaemon)
      {
         multiProcessStarted = true;

         foreach(idx; 1 .. config.daemonInstances)
         {
            import std.process : spawnProcess, Config;
            import std.range : repeat;
            import std.array : array;

            auto env = environment.toAA.dup;
            env["SERVERINO_DAEMON_CHILD"] = "1";
            env["SERVERINO_DAEMON_INDEX"] = idx.to!string;

            version(Posix) const pname = [WorkerInfo.exePath, cast(char[])(' '.repeat(30).array)];
            else const pname = WorkerInfo.exePath;

            auto pid = spawnProcess(pname, env, Config.detached);
            childDaemonPids ~= pid.processID;
         }
      }
      // isMainThread already computed above

      auto processType = isChildDaemon ? "child" : (isMainThread ? "main" : "secondary");
      info("Daemon started. [backend=", cast(string)(Backend), "; process=", processType, "]");
      now = CoarseTime.currTime;

      version(Posix)
      {
         if (isMainThread)
         {
            import core.sys.posix.signal;
            sigaction_t act = { sa_handler: &serverino_exit_handler };
            sigaction(SIGINT, &act, null);
            sigaction(SIGTERM, &act, null);

            sigaction_t act_reload = { sa_handler: &serverino_reload_handler };
            sigaction(SIGUSR1, &act_reload, null);

            version(serverino_enable_https)
            {
               import core.sys.posix.signal : SIGHUP;
               sigaction_t act_reload_certs = { sa_handler: &serverino_reload_certificates_handler };
               sigaction(SIGHUP, &act_reload_certs, null);
            }

            sigaction_t act_ignore = { sa_handler: SIG_IGN };
            sigaction(SIGPIPE, &act_ignore, null);
         }
         else
         {
            // OpenSSL uses write(): a closed client must not kill the application
            import core.sys.posix.signal : sigset_t, sigemptyset, sigaddset, pthread_sigmask, SIG_BLOCK, SIGPIPE;

            sigset_t set;
            sigemptyset(&set);
            sigaddset(&set, SIGPIPE);
            pthread_sigmask(SIG_BLOCK, &set, null);
         }
      }

      if (isMainThread) tryInit!Modules();

      static if (serverino.common.Backend == BackendType.EPOLL) epoll = epoll_create1(0);
      else static if (serverino.common.Backend == BackendType.KQUEUE)
      {
         kq = kqueue();
         if (kq == -1)
         {
            import std.experimental.logger : critical;
            critical("Failed to create kqueue. Is kqueue available?");
            assert(false, "Failed to create kqueue. Is kqueue available?");
         }
         changeList.length = 2048;
         changes = 0;
      }

      // Starting all the listeners (thread-local copies).
      Listener[] threadListeners;
      threadListeners.reserve(config.listeners.length);

      version(serverino_enable_https)
      {
         // Listeners sharing the same certificates share one context.
         // (addListener!BOTH builds two listeners out of a single call)
         TlsContext[string] tlsContexts;
         import core.atomic : atomicLoad;
         uint appliedCertificatesGeneration = atomicLoad(certificatesGeneration);
      }

      foreach(orig; config.listeners)
      {
         auto listener = new Listener(orig.index, orig.address, orig.certificates);
         listener.config = config;

         version(serverino_enable_https)
         {
            if (orig.certificates.length > 0)
            {
               immutable key = tlsContextKey(orig.certificates);

               if (auto cached = key in tlsContexts) listener.tlsContext = *cached;
               else
               {
                  auto ctx = new TlsContext(orig.certificates);

                  if (!ctx.isValid)
                  {
                     import std.experimental.logger : critical;
                     import core.stdc.stdlib : exit, EXIT_FAILURE;
                     critical("Cannot load any valid certificate for ", orig.address.toString, ". Refusing to serve it in clear.");
                     exit(EXIT_FAILURE);
                  }

                  if (ctx.invalidCount > 0)
                     warning("TLS: ", ctx.invalidCount, " certificate(s) not loaded for ", orig.address.toString);

                  tlsContexts[key] = ctx;
                  listener.tlsContext = ctx;
               }
            }
         }

         listener.socket = new TcpSocket(listener.address.addressFamily);

         // Windows lets child processes inherit handles: a worker would keep the port
         // busy, even after the daemon is gone.
         version(Windows)
         {
            import core.sys.windows.winbase : SetHandleInformation, HANDLE_FLAG_INHERIT;
            import core.sys.windows.windef : HANDLE;
            SetHandleInformation(cast(HANDLE) listener.socket.handle, HANDLE_FLAG_INHERIT, 0);
         }
         listener.socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

         if (listener.socket.addressFamily == AddressFamily.INET6)
            listener.socket.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);

         version(Posix) listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

         // Extra listener tuning for multi-process daemons (POSIX)
         version(Posix)
         {
            // FreeBSD: prefer SO_REUSEPORT_LB if available for better load balancing
            version(FreeBSD)
            {
               import core.sys.freebsd.sys.socket : SO_REUSEPORT_LB;

               if (config.daemonInstances > 1)
                  listener.socket.setOption(SocketOptionLevel.SOCKET, cast(SocketOption)SO_REUSEPORT_LB, true);
            }
            else
            {
               import core.sys.posix.sys.socket : SO_REUSEPORT;

               // Always enable SO_REUSEPORT with multi-process daemons for load balancing
               if (config.daemonInstances > 1)
                  listener.socket.setOption(SocketOptionLevel.SOCKET, cast(SocketOption)SO_REUSEPORT, true);

            }
         }

         try
         {
            listener.socket.bind(listener.address);

            // Reduce handshake and wakeups on Linux listeners
            version(linux)
            {
               listener.socket.setOption(SocketOptionLevel.TCP, cast(SocketOption)23, config.listenerBacklog);
               listener.socket.setOption(SocketOptionLevel.TCP, cast(SocketOption)9, true);
            }

            listener.socket.listen(config.listenerBacklog);
            version(serverino_enable_https)
            {
               if (listener.tlsContext !is null) info("Listening on https://%s/".format(listener.socket.localAddress.toString));
               else info("Listening on http://%s/".format(listener.socket.localAddress.toString));
            }
            else info("Listening on http://%s/".format(listener.socket.localAddress.toString));
         }
         catch (SocketException se)
         {
            import std.experimental.logger : critical;
            import core.stdc.stdlib : exit, EXIT_FAILURE;
            import std.stdio : stderr;

            string msg = "Can't listen on %s. %s".format(listener.address.toString, se.msg);

            version(Posix)
            {
               import std.process : execute;
               import std.string : replace, split, chomp;
               import std.file : exists, readText;
               import std.string : startsWith;

               // Try to find the PID of the process using fuser
               if (exists("/usr/bin/fuser")) {

                  string port = listener.address.toPortString ~ "/tcp";
                  auto pid = execute(["/usr/bin/fuser", port]).output
                     .chomp
                     .replace(' ', '\n')
                     .split('\n');

                  if (pid.length > 1 && pid[$-1].length > 0 && pid[0].startsWith(port))
                  {
                     string cmdLine = "?";

                     if (exists("/proc/" ~ pid[$-1] ~ "/cmdline"))
                        cmdLine = readText("/proc/" ~ pid[$-1] ~ "/cmdline");

                     msg = "Can't listen on %s. This address is already in use by `%s` (PID: %s).".format(listener.address.toString, cmdLine, pid[$-1]);
                  }
               }
            }

            critical(msg);

            foreach(ref l; threadListeners)
            {
               if (l.socket !is null)
               {
                  l.socket.shutdown(SocketShutdown.BOTH);
               }
            }

            exit(EXIT_FAILURE);
         }

         static if (serverino.common.Backend == BackendType.EPOLL)
            epollAddSocket(listener.socket.handle, EPOLLIN, cast(void*)listener);
         else static if (serverino.common.Backend == BackendType.KQUEUE)
            Daemon.addKqueueChange(listener.socket.handle, EVFILT_READ, EV_ADD | EV_ENABLE, cast(void*)listener);

         threadListeners ~= listener;
      }

      ThreadBase mainThread;
      // Search for the main thread (may not be used in background mode)
      foreach(ref t; Thread.getAll())
      {
         if (t.isMainThread)
         {
            mainThread = t;
            break;
         }
      }
      startAgain:

      WorkerInfo.backlogDepth = config.workerBacklog;

      // Create all workers and start the ones that are required.
      foreach(i; 0..config.maxWorkers)
      {
         auto worker = new WorkerInfo();

         if (i < config.minWorkers)
            worker.reinit(WorkerInfo.Type.STATIC);
      }

      foreach(idx; 0..512)
         new Communicator(config);

      static if (serverino.common.Backend == BackendType.SELECT)
      {
         // We use a socketset to check for updates
         SocketSet ssRead = new SocketSet(threadListeners.length + WorkerInfo.instances.length);
         SocketSet ssWrite = new SocketSet(128);
      }

      ready = true;

      while(!exitRequested)
      {

         // We have to reset and fill the socketSet every time!
         static if (serverino.common.Backend == BackendType.SELECT)
         {
            ssRead.reset();
            ssWrite.reset();

            // Fill socketSet with listeners, waiting for new connections.
            foreach(ref listener; threadListeners)
               ssRead.add(listener.socket);

            // Fill socketSet with workers, waiting updates.
            foreach(ref worker; WorkerInfo.alive)
               ssRead.add(worker.unixSocket);

            // Fill socketSet with communicators, waiting for updates.
            for(auto communicator = Communicator.alives; communicator !is null; communicator = communicator.next )
            {
               if (communicator.worker is null)
                  ssRead.add(communicator.clientSkt);

               if (!communicator.completed)
                  ssWrite.add(communicator.clientSkt);
            }

            long updates = -1;
            try { updates = Socket.select(ssRead, ssWrite, null, 1.seconds); }
            catch (SocketException se) {
               import std.experimental.logger : warning;
               warning("Exception: ", se.msg);
               updates = 0;
            }
         }
         else static if (serverino.common.Backend == BackendType.EPOLL)
         {
            enum MAX_EPOLL_EVENTS = 1500;
            epoll_event[MAX_EPOLL_EVENTS] events = void;
            long updates = epoll_wait(epoll, events.ptr, MAX_EPOLL_EVENTS, 1000);
         }
         else static if (serverino.common.Backend == BackendType.KQUEUE) {

            enum MAX_KQUEUE_EVENTS = 1500;
            kevent[MAX_KQUEUE_EVENTS] eventList = void;
            auto timeout = timespec(1, 0);
            int updates = kevent_f(kq, changeList.ptr, cast(int)changes, eventList.ptr, cast(int)MAX_KQUEUE_EVENTS, &timeout);
            changes = 0;
         }

         now = CoarseTime.currTime;

         // MACOS-HANDOFF: experimental, trying to fix the intermittent websocket failure on macOS CI.
         // Here and not later: a wait that times out skips the rest of the loop.
         version(Posix) if (pendingHandoffs.length > 0) checkPendingHandoffs();

         // Some sanity checks. We don't want to check too often.
         {
            static CoarseTime lastCheck = CoarseTime.zero;

            if (now-lastCheck >= 1.seconds)
            {
               lastCheck = now;

               version(Posix) { }
               else {
                  if (!exists(canaryFileName))
                     Daemon.reloadRequested = true;
               }

               // Certificates changed on disk: rebuild the contexts of this thread's listeners.
               version(serverino_enable_https)
               {
                  import core.atomic : atomicLoad;
                  immutable generation = atomicLoad(Daemon.certificatesGeneration);

                  if (generation != appliedCertificatesGeneration)
                  {
                     appliedCertificatesGeneration = generation;

                     TlsContext[string] rebuilt;

                     foreach(ref listener; threadListeners)
                     {
                        if (listener.certificates.length == 0) continue;

                        immutable key = tlsContextKey(listener.certificates);

                        if (auto cached = key in rebuilt) listener.tlsContext = *cached;
                        else
                        {
                           auto ctx = new TlsContext(listener.certificates);

                           if (!ctx.isValid)
                           {
                              // Never leave a https listener without certificates: keep the old ones.
                              error("TLS reload failed for ", listener.address.toString, ". Keeping the previous certificates.");
                              ctx.retire();
                              continue;
                           }

                           rebuilt[key] = ctx;
                           listener.tlsContext = ctx;
                        }
                     }

                     if (rebuilt.length > 0)
                     {
                        // Retire the contexts nobody uses anymore. They are freed as soon
                        // as the last connection built on them is gone.
                        foreach(oldContext; tlsContexts.byValue)
                        {
                           bool stillInUse = false;
                           foreach(newContext; rebuilt.byValue)
                              if (newContext is oldContext) stillInUse = true;

                           if (!stillInUse) oldContext.retire();
                        }

                        tlsContexts = rebuilt;
                        info("TLS certificates reloaded.");
                     }
                  }
               }

               // If a reload is requested we restart all the workers (not the running ones)
               if (Daemon.reloadRequested)
               {
                  Daemon.reloadRequested = false;
                  foreach(ref worker; WorkerInfo.instances)
                  {
                     if (worker.status == WorkerInfo.State.PROCESSING) worker.reloadRequested = true;
                     else if (worker.status == WorkerInfo.State.IDLING)
                     {
                        log("Killing worker " ~ worker.pi.id.to!string  ~ ". [REASON: reloading]");
                        worker.pi.kill();
                        worker.setStatus(WorkerInfo.State.STOPPED);
                     }
                  }
                  if (isMainThread) writeCanary();
               }

               // Kill workers that are in an invalid state (unlikely to happen but better to check)
               foreach(worker; WorkerInfo.alive)
               {
                  if (!worker.unixSocket.isAlive)
                  {
                     warning("Killing worker " ~ worker.pi.id.to!string  ~ ". [REASON: invalid state]");
                     worker.pi.kill();
                     worker.setStatus(WorkerInfo.State.STOPPED);
                  }
               }

               // Check various timeouts.
               for(auto communicator = Communicator.alives; communicator !is null; communicator = communicator.next )
               {
                  // Keep-alive timeout hit.
                  if (communicator.status == Communicator.State.KEEP_ALIVE && communicator.worker is null && communicator.lastRequest != CoarseTime.zero && now - communicator.lastRequest > config.keepAliveTimeout)
                     communicator.reset();

                  // Http timeout hit.
                  else if (communicator.status == Communicator.State.PAIRED || communicator.status == Communicator.State.READING_BODY || communicator.status == Communicator.State.READING_HEADERS )
                  {
                     if (communicator.lastRecv != CoarseTime.zero && now - communicator.lastRecv > config.maxHttpWaiting)
                     {
                        if (communicator.requestDataReceived)
                        {
                           debug warning("Connection closed. [REASON: http timeout]");
                           communicator.clientSkt.send("HTTP/1.0 408 Request Timeout\r\n\r\n");
                        }
                        communicator.reset();
                     }
                  }
               }

            }

            // NOTE: Kill communicators that are not alive anymore?
         }

         if (updates < 0 || exitRequested || suspended)
         {
            if (suspended) break;

            // Retry if wait was interrupted by a signal.
            import core.stdc.errno : errno, EINTR;
            if (updates < 0 && errno == EINTR) continue;

            // If not, exit.
            if (isMainThread) removeCanary();
            break;
         }
         else if (updates == 0)
         {
            // In background mode we don't depend on main thread liveness
            if (isMainThread && mainThread !is null && !mainThread.isRunning)
               exitRequested = true;

            continue;
         }
         // ------------------------
         // Select version main loop
         // ------------------------

         static if (serverino.common.Backend == BackendType.SELECT)
         {
            // Check the workers for updates
            foreach(ref worker; WorkerInfo.alive)
            {
               if (updates == 0)
                  break;

               if (ssRead.isSet(worker.unixSocket))
               {
                  --updates;
                  worker.onReadAvailable();
               }
            }

            // Check the communicators for updates
            for(auto communicator = Communicator.alives; communicator !is null;)
            {
               auto next = communicator.next;
               scope(exit) communicator = next;

               if(communicator.clientSkt is null)
                  continue;

               immutable isWriteSet = ssWrite.isSet(communicator.clientSkt);


               if (ssRead.isSet(communicator.clientSkt))
               {
                  updates--;
                  communicator.onReadAvailable();

                  if (updates == 0)
                     break;
               }

               if (isWriteSet)
               {
                  updates--;

                  if (communicator.clientSkt !is null)
                     communicator.onWriteAvailable();

                  if (updates == 0)
                     break;
               }
            }

            // Check for new incoming connections.
            foreach(ref listener; threadListeners)
            {
               if (updates == 0)
                  break;

               if (ssRead.isSet(listener.socket))
               {
                  updates--;
                  listener.onConnectionAvailable();
               }
            }
         }

         // ------------------------
         // epoll version main loop
         // ------------------------

         else static if (serverino.common.Backend == BackendType.EPOLL)
         {
            foreach(ref epoll_event e; events[0..updates])
            {
               Object o = cast(Object) e.data.ptr;

               Communicator communicator = cast(Communicator)(o);
               if (communicator !is null)
               {
                  if (communicator.clientSkt !is null && (e.events & EPOLLIN) > 0)
                     communicator.onReadAvailable();

                  if (communicator.clientSkt !is null && (e.events & EPOLLOUT) > 0)
                     communicator.onWriteAvailable();

                  continue;
               }

               WorkerInfo worker = cast(WorkerInfo)(o);
               if (worker !is null)
               {
                  worker.onReadAvailable();
                  continue;
               }

               Listener listener = cast(Listener)(o);
               if (listener !is null)
               {
                  listener.onConnectionAvailable();
                  continue;
               }

            }
         }

         // ------------------------
         // Kqueue version main loop
         // ------------------------

         else static if (serverino.common.Backend == BackendType.KQUEUE) {

            foreach(ref kevent e; eventList[0..updates])
            {

               Object o = cast(Object)(cast(void*) e.udata);

               Communicator communicator = cast(Communicator)(o);
               if (communicator !is null)
               {
                  if (communicator.clientSkt !is null && (e.filter == EVFILT_READ))
                     communicator.onReadAvailable();

                  if (communicator.clientSkt !is null && (e.filter == EVFILT_WRITE))
                     communicator.onWriteAvailable();

                  continue;
               }

               WorkerInfo worker = cast(WorkerInfo)(o);
               if (worker !is null)
               {
                  worker.onReadAvailable();
                  continue;
               }

               Listener listener = cast(Listener)(o);
               if (listener !is null)
               {
                  listener.onConnectionAvailable();
                  continue;
               }
            }
         }

         // Check if we have some free workers and some waiting communicators.
         if (Communicator.execWaitingListFront !is null)
         {
            auto availableWorkers = WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.IDLING);
            while(!availableWorkers.empty && Communicator.execWaitingListFront !is null)
            {
               auto communicator = Communicator.popFromWaitingList();

               assert(communicator.requestToProcess !is null);

               communicator.setWorker(availableWorkers.front);
               availableWorkers.popFront;
            }
         }

         // Check if we have some dead workers to start and some waiting communicators.
         if (Communicator.execWaitingListFront !is null)
         {
            auto deadWorkers = WorkerInfo.dead();
            while(!deadWorkers.empty && Communicator.execWaitingListFront !is null)
            {
               auto communicator = Communicator.popFromWaitingList();

               assert(communicator.requestToProcess !is null);

               deadWorkers.front.reinit(WorkerInfo.Type.DYNAMIC);
               communicator.setWorker(deadWorkers.front);
               deadWorkers.popFront;
            }
         }

         // Last resort: queue the request behind a busy worker. A queued request waits
         // for the ones in front of it, so idle workers and workers to start come first.
         if (config.workerBacklog > 0 && Communicator.execWaitingListFront !is null)
         {
            while(Communicator.execWaitingListFront !is null)
            {
               auto front = Communicator.execWaitingListFront;

               assert(front.requestToProcess !is null);
               immutable size = front.requestToProcess.data.length;

               // The least loaded busy worker with room for it. Nobody? It waits, and so do
               // the ones behind it: they must not overtake it.
               WorkerInfo best = null;
               foreach(w; WorkerInfo.instances)
                  if (w.canQueue(size) && (best is null || w.backlogCount < best.backlogCount))
                     best = w;

               if (best is null) break;

               Communicator.popFromWaitingList();
               front.setWorker(best);
            }
         }
      }

      if (suspended)
      {
         // Stop all the workers.
         foreach(ref worker; WorkerInfo.alive)
            worker.setStatus(WorkerInfo.State.STOPPED);

         info("Daemon suspended. All workers stopped.");

         // Wait until serverino is resumed or the main thread is stopped.
         while(suspended && !exitRequested)
         {
            if (!mainThread.isRunning)
            {
               exitRequested = true;
               break;
            }

            Thread.sleep(1.seconds);
         }

         // If the daemon is resumed, we start again.
         if(!exitRequested)
         {
            log("Daemon resumed.");
            goto startAgain;
         }
      }

      // Exit requested, shutdown everything.
      // ----------------------------------

      // Close all the listeners.
      foreach(ref listener; threadListeners)
      {
         listener.socket.shutdown(SocketShutdown.BOTH);
         listener.socket.close();
      }

      // MACOS-HANDOFF: experimental, trying to fix the intermittent websocket failure on macOS CI.
      version(Posix) checkPendingHandoffs(true);

      // Kill all the workers and release what they own right now, while this thread
      // is still alive and the kqueue/epoll descriptors are still valid. Leaving it
      // to the GC means doing it from a finalizer at process teardown, which is not
      // allowed to touch any of it. (see the note on WorkerInfo)
      foreach(ref worker; WorkerInfo.instances)
      {
         try
         {
            if (worker is null) continue;

            if (worker.unixSocket) worker.unixSocket.shutdown(SocketShutdown.BOTH);
            if (worker.pi) worker.pi.kill();

            // Straight to the field: setStatus() would try to restart a static worker.
            worker.status = WorkerInfo.State.STOPPED;
            worker.clear();
         }
         catch (Exception e) { }
      }

      WorkerInfo.instances = null;

      info("Daemon shutdown completed. Goodbye!");

      // Terminate all child daemon processes (fallback for non-Linux or if PDEATHSIG didn't trigger)
      version(Posix)
      {
         if (!isChildDaemon)
         {
            import core.sys.posix.signal : kill, SIGINT, SIGKILL;
            import std.datetime : msecs;

            foreach (pid; childDaemonPids)
            {
               kill(pid, SIGINT);
               Thread.yield();
            }
         }
      }

      // Call the onDaemonStop functions.
      if (isMainThread) tryUninit!Modules();

      // Delete the canary file.
      if (isMainThread) removeCanary();


      // Flush the output buffers.
      import std.stdio : stdout, stderr;
      stdout.flush();
      stderr.flush();

      import std.datetime : msecs;
      Thread.sleep(100.msecs);

      isDaemonRunning = false;
   }

   static if (serverino.common.Backend == BackendType.EPOLL)
   {
      import std.socket : socket_t;

      void epollAddSocket(socket_t s, int events, void* ptr)
      {
         epoll_event evt;
         evt.events = events;
         evt.data.ptr = ptr;

         auto res = epoll_ctl(epoll, EPOLL_CTL_ADD, s, &evt);
         assert(res == 0);
      }

      void epollRemoveSocket(socket_t s)
      {
         epoll_ctl(epoll, EPOLL_CTL_DEL, s, null);
      }

      void epollEditSocket(socket_t s, int events, void* ptr)
      {
         epoll_event evt;
         evt.events = events;
         evt.data.ptr = ptr;

         auto res = epoll_ctl(epoll, EPOLL_CTL_MOD, s, &evt);
         assert(res == 0);
      }

      int epoll;
   }
   else static if (serverino.common.Backend == BackendType.KQUEUE) {

      import serverino.databuffer;

      void addKqueueChange(socket_t s, short filter, ushort flags, void* udata)
      {
         auto change = &changeList[changes];
         change.ident = s;
         change.filter = filter;
         change.flags = flags;
         change.udata = udata;

         changes++;

         if (changes >= changeList.length)
         {
            kevent_f(kq, changeList.ptr, cast(int)changes, null, 0, null);
            changes = 0;
         }
      }

      private __gshared
      {
         int kq;
         size_t      changes = 0;
         kevent[]    changeList;
      }
   }

   private __gshared
   {
      string[string] workerEnvironment;
      int workerEnvInit = 0;
   }

   private
   {
      static shared bool exitRequested   = false;
      static shared bool reloadRequested = false;
      static shared bool ready           = false;
      static shared bool bootFailure     = false;
      static shared string bootErrorMessage = null;
      static shared bool suspended       = false;
      static shared bool isDaemonRunning = false;

      static shared ThreadGroup threadGroup = null;

      static shared int[] childDaemonPids;
      static bool multiProcessStarted = false;

   package:
      version(serverino_enable_https) static shared uint certificatesGeneration = 0;
   }

}


void tryInit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onDaemonStart))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onDaemonStart but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onDaemonStart but it is not callable");

      }}
   }
}

void tryUninit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onDaemonStop))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onDaemonStop but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onDaemonStop but it is not callable");

      }}
   }
}

// Time is cached to avoid calling CoarseTime.currTime too many times.
package __gshared CoarseTime now;

// MACOS-HANDOFF: experimental, trying to fix the intermittent websocket failure on macOS CI.
// Everything in this version(Posix) block belongs to it.
version(Posix)
{
   /+ A socket passed to a websocket process through SCM_RIGHTS stays open here until
    + the process has taken it. If we close it while it's still in flight, the message
    + is its only reference and macOS can discard it: the websocket reads EOF and the
    + client gets a RST. The websocket process closes the channel once it has the socket
    + and the headers, so EOF on the channel means the handoff is done.
    +/
   private struct PendingHandoff
   {
      socket_t    client;
      Socket      channel;
      CoarseTime  deadline;
   }

   // One list for each daemon thread: every thread runs its own loop.
   private PendingHandoff[] pendingHandoffs;

   private void addPendingHandoff(socket_t client, Socket channel)
   {
      import std.datetime : seconds;

      channel.blocking = false;
      pendingHandoffs ~= PendingHandoff(client, channel, now + 5.seconds);
   }

   private void checkPendingHandoffs(bool closeAll = false)
   {
      import std.socket : wouldHaveBlocked;
      import core.stdc.errno : errno, EINTR;
      import core.sys.posix.unistd : close;

      size_t i = 0;
      while (i < pendingHandoffs.length)
      {
         auto h = &pendingHandoffs[i];

         bool done = closeAll || now >= h.deadline;

         if (!done)
         {
            ubyte[1] data;
            auto received = h.channel.receive(data);

            // EOF or a real error. Anything else means the websocket is not done yet.
            done = received == 0 || (received < 0 && !wouldHaveBlocked && errno != EINTR);
         }

         if (!done)
         {
            ++i;
            continue;
         }

         close(h.client);
         h.channel.shutdown(SocketShutdown.BOTH);
         h.channel.close();

         pendingHandoffs[i] = pendingHandoffs[$-1];
         pendingHandoffs.length--;
         pendingHandoffs.assumeSafeAppend();
      }
   }
}