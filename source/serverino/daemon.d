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
import std.socket : linger, AddressFamily, socketPair, socket_t, Socket, Linger, SocketSet, SocketOption, SocketOptionLevel, TcpSocket, SocketShutdown;
import std.typecons : Tuple;
import std.datetime : SysTime, Clock, dur;
import core.thread : Thread, thread_detachInstance;
import std.algorithm : filter, splitter, each;
import core.sys.posix.signal : sigset, SIGTERM, SIGINT, SIGKILL;
import core.sys.posix.unistd : STDIN_FILENO, STDERR_FILENO, dup, dup2, fork;
import std.string : format;

import serverino.sockettransfer;
import serverino.common;
import serverino : CustomLogger;


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

   SysTime     createdAt;
   SysTime     statusChangedAt;
   State       status = WorkerState.State.STOPPED;
   Socket      socket;

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
         if(socket !is null)
         {
            socket.blocking = false;
            socket.shutdown(SocketShutdown.BOTH);
            socket.close();
            socket = null;
         }

         if(wi.ipcSocket !is null)
         {
            wi.ipcSocket.blocking = false;
            wi.ipcSocket.shutdown(SocketShutdown.BOTH);
            wi.ipcSocket.close();
            wi.ipcSocket = null;
         }
      }
      
      return term;
   }

   @safe nothrow void setStatus(State s)
   {
      assert(s != status || s == State.PROCESSING);

      status = s;
      statusChangedAt = Clock.currTime();
   }

   this(WorkerInfo wi) { 
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
      __gshared Daemon i = null;
      
      if (i is null) 
         i = new Daemon();

      return i;   
   } 

   ForkInfo wake(DaemonConfigPtr config)
   {
      // Always kill workers on exit
      scope(failure)
      {
         foreach(ref w; workers)
         {
            import core.sys.posix.stdlib : kill, SIGTERM, SIGKILL;
            kill(w.wi.pid, SIGKILL);
         }
      }

      extern(C) void uninit(int value)
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

            foreach(ref w; daemon.workers.filter!(w=>w.isAlive))
               if (!w.isTerminated)
                  killing = true;
         }

         daemon.exitRequested = true;
         daemon.loggerExitRequested = true;
      }

      sigset(SIGINT, &uninit);
      sigset(SIGTERM, &uninit);

      // Redirecting stderr to a pipe.
      import core.sys.posix.fcntl;
      daemonPipe = pipe();
      int stderrCopy = dup(STDERR_FILENO);
      int flags = fcntl(daemonPipe.readEnd.fileno, F_GETFL, 0); 
      fcntl(daemonPipe.readEnd.fileno, F_SETFL, flags | O_NONBLOCK);
      dup2(daemonPipe.writeEnd.fileno, STDERR_FILENO);
      
      log("Daemon started.");
   
      // Starting thread that "syncs" logs.
      loggerThread = new Thread({ logger(stderrCopy); }).start();

      // Starting all the listeners.
      foreach(ref listener; config.listeners)
      {
         listener.socket = new TcpSocket(listener.address.addressFamily);

         // Close socket as soon as possibile and make ports available again.
         import core.sys.posix.sys.socket : linger;
         listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, Linger(linger(1,0)));
         listener.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

         listener.socket.bind(listener.address);
         listener.socket.listen(config.listenerBacklog);

         info("Listening on %s://%s/".format(listener.isHttps?"https":"http", listener.socket.localAddress.toString));
      }

      // Workers
      workers.length = config.maxWorkers;
      
      // We use a socketset to check for updates
      SocketSet ssRead = new SocketSet(config.listeners.length);

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

         foreach(ref w; workers.filter!(x => x.isAlive))
            ssRead.add(w.wi.ipcSocket);

         // Check for new requests
         size_t updates = Socket.select(ssRead, null,null, 1.dur!"seconds");

         if (updates < 0) break;
         else if (updates == 0) continue;
               
         if (exitRequested)
            break;

         foreach(ref w; workers.filter!(x => x.isAlive))
         {
            if (updates == 0)
               break;

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

                     if (w.socket !is null) 
                     {
                        w.socket.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, Linger(linger(0,0)));
                        w.socket.shutdown(SocketShutdown.BOTH);
                        w.socket.close();
                        w.socket = null;
                     }

                     w.setStatus(WorkerState.State.IDLING);
                  }
                  // *S*TOPPED
                  else if(ack[0] == 'S') w.setStatus(WorkerState.State.STOPPED);
                  // KEEP *A*LIVE
                  else if(ack[0] == 'A')
                     w.setStatus(WorkerState.State.PROCESSING);
                  
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
               foreach(ref worker; workers)
               {
                  if (worker.status == WorkerState.State.IDLING)
                  {
                     served = true;
                     process(listener, worker);
                     break;
                  }
               }

               // If not, we wake up a stopped worker, if available
               if (!served)
               {
                  size_t index = 0;
                  foreach(k, ref worker; workers)
                  {
                     if (!worker.isAlive)
                     {
                        served = true;
                        index = k;
                        break;
                     }
                  }

                  if (!served)
                  {
                     // No free listeners found.
                     continue;
                  }

                  log("Waking up a sleeping worker.");

                  fi = createWorker(index<config.minWorkers);
                  if (fi.isThisAWorker) 
                  {
                     workers = null;
                     break;
                  }
                  
                  workers[index] = WorkerState(fi.wi);
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

         
      }

      foreach(ref listener; config.listeners)
      {
         listener.socket.shutdown(SocketShutdown.BOTH);
         listener.socket.close();
      }

      // Exiting
      return ForkInfo(false, WorkerInfo.init);
   }

   private: 
   
   bool          exitRequested = false;
   bool          loggerExitRequested = false;
   Thread        loggerThread;
   WorkerState[] workers;
   Pipe          daemonPipe;

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

   void process(ref Listener li, ref WorkerState worker)
   {
      Socket s = li.socket.accept();
    
      worker.setStatus(WorkerState.State.PROCESSING);
      worker.socket = s;

      IPCMessage header;
      header.data.command = "RQST";

      IPCRequestMessage request;
      request.data.isHttps = li.isHttps;
      request.data.isIPV4  = li.address.addressFamily == AddressFamily.INET;
      request.data.certIdx = li.index;

      worker.wi.ipcSocket.send(header.raw);
      worker.wi.ipcSocket.send(request.raw);
      
      // Send accepted socket thru ipc socket. That's magic!
      SocketTransfer.send(s.handle, worker.wi.ipcSocket);
   }

   
   ForkInfo checkWorkers(DaemonConfigPtr config)
   {

      auto now = Clock.currTime();
      foreach(k, ref w; workers)
      {
         if (!w.isAlive) continue;

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
      

      foreach(k, ref worker; workers)
      {
         if (worker.isAlive == true && worker.isTerminated)
            worker.setStatus(WorkerState.State.STOPPED);
         

         // Enforce min workers count
         if (k < config.minWorkers && worker.status == WorkerState.State.STOPPED)
         {
            auto fi = createWorker(k<config.minWorkers);
            if (fi.isThisAWorker) return fi;
            else 
            {
               workers[k] = WorkerState(fi.wi);
               workers[k].setStatus(WorkerState.State.IDLING);
            }
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
         thread_detachInstance(loggerThread);

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