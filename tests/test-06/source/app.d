/*
Copyright (c) 2026 Andrea Fontana

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


// The daemon must survive running out of file descriptors (POSIX only), and connections closed
// while a large response is in flight.
// The clients run in a child process (this same binary, with TEST06_CLIENT set): they must
// not use the fds of the daemon, which lives in this process.

module app;

import serverino;

import std;
import core.thread : Thread;

mixin ServerinoBackground;

enum PORT = 18090;
enum MAX_OPEN_FILES = 256;
enum CONNECTIONS = 600;

@onServerInit
ServerinoConfig conf()
{
   // The client process doesn't need a server
   if (environment.get("TEST06_CLIENT") !is null)
      return ServerinoConfig.create().setReturnCode(0, true);

   return ServerinoConfig
      .create()
      .addListener("127.0.0.1", PORT)
      .setMaxOpenFiles(MAX_OPEN_FILES)
      .setWorkers(2);
}

// A file far larger than the kernel's socket buffers, for test (4)
enum BIG_SIZE = 32 * 1024 * 1024;
string bigFile() { return buildPath(tempDir, "serverino-test-06.bin"); }

@endpoint
void handler(Request r, Output o)
{
   if (r.path == "/big") o.serveFile(bigFile, false);
   else o ~= "ok";
}

void main()
{
   import core.stdc.stdlib : exit;
   import serverino.daemon;

   version(Posix) { }
   else
   {
      writeln("All tests passed!");
      return;
   }

   if (auto mode = environment.get("TEST06_CLIENT"))
   {
      try client(mode);
      catch (Throwable t)
      {
         writeln("Client failed: ", t);
         exit(-1);
      }

      exit(0);
   }

   while(!Daemon.bootCompleted && !Daemon.bootFailed)
      Thread.sleep(10.msecs);

   if (Daemon.bootFailed)
   {
      writeln("Serverino did not start: ", Daemon.bootError);
      exit(-1);
   }

   try { test(); }
   catch (Throwable t)
   {
      writeln("Test failed");
      writeln(t);
      exit(-1);
   }

   Daemon.shutdown();
   writeln("All tests passed!");
}

enum REQUEST = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";

bool isOk(string response) { return response.startsWith("HTTP/1.1 200") && response.endsWith("ok"); }

string get() { return (cast(string) std.net.curl.get("http://127.0.0.1:" ~ PORT.to!string ~ "/")); }

// Reads a whole response, waiting at most `timeout`
string readResponse(Socket s, Duration timeout)
{
   s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, timeout);

   char[1024] buffer;
   string response;

   while(!response.canFind("\r\n\r\n") || !response.endsWith("ok"))
   {
      auto r = s.receive(buffer);
      if (r <= 0) break;
      response ~= buffer[0..r].idup;
   }

   return response;
}

Socket connect()
{
   auto s = new TcpSocket();
   s.connect(new InternetAddress("127.0.0.1", PORT));
   return s;
}

version(Posix)
void raiseFdLimit()
{
   import core.sys.posix.sys.resource;

   rlimit rlim;
   getrlimit(RLIMIT_NOFILE, &rlim);
   rlim.rlim_cur = min(rlim.rlim_max, CONNECTIONS * 4);
   setrlimit(RLIMIT_NOFILE, &rlim);
}

void client(string mode)
{
   version(Posix) raiseFdLimit();

   if (mode == "flood")
   {
      // Many more connections than the daemon can take, all of them waiting for the request
      Socket[] sockets;
      foreach(i; 0..CONNECTIONS)
      {
         auto s = connect();
         s.send("GET / HTTP/1.1\r\n");
         sockets ~= s;
      }

      Thread.sleep(1.seconds);

      // The connections already accepted are still served
      sockets[0].send("Host: localhost\r\n\r\n");
      auto response = readResponse(sockets[0], 5.seconds);
      enforce(isOk(response), "first connection not served: " ~ response);

      // Some connections were refused
      size_t refused = 0;
      foreach(s; sockets[1..$])
      {
         s.blocking = false;
         char[1] b;
         auto r = s.receive(b);
         if (r == 0 || (r < 0 && !wouldHaveBlocked)) refused++;
      }

      enforce(refused > 0, "no connection was refused");
      writeln("refused: ", refused);
   }
   else if (mode == "emfile")
   {
      // Told by the parent when its fds (and the daemon's) are exhausted
      enforce(stdin.readln().strip == "go");

      auto s = connect();
      s.send(REQUEST);
      Thread.sleep(500.msecs);

      writeln("sent");
      stdout.flush();

      // The daemon accepts it as soon as the fds are released
      enforce(stdin.readln().strip == "released");

      auto response = readResponse(s, 5.seconds);
      enforce(isOk(response), "connection not served after the fds were released: " ~ response);
      writeln("served");
   }
   else enforce(false, "unknown mode " ~ mode);
}

version(Posix)
void test()
{
   import core.sys.posix.sys.resource;

   // ---- (1) setMaxOpenFiles sets the soft limit
   rlimit rlim;
   getrlimit(RLIMIT_NOFILE, &rlim);
   assert(rlim.rlim_max < MAX_OPEN_FILES || rlim.rlim_cur == MAX_OPEN_FILES, "soft limit is " ~ rlim.rlim_cur.to!string);

   assert(get() == "ok");

   // ---- (2) too many connections: the daemon refuses the extra ones and keeps serving the others
   {
      auto r = execute([thisExePath], ["TEST06_CLIENT" : "flood"]);
      assert(r.status == 0, r.output);
   }

   // Every connection is gone: business as usual
   Thread.sleep(500.msecs);
   assert(get() == "ok");

   // ---- (3) accept() fails with EMFILE: the daemon waits and does not crash
   {
      import core.sys.posix.fcntl : open, O_RDONLY;
      import core.sys.posix.unistd : close;
      import core.stdc.errno : errno, EMFILE;

      auto pipes = pipeProcess([thisExePath], Redirect.stdin | Redirect.stdout, ["TEST06_CLIENT" : "emfile"]);

      // Use every fd left in this process
      int[] hogs;
      while(true)
      {
         auto fd = open("/dev/null", O_RDONLY);
         if (fd < 0) { assert(errno == EMFILE); break; }
         hogs ~= fd;
      }

      pipes.stdin.writeln("go");
      pipes.stdin.flush();

      auto line = pipes.stdout.readln().strip;

      foreach(fd; hogs) close(fd);

      assert(line == "sent", "client: " ~ line);

      pipes.stdin.writeln("released");
      pipes.stdin.flush();

      line = pipes.stdout.readln().strip;
      auto status = wait(pipes.pid);
      assert(status == 0 && line == "served", "client: " ~ line);
   }

   // The daemon is still alive
   assert(get() == "ok");

   // ---- (4) a connection closed while a large response is in flight: the next connection is
   // served normally
   {
      {
         auto f = File(bigFile, "wb");
         auto chunk = new ubyte[1024 * 1024];
         foreach (i, ref b; chunk) b = cast(ubyte)('a' + i % 26);
         foreach (i; 0 .. BIG_SIZE / chunk.length) f.rawWrite(chunk);
      }
      scope(exit) remove(bigFile);

      foreach (round; 0 .. 3)
      {
         // a small receive window, a little read, then a reset
         auto a = new TcpSocket();
         a.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVBUF, 4096);
         a.connect(new InternetAddress("127.0.0.1", PORT));
         a.send("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n");
         char[1000] head;
         a.receive(head);
         Thread.sleep(300.msecs);
         Linger reset;
         reset.on = 1;
         reset.time = 0;
         a.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, reset);
         a.close();
         Thread.sleep(300.msecs);

         // the next connection: its response starts with its own status line
         auto b = connect();
         b.send("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
         auto response = readResponse(b, 5.seconds);
         b.close();
         assert(isOk(response), "round " ~ round.to!string ~ ": " ~ response[0 .. min(60, $)]);
      }
   }
}
else void test() { }
