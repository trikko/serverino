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
import serverino.responder;
import serverino.config;

import std.stdio : File;
import std.conv : to;
import std.experimental.logger : log, info, warning;
import std.process : ProcessPipes;

import std.format : format;
import std.socket;
import std.array : array;
import std.algorithm : filter;
import std.datetime : SysTime, Clock, dur, MonoTime;

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

      assignedResponder = null;
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
   Responder               assignedResponder = null;

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
      import serverino.interface : Request;
      import std.process : environment, thisProcessID;
      import std.stdio;

      workerEnvironment = environment.toAA();
      workerEnvironment["SERVERINO_DAEMON"] = thisProcessID.to!string;
      workerEnvironment["SERVERINO_BUILD"] = Request.simpleNotSecureCompileTimeHash();

      log("Daemon started.");

      // Starting all the listeners.
      foreach(ref listener; config.listeners)
      {
         listener.socket = new TcpSocket(listener.address.addressFamily);
         listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

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

      Responder.alive = SimpleList();
      Responder.dead = SimpleList();

      foreach(idx; 0..128)
         new Responder(config);

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

         foreach(idx; Responder.alive.asRange)
         {
            ssRead.add(Responder.instances[idx].socket);

            if (!Responder.instances[idx].completed)
               ssWrite.add(Responder.instances[idx].socket);
         }


         // Check for new requests
         size_t updates;
         try { updates = Socket.select(ssRead, ssWrite, null, 1.dur!"seconds"); }
         catch (SocketException se) {
            import std.experimental.logger : warning;
            warning("Exception: ", se.msg);
         }

         MonoTime now = MonoTime.currTime;
         {
            static MonoTime lastCheck = MonoTime.zero;

            if (now-lastCheck >= 1.dur!"seconds")
            {
               foreach(idx; Responder.alive.asRange)
               {
                  auto responder = Responder.instances[idx];

                  // Keep-alive timeout hit.
                  if (responder.status == Responder.State.KEEP_ALIVE && now - responder.lastRequest > 5.dur!"seconds")
                  {
                     responder.reset();
                  }

                  // Http timeout hit.
                  else if (responder.status == Responder.State.ASSIGNED || responder.status == Responder.State.READING_BODY || responder.status == Responder.State.READING_HEADERS )
                  {
                     if (responder.lastRecv != MonoTime.zero && now - responder.lastRecv > config.maxHttpWaiting)
                     {
                        warning("Responder closed. [REASON: http timeout]");
                        responder.reset();
                     }
                  }
               }
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
            Responder r = w.assignedResponder;
            if (ssRead.isSet(w.channel))
            {

               updates--;

               ubyte[32*1024] buffer;
               auto bytes = w.channel.receive(buffer);

               if (bytes == Socket.ERROR)
               {
                  log("ERROR");
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
                  if (r.responseLength == 0)
                  {
                     r.isKeepAlive = *(cast(bool*)(buffer.ptr));
                     r.setResponseLength(*(cast(size_t*)buffer[bool.sizeof..bool.sizeof + size_t.sizeof]));
                     r.write(cast(char[])buffer[bool.sizeof + size_t.sizeof..bytes]);
                  }
                  else
                  {
                     r.write(cast(char[])buffer[0..bytes]);
                  }

                  if (r.completed)
                  {
                     r.detachWorker();

                     if (r.status != Responder.State.KEEP_ALIVE)
                        r.reset();
                  }
               }
            }

         }


         foreach(idx; Responder.alive.asRange)
         {
            auto responder = Responder.instances[idx];

            if (updates == 0)
               continue;

            if (responder.socket !is null && ssRead.isSet(responder.socket))
            {
               responder.lastRecv = now;
               responder.read();
            }

            if (responder.socket is null)
            {
               continue;
            }

            if (ssWrite.isSet(responder.socket))
            {
               responder.write();

               if (responder.completed)
               {
                  responder.detachWorker();
               }
            }
         }

         foreach(ref r; Responder.instances.filter!(x => x.requestsQueue.length > 0 && x.requestsQueue[0].isValid))
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
               Responder responder;

               // First: check if any idling worker is available
               auto idling = Responder.dead.asRange;

               if (!idling.empty) responder = Responder.instances[idling.front];
               else
               {
                  responder = new Responder(config);
               }

               responder.lastRecv = now;

               auto nextId = requestId++;
               responder.assignSocket(listener.socket.accept(), nextId);
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