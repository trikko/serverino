module app;

import std;
import simplesession;
import serverino;

mixin ServerinoMain;

@endpoint @route!("/")
void session_test(Request request, Output output)
{
	// This is a simple session manager.
	// It will create a session if it doesn't exist and set the session_id cookie.
	// It will also read the session_id cookie and use it to identify the session.
	// The session will be stored in a file in the ./sessions directory.
	// The session will expire after 10 seconds.
	SimpleSession session = SimpleSession(request, output, 10.seconds);

	// SimpleSession stores the data in a JSON file.
	JSONValue data = session.load();

	ulong hits = 0;

	if ("hits" in data)
		hits = data["hits"].get!ulong;

	// Increment the hits
	data["hits"] = ++hits;

	// Save session data, you can delete the session using session.remove()
	session.save(data);

	// Just a simple HTML page.
	string htmlTemplate =
	`
	<html><head><style>
	body { font-family: Arial, sans-serif; background-color: #f4f4f9; color: #333; }
	.container { max-width: 600px; margin: 50px auto; padding: 20px; background-color: #fff; border-radius: 8px; box-shadow: 0 0 10px rgba(0, 0, 0, 0.1); }
	h1 { color: #808080; }
	</style></head><body>
	<div class='container'>
	<h1>Session Info</h1>
	<p><strong>Session ID:</strong> {{SESSION_ID}}</p>
	<p><strong>Hits:</strong> {{HITS}}</p>
	<p>If you refresh the page in the next 10 seconds, the hits will increase. If not, the session will expire and the hits will reset.</p>
	</div></body></html>`;

	// Using replace to inject the session id and hits into the template is a bad idea.
	// It's just for demonstration purposes. Use a template engine instead
	// (did you try parserino? https://github.com/trikko/parserino)
	string htmlContent = htmlTemplate
		.replace("{{SESSION_ID}}", session.id())
		.replace("{{HITS}}", hits.to!string);

	output ~= htmlContent;
}
