/*
Copyright (c) 2022 Andrea Fontana

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
import serverino.connectionhandler;
import serverino.config;

import std.stdio : File;
import std.conv : to;
import std.experimental.logger : log, info, warning;
import std.process : ProcessPipes;

import std.format : format;
import std.socket;
import std.array : array;
import std.algorithm : filter;
import std.datetime : SysTime, Clock, dur;

package class WorkerInfo
{
   enum State
   {
      IDLING = 0,
      PROCESSING,
      EXITING,
      INVALID,
      STOPPED
   }

   this()
   {
      this.id = instances.length;
      instances ~= this;

      status = State.STOPPED;
      statusChangedAt = Clock.currTime();
      lookup[State.STOPPED].insertBack(id);
   }

   void init()
   {
      assert(status == State.STOPPED);

      clear();

      import std.process : pipeProcess, Redirect, Config;
      import std.file : thisExePath;
      import std.uuid : randomUUID;

      auto uuid = randomUUID().toString();


      version(linux)
      {
         string socketAddress = "SERVERINO_SOCKET/" ~ uuid;
         Socket s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
         s.bind(new UnixAddress("\0%s".format(socketAddress)));
      }
      else
      {
         import std.path : buildPath;
         import std.file : tempDir;
         string socketAddress = buildPath(tempDir, uuid);
         Socket s = new Socket(AddressFamily.UNIX, SocketType.STREAM);
         s.bind(new UnixAddress(socketAddress));
      }

      s.listen(1);

      auto env = Daemon.instance.workerEnvironment.dup;
      env["SERVERINO_SOCKET"] = socketAddress;

      auto pipes = pipeProcess(thisExePath(), Redirect.stdin, env, Config.detached);

      Socket accepted = s.accept();
      s.blocking = false;

      this.pi = new ProcessInfo(pipes.pid.processID);
      this.channel = accepted;

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

      if (this.channel)
      {
         channel.shutdown(SocketShutdown.BOTH);
         channel.close();
         channel = null;
      }

      assignedConnectionHandler = null;
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
   Socket                  channel     = null;
   ConnectionHandler       assignedConnectionHandler = null;

   static WorkerInfo[]   instances;
   static SimpleList[5]  lookup;
}

struct Daemon
{
   static auto isReady() { return ready; }

   static auto instance()
   {
      static Daemon* _instance;
      if (_instance is null) _instance = new Daemon();
      return _instance;
   }

   auto ref workersAlive()
   {
      import std.range : chain;
      return chain(
         WorkerInfo.lookup[WorkerInfo.State.IDLING].asRange,
         WorkerInfo.lookup[WorkerInfo.State.PROCESSING].asRange,
         WorkerInfo.lookup[WorkerInfo.State.EXITING].asRange
      );
   }

   auto ref workersDead()
   {
      import std.range : chain;
      return chain(
         WorkerInfo.lookup[WorkerInfo.State.STOPPED].asRange,
         WorkerInfo.lookup[WorkerInfo.State.INVALID].asRange
      );
   }


   void wake(DaemonConfigPtr config)
   {
      import serverino.interfaces : Request;
      import std.process : environment, thisProcessID;
      import std.stdio;

      workerEnvironment = environment.toAA();
      workerEnvironment["SERVERINO_DAEMON"] = thisProcessID.to!string;
      workerEnvironment["SERVERINO_BUILD"] = Request.simpleNotSecureCompileTimeHash();

      info("Daemon started.");

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

      ConnectionHandler.alive = SimpleList();
      ConnectionHandler.dead = SimpleList();

      foreach(idx; 0..128)
         new ConnectionHandler(config);

      // We use a socketset to check for updates
      SocketSet ssRead = new SocketSet(config.listeners.length + WorkerInfo.instances.length);
      SocketSet ssWrite = new SocketSet(128);

      while(!exitRequested)
      {
         // Create workers if needed. Kills old workers, freezed ones, etc.
         checkWorkers(config);

         ready = true;

         // Wait for a new request.
         ssRead.reset();
         ssWrite.reset();

         // Fill socketSet
         foreach(ref listener; config.listeners)
            ssRead.add(listener.socket);

         foreach(idx; workersAlive)
            ssRead.add(WorkerInfo.instances[idx].channel);

         foreach(idx; ConnectionHandler.alive.asRange)
         {
            ssRead.add(ConnectionHandler.instances[idx].socket);

            if (!ConnectionHandler.instances[idx].completed)
               ssWrite.add(ConnectionHandler.instances[idx].socket);
         }

         // Check for new requests
         size_t updates;
         try { updates = Socket.select(ssRead, ssWrite, null, 1.dur!"seconds"); }
         catch (SocketException se) {
            import std.experimental.logger : warning;
            warning("Exception: ", se.msg);
         }

         CoarseTime now = CoarseTime.currTime;
         {
            static CoarseTime lastCheck = CoarseTime.zero;

            if (now-lastCheck >= 1.dur!"seconds")
            {
               import std.file : exists;
               if (exists("/tmp/kill")) exitRequested = true;

               ConnectionHandler[] toReset;
               foreach(idx; ConnectionHandler.alive.asRange)
               {
                  auto connectionHandler = ConnectionHandler.instances[idx];

                  // Keep-alive timeout hit.
                  if (connectionHandler.status == ConnectionHandler.State.KEEP_ALIVE && connectionHandler.lastRequest != CoarseTime.zero && now - connectionHandler.lastRequest > 5.dur!"seconds")
                     toReset ~= connectionHandler;

                  // Http timeout hit.
                  else if (connectionHandler.status == ConnectionHandler.State.ASSIGNED || connectionHandler.status == ConnectionHandler.State.READING_BODY || connectionHandler.status == ConnectionHandler.State.READING_HEADERS )
                  {
                     if (connectionHandler.lastRecv != CoarseTime.zero && now - connectionHandler.lastRecv > config.maxHttpWaiting)
                     {
                        if (connectionHandler.started)
                        {
                           debug warning("Connection closed. [REASON: http timeout]");
                           connectionHandler.socket.send("HTTP/1.0 408 Request Timeout\r\n");
                        }
                        toReset ~= connectionHandler;
                     }
                  }
               }

               foreach(r; toReset)
                  r.reset();

            }

            size_t cnt = 0;
            foreach(r; ConnectionHandler.dead.asRange)
            {
               if (r == ConnectionHandler.instances.length - 1 && r > 5)
                  cnt++;

               else break;
            }

            for(size_t i = 0; i < cnt; ++i)
            {
               ConnectionHandler.dead.remove(ConnectionHandler.instances.length-1);
               ConnectionHandler.instances.length--;
            }
         }

         if (updates < 0) break;
         else if (updates == 0) continue;

         if (exitRequested)
            break;

         auto wa = workersAlive.array;
         foreach(idx; wa)
         {
            if (updates == 0)
               break;

            WorkerInfo w = WorkerInfo.instances[idx];
            ConnectionHandler r = w.assignedConnectionHandler;

            if (ssRead.isSet(w.channel))
            {
               updates--;

               if (r is null)
               {
                  w.pi.kill();
                  w.setStatus(WorkerInfo.State.STOPPED);
                  continue;
               }

               ubyte[32*1024] buffer;
               auto bytes = w.channel.receive(buffer);

               if (bytes == Socket.ERROR)
               {
                  debug warning("Error: worker killed?");
                  w.setStatus(WorkerInfo.State.STOPPED);
                  w.clear();
                  r.reset();
               }
               else if (bytes == 0)
               {
                  w.setStatus(WorkerInfo.State.STOPPED);
                  w.clear();

                  // User closed socket.
                  if (r !is null && r.socket !is null && r.socket.isAlive)
                     r.socket.shutdown(SocketShutdown.BOTH);
               }
               else
               {
                  if (r is null)
                  {
                     continue;
                  }
                  if (r.responseLength == 0)
                  {
                     r.isKeepAlive = *(cast(bool*)(buffer.ptr));
                     r.setResponseLength(*(cast(size_t*)buffer[bool.sizeof..bool.sizeof + size_t.sizeof]));
                     r.write(cast(char[])buffer[bool.sizeof + size_t.sizeof..bytes]);
                  }
                  else r.write(cast(char[])buffer[0..bytes]);

                  if (r.completed)
                  {
                     r.detachWorker();

                     if (r.status != ConnectionHandler.State.KEEP_ALIVE)
                        r.reset();
                  }
               }
            }

         }


         foreach(idx; ConnectionHandler.alive.asRange)
         {
            auto connectionHandler = ConnectionHandler.instances[idx];

            if (updates == 0)
               continue;

            if (connectionHandler.socket !is null && ssRead.isSet(connectionHandler.socket))
            {
               connectionHandler.lastRecv = now;
               connectionHandler.read();
            }

            if (connectionHandler.socket is null)
            {
               continue;
            }

            if (ssWrite.isSet(connectionHandler.socket))
            {
               connectionHandler.write();

               if (connectionHandler.completed)
               {
                  connectionHandler.detachWorker();
               }
            }
         }

         foreach(ref r; ConnectionHandler.instances.filter!(x=>x.requestToProcess !is null && x.requestToProcess.isValid))
         {
            auto workers = WorkerInfo.lookup[WorkerInfo.State.IDLING].asRange;


            if (!workers.empty) r.assignWorker(WorkerInfo.instances[workers.front]);
            else {
               auto dead = workersDead();

               if (!dead.empty)
               {
                  WorkerInfo.instances[dead.front].init;
                  r.assignWorker(WorkerInfo.instances[dead.front]);
               }

            }

         }

         foreach(ref listener; config.listeners)
         {

            if (updates == 0)
               break;


            if (ssRead.isSet(listener.socket))
            {
               updates--;

               // We have an incoming connection to handle
               ConnectionHandler connectionHandler;

               // First: check if any idling worker is available
               auto idling = ConnectionHandler.dead.asRange;

               if (!idling.empty) connectionHandler = ConnectionHandler.instances[idling.front];
               else connectionHandler = new ConnectionHandler(config);


               connectionHandler.lastRecv = now;

               auto nextId = requestId++;
               connectionHandler.assignSocket(listener.socket.accept(), nextId);
            }
         }

      }

      foreach(ref listener; config.listeners)
      {
         listener.socket.shutdown(SocketShutdown.BOTH);
         listener.socket.close();
      }

      foreach(ref idx; workersAlive.array)
      {
         WorkerInfo w = WorkerInfo.instances[idx];

         try
         {
            if (w)
            {
               if (w.channel) w.channel.shutdown(SocketShutdown.BOTH);
               if (w.pi) w.pi.kill();
            }
         }
         catch (Exception e) { }
      }

      import core.stdc.stdlib : exit;
      exit(0);
   }

   void shutdown() { exitRequested = true; }

private:

   void checkWorkers(DaemonConfigPtr config)
   {

      auto now = Clock.currTime();
      foreach(k; workersAlive)
      {
         auto w = WorkerInfo.instances[k];

         if (!w.channel.isAlive)
         {
            w.setStatus(WorkerInfo.State.INVALID);
            log("Killing ", w.pi.id, ". Invalid state.");

            w.pi.kill();
            w.setStatus(WorkerInfo.State.STOPPED);
         }

      }

      while (
         WorkerInfo.lookup[WorkerInfo.State.IDLING].length +
         WorkerInfo.lookup[WorkerInfo.State.PROCESSING].length < config.minWorkers
      )
      {
         auto dead = workersDead();

         if (dead.empty) break;

         auto idx = dead.front();
         WorkerInfo.instances[idx].init;
      }

   }

   ulong requestId = 0;
   string[string] workerEnvironment;

   __gshared bool exitRequested = false;
   __gshared bool ready = false;
}