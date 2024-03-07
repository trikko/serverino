module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
import serverino;

mixin ServerinoMain;

// Optional. If you want to configure custom options, you can use this function.
// See: https://trikko.github.io/serverino/serverino/config/ServerinoConfig.html
@onServerInit ServerinoConfig configure()
{
	return ServerinoConfig
		.create()
		.addListener("0.0.0.0", 8080)
		.setMaxRequestTime(1.seconds)
		.setMaxRequestSize(1024*1024); // 1 MB
		// Many other options are available. Check the docs.
}


@endpoint @route!"/"
void index(Request request, Output output)
{
	// Simply serve the html file.
	output.serveFile("html/form.html");
}


@endpoint @route!"/form_action"
void action(Request request, Output output)
{
	// If the request is not a POST, we don't want to process it.
	if (request.method != Request.Method.Post)
	{
		output.status = 405;
		return;
	}

	// Show the data sent by the form.
	output.addHeader("content-type", "text/plain");
	output ~= "First Name: " ~ request.post.read("first_name", "N/A") ~ "\n";
	output ~= "Last Name: " ~ request.post.read("last_name", "N/A") ~ "\n";
	output ~= "Favorite Color: " ~ request.post.read("color", "N/A") ~ "\n";
}