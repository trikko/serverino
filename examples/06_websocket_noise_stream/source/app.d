module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
// Examples: https://github.com/trikko/serverino/tree/master/examples
import serverino;
import opensimplexnoise;
import core.thread;

mixin ServerinoMain;

OpenSimplexNoise!float noise;
SysTime startedAt;


@onWebSocketUpgrade bool onUpgrade(Request r) {
	// Ok we should check if url and host are correct but it's just an example
	return true;
}

@onWebSocketStart void onWsStart() {
	// We init the opensimplex noise generator
	noise = new OpenSimplexNoise!float(1234);
	startedAt = Clock.currTime;
}

@endpoint void websocket(Request request, WebSocket ws)
{
	immutable res = 32;

	while(true)
	{
		float[res*res] data;

		float z = (Clock.currTime - startedAt).total!"msecs"/1000.0f;

		foreach(y; 0..res)
			foreach(x;0..res)
				data[y*res+x] = noise.eval(x/12.0, y/12.0, z*1.5) * 0.5 + 0.5;

		ws.send(data);
		Thread.sleep(10.msecs);
	}


}

@route!"/"
@endpoint void index(Request r, Output o) { o.serveFile("static/index.html"); }

@route!"/style.css"
@endpoint void css(Request r, Output o) { o.serveFile("static/style.css"); }
