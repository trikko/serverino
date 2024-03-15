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
import serverino.tests;

import std;

mixin ServerinoTest;

@route!"/sleep"
@endpoint void sleep(Request r, Output o)
{
   import core.thread;
   Thread.sleep(1.dur!"seconds");
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

@onServerInit
ServerinoConfig conf()
{
   return ServerinoConfig
      .create()
      .setMaxRequestTime(1.dur!"seconds")
      .setMaxRequestSize(2000)
      .addListener("0.0.0.0", 8080)
      .setWorkers(4);
}

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
      assert(data == "HTTP/1.0 200 OK\r\nconnection: close\r\ncontent-type: text/plain\r\ncontent-length: 6\r\n\r\nsimple");
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

         assert(data == "HTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-type: text/plain\r\ncontent-length: 6\r\n\r\nsimpleHTTP/1.1 200 OK\r\nconnection: keep-alive\r\ncontent-type: text/plain\r\ncontent-length: 5\r\n\r\nsleptHTTP/1.0 200 OK\r\nconnection: close\r\ncontent-type: text/plain\r\ncontent-length: 6\r\n\r\nsimple");
      }




   }
}