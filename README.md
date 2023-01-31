###### [quickstart](https://github.com/trikko/serverino/blob/master/README.md#quickstart) – [minimal example](https://github.com/trikko/serverino/blob/master/README.md#a-simple-webserver-in-just-three-lines) – [docs]( https://github.com/trikko/serverino/blob/master/README.md#documentation-you-need) – [use nginx as proxy](https://github.com/trikko/serverino/blob/master/README.md#shielding-the-whole-thing) – [run serverino inside a docker](https://github.com/trikko/serverino/blob/master/README.md#run-serverino-inside-a-docker) 

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
* [Request](https://serverino.dpldocs.info/serverino.interfaces.Request.html) - What user asked
* [Output](https://serverino.dpldocs.info/serverino.interfaces.Output.html) - Your reply
* [ServerinoConfig](https://serverino.dpldocs.info/serverino.config.ServerinoConfig.html) - Server configuration

## Defining more than one endpoint
**Every function marked with ```@endpoint``` is called until one writes something to output**

The calling order is defined by ```@priority```

```d
import serverino;
mixin ServerinoMain;

// This function will never block the execution of other endpoints since it doesn't write anything to output
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
   sc.addListener!(ServerinoConfig.ListenerProtocol.IPV6)("localhost", 8082); // IPV6
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

## Run serverino inside a docker

First, create your serverino application:
```dub init -t serverino my_serverino && cd my_serverino```

Then, create a ```Dockerfile``` with a minimal system. Let's use Alpine (but you can use everything you want: ubuntu, arch, etc..)

```Dockerfile
FROM alpine:latest

RUN apk update && apk upgrade
RUN apk add dmd dub cmake gcc make musl-dev
RUN ln -fs /usr/share/zoneinfo/Europe/Rome /etc/localtime
RUN apk add tzdata
RUN adduser -D -S www-data

WORKDIR /source
```

Build your docker
```
docker build -t your_docker .
```

Finally run dub inside your docker but using your local dir for source and dub cache. I guess you want to put the following line in a script ```dub.sh```
```sh
docker run -ti --rm -v $(pwd):/source -v $(pwd)/.docker-dub:/root/.dub -p 8080:8080 your_docker dub
```
