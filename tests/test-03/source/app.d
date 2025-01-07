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

mixin ServerinoBackground;

@endpoint @route!"/head-test"
void head_test(Request request, Output output)
{
   output.status = 200;
   output ~= "OK";
}


@endpoint @route!"/head-mute-test"
void head_mute_test(Request request, Output output)
{
   output.status = 200;
   output ~= "OK";
   output = false;
}

@endpoint @route!"/clear-test"
void clear_test(Request request, Output output)
{
   output.status = 200;
   output ~= "This is a test"; // This will be deleted
   output = null; // Deletes the buffer
   output ~= "This should be sent";
}


@endpoint
void test(Request request, Output output)
{
   output.status = 200;
   output ~= "OK";

   log("Request received: ", request.path);

   if (request.path == "/exception")
      throw new Exception("Test exception");
}

@onWorkerException
bool onException(Request request, Output output, Exception exception)
{
   output.status = 200;
   output ~= "Exception catched";
   return true;
}

void main()
{
   import serverino.daemon;

   assert(Daemon.isRunning, "Wrong daemon state.");
   HTTP client = HTTP();

   // Set the timeout to 500ms.
   client.connectTimeout = 500.msecs;
   client.operationTimeout = 500.msecs;
   client.dataTimeout = 500.msecs;

   while(!Daemon.bootCompleted) Thread.sleep(100.msecs);

   assertNotThrown(get("http://localhost:8080/1", client) == "OK");

   Daemon.suspend();
   Thread.sleep(1.seconds);
   assert(!Daemon.isRunning, "Wrong daemon state.");
   assertThrown(get("http://localhost:8080/2", client));

   Daemon.resume();
   Thread.sleep(1.seconds);
   assert(Daemon.isRunning, "Wrong daemon state.");

   assertNotThrown(get("http://localhost:8080/exception", client) == "Exception catched");



   {
      string content;

      HTTP req = HTTP();
      req.connectTimeout = 500.msecs;
      req.operationTimeout = 500.msecs;
      req.dataTimeout = 500.msecs;
      req.method = HTTP.Method.head;
      req.url = "http://localhost:8080/head-test";
      req.onReceiveHeader = (key, value) { assert(key != "content-length" || value == "2"); };
      req.onReceive = (data) { content ~= cast(string)data; return data.length; };
      req.perform();

      assert(content != "OK");
   }

   {
      string content;

      HTTP req = HTTP();
      req.connectTimeout = 500.msecs;
      req.operationTimeout = 500.msecs;
      req.dataTimeout = 500.msecs;
      req.method = HTTP.Method.get;
      req.url = "http://localhost:8080/head-test";
      req.onReceiveHeader = (key, value) { assert(key != "content-length" || value == "2"); };
      req.onReceive = (data) { content ~= cast(string)data; return data.length; };
      req.perform();

      assert(content == "OK");
   }

   {
      string content;

      HTTP req = HTTP();
      req.connectTimeout = 500.msecs;
      req.operationTimeout = 500.msecs;
      req.dataTimeout = 500.msecs;
      req.method = HTTP.Method.head;
      req.url = "http://localhost:8080/head-mute-test";
      req.onReceiveHeader = (key, value) { assert(key != "content-length" || value == "0"); };
      req.onReceive = (data) { content ~= cast(string)data; return data.length; };
      req.perform();

      assert(content != "OK");
   }

   {
      string content;

      HTTP req = HTTP();
      req.connectTimeout = 500.msecs;
      req.operationTimeout = 500.msecs;
      req.dataTimeout = 500.msecs;
      req.method = HTTP.Method.get;
      req.url = "http://localhost:8080/head-mute-test";
      req.onReceiveHeader = (key, value) { assert(key != "content-length" || value == "0"); };
      req.onReceive = (data) { content ~= cast(string)data; return data.length; };
      req.perform();

      assert(content == string.init);
   }

   {
      string content;

      HTTP req = HTTP();
      req.connectTimeout = 500.msecs;
      req.operationTimeout = 500.msecs;
      req.dataTimeout = 500.msecs;
      req.method = HTTP.Method.get;
      req.url = "http://localhost:8080/clear-test";
      req.onReceive = (data) { content ~= cast(string)data; return data.length; };
      req.perform();

      assert(content == "This should be sent");
   }

   Daemon.shutdown();

}