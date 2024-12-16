module app;

import std;
import serverino;

mixin ServerinoMain;

// Just dump the request to the output, it's just an example.
void example(Request request, Output output)
{
	output ~= request.dump(true);
}

// If you need to pass command line arguments to the serverino, you can do it here.
@onServerInit ServerinoConfig configure(string[] args)
{
	ushort port = 0;
	bool showHelp = false;

	// Parse the command line arguments using std.getopt looking for the --port option.
	try { showHelp = getopt(args, "port",  &port).helpWanted; }
	catch (Exception e) { showHelp = true; }

	// If the user asked for --help or the port is not set, show the usage and exit with code 1.
	if (showHelp || port == 0)
	{
		writeln("Usage: \n" ~ thisExePath.baseName ~ " --port <port>\n");
		writeln("Example: \n" ~ thisExePath.baseName ~ " --port 8080\n");
		return ServerinoConfig.create().setReturnCode(1);
	}

	// Return the configuration for the serverino with the port set by the user.
	return ServerinoConfig.create().addListener("0.0.0.0", port);
}


