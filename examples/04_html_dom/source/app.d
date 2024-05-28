module app;

import std;

// Docs: https://trikko.github.io/serverino/
// Tips and tricks: https://github.com/trikko/serverino/wiki/
import serverino;

// A super fast dom library. Docs: https://trikko.github.io/parserino/
import parserino;

mixin ServerinoMain;


@endpoint
void example(Request request, Output output)
{
	// Skip if the request is not for the root
	// You can also use @route!("/") to achieve the same result
	if (request.path != "/")
		return;

	// Read the query parameter, default to "https://trikko.github.io/serverino"
	auto query = request.get.read("query", "https://trikko.github.io/serverino");

	// Parse the html
	Document doc = Document(readText("html/index.html"));

	// Set the title and caption
	doc.byTagName("title").front.innerText = `QRCode for text: \"` ~ query ~ `"`;
	doc.byId("caption").innerText = "QRCode for text: " ~ query;

	// Get the url for the QRCode. This is a public API that generates QRCode images.
	doc.byTagName("img").front.setAttribute("src", "https://api.qrserver.com/v1/create-qr-code/?margin=25&size=300x300&data=" ~ query);

	// Write the document to the output
	output ~= doc;
}

// Low priority endpoint to handle 404 errors. This will be called if no other endpoint writes to the output.
@endpoint @priority(-1)
void page404(Output output)
{
	// Set the status code to 404
	output.status = 404;
	output.addHeader("Content-Type", "text/plain");

	// Write a simple message
	output.write("Page not found!");
}

