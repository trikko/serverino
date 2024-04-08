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

module app;

import serverino;

import std;
import core.thread;

mixin ServerinoMain;

@onDaemonStart void run_tests()
{
   import core.thread;
   import core.stdc.stdlib : exit;
   import serverino.daemon;

   new Thread({

      Thread.getThis().isDaemon = true;

      // Is serverino ready?
      while(!Daemon.bootCompleted)
         Thread.sleep(10.msecs);

      // Run the tests
      try {
         test();
         writeln("All tests passed!");
      }
      catch (Throwable t)
      {
         writeln("Test failed");
         writeln(t);
         exit(-1);
      }

      Daemon.shutdown();

   }).start();
}

@route!"/sleep"
@endpoint void sleep(Request r, Output o)
{
   import core.thread;
   Thread.sleep(600.msecs);
   o.addHeader("Content-type", "text/plain");
   o ~= "slept";
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

@route!(x => x.uri.startsWith("/echo/"))
@endpoint void echo(Request r, Output o)
{
   o ~= r.uri[6..$];
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

@onWebSocketUpgrade bool upgrade(Request r) { return r.uri == "/chat" || r.uri == "/pizza" || r.uri == "/hello"; }

void test()
{

   // Testing minimal http/1.0 request
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

   // Testing crash endpoint. The server should not crash
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

   // Testing pipeline
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

   // Testing crash endpoint. The server should not crash
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

   // Multiple parallels pipelines (100 request * 10 pipelines)
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

         assert(data == response);
      }

      ThreadGroup tg = new ThreadGroup();

      foreach(k; 0..10)
         tg.add(new Thread({pipeline(k+1);}).start());

      tg.joinAll();


   }
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
      assert(reply.startsWith("HTTP/1.1 426 Upgrade Required"), reply);
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

      WebSocket ws = new WebSocket(sck);
      ws.sendMessage(WebSocketMessage("Hello from client"), true, true);

      buffer.length = 32000;
      ubyte[] reply;

      while(reply.length < "Hello from client".length + 2 + 4 + 2)
      {
         auto recv = sck.receive(buffer);

         if(recv <= 0) break;

         reply ~= buffer[0..recv];
      }

      assert(reply[2..$].startsWith("Hello from client".representation), reply.to!string);
      assert(reply[2 + "Hello from client".representation.length + 2..$].startsWith([123,0,0,0]), reply.to!string);
      ws.sendClose();
   }

   import core.thread;
   Thread.sleep(250.msecs);
}