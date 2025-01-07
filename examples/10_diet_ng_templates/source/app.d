module app;

// Use the diet-ng library to compile HTML templates and serve them with serverino
// Translated from https://github.com/rejectedsoftware/diet-ng/tree/master/examples/htmlserver
import diet.html;
import serverino;

mixin ServerinoMain;

void simple(Request request, Output output)
{
	import std.array : appender;

	auto page = appender!string;	// Page will be written to this
	int iterations = 10;				// Number of iterations to show in the page

	// Compile the page
	page.compileHTMLDietFile!("index.dt", iterations);

	// Write the page to the output
	output ~= page.data;
}
