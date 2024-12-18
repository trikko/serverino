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

@endpoint
void test(Request request, Output output)
{
   output.status = 200;
   output ~= "OK";

   log("Request received: ", request.path);
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
   assertNotThrown(get("http://localhost:8080/3", client) == "OK");

   Daemon.shutdown();

}