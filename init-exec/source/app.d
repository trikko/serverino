import std.path: buildPath;
import std.file: getcwd, mkdir, write;

immutable example =
`module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
import serverino;

mixin ServerinoMain;

// Optional. This is used to config serverino.
// See: https://trikko.github.io/serverino/serverino/config/ServerinoConfig.html
@onServerInit ServerinoConfig configure()
{
	return ServerinoConfig
		.create()
		.addListener("0.0.0.0", 8080)
		.setWorkers(4);
}


// If you need more than one endpoint, use @endpoint and (optionally) @priority
// See: https://github.com/trikko/serverino#defining-more-than-one-endpoint
void example(Request request, Output output)
{
	// Probably you want to delete this spam.
	info("Hello, log! There's a new incoming request. Url: ", request.uri);

	output ~= request.dump(true);
}

`;

void main(string[] args)
{
	string sourceFolder = buildPath(getcwd(), "source");
	mkdir(sourceFolder);

	string appFilePath = buildPath(sourceFolder, "app.d");
	write(appFilePath, example);
}
