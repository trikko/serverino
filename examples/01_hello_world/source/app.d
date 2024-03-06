module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
import serverino;

mixin ServerinoMain;

// Just print your name, try: http://localhost:8080/?name=yourname
void example(Request request, Output output)
{
	// Print the name if it's provided, otherwise print "guest"
	output ~= "Hello " ~ request.get.read("name", "guest") ~ "!";
}

