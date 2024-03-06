module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
import serverino;

mixin ServerinoMain;

// This endpoint will be called for every request
// It has the highest priority, so it will be called first
@endpoint @route!("/") @priority(1000)
void check_method(Request request, Output output)
{
	if (request.method != Request.Method.Get)
		output.status = 405;
}

// This endpoint will be called only if the first one do not write anything to the output (including setting the status)
@priority(10)
@endpoint
@route!("/") // It matches only the root path
void example(Request request, Output output)
{
	output ~= "<html><body>Hello, World! Try <a href=\"/other\">another page</a></body></html>";
}

// This endpoint will be called only if the first two do not write anything to the output
// It has the lowest priority, so it will be called last
@endpoint
void dump(Request request, Output output)
{
	output ~= request.dump(true);
}
