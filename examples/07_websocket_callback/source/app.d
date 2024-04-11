module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
// Examples: https://github.com/trikko/serverino/tree/master/examples
import serverino;
mixin ServerinoMain;


@onWebSocketUpgrade bool onUpgrade(Request r) {
	// Ok we should check if url and host are correct but it's just an example
	return true;
}

@endpoint void websocket(Request request, WebSocket ws)
{
	// When websocket receives a text message this function is called
	ws.onTextMessage = (text) {
		// Echo the message received from the client
		log("Received text message: ", text);

		// Message will not propagate to other handlers
		return false;
	};

	// When websocket receives a close message this function is called
	ws.onCloseMessage = (msg) {
		import core.stdc.stdlib;

		log("Received close message. Goodbye!");
		exit(0);

		return false;
	};

	// Also: ws.onBinaryMessage and ws.onMessage

	// Infinite loop waiting for messages
	ws.socket.blocking = true;
	while(true) { ws.receiveMessage(); }
}

@route!"/"
@endpoint void index(Request r, Output o) { o.serveFile("static/index.html"); }
