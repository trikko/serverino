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
   void reinit(bool isDynamicWorker)
   {
      assert(status == State.STOPPED);

      isDynamic = isDynamicWorker;

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
      env["SERVERINO_DYNAMIC_WORKER"] = isDynamicWorker?"1":"0";

      reloadRequested = false;
      import std.range : repeat;
      import std.array : array;

      version(Posix) const pname = [exePath, cast(char[])(' '.repeat(30).array)];
      else const pname = exePath;

      auto pipes = pipeProcess(pname, Redirect.stdin, env, Config.detached);

      Socket accepted = s.accept();
      this.pi = new ProcessInfo(pipes.pid.processID);
      this.unixSocket = accepted;

      // Wait for the worker to wake up.
      ubyte[1] data;
      accepted.receive(data);

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
      assert(s!=status || s == State.PROCESSING, " > Trying to change WorkerInfo status from " ~ status.to!string ~ " to " ~ s.to!string ~ "\n" ~ this.toString());
      status = s;
      statusChangedAt = now;

      // Automatically reinit the worker if it's stopped and it's not dynamic.
      if (s == State.STOPPED && !isDynamic && !Daemon.exitRequested)
         reinit(false);

      // If a reload is requested we kill the worker when it's idling.
      else if (s == State.IDLING && reloadRequested)
      {
         log("Killing worker " ~ pi.id.to!string  ~ ". [REASON: reloading]");
         pi.kill();
         setStatus(WorkerInfo.State.STOPPED);
      }
   }

   // A lazy list of busy workers.
   pragma(inline, true)
   static auto ref alive() { return WorkerInfo.instances.filter!(x => x.status != WorkerInfo.State.STOPPED); }

   // A lazy list of workers we can reuse.
   pragma(inline, true)
   static auto ref dead() { return WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.STOPPED); }

   private shared static this() { import std.file : thisExePath; exePath = thisExePath(); }

package:

   Socket                  listener;
   ProcessInfo             pi;

   CoarseTime              statusChangedAt;

   State                   status            = State.STOPPED;
   Socket                  unixSocket        = null;
   Communicator            communicator      = null;
   bool                    reloadRequested   = false;
   bool                    isDynamic         = false;

   static WorkerInfo[]     instances;
   static string           exePath;

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

static:

   /// Is serverino ready to accept requests?
   bool bootCompleted() { return ready; }

   /// Shutdown the serverino daemon.
   void shutdown() @nogc nothrow { exitRequested = true; }

package:

   void wake(Modules...)(DaemonConfigPtr config)
   {
      import serverino.interfaces : Request;
      import std.process : environment, thisProcessID;
      import std.file : tempDir, exists, remove;
      import std.path : buildPath, baseName;
      import std.digest.sha : sha256Of;
      import std.digest : toHexString;
      import std.ascii : LetterCase;
      import core.runtime : Runtime;

      immutable daemonPid = thisProcessID.to!string;
      immutable canaryFileName = tempDir.buildPath("serverino-" ~ daemonPid ~ "-" ~ sha256Of(daemonPid).toHexString!(LetterCase.lower) ~ ".canary");

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

      // Create all workers and start the ones that are required.
      foreach(i; 0..config.maxWorkers)
      {
         auto worker = new WorkerInfo();

         if (i < config.minWorkers)
            worker.reinit(false);
      }

      foreach(idx; 0..128)
         new Communicator(config);

      // We use a socketset to check for updates
      SocketSet ssRead = new SocketSet(config.listeners.length + WorkerInfo.instances.length);
      SocketSet ssWrite = new SocketSet(128);

      ready = true;

      while(!exitRequested)
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
         }

         now = CoarseTime.currTime;

         // Some sanity checks. We don't want to check too often.
         {
            static CoarseTime lastCheck = CoarseTime.zero;

            if (now-lastCheck >= 1.seconds)
            {
               lastCheck = now;

               // If a reload is requested we restart all the workers (not the running ones)
               if (!exists(canaryFileName))
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

                  writeCanary();
               }

               // Kill workers that are in an invalid state (unlikely to happen but better to check)
               foreach(worker; WorkerInfo.alive)
               {
                  if (!worker.unixSocket.isAlive)
                  {
                     log("Killing worker " ~ worker.pi.id.to!string  ~ ". [REASON: invalid state]");
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
                  debug warning("Worker #" ~ worker.pi.id.to!string  ~ " exited/terminated/killed (null communicator).");
                  worker.pi.kill();
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  continue;
               }

               ubyte[DEFAULT_BUFFER_SIZE] buffer = void;
               auto bytes = worker.unixSocket.receive(buffer);

               if (bytes == Socket.ERROR)
               {
                  debug warning("Worker #" ~ worker.pi.id.to!string  ~ " exited/terminated/killed (socket error).");
                  worker.setStatus(WorkerInfo.State.STOPPED);
                  communicator.reset();
               }
               else if (bytes == 0)
               {
                  worker.setStatus(WorkerInfo.State.STOPPED);

                  // User closed socket.
                  if (communicator.clientSkt !is null && communicator.clientSkt.isAlive)
                     communicator.clientSkt.shutdown(SocketShutdown.BOTH);
               }
               else
               {
                  if (communicator.responseLength == 0)
                  {
                     WorkerPayload *wp = cast(WorkerPayload*)buffer.ptr;
                     auto data = cast(char[])buffer[WorkerPayload.sizeof..bytes];

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

                           communicator.unsetClientSocket();
                           communicator.unsetWorker();
                           continue;
                        }
                     }

                     communicator.isKeepAlive = (wp.flags & WorkerPayload.Flags.HTTP_KEEP_ALIVE) != 0;
                     communicator.setResponseLength(wp.contentLength);
                     communicator.write(data);
                  }
                  else communicator.write(cast(char[])buffer[0..bytes]);
               }
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
               communicator.lastRecv = now;
               communicator.read();

               if (updates == 0)
                  break;
            }

            if (isWriteSet)
            {
               updates--;

               if (communicator.clientSkt !is null)
                  communicator.write();

               if (updates == 0)
                  break;
            }
         }


         auto availableWorkers = WorkerInfo.instances.filter!(x => x.status == WorkerInfo.State.IDLING);
         auto deadWorkers = WorkerInfo.dead();

         // We have communicators waiting for a worker.
         while(Communicator.execWaitingListFront !is null)
         {
             if (!availableWorkers.empty)
             {
               auto communicator = Communicator.popFromWaitingList();

               communicator.setWorker(availableWorkers.front);
               availableWorkers.popFront;
             }
             else if(!deadWorkers.empty)
             {
               auto communicator = Communicator.popFromWaitingList();

               deadWorkers.front.reinit(true);
               communicator.setWorker(deadWorkers.front);
               deadWorkers.popFront;
             }
             else break; // All workers are busy. We'll try again later.
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
               communicator.setClientSocket(listener.socket.accept());
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

__gshared:

   string[string] workerEnvironment;

   bool exitRequested = false;
   bool ready = false;
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