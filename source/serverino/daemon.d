/*
Copyright (c) 2023-2024 Andrea Fontana

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
import std.socket;
import std.algorithm : filter;
import std.datetime : SysTime, Clock, seconds;


// The class WorkerInfo is used to keep track of the workers.
package class WorkerInfo
{
   enum State
   {
      IDLING = 0, // Worker is waiting for a request.
      PROCESSING, // Worker is processing a request.
      STOPPED     // Worker is stopped.
   }

   override string toString()
   {
      string s;
      s ~= "PID: " ~ pi.id.to!string ~ "\n";
      s ~= "ID: " ~ id.to!string ~ "\n";
      s ~= "STATE: " ~ status.to!string ~ "\n";
      s ~= "STATUS CHANGED AT: " ~ statusChangedAt.to!string ~ "\n";
      s ~= "RELOAD REQUESTED: " ~ reloadRequested.to!string ~ "\n";
      return s;
   }

   // New worker instances are set to STOPPED
   this()
   {
      this.id = instances.length;
      instances ~= this;

      status = State.STOPPED;
      statusChangedAt = now;
   }

   // Initialize the worker.
   void reinit(bool isDynamicWorker)
   {
      assert(status == State.STOPPED);

      // Set default status.
      clear();

      import std.process : pipeProcess, Redirect, Config;
      import std.uuid : randomUUID;

      // Create a new socket and bind it to a random address.
      auto uuid = randomUUID().toString();

      // We use a unix socket on both linux and macos/windows but ...
      version(linux)
      {
         string socketAddress = "SERVERINO_SOCKET/" ~ uuid;
         Socket s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
         s.bind(new UnixAddress("\0%s".format(socketAddress)));
      }
      else
      {
         // ... on windows and macos we use a temporary file.
         import std.path : buildPath;
         import std.file : tempDir;
         string socketAddress = buildPath(tempDir, uuid);
         Socket s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
         s.bind(new UnixAddress(socketAddress));
      }

      s.listen(1);

      // We start a new process and pass the socket address to it.
      auto env = Daemon.instance.workerEnvironment.dup;
      env["SERVERINO_SOCKET"] = socketAddress;
      env["SERVERINO_DYNAMIC_WORKER"] = isDynamicWorker?"1":"0";

      reloadRequested = false;
      auto pipes = pipeProcess(exePath, Redirect.stdin, env, Config.detached);

      Socket accepted = s.accept();
      this.pi = new ProcessInfo(pipes.pid.processID);
      this.unixSocket = accepted;

      // Wait for the worker to wake up.
      ubyte[1] data;
      accepted.receive(data);

      s.blocking = false;
      setStatus(WorkerInfo.State.IDLING);
   }

   ~this()
   {
      clear();
   }

   void clear()
   {
      assert(status == State.STOPPED);

      if (this.pi) this.pi.kill();

      if (this.unixSocket)
      {
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
      assert(s!=status || s == State.PROCESSING, id.to!string ~ " > Trying to change WorkerInfo status from " ~ status.to!string ~ " to " ~ s.to!string);
      status = s;
      statusChangedAt = now;
   }

   // A lazy list of busy workers.
   pragma(inline, true)
   static auto ref alive() { return WorkerInfo.instances.filter!(x => x.status != WorkerInfo.State.STOPPED); }

   // A lazy list of workers we can reuse.
   pragma(inline, true)
   static auto ref dead() { return WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.STOPPED); }

   private shared static this() { import std.file : thisExePath; exePath = thisExePath(); }

package:

   size_t                  id;
   ProcessInfo             pi;

   CoarseTime              statusChangedAt;

   State                   status            = State.STOPPED;
   Socket                  unixSocket        = null;
   Communicator            communicator      = null;
   bool                    reloadRequested   = false;

   static WorkerInfo[]   instances;
   static string         exePath;

}

version(Posix)
{
   extern(C) void serverino_exit_handler(int num) nothrow @nogc @system
   {
      import core.stdc.stdlib : exit;
      if (Daemon.exitRequested) exit(-1);
      else Daemon.exitRequested = true;
   }
}

// The Daemon class is the core of serverino.
struct Daemon
{

   /// Is serverino ready to accept requests?
   bool bootCompleted() { return ready; }

   /// The instance method returns the singleton instance of the Daemon class.
   static auto instance()
   {
      static Daemon* _instance;
      if (_instance is null) _instance = new Daemon();
      return _instance;
   }

   /// Shutdown the serverino daemon.
   void shutdown() @nogc nothrow { exitRequested = true; }

package:

   void wake(Modules...)(DaemonConfigPtr config)
   {
      import serverino.interfaces : Request;
      import std.process : environment, thisProcessID;
      import std.file : tempDir, exists, remove;
      import std.path : buildPath;
      import std.digest.sha : sha256Of;
      import std.digest : toHexString;
      import std.ascii : LetterCase;

      immutable daemonPid = thisProcessID.to!string;
      immutable canaryFileName = tempDir.buildPath("serverino-" ~ daemonPid ~ "-" ~ sha256Of(daemonPid).toHexString!(LetterCase.lower) ~ ".canary");

      workerEnvironment = environment.toAA();
      workerEnvironment["SERVERINO_DAEMON"] = daemonPid;
      workerEnvironment["SERVERINO_BUILD"] = Request.simpleNotSecureCompileTimeHash();

      void removeCanary() { remove(canaryFileName); }
      void writeCanary() { File(canaryFileName, "w").write("delete this file to reload serverino workers (process id: " ~ daemonPid ~ ")\n"); }

      writeCanary();
      scope(exit) removeCanary();

      info("Daemon started.");
      now = CoarseTime.currTime;

      version(Posix)
      {
         import core.sys.posix.signal;
         sigaction_t act = { sa_handler: &serverino_exit_handler };
	      sigaction(SIGINT, &act, null);
         sigaction(SIGTERM, &act, null);
      }
      else version(Windows) scope(exit) tryUninit!Modules();

      tryInit!Modules();

      // Starting all the listeners.
      foreach(ref listener; config.listeners)
      {
         listener.socket = new TcpSocket(listener.address.addressFamily);
         version(Windows) { } else { listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true); }

         try
         {
            listener.socket.bind(listener.address);
            listener.socket.listen(config.listenerBacklog);
            info("Listening on http://%s/".format(listener.socket.localAddress.toString));
         }
         catch (SocketException se)
         {
            import std.experimental.logger : critical;
            import core.stdc.stdlib : exit, EXIT_FAILURE;
            import std.stdio : stderr;

            critical("Can't listen on http://%s/. Are you allowed to listen on this port? Is port already used by another process?".format(listener.address.toString));

            foreach(ref l; config.listeners)
            {
               if (l.socket !is null)
               {
                  l.socket.shutdown(SocketShutdown.BOTH);
               }
            }

            exit(EXIT_FAILURE);
         }
      }

      // Workers
      foreach(i; 0..config.maxWorkers)
         new WorkerInfo();

      foreach(idx; 0..128)
         new Communicator(config);

      // We use a socketset to check for updates
      SocketSet ssRead = new SocketSet(config.listeners.length + WorkerInfo.instances.length);
      SocketSet ssWrite = new SocketSet(128);

      while(!exitRequested)
      {
         // Create workers if needed. Kills old workers, freezed ones, etc.
         checkWorkers(config);

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
            ssRead.add(communicator.clientSkt);

            if (!communicator.completed)
               ssWrite.add(communicator.clientSkt);
         }

         long updates = -1;
         try { updates = Socket.select(ssRead, ssWrite, null, 1.seconds); }
         catch (SocketException se) {
            import std.experimental.logger : warning;
            warning("Exception: ", se.msg);
         }

         // Check for timeouts.
         now = CoarseTime.currTime;
         {
            static CoarseTime lastCheck = CoarseTime.zero;

            if (now-lastCheck >= 1.seconds)
            {

               if (!exists(canaryFileName))
               {
                  reloadRequested = true;
                  writeCanary();
               }

               lastCheck = now;

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
                           communicator.clientSkt.send("HTTP/1.0 408 Request Timeout\r\n");
                        }
                        communicator.reset();
                     }
                  }
               }

            }

            // NOTE: Kill communicators that are not alive anymore?
         }

         if (updates < 0 || exitRequested)
         {
            removeCanary();
            break;
         }
         else if (updates == 0) continue;

         // Check the workers for updates
         foreach(ref worker; WorkerInfo.alive)
         {
            if (updates == 0)
               break;

            Communicator communicator = worker.communicator;

            if (ssRead.isSet(worker.unixSocket))
            {
               --updates;

               if (communicator is null)
               {
                  debug warning("Null communicator for worker " ~ worker.pi.id.to!string  ~ ". Was process killed?");
                  worker.pi.kill();
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  continue;
               }

               ubyte[32*1024] buffer;
               auto bytes = worker.unixSocket.receive(buffer);

               if (bytes == Socket.ERROR)
               {
                  debug warning("Socket error for worker " ~ worker.pi.id.to!string  ~ ". Was process killed?");
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  worker.clear();
                  communicator.reset();
               }
               else if (bytes == 0)
               {
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  worker.clear();

                  // User closed socket.
                  if (communicator.clientSkt !is null && communicator.clientSkt.isAlive)
                     communicator.clientSkt.shutdown(SocketShutdown.BOTH);
               }
               else
               {
                  if (communicator.responseLength == 0)
                  {
                     WorkerPayload *wp = cast(WorkerPayload*)buffer.ptr;

                     communicator.isKeepAlive = wp.isKeepAlive;
                     communicator.setResponseLength(wp.contentLength);
                     communicator.write(cast(char[])buffer[WorkerPayload.sizeof..bytes]);
                  }
                  else communicator.write(cast(char[])buffer[0..bytes]);
               }
            }
         }

         // Check the communicators for updates
         for(auto communicator = Communicator.alives; communicator !is null; communicator = communicator.next )
         {
            if(communicator.clientSkt is null)
               continue;

            if (ssRead.isSet(communicator.clientSkt))
            {
               updates--;
               communicator.lastRecv = now;
               communicator.read();
            }
            else if(communicator.hasQueuedRequests)
            {
               communicator.lastRecv = now;
               communicator.read(true);
            }

            if (updates > 0 && communicator.clientSkt !is null && ssWrite.isSet(communicator.clientSkt))
            {
               updates--;
               communicator.write();
            }
         }

         auto available = WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.IDLING);

         // Check for communicators that need a worker.
         for(auto communicator = Communicator.alives; communicator !is null; communicator = communicator.next)
         {
            // If the communicator hasn't a request to process (or it has already a worker assigned) we skip it.
            if (communicator.requestToProcess is null || !communicator.requestToProcess.isValid || communicator.worker !is null)
               continue;

            // If there are idling workers we assign one to the communicator.
            if (!available.empty)
            {
               communicator.setWorker(available.front);
               available.popFront;
            }
            else
            {
               // If we have a dead worker we can reinit it.
               // Probably we are over the minWorkers limit but below the maxWorkers limit.
               // Extra workers over the minWorkers limit are normally dead.
               auto dead = WorkerInfo.dead();

               if (!dead.empty)
               {
                  dead.front.reinit(true);
                  communicator.setWorker(dead.front);
               }
               else break; // All workers are busy. Will try again later.
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

               // We have an incoming connection to handle
               Communicator communicator;

               // First: check if any idling communicator is available
               auto dead = Communicator.deads;

               if (dead !is null) communicator = dead;
               else communicator = new Communicator(config);

               communicator.lastRecv = now;

               auto nextId = requestId++;
               communicator.setClientSocket(listener.socket.accept(), nextId);
            }
         }

      }

      // Exit requested, shutdown everything.

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

      // Force exit.
      import core.stdc.stdlib : exit;
      exit(0);
   }

private:

   void checkWorkers(DaemonConfigPtr config)
   {
      if (reloadRequested)
      {
         foreach(ref worker; WorkerInfo.instances)
         {
            if (worker.status != WorkerInfo.State.PROCESSING)
            {
               log("Killing worker " ~ worker.pi.id.to!string  ~ ". [REASON: reloading]");
               worker.pi.kill();
               worker.setStatus(WorkerInfo.State.STOPPED);
            }
            else worker.reloadRequested = true;
         }

         reloadRequested = false;
      }

      size_t workersAliveCnt = 0;

      foreach(worker; WorkerInfo.alive)
      {
         if (!worker.unixSocket.isAlive)
         {
            log("Killing worker " ~ worker.pi.id.to!string  ~ ". [REASON: invalid state]");
            worker.pi.kill();
            worker.setStatus(WorkerInfo.State.STOPPED);
         }
         else if (worker.reloadRequested && worker.status == WorkerInfo.State.IDLING)
         {
            log("Killing worker " ~ worker.pi.id.to!string  ~ ". [REASON: reloading]");
            worker.pi.kill();
            worker.setStatus(WorkerInfo.State.STOPPED);
         }
         else ++workersAliveCnt;
      }

      auto dead = WorkerInfo.dead();

      while (workersAliveCnt < config.minWorkers && !dead.empty)
      {
         dead.front.reinit(false);
         dead.popFront;
      }

      if (!ready) ready = true;

   }

   ulong          requestId = 0;
   string[string] workerEnvironment;

   __gshared bool reloadRequested = false;
   __gshared bool exitRequested = false;
   __gshared bool ready = false;
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
package CoarseTime now;