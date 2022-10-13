# serverino [![BUILD & TEST](https://github.com/trikko/serverino/actions/workflows/d.yml/badge.svg)](https://github.com/trikko/serverino/actions/workflows/d.yml)
* Ready-to-go http server
* Cross-platform (Linux/Windows/MacOS)
* Multi-process
* Dynamic number of workers
* Zero dependencies
* Build & start your project in a few seconds


## Quickstart
```
dub init your_fabulous_project -t serverino
cd your_fabulous_project
dub run
```

## A simple webserver in just three lines
```d
import serverino;
mixin ServerinoMain;
void hello(const Request req, Output output) { output ~= req.dump(); }
```

## Documentation you need
* [Request](https://serverino.dpldocs.info/serverino.worker.Request.html) - What user asked
* [Output](https://serverino.dpldocs.info/serverino.worker.Output.html) - Your reply
* [ServerinoConfig](https://serverino.dpldocs.info/serverino.common.ServerinoConfig.html) - Server configuration

## Defining more than one endpoint
**Every function marked with ```@endpoint``` is called until one writes something to output**. The calling order is defined by ```@priority```

```d
import serverino;
mixin ServerinoMain;

// This function will never block the execution of other endpoints since it doesn't write anything
// In this case `output` param is not needed and this works too: `@priority(10) @endpoint void logger(Request req)`
@priority(10) @endpoint void logger(Request req, Output output)
{
   import std.experimental.logger; // std.experimental.logger works fine!
   log(req.uri);
}

// This endpoint (default priority == 0) handles the homepage
// Request and Output can be used in @safe code
@safe
@endpoint void hello(Request req, Output output)
{
   // Skip this endpoint if uri is not "/"
   if (req.uri != "/") return;

   output ~= "Hello world!";
}

// This function will be executed only if `hello(...)` doesn't write anything to output.
@priority(-10000) @endpoint void notfound(const Request req, Output output)
{
   output.status = 404;
   output ~= "Not found";
}
```

## @onServerInit UDA
Use ```@onServerInit``` to configure your server
```d
// Try also `setup(string args[])` if you need to read arguments passed to your application
@onServerInit ServerinoConfig setup()
{
   ServerinoConfig sc = ServerinoConfig.create(); // Config with default params
   sc.addListener("127.0.0.1", 8080);
   sc.addListener("127.0.0.1", 8081);
   sc.setWorkers(2);
   // etc...

   return sc;
}

```

## @onWorkerStart, @onWorkerStop UDAs

```d
/+
 When a worker is created, this function is called.
 Useful to init database connection & everything else.
+/
@onWorkerStart
auto start()
{
   // Connect to db...
}
```

## Use serverino across multiple modules

```d
module test;
import serverino;

@endpoint void f1(Request r, Output o) { ... }
```

```d
module other;
import serverino;

@endpoint void f2(Request r, Output o) { ... }
```

```d
module main;
import serverino;
import test, other;

mixin ServerinoMain!(other, test); // Current module is always processed
```

## Shielding the whole thing
I would not put serverino into the wild. For using in production I suggest shielding serverino under nginx.
It's pretty easy. Just add these lines inside your nginx configuration:

```
server {
   listen 80 default_server;
   listen [::]:80 default_server;
   
   location /your_path/ {
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      
      proxy_pass http://localhost:8080;
   }
   ...
   ...
}
```

If you want to enable keepalive (between nginx and serverino) you must use an upstream:

```
upstream your_upstream_name {
  server localhost:8080;
  keepalive 64;
}


server {
   listen 80 default_server;
   listen [::]:80 default_server;

   location /your_path/ {
      proxy_set_header Connection "";
      proxy_http_version 1.1;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      
      proxy_pass http://your_upstream_name;
    }
    
    ...
    ...
 }
```
