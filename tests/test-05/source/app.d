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

// A single worker, so that every request races for it. Run it twice: as it is, and
// with SERVERINO_TEST_BACKLOG=1 to queue requests behind the busy worker.

module app;

import serverino;

import std;
import core.thread : Thread;

mixin ServerinoBackground;

@onServerInit
ServerinoConfig conf()
{
   auto config = ServerinoConfig
      .create()
      .setMaxRequestTime(1.seconds)
      .addListener("127.0.0.1", 8080)
      .setWorkers(environment.get("SERVERINO_TEST_WORKERS", "1").to!size_t);

   // (the check lets the same test run on a serverino without the backlog)
   static if (__traits(hasMember, ServerinoConfig, "enableWorkerBacklog"))
   {
      if (environment.get("SERVERINO_TEST_BACKLOG", "0") == "1")
         config.enableWorkerBacklog(4);
   }

   return config;
}

@endpoint
void handler(Request r, Output o)
{
   if (r.path == "/slow")
   {
      Thread.sleep(r.get.read("ms", "300").to!int.msecs);
      o ~= "slow";
   }
   else if (r.path == "/hang") Thread.sleep(5.seconds);
   else if (r.path == "/pid") o ~= r.worker;
   else if (r.path == "/size") o ~= r.body.data.length.to!string;
   else if (r.path.startsWith("/echo/")) o ~= r.path["/echo/".length..$];
}

Socket connectToServer()
{
   auto s = new TcpSocket(new InternetAddress("127.0.0.1", 8080));
   s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 5.seconds);
   return s;
}

void sendGet(Socket s, string path)
{
   s.send("GET " ~ path ~ " HTTP/1.1\r\nHost: localhost\r\n\r\n");
}

// Read one response from the socket. Returns "status body", or "closed".
string readResponse(Socket s, ref char[] pending)
{
   char[4096] buf;

   while(true)
   {
      auto headersEnd = pending.indexOf("\r\n\r\n");

      if (headersEnd >= 0)
      {
         auto head = pending[0..headersEnd].idup;
         auto status = head.split(" ")[1];

         size_t len = 0;
         foreach(line; head.lineSplitter.drop(1))
         {
            auto c = line.indexOf(':');
            if (line[0..c].toLower == "content-length") len = line[c+1..$].strip.to!size_t;
         }

         if (pending.length >= headersEnd + 4 + len)
         {
            auto content = pending[headersEnd + 4 .. headersEnd + 4 + len].idup;
            pending = pending[headersEnd + 4 + len .. $].dup;
            return status ~ " " ~ content;
         }
      }

      auto r = s.receive(buf);
      if (r <= 0) return "closed";
      pending ~= buf[0..r];
   }
}

string readResponse(Socket s)
{
   char[] pending;
   return readResponse(s, pending);
}

void test()
{
   // Warm up: the worker is started on the first request
   {
      auto s = connectToServer();
      sendGet(s, "/echo/warmup");
      assert(readResponse(s) == "200 warmup");
      s.close();
   }

   // Several clients waiting for the only worker: everybody gets its own response.
   {
      auto slow = connectToServer();
      sendGet(slow, "/slow?ms=300");
      Thread.sleep(50.msecs);

      Socket[] others;
      foreach(i; 0..4)
      {
         others ~= connectToServer();
         sendGet(others[$-1], "/echo/" ~ i.to!string);
      }

      assert(readResponse(slow) == "200 slow");
      foreach(i, s; others) assert(readResponse(s) == "200 " ~ i.to!string, "client " ~ i.to!string);

      slow.close();
      foreach(s; others) s.close();
      writeln(" - Concurrent clients: OK");
   }

   // A client closes the connection during a request: the worker waits for the end of
   // the request and then keeps serving.
   {
      auto before = connectToServer();
      sendGet(before, "/pid");
      immutable pidBefore = readResponse(before);
      before.close();

      auto leaving = connectToServer();
      sendGet(leaving, "/slow?ms=300");
      Thread.sleep(50.msecs);
      leaving.close();
      Thread.sleep(50.msecs);

      auto other = connectToServer();
      sendGet(other, "/echo/mine");
      auto r = readResponse(other);
      assert(r == "200 mine", "got `" ~ r ~ "`");
      other.close();

      // With a single worker it must be the same process as before
      if (environment.get("SERVERINO_TEST_WORKERS", "1") == "1")
      {
         Thread.sleep(400.msecs);
         auto after = connectToServer();
         sendGet(after, "/pid");
         immutable pidAfter = readResponse(after);
         after.close();
         assert(pidBefore == pidAfter, "worker restarted: " ~ pidBefore ~ " -> " ~ pidAfter);
      }
      writeln(" - Connection closed during a request: OK");
   }

   // A client leaves while its request is queued.
   {
      auto slow = connectToServer();
      sendGet(slow, "/slow?ms=300");
      Thread.sleep(50.msecs);

      auto leaving = connectToServer();
      sendGet(leaving, "/echo/leaving");
      Thread.sleep(20.msecs);
      leaving.close();

      auto other = connectToServer();
      sendGet(other, "/echo/other");

      assert(readResponse(slow) == "200 slow");
      auto r = readResponse(other);
      assert(r == "200 other", "got `" ~ r ~ "`");

      slow.close();
      other.close();
      writeln(" - Connection closed while queued: OK");
   }

   // Two requests on the same connection, the second one sent a bit later.
   {
      auto s = connectToServer();
      char[] pending;

      sendGet(s, "/slow?ms=200");
      Thread.sleep(50.msecs);
      sendGet(s, "/echo/second");

      auto first = readResponse(s, pending);
      auto second = readResponse(s, pending);
      assert(first == "200 slow", "got `" ~ first ~ "`");
      assert(second == "200 second", "got `" ~ second ~ "`");

      s.close();
      writeln(" - Two requests on one connection: OK");
   }

   // A big body, sent while the worker is busy: it must be served anyway, both when it
   // fits the backlog (20 KB) and when it doesn't (40 KB) and has to wait for the worker.
   foreach(size; [20_000, 40_000])
   {
      auto slow = connectToServer();
      sendGet(slow, "/slow?ms=300");
      Thread.sleep(50.msecs);

      auto big = connectToServer();
      auto body = 'x'.repeat(size).array;
      big.send("POST /size HTTP/1.1\r\nHost: localhost\r\nContent-Length: " ~ body.length.to!string ~ "\r\n\r\n" ~ body);

      assert(readResponse(slow) == "200 slow");
      assert(readResponse(big) == "200 " ~ size.to!string);

      slow.close();
      big.close();
      writeln(" - Big request while busy (", size, " bytes): OK");
   }

   // The worker is killed by the timeout while a request is waiting for it: the
   // waiting client must get an answer, and the server must keep working.
   {
      auto hang = connectToServer();
      sendGet(hang, "/hang");
      Thread.sleep(100.msecs);

      auto waiting = connectToServer();
      sendGet(waiting, "/echo/waiting");

      assert(readResponse(hang).startsWith("504"));

      auto r = readResponse(waiting);
      assert(r == "200 waiting" || r.startsWith("500"), "got `" ~ r ~ "`");

      hang.close();
      waiting.close();

      auto after = connectToServer();
      sendGet(after, "/echo/after");
      assert(readResponse(after) == "200 after");
      after.close();
      writeln(" - Timeout with a waiting client (", r, "): OK");
   }
}

void main()
{
   import core.stdc.stdlib: exit;
   import serverino.daemon;

   while(!Daemon.bootCompleted && !Daemon.bootFailed)
      Thread.sleep(10.msecs);

   if (Daemon.bootFailed)
   {
      writeln("Serverino did not start: ", Daemon.bootError);
      exit(-1);
   }

   writeln("Backlog: ", environment.get("SERVERINO_TEST_BACKLOG", "0"));

   try { test(); }
   catch (Throwable t)
   {
      writeln("Test failed");
      writeln(t);
      exit(-1);
   }

   writeln("All tests passed");
   exit(0);
}
