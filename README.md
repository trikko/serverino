# serverino
Small and ready-to-go http/https server, in D.

## Ready-to-go in less than a minute
You can serve a html page in just three lines

```d
import serverino;
mixin ServerinoMain;
void hello(const Request req, Output output) { output ~= req.dump(); }
```

## Defining more than one endpoint
Every function marked with ```@endpoint``` will be evaluated until the first one that write something on output
The calling order is based on assigned ```@priority```

```d
import serverino;
mixin ServerinoMain;

// This function will never block the execution of other endpoints since it doesn't write anything
// Try also: @priority(10) @endpoint void logger(Request req) { ... }
@priority(10) @endpoint void logger(Request req, Output output) 
{ 
   import std.experimental.logger; // std.experimental.logger works fine!
   log(req.uri);
}

// This function (default priority == 0) handle / url
@endpoint @safe void hello(Request req, Output output) 
{ 
   // Skip this endpoint if uri is not "/"
   if (req.uri != "/") return;

   output ~= "Hello world!";
}

// Low priority, last function executed
@priority(-10000) @endpoint void notfound(const Request req, Output output) 
{
   output.status = 404;
   output ~= "Not found";
}
```

## Setup server

```d

import serverino;
mixin ServerinoMain;

string mystr = "toinit";

@endpoint @safe void hello(Request req, Output output) 
{ 
   import std.conv : to;
   output ~= "Request handled by worker " ~ req.worker.to!string ~ " - My str:" ~ mystr;
   output ~= req.dump();
}

// Setup server. Use setup(string args[]) if you need app params
@onServerInit 
auto setup()
{
   ServerinoConfig sc = ServerinoConfig.create();
   sc.addListener("127.0.0.1", 8080);
   sc.addListener("127.0.0.1", 8081);
   sc.setWorkers(2); 

   return sc;
}

// When a worker is created, this function is called.
// Useful to init database connection & everything else.
@onWorkerStart
auto start()
{
   import std.experimental.logger;
   log("New worker ready.");
   mystr = "inited";
}

```


