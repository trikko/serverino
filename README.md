serverino
<img align="left" alt="Logo" width="100" src="https://github.com/trikko/serverino/assets/647157/a6f462fa-8b76-43c3-9855-0671e704aa6c" height="96">
=======
[![BUILD & TEST](https://github.com/trikko/serverino/actions/workflows/d.yml/badge.svg)](https://github.com/trikko/serverino/actions/workflows/d.yml) [![LICENSE](https://img.shields.io/badge/LICENSE-MIT-blue)](https://github.com/trikko/serverino/tree/master/LICENSE) [![Donate](https://img.shields.io/badge/paypal-buy_me_a_beer-FFEF00?logo=paypal&logoColor=white)](https://paypal.me/andreafontana/5)
###### [quickstart](#quickstart) – [minimal example](#a-simple-webserver-in-just-three-lines) – [wiki](https://github.com/trikko/serverino/wiki/) - [more examples](https://github.com/trikko/serverino/tree/master/examples/) - [docs]( #documentation-you-need) – [shielding serverino using proxy](#shielding-the-whole-thing)
---
* 🚀 **Quick build & start**: *build & run your server in seconds.*
* 🙌 **Zero dependencies**: *serverino doesn't rely on any external library.*
* 💪 **High performance**: *capable of managing tens of thousands of connections per second.*
* 🌐 **Cross-platform**: *every release is tested on Linux, Windows, and MacOS.*
* 🔄 **Hot-reload**: *restart workers without downtime or dropped connections. [(how?)](#restarting-workers-without-downtime)*


## Quickstart
Install a [dlang compiler](https://dlang.org/), then:
```sh
dub init your_app_name -t serverino
cd your_app_name
dub run
```

## A simple webserver in just three lines
```d
import serverino;
mixin ServerinoMain;
void simple(Request request, Output output) { output ~= request.dump(); }
```

## Documentation you need
* [Serverino docs](https://trikko.github.io/serverino/) - Serverino reference, generated from code
* [Examples](https://github.com/trikko/serverino/tree/master/examples) - Some ready-to-try examples
* [Tips](https://github.com/trikko/serverino/wiki/) - Some snippets you want to read

## Defining more than one endpoint
> [!IMPORTANT]
> All the functions marked with ```@endpoint``` will be called one by one, in order of ```@priority``` (higher to lower), until one of them modifies the output.

```d
module app;

import std;
import serverino;

mixin ServerinoMain;

// This endpoint handles the root of the server. Try: http://localhost:8080/
@endpoint @route!"/"
void homepage(Request request, Output output)
{
	output ~= `<html><body>`;
	output ~= `<a href="/private/profile">Private page</a><br>`;
	output ~= `<a href="/private/asdasd">Private (404) page</a>`;
	output ~= `</body></html>`;
}

// This endpoint shows a private page: it's protected by the auth endpoint below.
@endpoint @route!"/private/profile"
void user(Request request, Output output)
{
	output ~= "Hello user!";
}

// This endpoint shows a private page: it's protected by the auth endpoint below.
@endpoint
void blah(Request request, Output output)
{
	// Same as marking this endpoint with @route!"/private/dump"
	if (request.path != "/private/dump")
		return;

	output ~= request.dump();
}

// This endpoint simply checks if the user and password are correct for all the private pages.
// Since it has a higher priority than the previous endpoints, it will be called first.
@priority(10)
@endpoint @route!(r => r.path.startsWith("/private/"))
void auth(Request request, Output output)
{
	if (request.user != "user" || request.password != "password")
	{
		// If the user and password are not correct, we return a 401 status code and a www-authenticate header.
		output.status = 401;
		output.addHeader("www-authenticate",`Basic realm="my serverino"`);
	}

	// If the user and password are correct, we call the next matching endpoint.
	// (the next matching endpoint will be called only if the current endpoint doesn't write anything)
}

// This endpoint has the highest priority between the endpoints and it logs all the requests.
@priority(12) @endpoint
void requestLog(Request request)
{
	// There's no http output, so the next endpoint will be called.
	info("Request: ", request.path);
}
```
> [!NOTE]
> Using `Fallthrough.Yes` as a return value for a endpoint allows you to avoid stopping the flow even if the output is touched.

## Managing request-scoped state

Global variables marked with `@requestScope` are automatically reset at the beginning and end of each request, preventing data leaks between separate HTTP requests.

```d
import serverino;

mixin ServerinoMain;

// Global variable - reset for every request
@requestScope UserData currentUser;

// Global variable - persists across requests (until the worker is stopped)
UserCache cache;

@endpoint
void handler(Request request, Output output)
{
	currentUser.id = request.get("user_id").to!int;  // Reset every request
	cache.store(currentUser.id);  // Persists across requests

	output ~= "User " ~ currentUser.id.to!text ~ " loaded";
}
```

**How it works:**
- Global variables marked with `@requestScope` are automatically destroyed and re-initialized at the beginning and end of each HTTP request
- This ensures that state from one request doesn't leak into the next request
- Useful for request-specific global state like the current user, request buffers, or temporary session data

## Websockets

```d
// Accept a new connection only if the request path is "/echo"
// Every websocket will start a new indipendent process
@onWebSocketUpgrade bool onUpgrade(Request req) {
	return req.path == "/echo";
}

// Handle the WebSocket connection
// Just like a normal endpoint, but with a WebSocket parameter
@endpoint void echo(Request r, WebSocket ws) {

	// Keep the websocket running
	while (true) {

		// Try to receive a message from the client
		if (WebSocketMessage msg = ws.receiveMessage())
		{
			// If we received a message, send it back to the client
			ws.send("I received your message: `" ~ msg.asString ~ "`");
		}
	}

	// When the function returns, the WebSocket connection is closed
}
```

## Restarting workers without downtime
> [!CAUTION]
> Hot-reloading only affects the worker processes, not the main daemon process. If you modify code in the main daemon process, those changes will not be applied until you fully restart the server. Only changes to endpoint handlers and worker-specific code will be picked up by the hot-reload mechanism.

Serverino workers can be restarted on demand without causing downtime.
 * On POSIX systems: send `SIGUSR1` signal to the main process with `kill -10 <daemon_pid>` or `kill -SIGUSR1 <daemon_pid>`
 * On Windows: delete the canary file in the temp folder named `serverino-pid-<sha256 of pid>.canary`

This allows you to recompile your workers and perform hot-reloading of your application code without any service interruption or dropped connections.


## Shielding the whole thing
> [!CAUTION]
>  I recommend securing *serverino* behind a full web server. Below, I provide three examples of how to run *serverino* with *caddy*, *nginx* and *apache*.

### Using caddy
Caddy is probably the fastest and easiest solution. It automatically obtains and renews SSL certificates for your domains.

Here's a minimal working `Caddyfile` (with https!):
```
yourhost.example.com {   
   reverse_proxy localhost:8080 
}
```

Probably you want to forward also some headers (in this example we create a local proxy on port 8081):
```
:8081 {   
   reverse_proxy localhost:8080 {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
   }
}
```

You can easily balance the load between multiple serverino instances, Caddy automatically handles round-robin load balancing when you specify multiple backends:
```
yourhost.example.com {   
   reverse_proxy localhost:8080 backend1.example.com:8080 backend2.example.com:8080 {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
   }
}
```


### Using nginx
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
### Using apache2
Enable proxy module for apache2:
```
sudo a2enmod proxy
sudo a2enmod proxy_http
```

Add a proxy in your virtualhost configuration:
```
<VirtualHost *:80>
   ProxyPass "/"  "http://localhost:8080/"
   ...
</VirtualHost>
```
