# serverino
* Ready-to-go https/https server
* Multi-process
* Dynamic number of workers
* Zero dub dependencies
* Just one C dependency (optional, if you use https)

## A simple webserver in three lines
```d
import serverino;
mixin ServerinoMain;
void hello(const Request req, Output output) { output ~= req.dump(); }
```
## Documentation you need
* [Request](http://) - What user asked
* [Output](http://) - Your reply
* [ServerinoConfig](http://) - Server configuration

## Defining more than one endpoint
Every function marked with ```@endpoint``` will be evaluated until something is sent to output. The calling order is defined by ```@priority```

```d
import serverino;
mixin ServerinoMain;

// This function will never block the execution of other endpoints since it doesn't write anything
// In this case output is not needed and this works too: `@priority(10) @endpoint void logger(Request req)`
@priority(10) @endpoint void logger(Request req, Output output) 
{ 
   import std.experimental.logger; // std.experimental.logger works fine!
   log(req.uri);
}

// This endpoint (default priority == 0) handles the homepage
@endpoint @safe void hello(Request req, Output output) 
{ 
   // Skip this endpoint if uri is not "/"
   if (req.uri != "/") return;

   output ~= "Hello world!";
}

// This function will be executed only if `hello(...)` doesn't touch output.
@priority(-10000) @endpoint void notfound(const Request req, Output output) 
{
   output.status = 404;
   output ~= "Not found";
}
```

## @onServerInit UDA
Use ```@onServerInit``` to configure your server
```d
// Try also `setup(string args[])` if you need to read arguments passed to program
@onServerInit auto setup()
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


