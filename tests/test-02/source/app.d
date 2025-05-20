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

module app;

import serverino;

import std;
import core.thread;

mixin ServerinoBackground;

void main()
{
   import core.stdc.stdlib: exit;
   import core.thread;
   import serverino.daemon;

   // Is serverino ready?
   while(!Daemon.bootCompleted)
      Thread.sleep(10.msecs);

   // Run the tests
   try {
      test();
   }
   catch (Throwable t)
   {
      writeln("Test failed");
      writeln(t);
      exit(-1);
   }

   Daemon.shutdown();
   writeln("All tests passed!");
}

@route!"/nullptr"
@endpoint void nullptr(Request r, Output o)
{
   void *p = cast(void*)0x1;
   *(cast(int*)p) = 10;
}

@route!"/sleep"
@endpoint void sleep(Request r, Output o)
{
   import core.thread;
   Thread.sleep(600.msecs);
   o.addHeader("Content-type", "text/plain");
   o ~= "slept";
   log("Slept");
}

@route!"/simple"
@endpoint void simple(Request r, Output o)
{
   import core.thread;
   o.addHeader("Content-type", "text/plain");
   o ~= "simple";
}

@route!"/crash"
@endpoint void crash(Request r, Output o)
{
   import core.stdc.stdlib :exit;
   exit(1);
}

@route!"/serveKeep"
@endpoint void servingKeep(Request r, Output o)
{
   char[] buffer;
   buffer.length = 1024*1024*10;
   buffer[] = '\n';

   File f = File("pizza.txt", "wb+");
   f.write(buffer);
   f.close();

   o.serveFile("pizza.txt");
}

@route!"/serveDelete"
@endpoint void servingDelete(Request r, Output o)
{
   char[] buffer;
   buffer.length = 1024*1024*10;
   buffer[] = '\n';

   File f = File("pizza.txt", "wb+");
   f.write(buffer);
   f.close();

   o.serveFile!(OnFileServed.DeleteFile)("pizza.txt");
}

@route!"/buffered"
@endpoint void buffered(Request r, Output o)
{
   char[] buffer;
   buffer.length = 1024*1024*10;
   buffer[] = '\n';

   o ~= buffer;
}

@route!(x => x.path.startsWith("/echo/"))
@endpoint void echo(Request r, Output o)
{
   o ~= r.path[6..$];
}

@onServerInit
ServerinoConfig conf()
{
   return ServerinoConfig
      .create()
      .setMaxRequestTime(1.seconds)
      .setMaxRequestSize(2000)
      .addListener("0.0.0.0", 8080)
      .setWorkers(4);
}

@priority(100)
@route!"/pizza"
@endpoint void ws2(Request r, WebSocket s)
{
   s.socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
   s.socket.blocking = true;
   s.send("Hello world.");
   s.receiveMessage();
}

@priority(-1)
@endpoint void ws3(Request r, WebSocket s)
{
   s.socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
   s.socket.blocking = true;
   WebSocketMessage msg;

   while(true)
   {
      msg = s.receiveMessage();

      if (msg)
         break;

      Thread.sleep(100.msecs);
      Thread.yield();
   }

   assert(msg.isValid);
   assert(msg.asString == "Hello from client");
   s.send(msg.asString);
   s.send(cast(int)123);

   s.receiveMessage();
}

@route!"/chat"
@endpoint void ws(Request r, WebSocket s)
{
   s.socket.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
   s.socket.blocking = true;
   s.send("Hello world!");
   s.receiveMessage();
}

@onWebSocketUpgrade bool upgrade(Request r) { return r.path == "/chat" || r.path == "/pizza" || r.path == "/hello"; }

void test()
{
   info("Worker crash");
   {
      bool asserted = false;

      try { get("http://localhost:8080/nullptr"); }
      catch (CurlException e) { asserted = true; }

      assert(asserted);
   }

   info("Serving file");
   {
      auto req = "GET /serveKeep HTTP/1.0\r\n\r\n";

      auto sck = new TcpSocket();
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(req);

      char[] buffer;
      char[] data;

      data.reserve = 1024*1024*10;
      buffer.length = 128;

      while(true)
      {
         auto ln = sck.receive(buffer);
         if (ln <= 0) break;
         data ~= buffer[0..ln];
      }

      auto headers = "HTTP/1.0 200 OK\r\nconnection: close\r\ncontent-length: 10485760\r\ncontent-type: text/plain\r\n\r\n";
      assert(data.startsWith(headers), "LEN: " ~ data.length.to!string ~ " " ~ data.take(1024).to!string);

      data = data[headers.length..$];
      import std.digest.md;
      auto md5 = md5Of(data).toHexString().dup.toLower();
      assert(md5 == "ecce263106eaa75fa87c463fc197bf8c", md5);
      assert(exists("pizza.txt"));
      std.file.remove("pizza.txt");
   }

   {
      auto req = "GET /serveDelete HTTP/1.0\r\n\r\n";

      auto sck = new TcpSocket();
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(req);

      char[] buffer;
      char[] data;

      data.reserve = 1024*1024*10;
      buffer.length = 4096;

      while(true)
      {
         auto ln = sck.receive(buffer);

         if (ln <= 0) break;

         data ~= buffer[0..ln];
      }

      auto headers = "HTTP/1.0 200 OK\r\nconnection: close\r\ncontent-length: 10485760\r\ncontent-type: text/plain\r\n\r\n";
      assert(data.startsWith(headers), data.take(1024).to!string);

      data = data[headers.length..$];
      import std.digest.md;
      auto md5 = md5Of(data).toHexString().dup.toLower();
      assert(md5 == "ecce263106eaa75fa87c463fc197bf8c", md5);
      assert(!exists("pizza.txt"));
   }

   info("Buffered send");
   {
      auto req = "GET /buffered HTTP/1.0\r\n\r\n";

      auto sck = new TcpSocket();
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(req);

      char[] buffer;
      char[] data;

      buffer.length = 4096;

      {
         auto ln = sck.receive(buffer);

         if (ln > 0)
            data ~= buffer[0..ln];
      }

      Thread.sleep(100.msecs);

      while(true)
      {
         auto ln = sck.receive(buffer);

         if (ln <= 0) break;

         data ~= buffer[0..ln];
      }
      assert(data.startsWith("HTTP/1.0 200 OK\r\nconnection: close\r\ncontent-length:"), data.take(1024).to!string);
   }

   info("minimal HTTP/1.0");
   {
      auto req = "GET /simple HTTP/1.0\r\n\r\n";

      auto sck = new TcpSocket();
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(req);

      char[] buffer;
      char[] data;

      buffer.length = 4096;
      while(true)
      {
         auto ln = sck.receive(buffer);

         if (ln <= 0) break;

         data ~= buffer[0..ln];
      }
      assert(data == "HTTP/1.0 200 OK\r\nconnection: close\r\ncontent-length: 6\r\ncontent-type: text/plain\r\n\r\nsimple");
   }

   info("Testing boundary delimitation.");
   {
      string postBody ="
      \r\n
      --2gnBwjvY18YFWfzZrUMe2XPYwTp\r\nContent-Disposition: form-data;\r\nContent-Type: text/plain\r\najejje\r\n--2gnBwjvY18YFWfzZrUMe2XPYwTp--\r\n
      ";

      auto http = HTTP("http://127.0.0.1:8080/?");
      http.setPostData(postBody,"multipart/form-data; boundary=2gnBwjvY18YFWfzZrUMe2XPYwTp");

      http.method = HTTP.Method.post;
      http.onReceive = (ubyte[] data) {  return data.length; };
      http.perform();

      assert(http.statusLine.code == 400);

   }
   info("Testing crash endpoint. The server must not crash");
   {
      auto req = "GET /crash HTTP/1.1\r\nhost:localhost\r\n\r\n";

      auto sck = new TcpSocket();
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(req);

      char[] buffer;
      char[] data;

      buffer.length = 4096;
      while(true)
      {
         auto read = sck.receive(buffer);
         if (read <= 0) break;
         data ~= buffer[0..read];
      }

      assert(data.empty);
   }

   info("Testing pipeline");
   {
      import core.thread;

      __gshared bool done = false;

      new Thread({
         while(!done)
         {
            auto req = "GET /simple HTTP/1.0\r\nx-test:blah\r\n\r\n";
            auto sck = new TcpSocket();
            sck.connect(new InternetAddress("localhost", 8080));
            sck.send(req);

            char[] buffer;
            char[] data;

            buffer.length = 4096;
            while(true)
            {
               auto ln = sck.receive(buffer);

               if (ln <= 0) break;

               data ~= buffer[0..ln];
            }

            Thread.sleep(100.msecs);
         }
      }).start();

      {
         auto req = "GET /simple HTTP/1.1\r\nhost:localhost\r\n\r\n";
         req ~= "GET /sleep HTTP/1.1\r\nhost:localhost\r\n\r\n";

         // This one is HTTP/1.0 so connection will be closed
         req ~= "GET /simple HTTP/1.0\r\nhost:localhost\r\n\r\n";


         auto sck = new TcpSocket();
         sck.connect(new InternetAddress("localhost", 8080));
         sck.send(req);

         char[] buffer;
         char[] data;

         buffer.length = 4096;
         while(true)
         {
            auto ln = sck.receive(buffer);
            if (ln <= 0) break;

            data ~= buffer[0..ln];
         }
         done = true;


         assert(data == "HTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 6\r\ncontent-type: text/plain\r\n\r\nsimpleHTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 5\r\ncontent-type: text/plain\r\n\r\nsleptHTTP/1.0 200 OK\r\nconnection: close\r\ncontent-length: 6\r\ncontent-type: text/plain\r\n\r\nsimple", "DATA: " ~ data);
      }
   }

   info("Testing crash endpoint. The server must not crash");
   {
      auto req = "GET /crash HTTP/1.1\r\nhost:localhost\r\n\r\n";

      auto sck = new TcpSocket();
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(req);

      char[] buffer;
      char[] data;

      buffer.length = 4096;
      while(true)
      {
         auto read = sck.receive(buffer);
         if (read <= 0) break;
         data ~= buffer[0..read];
      }

      assert(data.empty);
   }

   // Testing partial sending
   {
      import core.thread;

      {
         auto req = "GET /simple HTTP/1.1\r\nhost:localhost\r\n\r\n";
         req ~= "GET /sleep HTTP/1.1\r\nhost:localhost\r\n\r\n";
         req ~= "GET /simple HTTP/1.0\r\nhost:localhost\r\n\r\n";

         auto sck = new TcpSocket();
         sck.connect(new InternetAddress("localhost", 8080));
         sck.send(req[0..5]);
         Thread.sleep(10.msecs);
         sck.send(req[5..50]);
         Thread.sleep(10.msecs);
         sck.send(req[50..$]);


         char[] buffer;
         char[] data;

         buffer.length = 4096;
         while(true)
         {
            auto ln = sck.receive(buffer);

            if (ln <= 0) break;

            data ~= buffer[0..ln];
         }

         assert(data == "HTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 6\r\ncontent-type: text/plain\r\n\r\nsimpleHTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 5\r\ncontent-type: text/plain\r\n\r\nsleptHTTP/1.0 200 OK\r\nconnection: close\r\ncontent-length: 6\r\ncontent-type: text/plain\r\n\r\nsimple");
      }

   }

   info("Multiple parallels pipelines (100 request * 10 pipelines)");
   {
      import core.thread;

      __gshared bool done = false;


      void pipeline(int k){

         string req;
         string response;

         foreach(i; 0..100)
         {
            req ~= "GET /echo/" ~ std.conv.to!string(1000+k*100+i) ~ " HTTP/1.1\r\nhost:localhost\r\n\r\n";
            response ~= "HTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-length: 4\r\ncontent-type: text/html;charset=utf-8\r\n\r\n" ~ std.conv.to!string(1000+k*100+i);
         }

         auto sck = new TcpSocket();
         sck.connect(new InternetAddress("localhost", 8080));
         sck.send(req);

         char[] buffer;
         char[] data;

         buffer.length = 32768;
         while(true)
         {
            auto ln = sck.receive(buffer);

            if (ln <= 0) break;

            data ~= buffer[0..ln];

            if (data.length >= response.length)
               break;
         }

         assert(data == response, "WAITING: " ~ cast(string)response ~ "\nRECEIVED: " ~ cast(string)data);
      }

      ThreadGroup tg = new ThreadGroup();

      import core.atomic;

      int idx = 0;

      foreach(k; 0..10)
         tg.add
         (
            new Thread
            (
               {
                  auto cur = atomicFetchAdd(idx, 1);
                  pipeline(cur);
               }
            ).start()
         );

      tg.joinAll();

      assert(idx == 10);
   }

   info("Testing WebSocket");
   {
      auto handshake = "GET /chat HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

      auto sck = new TcpSocket();
      sck.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
      sck.blocking = true;
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(handshake);

      ubyte[] buffer;
      buffer.length = 129;

      {
         auto ln = sck.receive(buffer);

         auto reply = buffer[0..ln];

         assert(reply.startsWith("HTTP/1.1 101 Switching Protocols"), "REPLY: " ~ cast(char[])reply);
         assert(reply.canFind("sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="), "REPLY: " ~ cast(char[])reply);
      }

      buffer.length = 32000;
      ubyte[] reply;

      while(reply.length < 2+ "Hello world!".length)
      {
         auto recv = sck.receive(buffer);

         if(recv <= 0) break;

         reply ~= buffer[0..recv];
      }

      assert(reply[2..$].startsWith("Hello world!".representation), reply.to!string);
      (new WebSocket(sck)).sendClose();
   }

   {
      auto handshake = "GET /pizza HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

      auto sck = new TcpSocket();
      sck.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
      sck.blocking = true;
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(handshake);

      ubyte[] buffer;
      buffer.length = 129;

      {
         auto ln = sck.receive(buffer);

         auto reply = buffer[0..ln];

         assert(reply.startsWith("HTTP/1.1 101 Switching Protocols"));
         assert(reply.canFind("sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
      }

      buffer.length = 32000;
      ubyte[] reply;

      while(reply.length < 2 + "Hello world.".length)
      {
         auto recv = sck.receive(buffer);

         if(recv <= 0) break;

         reply ~= buffer[0..recv];
      }

      assert(reply[2..$].startsWith("Hello world.".representation), reply.to!string);
      (new WebSocket(sck)).sendClose();
   }

   info("Testing Websocket not accepted");
   {
      auto handshake = "GET /notaccepted HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

      auto sck = new TcpSocket();
      sck.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
      sck.blocking = true;
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(handshake);

      char[] buffer;
      buffer.length = 32000;

      auto ln = sck.receive(buffer);
      auto reply = buffer[0..ln];
      assert(reply.startsWith("HTTP/1.1 403 Forbidden"), reply);
   }

   {
      auto handshake = "GET /hello HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

      auto sck = new TcpSocket();
      sck.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
      sck.blocking = true;
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(handshake);

      ubyte[] buffer;
      buffer.length = 129;

      {
         auto ln = sck.receive(buffer);

         auto reply = buffer[0..ln];

         assert(reply.startsWith("HTTP/1.1 101 Switching Protocols"));
         assert(reply.canFind("sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
      }

      WebSocket ws = new WebSocket(sck, WebSocket.Role.Client);
      ws.sendMessage(WebSocketMessage("Hello from client"), true);

      buffer.length = 32000;
      ubyte[] reply;

      while(reply.length < "Hello from client".length + 2 + 4 + 2)
      {
         auto recv = sck.receive(buffer);

         if(recv <= 0)
         {
            version(Posix)
            {
               import core.stdc.errno : errno, EINTR;
               if (errno == EINTR)
               {
                  warning("EINTR");
                  continue;
               }
               else warning("errno: ", errno);
            }
            break;
         }

         reply ~= buffer[0..recv];
      }

      assert(reply[2..$].startsWith("Hello from client".representation), reply.to!string);
      assert(reply[2 + "Hello from client".representation.length + 2..$].startsWith([123,0,0,0]), reply.to!string);
      ws.sendClose();
   }

   info("Test splitted message");
   {
      auto handshake = "GET /hello HTTP/1.1\r\nHost: localhost:8080\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n";

      auto sck = new TcpSocket();
      sck.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
      sck.blocking = true;
      sck.connect(new InternetAddress("localhost", 8080));
      sck.send(handshake);

      ubyte[] buffer;
      buffer.length = 129;

      ubyte[] handshakeReply;
      {
         auto ln = sck.receive(buffer);

         handshakeReply = buffer[0..ln];

         assert(handshakeReply.startsWith("HTTP/1.1 101 Switching Protocols"));
         assert(handshakeReply.canFind("sec-websocket-accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="));
      }

      WebSocket ws = new WebSocket(sck, WebSocket.Role.Client);
      ws.sendMessage(WebSocketMessage("Hello "), false);
      ws.sendMessage(WebSocketMessage(WebSocketMessage.OpCode.Continue, "from "), false);
      ws.sendMessage(WebSocketMessage(WebSocketMessage.OpCode.Continue, "client"), true);

      buffer.length = 32000;
      ubyte[] reply;
      ptrdiff_t recv;

      while(reply.length < "Hello from client".length + 2 + 4 + 2)
      {
         recv = sck.receive(buffer);

         if(recv <= 0)
         {
            version(Posix)
            {
               import core.stdc.errno : errno, EINTR;
               if (errno == EINTR)
               {
                  warning("EINTR");
                  continue;
               }
               else warning("errno: ", errno);
            }
            break;
         }

         reply ~= buffer[0..recv];
      }

      // For debugging error popping up every now and then on macOS
      if (reply.length < 2)
      {
         warning("Recv: ", recv);
         warning("Socket error: ", sck.getErrorText());
         warning("Socket alive: ", sck.isAlive);
      }

      assert(reply[2..$].startsWith("Hello from client".representation), reply.to!string);
      assert(reply[2 + "Hello from client".representation.length + 2..$].startsWith([123,0,0,0]), reply.to!string);
      ws.sendClose();
   }

   import core.thread;
   Thread.sleep(250.msecs);
}
