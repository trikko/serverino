import std.path: buildPath;
import std.file: getcwd, mkdir, write;

immutable example =
`module app;

import serverino;
mixin ServerinoMain;

// Optional. This is used to config serverino.
// See: https://serverino.dpldocs.info/serverino.common.ServerinoConfig.html
@onServerInit ServerinoConfig configure()
{
	return ServerinoConfig
		.create()
      .addListener("0.0.0.0", 8080)
		.setWorkers(4);
}

/*
// Optional. If you need to init db connection or anything else on each worker
// See: https://github.com/trikko/serverino#onworkerstart-onworkerstop-udas
@onWorkerStart void start()
{
   // db = connect_to_db(...);
}
*/


// If you need more than one endpoint, use @endpoint and (optionally) @priority
// See: https://github.com/trikko/serverino#defining-more-than-one-endpoint
void dump(Request request, Output output)
{
	output ~= request.dump(true);
}
`;

void main(string[] args)
{
	string sourceFolder = buildPath(getcwd(), "source");
	mkdir(sourceFolder);

	string appFilePath = buildPath(sourceFolder, "main.d");
	write(appFilePath, example);
}