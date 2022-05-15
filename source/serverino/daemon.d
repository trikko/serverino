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

import std.process : thisProcessID, Pipe, pipe;
import std.experimental.logger : log, info;
import std.socket : linger, AddressFamily, socketPair, socket_t, Socket, Linger, SocketSet, SocketOption, SocketOptionLevel, TcpSocket, SocketShutdown, SocketException;
import std.typecons : Tuple;
import std.datetime : SysTime, Clock, dur;
import core.thread : Thread, thread_detachInstance;
import std.algorithm : filter, splitter, each, map;
import core.sys.posix.signal : sigset, SIGTERM, SIGINT, SIGKILL;
import core.sys.posix.unistd : STDIN_FILENO, STDERR_FILENO, dup, dup2, fork;
import std.string : format;
import core.time : MonoTimeImpl, ClockType;

import serverino.sockettransfer;
import serverino.common;
import serverino : CustomLogger;

alias CoarseTime = MonoTimeImpl!(ClockType.coarse);

private struct SimpleList
{
   private struct SLElement
   {
      size_t v;
      size_t prev = size_t.max;
      size_t next = size_t.max;
   }

   auto asRange()
   {
      struct Range
      {
        bool empty() {
            return tail == size_t.max || elements[tail].next == head;
        }

         void popFront() { head = elements[head].next; if (head == size_t.max) tail = size_t.max; }
         size_t front() { return elements[head].v; }

         void popBack() { tail = elements[tail].prev;  if (tail == size_t.max) head = size_t.max; }
         size_t back() { return elements[tail].v; }

         private:
         size_t head;
         size_t tail;
         SLElement[] elements;
      }

      return Range(head, tail, elements);
   }

   size_t insert(size_t e, bool prepend)
   {
      count++;

      enum EOL = size_t.max;

      size_t selected = EOL;

      if (free == EOL)
      {
         elements ~= SLElement(e, EOL, EOL);
         selected = elements.length - 1;
      }
      else {
         selected = free;
         elements[selected].v = e;
         free = elements[selected].next;

         if (free != EOL)
            elements[free].prev = EOL;
      }


      if (head == EOL)
      {
         head = selected;
         tail = selected;
         elements[selected].next = EOL;
         elements[selected].prev = EOL;
      }
      else
      {
         if (prepend)
         {
            size_t oldHead = head;
            head = selected;
            elements[selected].next = oldHead;
            elements[selected].prev = EOL;
            elements[oldHead].prev = selected;
         }
         else
         {
            size_t oldTail = tail;
            tail = selected;
            elements[selected].prev = oldTail;
            elements[selected].next = EOL;
            elements[oldTail].next = selected;
         }
      }

      return selected;
   }

   size_t insertBack(size_t e) { return insert(e, false); }
   size_t insertFront(size_t e) { return insert(e, true); }

   size_t remove(size_t e)
   {
      enum EOL = size_t.max;

      auto t = head;
      while(t != EOL)
      {
         if (elements[t].v == e)
         {
            count--;

            if (elements[t].prev == EOL) head = elements[t].next;
            else elements[elements[t].prev].next = elements[t].next;

            if (elements[t].next == EOL) tail = elements[t].prev;
            else elements[elements[t].next].prev = elements[t].prev;

            elements[t].prev = EOL;
            elements[t].next = free;

            if (free != EOL)
               elements[free].prev = t;

            free = t;
            return t;
         }

         t = elements[t].next;
      }

      return EOL;
   }

   size_t length() { return count; }
   bool empty() { return head == size_t.max; }

   private:


   SLElement[] elements;
   size_t head = size_t.max;
   size_t tail = size_t.max;
   size_t free = size_t.max;
   size_t count = 0;
}

private struct KeepAliveState
{
   enum State
   {
      WAITING,
      FREE
   }

   JobInfo     ji;
   CoarseTime  timeout;

   State    status = State.FREE;
   size_t   listIdx;
   bool     waiting = false;
}

private struct JobInfo
{
   Socket socket;
   size_t listenerIndex;
}

private struct WorkerState
{
   enum State
   {
      IDLING = 0,
      PROCESSING,
      EXITING,
      INVALID,
      STOPPED
   }

   WorkerInfo  wi;
   JobInfo     ji;

   SysTime     createdAt;
   SysTime     statusChangedAt;
   State       status = WorkerState.State.STOPPED;

   size_t      id;

   bool isAlive() { return (status != State.INVALID && status != State.STOPPED); }

   bool isTerminated()
   {
      import core.sys.posix.sys.wait : waitpid, WNOHANG, WIFEXITED, WIFSIGNALED;
      import core.stdc.errno : errno, ECHILD;

      bool term = false;

      while(true)
      {
            int status;
            auto check = waitpid(wi.pid, &status, WNOHANG);

            if (check == -1)
            {
               if (errno == ECHILD) {
                  term = true;
                  break;
               }
               else continue;
            }

            if (check == 0)
            {
               term = false;
               break;
            }

            if (WIFEXITED(status)) { term = true; break; }
            if (WIFSIGNALED(status)) { term = true; break; }

            term = false;
            break;
      }

      if (term == true)
      {
         with(ji)
         {
            if(socket !is null)
            {
               socket.blocking = false;
               socket.shutdown(SocketShutdown.BOTH);
               socket.close();
               socket = null;
            }
         }

         with(wi)
         {
            if(ipcSocket !is null)
            {
               ipcSocket.blocking = false;
               ipcSocket.shutdown(SocketShutdown.BOTH);
               ipcSocket.close();
               ipcSocket = null;
            }
         }
      }

      return term;
   }

   @trusted void setStatus(State s)
   {
      import std.conv : to;
      assert(s != status || s == State.PROCESSING, "Trying to change status from " ~ status.to!string ~ " to " ~ s.to!string);

      if (s!=status)
      {
         with(Daemon.instance)
         {
            workersLookup[status].remove(id);
            if (wi.persistent) workersLookup[s].insertFront(id);
            else workersLookup[s].insertBack(id);
         }
      }

      status = s;
      statusChangedAt = Clock.currTime();
   }

   this(size_t id, WorkerInfo wi) {
      this.id           = id;
      this.wi           = wi;
      createdAt         = Clock.currTime();
      statusChangedAt   = Clock.currTime();
   }
}

package class Daemon
{
   package:
   alias ForkInfo = Tuple!(bool, "isThisAWorker", WorkerInfo, "wi");

   static auto instance()
   {
      if (_instance is null)
         _instance = new Daemon();
      return _instance;
   }

   auto ref workersAlive()
   {
      import std.range : chain;
      return chain(
         workersLookup[WorkerState.State.IDLING].asRange,
         workersLookup[WorkerState.State.PROCESSING].asRange,
         workersLookup[WorkerState.State.EXITING].asRange
      );
   }

   auto ref workersDead()
   {
      import std.range : chain;
      return chain(
         workersLookup[WorkerState.State.STOPPED].asRange,
         workersLookup[WorkerState.State.INVALID].asRange
      );
   }


   ForkInfo wake(DaemonConfigPtr config)
   {
      keepAliveState.length = 10;
      foreach(x; 0..keepAliveState.length)
         keepAliveLookup[KeepAliveState.State.FREE].insertBack(x);

      void killWorkers()
      {
         foreach(ref w; workers)
         {
            import core.sys.posix.stdlib : kill, SIGTERM, SIGKILL;
            kill(w.wi.pid, SIGKILL);
         }
      }

      // Always kill workers on exit
      scope(failure) { killWorkers(); }

      extern(C) void uninit(int value = 0)
      {
         import core.sys.posix.stdlib : kill, SIGTERM;

         Daemon daemon = Daemon.instance;


         SysTime t = Clock.currTime;
         bool killing = true;
         while(killing)
         {
            auto elapsed = (Clock.currTime - t).total!"msecs";
            if (elapsed > 500) break;

            killing = false;

            foreach(k; daemon.workersAlive)
            {
               auto w = &(daemon.workers[k]);

               if (!w.isTerminated)
                  killing = true;
            }
         }

         daemon._instance = null;
         daemon.exitRequested = true;
         daemon.loggerExitRequested = true;

      }

      sigset(SIGINT, &uninit);
      sigset(SIGTERM, &uninit);

      // Redirecting stderr to a pipe.
      version(unittest) { }
      else
      {
         import core.sys.posix.fcntl;
         daemonPipe = pipe();
         int stderrCopy = dup(STDERR_FILENO);
         int flags = fcntl(daemonPipe.readEnd.fileno, F_GETFL, 0);
         fcntl(daemonPipe.readEnd.fileno, F_SETFL, flags | O_NONBLOCK);
         dup2(daemonPipe.writeEnd.fileno, STDERR_FILENO);
         loggerThread = new Thread({ logger(stderrCopy); }).start();
      }

      log("Daemon started.");

      // Starting all the listeners.
      foreach(ref listener; config.listeners)
      {
         listener.socket = new TcpSocket(listener.address.addressFamily);

         // Close socket as soon as possibile and make ports available again.
         import core.sys.posix.sys.socket : linger;
         listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, Linger(linger(1,0)));
         listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

         try
         {
            listener.socket.bind(listener.address);
            listener.socket.listen(config.listenerBacklog);

            info("Listening on %s://%s/".format(listener.isHttps?"https":"http", listener.socket.localAddress.toString));
         }
         catch (SocketException se)
         {
            import std.experimental.logger : critical;
            import core.stdc.stdlib : exit, EXIT_FAILURE;
            import std.stdio : stderr;

            critical("Can't listen on %s://%s/. Are you allowed to listen on this port? Is port already used by another process?".format(listener.isHttps?"https":"http", listener.address.toString));

            stderr.flush;
            if (loggerThread !is null)
            {
               loggerExitRequested = true;
               loggerThread.join();
            }

            foreach(ref l; config.listeners)
            {
               if (l.socket !is null)
               {
                  l.socket.close();
                  l.socket.shutdown(SocketShutdown.BOTH);
               }
            }

            exit(EXIT_FAILURE);
         }
      }

      // Workers
      import std.traits : EnumMembers;
      static foreach(e; EnumMembers!(WorkerState.State))
      {
         workersLookup[e] = SimpleList();
      }

      workers.length = config.maxWorkers;
      foreach(i; 0..workers.length)
         workersLookup[WorkerState.State.STOPPED].insertBack(i);


      // We use a socketset to check for updates
      SocketSet ssRead = new SocketSet(config.listeners.length);

      CoarseTime nextContextSwitch = CoarseTime.currTime + 2.dur!"seconds";
      CoarseTime nextIdlingCheck = CoarseTime.zero();
      size_t     maxIdlingWorkers = 0;

      ForkInfo fi;
      while(!exitRequested)
      {
         // Create workers if needed. Kills old workers, freezed ones, etc.
         fi = checkWorkers(config);

         // This is a forked listener
         if (fi.isThisAWorker)
         {
            workers = null;
            return fi;
         }

         // Wait for a new request.
         ssRead.reset();

         // Fill socketSet
         foreach(ref listener; config.listeners)
            ssRead.add(listener.socket);

         foreach(idx; workersAlive)
            ssRead.add(workers[idx].wi.ipcSocket);

         foreach(ref kas; keepAliveLookup[KeepAliveState.State.WAITING].asRange.map!(x => keepAliveState[x]).filter!(x => x.ji.socket.isAlive))
            ssRead.add(kas.ji.socket);

         // Check for new requests
         size_t updates;
         try { updates = Socket.select(ssRead, null,null, 1.dur!"seconds"); }
         catch (SocketException se) {
            import std.experimental.logger : warning;
            warning("Exception: ", se.msg);
         }

         if (updates < 0) break;
         else if (updates == 0) continue;

         if (exitRequested)
            break;

         bool switchRequired = false;

         foreach(idx; workersAlive)
         {
            if (updates == 0)
               break;

            auto w = &(workers[idx]);

            if (ssRead.isSet(w.wi.ipcSocket))
            {
               updates--;

               // Worker send a \n when finished
               char[1] ack;
               auto bytes = w.wi.ipcSocket.receive(ack);

               if (bytes > 0)
               {
                  // *D*ONE
                  if (ack[0] == 'D')
                  {
                     with(w.ji)
                     {
                        if (socket !is null)
                        {
                           socket.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, Linger(linger(0,0)));
                           socket.shutdown(SocketShutdown.BOTH);
                           socket.close();
                           socket = null;
                        }
                     }

                     w.setStatus(WorkerState.State.IDLING);
                  }
                  // KEEP *A*LIVE
                  else if (ack[0] == 'A')
                  {
                     if (keepAliveLookup[KeepAliveState.State.FREE].empty)
                     {
                        keepAliveLookup[KeepAliveState.State.FREE].insertBack(keepAliveState.length);
                        keepAliveState.length++;
                     }

                     size_t freeIdx = keepAliveLookup[KeepAliveState.State.FREE].asRange.front;
                     keepAliveLookup[KeepAliveState.State.FREE].remove(freeIdx);
                     keepAliveLookup[KeepAliveState.State.WAITING].insertBack(freeIdx);

                     keepAliveState[freeIdx] = KeepAliveState(w.ji, CoarseTime.currTime + config.maxHttpWaiting);
                     w.ji.socket = null;
                     w.setStatus(WorkerState.State.IDLING);
                  }
                  // *S*TOPPED
                  else if(ack[0] == 'S') w.setStatus(WorkerState.State.STOPPED);
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

               bool served = false;

               // We have an incoming connection to handle

               // First: check if any idling worker is available
               auto idling = workersLookup[WorkerState.State.IDLING].asRange;

               if (!idling.empty)
               {
                  served = true;
                  process(listener, workers[idling.front]);
                  continue;
               }

               // If not, we wake up a stopped worker, if available
               if (!served)
               {
                  size_t index = 0;
                  auto dead = workersDead;
                  if(!dead.empty)
                  {
                     served = true;
                     index = dead.front;
                  }

                  if (!served)
                  {
                     // No free listeners found.
                     switchRequired = true;
                     continue;
                  }

                  log("Waking up a sleeping worker.");

                  fi = createWorker(false);
                  if (fi.isThisAWorker)
                  {
                     workers = null;
                     break;
                  }

                  workers[index] = WorkerState(index, fi.wi);
                  workers[index].setStatus(WorkerState.State.IDLING);
                  process(listener, workers[index]);
               }

            }
         }

         // We are in a forked process, exit from there.
         if (fi.isThisAWorker)
         {
            return fi;
         }

         SimpleList *kaWaiting = &keepAliveLookup[KeepAliveState.State.WAITING];
         SimpleList *kaFree = &keepAliveLookup[KeepAliveState.State.FREE];

         CoarseTime now = CoarseTime.currTime;

         foreach(idx; kaWaiting.asRange)
         {
            auto kas = &keepAliveState[idx];

            if (!kas.ji.socket.isAlive)
            {
               kaWaiting.remove(idx);
               kaFree.insertBack(idx);
               continue;
            }

            if (updates > 0 && ssRead.isSet(kas.ji.socket))
            {

               kas.waiting = true;
               updates--;

               bool served = false;

               // We have an incoming connection to handle

               // First: check if any idling worker is available
               auto idling = workersLookup[WorkerState.State.IDLING].asRange;
               if (!idling.empty)
               {
                  served = true;
                  kaWaiting.remove(idx);
                  kaFree.insertBack(idx);
                  process(config.listeners[kas.ji.listenerIndex], workers[idling.front], kas);
                  continue;
               }

               // If not, we wake up a stopped worker, if available
               if (!served)
               {
                  size_t index = 0;
                  auto dead = workersDead;
                  if(!dead.empty)
                  {
                     served = true;
                     index = dead.front;
                  }

                  if (!served)
                  {
                     switchRequired = true;
                     continue;
                  }

                  log("Waking up a sleeping worker.");

                  fi = createWorker(false);
                  if (fi.isThisAWorker)
                  {
                     workers = null;
                     break;
                  }

                  kaWaiting.remove(idx);
                  kaFree.insertBack(idx);
                  workers[index] = WorkerState(index, fi.wi);
                  workers[index].setStatus(WorkerState.State.IDLING);
                  process(config.listeners[kas.ji.listenerIndex], workers[index], kas);
               }

            }
            else if (!kas.waiting && now > kas.timeout)
            {
               kaWaiting.remove(idx);
               kaFree.insertBack(idx);
               kas.ji.socket.shutdown(SocketShutdown.BOTH);
               kas.ji.socket.close();
               kas.ji.socket = null;
            }

         }

         // We are in a forked process, exit from there.
         if (fi.isThisAWorker)
         {
            return fi;
         }

         if (switchRequired)
         {
            if (CoarseTime.currTime > nextContextSwitch)
            {
               foreach(workerIdx; workersLookup[WorkerState.State.PROCESSING].asRange)
               {
                  WorkerState *w = &workers[workerIdx];
                  IPCMessage header;
                  header.data.command = "SWCH";
                  w.wi.ipcSocket.send(header.raw);
               }

               nextContextSwitch = CoarseTime.currTime + 2.dur!"seconds";
            }

         }

      }

      foreach(ref listener; config.listeners)
      {
         listener.socket.shutdown(SocketShutdown.BOTH);
         listener.socket.close();
      }

      killWorkers();
      uninit(0);

      // Exiting
      return ForkInfo(false, WorkerInfo.init);
   }

   void shutdown()
   {
      import core.thread;
      exitRequested = true;
   }

   private:

   bool           exitRequested = false;
   bool           loggerExitRequested = false;
   Thread         loggerThread;
   WorkerState[]  workers;
   Pipe           daemonPipe;


   SimpleList[5]     workersLookup;
   SimpleList[2]     keepAliveLookup;
   KeepAliveState[]  keepAliveState;

   __gshared Daemon  _instance = null;


   this() { }

   void logger(int stdErrFd)
   {
      import core.sys.posix.sys.select : timeval, fd_set, FD_ISSET, FD_ZERO, FD_SET, select;
      import core.sys.posix.poll : poll, pollfd, POLLIN;
      import std.stdio : stderr, File, stdout;

      File realStdErr;
      realStdErr.fdopen(stdErrFd, "w");

      string readBuffer(File file)
      {
         import std.stdio : write, stderr;
         import std.string : indexOf;

         string output;
         char[4096] buffer;
         buffer = 0;

         while(true)
         {
            import core.stdc.stdio : fgets;
            auto f = fgets(buffer.ptr, 4096, file.getFP);
            if (f == null) break;
            output ~= buffer[0..buffer[0..$].indexOf(0)];
            if (file.eof()) break;
         }

         return output;
      }

      auto deamonLog = daemonPipe.readEnd;

      while(!loggerExitRequested)
      {
         fd_set   set;
         timeval  tv;
         tv.tv_sec = 0;
         tv.tv_usec = 1_000_000/2;
         FD_ZERO(&set);

         int maxfd = deamonLog.fileno;
         FD_SET(deamonLog.fileno, &set);


         foreach(ref ws; workers.filter!(x => x.isAlive))
         {
            if (maxfd < ws.wi.pipe.fileno) maxfd = ws.wi.pipe.fileno;
            FD_SET(ws.wi.pipe.fileno, &set);
         }

         int ret = select(maxfd+1, &set, null, null, &tv);

         if (ret >= 0)
         {
            size_t changed = 0;

            if (FD_ISSET(deamonLog.fileno, &set) == true)
            {
               import std.stdio : write, stderr;
               string output = readBuffer(deamonLog);

               output
               .splitter("\n")
               .filter!(x => x.length > 0)
               .each!(
                  ln => realStdErr.writeln("\x1b[1m★\x1b[0m [", thisProcessID(), "] ", ln)
               );
            }

            foreach(ref ws; workers.filter!(x => x.isAlive))
            {
               if (FD_ISSET(ws.wi.pipe.fileno, &set) == true)
               {
                  import std.stdio : write, stderr;
                  import std.string : indexOf;

                  size_t seed = ws.wi.pid;

                  auto r = ((seed*123467983)%15+1)     * 255/15;
                  auto g = ((r*seed*123479261)%15+1)   * 255/15;
                  auto b = ((g*seed*123490957)%15+1)   * 255/15;

                  string output = readBuffer(ws.wi.pipe);

                  output
                  .splitter("\n")
                  .filter!(x => x.length > 0)
                  .each!(
                     ln => realStdErr.writeln("\x1b[38;2;", r, ";", g, ";", b,"m■\x1b[0m [", ws.wi.pid, "] ", ln)
                  );

               }
            }

         }
      }

   }

   void process(ref Listener li, ref WorkerState worker, KeepAliveState *kas = null)
   {
      worker.setStatus(WorkerState.State.PROCESSING);

      if (kas is null)
      {
         try { worker.ji.socket = li.socket.accept(); }
         catch (SocketException se) {
            import std.experimental.logger : warning;
            warning("Exception: ", se.msg);

            worker.ji.socket = null;
            worker.setStatus(WorkerState.State.IDLING);
            return;
         }

         worker.ji.listenerIndex = li.index;
      }
      else
      {
         worker.ji.socket = kas.ji.socket;
         worker.ji.listenerIndex = kas.ji.listenerIndex;
      }

      transferRequest(li, worker);
   }

   void transferRequest(ref Listener li, ref WorkerState worker)
   {
      IPCMessage header;
      header.data.command = "RQST";

      IPCRequestMessage request;
      request.data.isHttps = li.isHttps;
      request.data.isIPV4  = li.address.addressFamily == AddressFamily.INET;
      request.data.certIdx = li.index;

      worker.wi.ipcSocket.send(header.raw);
      worker.wi.ipcSocket.send(request.raw);

      // Send accepted socket thru ipc socket. That's magic!
      SocketTransfer.send(worker.ji.socket.handle, worker.wi.ipcSocket);
   }

   ForkInfo checkWorkers(DaemonConfigPtr config)
   {

      auto now = Clock.currTime();
      foreach(k; workersAlive)
      {
         auto w = &(workers[k]);
         import core.sys.posix.stdlib : kill, SIGTERM, SIGKILL;

         if (!w.wi.ipcSocket.isAlive)
         {
            w.setStatus(WorkerState.State.INVALID);
            log("Killing ", w.wi.pid, ". Invalid state.");

            if (w.status != WorkerState.State.EXITING)
            {
               kill(w.wi.pid, SIGTERM);
               w.setStatus(WorkerState.State.EXITING);
            }
            else
            {
               kill(w.wi.pid, SIGKILL);
               w.setStatus(WorkerState.State.STOPPED);
            }
         }

      }

      workersAlive.map!(x=>workers[x]).filter!(x => x.isTerminated).each!(x => x.setStatus(WorkerState.State.STOPPED));

      while (
         workersLookup[WorkerState.State.IDLING].length +
         workersLookup[WorkerState.State.PROCESSING].length < config.minWorkers
      )
      {
         auto dead = workersDead();

         if (dead.empty) break;

         auto idx = dead.front();
         auto fi = createWorker(true);
         if (fi.isThisAWorker) return fi;
         else
         {
            workers[idx] = WorkerState(idx, fi.wi);
            workers[idx].setStatus(WorkerState.State.IDLING);
         }
      }

      return ForkInfo(false, WorkerInfo.init);
   }

   ForkInfo createWorker(bool persistent)
   {
      Socket[2]   sockets = datagramSocketPair();
      Pipe        pipes = pipe();

      WorkerInfo  wi;
      wi.persistent = persistent;

      int forked = fork();

      if (forked == 0)
      {
         import std.stdio : File;
         import std.conv : to;

         // These thread don't exist in child process.
         // Druntime doesn't know that.
         version(unittest) { }
         else thread_detachInstance(loggerThread);

         // We're not going to use these
         pipes.readEnd().close();
         sockets[1].close();

         Daemon.workers[] = WorkerState.init;
         Daemon.workers.destroy;
         Daemon.workers = null;

         wi.pid = thisProcessID();
         wi.ipcSocket = sockets[0];
         wi.pipe = pipes.writeEnd();

         // stderr -> pipe
         // stdin <- /dev/null
         dup2(wi.pipe.fileno, STDERR_FILENO);
         dup2(File("/dev/null").fileno, STDIN_FILENO);

         return ForkInfo(true, wi);
      }
      else if (forked > 0)
      {
         // We're not going to use these
         pipes.writeEnd.close();
         sockets[0].close();

         wi.pipe = pipes.readEnd();

         import core.sys.posix.fcntl;
         int flags = fcntl(wi.pipe.fileno, F_GETFL, 0);
         fcntl(wi.pipe.fileno, F_SETFL, flags | O_NONBLOCK);

         wi.pid = forked;
         wi.ipcSocket = sockets[1];
         wi.ipcSocket.blocking = false;

         return ForkInfo(false, wi);
      }
      else assert(0, "Can't fork a process?");

      assert(0);
   }

   // Used for ipc between daemon <-> workers
   Socket[2] datagramSocketPair()
   {
      import std.socket : AF_UNIX, SOCK_DGRAM, socketpair, SocketOSException;
      int[2] socks;

      if (socketpair(AF_UNIX, SOCK_DGRAM, 0, socks) == -1)
         throw new SocketOSException("Unable to create socket pair");

      return [new Socket(cast(socket_t)socks[0], AddressFamily.UNIX), new Socket(cast(socket_t)socks[1], AddressFamily.UNIX)];
   }
}