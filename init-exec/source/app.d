immutable example =
`module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
// Examples: https://github.com/trikko/serverino/tree/master/examples
import serverino;

mixin ServerinoMain;

// Use @endpoint and (optionally) @priority if you need more than one endpoint.
// More info: https://github.com/trikko/serverino#defining-more-than-one-endpoint
void example(Request request, Output output)
{
	// Probably you want to delete this spam.
	info("Hello, log! There's a new incoming request. URL: ", request.path);

	// Add the formatted HTML representation of the HTTP request to the output.
	// Useful for debugging. Replace with your own HTML page.
	output ~= request.dump(true);
}

/* The default configuration is used if you do not implement this function.

@onServerInit ServerinoConfig configure()
{
	return ServerinoConfig
		.create()
		.addListener("0.0.0.0", 8080)
		.setMaxRequestTime(1.seconds)
		.setMaxRequestSize(1024*1024); // 1 MB
		// To set a fixed number of workers, use .setWorkers(10)
		// Many other options are available: https://trikko.github.io/serverino/serverino/config/ServerinoConfig.html
}

*/
`;

int main(string[] args)
{
	import std;

	auto bold = "\033[1m";
	auto reset = "\033[0m";
	auto indent = repeat(" ", 13).join;

	version(Windows)
	{
		bold = "";
		reset = "";
	}

	writeln();

	string sourceFolder = buildPath(getcwd(), "source");
	string appFilePath = buildPath(sourceFolder, "app.d");

	if (exists(sourceFolder))
	{
		writeln(bold, "[ERROR]", reset, " A dub package already exists in the directory ", bold, getcwd(), reset, ".");
		writeln(bold, "[ERROR]", reset, " Please choose an empty directory to initialize your new serverino app.");
		return -1;
	}

	mkdir(sourceFolder);
	std.file.write(appFilePath, example);
	writeln(bold, indent, "Well done! Run your shiny new serverino app with:\n");
	writeln(indent, "cd ", getcwd());
	writeln(indent, "dub", reset, "\n");
	return 0;
}
