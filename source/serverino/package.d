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

/++ Serverino is a small and ready-to-go http server, in D. It is multiplatform
+ and compiles with DMD, LDC and GDC.
+
+ The following example shows how to create a server that responds to all requests
+ with the request dump, in a few lines of code.
+ ---
+ import serverino;
+ mixin ServerinoMain;
+ void hello(const Request req, Output output) { output ~= req.dump(); }
+ ---
+ `serverino.interfaces.Request` is the request object received, and `serverino.interfaces.Output` is the output you can write to.
+
+ A more complete example is the following:
+
+ ---
+ import serverino;
+ mixin ServerinoMain;
+
+ @onServerInit ServerinoConfig setup()
+ {
+    ServerinoConfig sc = ServerinoConfig.create(); // Config with default params
+    sc.addListener("127.0.0.1", 8080);
+    sc.setWorkers(2);
+    // etc...
+
+    return sc;
+ }
+
+ @endpoint
+ void dump(const Request req, Output output) { output ~= req.dump(); }
+
+ @endpoint @priority(1)
+ @route!"/hello"
+ void hello(const Request req, Output output) { output ~= "Hello, world!"; }
+ ---
+
+ The function decorated with `serverino.config.onServerInit` is called when the server is initialized, and it is
+ used to configure the server. It must return a `serverino.config.ServerinoConfig` object.
+ In this example, the server is configured to listen on localhost:8080, with 2 workers.
+
+ Every function decorated with `serverino.config.endpoint` is an endpoint. They are called in order of priority assigned with
+ `serverino.config.priority` (default is 0). The first endpoint that write something to the output is the one that will respond to the request.
+
+ The `serverino.config.route` attribute can be used to filter the requests that are passed to the endpoint, using a path or a `bool delegate(Request r)` argument.
+ In this example, only requests to `/hello` are passed to the `hello` endpoint. The `serverino.config.route` attribute can be used multiple times to specify multiple routes also using a delegate.
+/
module serverino;

public import serverino.main;
public import serverino.config;
public import serverino.interfaces;
