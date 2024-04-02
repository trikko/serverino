module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
// Examples: https://github.com/trikko/serverino/tree/master/examples
import serverino;

mixin ServerinoMain;

// Accept a new connection only if the request URI is "/echo"
@onWebSocketUpgrade bool onUpgrade(Request req) {
	return req.uri == "/echo";
}

// Handle the WebSocket connection
@endpoint void echo(Request r, WebSocketProxy ws) {

	// Read messages from the client
	while (true) {

		// Only if the message is valid
		if (WebSocketMessage msg = ws.receiveMessage())
		{
			// Send the message back to the client
			ws.sendText("I received your message: `" ~ msg ~ "`");
		}
	}
}

@route!"/"
@endpoint void index(Request r, Output o) { o.serveFile("static/index.html"); }

@route!"/style.css"
@endpoint void css(Request r, Output o) { o.serveFile("static/style.css"); }
