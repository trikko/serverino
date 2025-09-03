/*
Copyright (c) 2023-2025 Andrea Fontana

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

import std.stdio : File;
import std.conv : to;
import std.experimental.logger : log, info, warning;
import std.process : ProcessPipes;

import std.format : format;
import std.socket : Socket, SocketSet, SocketType, AddressFamily, SocketShutdown, TcpSocket, SocketOption, SocketOptionLevel, SocketException, socket_t;
import std.algorithm : filter;
import std.datetime : SysTime, Clock, seconds;

import core.thread : ThreadBase, Thread;

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

      accepted.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDBUF, 64*1024);
      accepted.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, 64*1024);

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

   ~this()
   {
      if (status != State.STOPPED)
         setStatus(State.STOPPED);

      clear();
   }

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
      }

      communicator = null;
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
      if (communicator is null)
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
         if (communicator.responseLength == 0)
         {
            WorkerPayload *wp = cast(WorkerPayload*)buffer.ptr;
            auto data = cast(char[])buffer[WorkerPayload.sizeof..bytes];

            if (wp.flags & WorkerPayload.Flags.DAEMON_SHUTDOWN) Daemon.shutdown();
            else if (wp.flags & WorkerPayload.Flags.DAEMON_SUSPEND) Daemon.suspend();

            version(disable_websockets)
            {
               // Nothing to do here.
            }
            else static if(__VERSION__ < 2102)
            {
               pragma(msg, "-----------------------------------------------------------------------------------");
               pragma(msg, "Warning: DMD 2.102 or later is required to use the websocket feature.");
               pragma(msg, "Please upgrade your DMD compiler or build using `disable_websockets` version/config");
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
                  auto toSend = communicator.clientSkt.release();

                  // We must remove the socket from the epoll/kqueue before sending it to the websocket.
                  static if (serverino.common.Backend == BackendType.EPOLL) Daemon.epollRemoveSocket(toSend);
                  else static if (serverino.common.Backend == BackendType.KQUEUE)
                  {
                     Daemon.addKqueueChange(toSend, EVFILT_READ, EV_DELETE | EV_DISABLE, null);
                     Daemon.addKqueueChange(toSend, EVFILT_WRITE, EV_DELETE | EV_DISABLE, null);
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
                  }
                  else
                  {
                     // Send address family (AF_INET or AF_INET6)
                     ushort[1] addressFamily = [cast(ushort)communicator.clientSkt.addressFamily];
                     webs.send(addressFamily);

                     // Send worker http upgrade response
                     webs.send(hdrs);

                     version(Posix)
                     {
                        import core.sys.posix.unistd : close;
                        close(toSend);
                     }
                  }

                  communicator.reset();
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
         else communicator.write(cast(char[])buffer[0..bytes]);
      }
      else if (bytes == 0)
      {
         // User closed socket.
         communicator.reset();
         setStatus(WorkerInfo.State.STOPPED);
      }
      else
      {
         debug warning("Worker #" ~ pi.id.to!string  ~ " exited/terminated/killed (socket error).");
         communicator.reset();
         setStatus(WorkerInfo.State.STOPPED);
      }

   }
   // A lazy list of busy workers.
   pragma(inline, true)
   static auto ref alive() { return WorkerInfo.instances.filter!(x => x.status != WorkerInfo.State.STOPPED); }

   // A lazy list of workers we can reuse.
   pragma(inline, true)
   static auto ref dead() { return WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.STOPPED); }

   private shared static this() { exePath = thisExePathWithFallback(); }

package:

   Socket                  listener;
   ProcessInfo             pi;

   CoarseTime              statusChangedAt;

   State                   status            = State.STOPPED;
   Socket                  unixSocket        = null;
   socket_t                unixSocketHandle  = socket_t.max;

   Communicator            communicator      = null;
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
   }
}

// The Daemon class is the core of serverino.
struct Daemon
{

static:

   /// Is serverino ready to accept requests?
   bool bootCompleted() @safe @nogc nothrow { return ready; }

   /// Reload all workers
   void reload() @safe @nogc nothrow { reloadRequested = true; }

   /// Shutdown the serverino daemon.
   void shutdown() {
      exitRequested = true;

      if (daemonThread is null)
         return;

      if (Thread.getThis() !is cast(ThreadBase)daemonThread)
         (cast(ThreadBase)daemonThread).join();
   }

   /// Suspend the daemon.
   void suspend() @safe @nogc nothrow { suspended = true; }

   /// Resume the daemon.
   void resume()  @safe @nogc nothrow { suspended = false; }

   /// Check if the daemon is running.
   bool isRunning() @nogc nothrow
   {
      if (daemonThread is null) return true;
      else return !suspended && !exitRequested;
   }

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
      immutable argsBkp = Base64.encode(Runtime.args.join("\0").representation);

      environment["SERVERINO_COMPONENT"] = "D";

      version(Posix)
      {
         auto base = baseName(Runtime.args[0]);

         setProcessName
         (
            [
               base ~ " / daemon [PID: " ~ daemonPid ~ "]",
               base ~ " / daemon",
               base ~ " [D]"
            ]
         );
      }

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

      // Reload the workers if the main executable is modified.
      if (config.autoReload)
      {
         new Thread({

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

         }).start();
      }

      cast(ThreadBase)daemonThread = Thread.getThis();
      bool isMainThread = (cast(ThreadBase)daemonThread).isMainThread;

      info("Daemon started. [backend=", cast(string)(Backend), "; thread=", isMainThread ? "main" : "secondary", "]");
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
         }
      }

      tryInit!Modules();

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

      // Starting all the listeners.
      foreach(ref listener; config.listeners)
      {
         listener.config = config;

         listener.socket = new TcpSocket(listener.address.addressFamily);
         listener.socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);

         if (listener.socket.addressFamily == AddressFamily.INET6)
            listener.socket.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);

         version(Posix) listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

         // Extra listener tuning on Linux
         version(linux)
         {
            import core.sys.posix.sys.socket : SO_REUSEPORT;
            listener.socket.setOption(SocketOptionLevel.SOCKET, cast(SocketOption)SO_REUSEPORT, true);
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
            info("Listening on http://%s/".format(listener.socket.localAddress.toString));
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

            foreach(ref l; config.listeners)
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
      }

      ThreadBase mainThread;

      // Search for the main thread.
      foreach(ref t; Thread.getAll())
      {
         if (t.isMainThread)
         {
            mainThread = t;
            break;
         }
      }

      assert(mainThread !is null, "Main thread not found");
      startAgain:

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
         SocketSet ssRead = new SocketSet(config.listeners.length + WorkerInfo.instances.length);
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
            foreach(ref listener; config.listeners)
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

                  writeCanary();
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
                  if (communicator.status == Communicator.State.KEEP_ALIVE && communicator.worker is null && communicator.lastRequest != CoarseTime.zero && now - communicator.lastRequest > 5.seconds)
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
            removeCanary();
            break;
         }
         else if (updates == 0)
         {
            if (!mainThread.isRunning)
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
            foreach(ref listener; config.listeners)
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
      foreach(ref listener; config.listeners)
      {
         listener.socket.shutdown(SocketShutdown.BOTH);
         listener.socket.close();
      }

      // Kill all the workers.
      foreach(ref worker; WorkerInfo.alive)
      {
         try
         {
            if (worker)
            {
               if (worker.unixSocket) worker.unixSocket.shutdown(SocketShutdown.BOTH);
               if (worker.pi) worker.pi.kill();
            }
         }
         catch (Exception e) { }
      }

      // Call the onDaemonStop functions.
      tryUninit!Modules();

      // Delete the canary file.
      removeCanary();

      info("Daemon shutdown completed. Goodbye!");

      // Flush the output buffers.
      import std.stdio : stdout, stderr;
      stdout.flush();
      stderr.flush();

      if (isMainThread)
      {
         import core.stdc.stdlib : exit;
         exit(0);
      }
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
   }

   private
   {
      static shared bool exitRequested   = false;
      static shared bool reloadRequested = false;
      static shared bool ready           = false;
      static shared bool suspended       = false;

      static shared ThreadBase daemonThread = null;
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