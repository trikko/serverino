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
import std.array : array;
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

   // New worker instances are set to STOPPED and added to the lookup table.
   this()
   {
      this.id = instances.length;
      instances ~= this;

      status = State.STOPPED;
      statusChangedAt = Clock.currTime();
      lookup[State.STOPPED].insertBack(id);
   }

   // Initialize the worker.
   void reinit()
   {
      assert(status == State.STOPPED);

      // Set default status.
      clear();

      import std.process : pipeProcess, Redirect, Config;
      import std.file : thisExePath;
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

      auto pipes = pipeProcess(thisExePath(), Redirect.stdin, env, Config.detached);

      Socket accepted = s.accept();
      s.blocking = false;

      this.pi = new ProcessInfo(pipes.pid.processID);
      this.unixSocket = accepted;

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

   void setStatus(State s)
   {
      import std.conv : to;
      assert(s!=status || s == State.PROCESSING, id.to!string ~ " > Trying to change WorkerInfo status from " ~ status.to!string ~ " to " ~ s.to!string);

      if (s!=status)
      {
         lookup[status].remove(id);
         lookup[s].insertBack(id);
      }

      status = s;
      statusChangedAt = Clock.currTime();
   }

package:

   size_t                  id;
   ProcessInfo             pi;

   SysTime                 statusChangedAt;

   State                   status      = State.STOPPED;
   Socket                  unixSocket     = null;
   Communicator            communicator = null;

   static WorkerInfo[]   instances;
   static SimpleList[3]  lookup;
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
   // Create a lazy list of busy workers.
   pragma(inline, true)
   auto ref workersAlive()
   {
      import std.range : chain;
      return chain(
         WorkerInfo.lookup[WorkerInfo.State.IDLING].asRange,
         WorkerInfo.lookup[WorkerInfo.State.PROCESSING].asRange
      );
   }

   // Create a lazy list of workers we can reuse.
   pragma(inline, true);
   auto ref workersDead()
   {
      return WorkerInfo.lookup[WorkerInfo.State.STOPPED].asRange;
   }


   void wake(Modules...)(DaemonConfigPtr config)
   {
      import serverino.interfaces : Request;
      import std.process : environment, thisProcessID;
      import std.stdio;

      workerEnvironment = environment.toAA();
      workerEnvironment["SERVERINO_DAEMON"] = thisProcessID.to!string;
      workerEnvironment["SERVERINO_BUILD"] = Request.simpleNotSecureCompileTimeHash();

      info("Daemon started.");

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
      import std.traits : EnumMembers;
      static foreach(e; EnumMembers!(WorkerInfo.State))
      {
         WorkerInfo.lookup[e] = SimpleList();
      }

      foreach(i; 0..config.maxWorkers)
         new WorkerInfo();

      Communicator.alive = SimpleList();
      Communicator.dead = SimpleList();

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
         foreach(idx; workersAlive)
            ssRead.add(WorkerInfo.instances[idx].unixSocket);

         // Fill socketSet with communicators, waiting for updates.
         foreach(idx; Communicator.alive.asRange)
         {
            ssRead.add(Communicator.instances[idx].clientSkt);

            if (!Communicator.instances[idx].completed)
               ssWrite.add(Communicator.instances[idx].clientSkt);
         }

         long updates = -1;
         try { updates = Socket.select(ssRead, ssWrite, null, 1.seconds); }
         catch (SocketException se) {
            import std.experimental.logger : warning;
            warning("Exception: ", se.msg);
         }

         // Check for timeouts.
         immutable now = CoarseTime.currTime;
         {
            static CoarseTime lastCheck = CoarseTime.zero;

            if (now-lastCheck >= 1.seconds)
            {
               lastCheck = now;

               // A list of communicators that hit the timeout.
               Communicator[] toReset;

               foreach(idx; Communicator.alive.asRange)
               {
                  auto communicator = Communicator.instances[idx];

                  // Keep-alive timeout hit.
                  if (communicator.status == Communicator.State.KEEP_ALIVE && communicator.lastRequest != CoarseTime.zero && now - communicator.lastRequest > 5.seconds)
                     toReset ~= communicator;

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
                        toReset ~= communicator;
                     }
                  }
               }

               // Reset the communicators that hit the timeout.
               foreach(communicator; toReset)
                  communicator.reset();

            }

            // Free dead communicators.
            if (Communicator.instances.length > 1024)
            foreach(communicator; Communicator.dead.asRange)
            {
               if (communicator + 1 == Communicator.instances.length && communicator > 128)
               {
                  Communicator.dead.remove(communicator);
                  Communicator.instances.length--;
                  break;
               }
            }
         }

         if (updates < 0) break;
         else if (updates == 0) continue;

         if (exitRequested)
            break;

         auto wa = workersAlive;
         size_t nextIdx;

         // Check the workers for updates
         while(!wa.empty)
         {
            if (updates == 0)
               break;

            auto idx = wa.front;
            wa.popFront;

            if (!wa.empty)
               nextIdx = wa.front;

            scope(exit) idx = nextIdx;

            WorkerInfo worker = WorkerInfo.instances[idx];
            Communicator communicator = worker.communicator;

            if (ssRead.isSet(worker.unixSocket))
            {
               updates--;

               if (communicator is null)
               {
                  worker.pi.kill();
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  continue;
               }

               ubyte[32*1024] buffer;
               auto bytes = worker.unixSocket.receive(buffer);

               if (bytes == Socket.ERROR)
               {
                  debug warning("Error: worker killed?");
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  worker.clear();
                  communicator.reset();
               }
               else if (bytes == 0)
               {
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  worker.clear();

                  // User closed socket.
                  if (communicator !is null && communicator.clientSkt !is null && communicator.clientSkt.isAlive)
                     communicator.clientSkt.shutdown(SocketShutdown.BOTH);
               }
               else
               {
                  if (communicator is null)
                  {
                     continue;
                  }
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
         foreach(idx; Communicator.alive.asRange)
         {
            auto communicator = Communicator.instances[idx];

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

         // Check for communicators that need a worker.
         foreach(ref communicator; Communicator.instances.filter!(x=>x.requestToProcess !is null && x.requestToProcess.isValid && x.worker is null))
         {
            auto workers = WorkerInfo.lookup[WorkerInfo.State.IDLING].asRange;


            if (!workers.empty) communicator.setWorker(WorkerInfo.instances[workers.front]);
            else {
               auto dead = workersDead();

               if (!dead.empty)
               {
                  WorkerInfo.instances[dead.front].reinit();
                  communicator.setWorker(WorkerInfo.instances[dead.front]);
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
               auto idling = Communicator.dead.asRange;

               if (!idling.empty) communicator = Communicator.instances[idling.front];
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
      foreach(ref idx; workersAlive)
      {
         WorkerInfo worker = WorkerInfo.instances[idx];

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
      foreach(k; workersAlive)
      {
         auto worker = WorkerInfo.instances[k];

         if (!worker.unixSocket.isAlive)
         {
            log("Killing ", worker.pi.id, ". Invalid state.");
            worker.pi.kill();
            worker.setStatus(WorkerInfo.State.STOPPED);
         }

      }

      while (
         WorkerInfo.lookup[WorkerInfo.State.IDLING].length +
         WorkerInfo.lookup[WorkerInfo.State.PROCESSING].length < config.minWorkers
      )
      {
         auto dead = workersDead();

         if (dead.empty)
            break;

         auto idx = dead.front();
         WorkerInfo.instances[idx].reinit();
      }

      if (!ready) ready = true;

   }

   ulong          requestId = 0;
   string[string] workerEnvironment;

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
