/+
 + The code shown on the site.
 +
 + Examples are read from ../examples at compile time (string imports), and the
 + demo snippets are cut out of demos.d the same way: the site cannot show code
 + that differs from the code in the repository.
+/
module sources;

import std;
import serverino;
import serverino.common : SERVERINO_MAJOR, SERVERINO_MINOR, SERVERINO_REVISION;

struct Example
{
   string id;
   string title;
   string summary;
   string code;
}

immutable Example[] examples = [
   Example("01_hello_world", "Hello world",
      "The whole server: read a query parameter, write an answer.",
      import("01_hello_world/source/app.d")),

   Example("02_priority", "Priority",
      "A high priority endpoint filters requests before the others see them.",
      import("02_priority/source/app.d")),

   Example("03_form", "Forms and uploads",
      "GET and POST fields, multipart forms and uploaded files.",
      import("03_form/source/app.d")),

   Example("04_html_dom", "HTML templates",
      "Filling an HTML template through a DOM, with parserino.",
      import("04_html_dom/source/app.d")),

   Example("05_websocket_echo", "WebSocket echo",
      "An upgrade handler and a receive loop: that's a WebSocket server.",
      import("05_websocket_echo/source/app.d")),

   Example("06_websocket_noise_stream", "WebSocket stream",
      "Pushing a continuous stream of generated data to the browser.",
      import("06_websocket_noise_stream/source/app.d")),

   Example("07_websocket_callback", "WebSocket callbacks",
      "The same thing in callback style, instead of a receive loop.",
      import("07_websocket_callback/source/app.d")),

   Example("08_cmdline_args", "Command line arguments",
      "Configuring the server from argv, inside @onServerInit.",
      import("08_cmdline_args/source/app.d")),

   Example("09_simple_session", "Sessions",
      "A minimal cookie based session manager.",
      import("09_simple_session/source/app.d")),

   Example("10_diet_ng_templates", "diet-ng templates",
      "Compile time HTML templates with diet-ng.",
      import("10_diet_ng_templates/source/app.d")),

   Example("11_elemi_integration", "Type safe HTML",
      "Building HTML in D with elemi, no templates involved.",
      import("11_elemi_integration/source/app.d")),

   Example("12_https", "HTTPS",
      "Plain and encrypted listeners in the same process, and a redirect.",
      import("12_https/source/app.d")),

   Example("13_letsencrypt", "Let's Encrypt",
      "A server that gets and renews its own certificate, with no restart.",
      import("13_letsencrypt/source/app.d")),
];

/// The demos, with the very code that serves them.
immutable string[] demoIds = [
   "hello", "chain", "crash", "slow", "pool",
   "footprint", "telemetry", "upload", "chat"
];

/+ The version of the library that is actually compiled into this binary:
 + serverino exposes it as three constants, so there is nothing to keep in
 + sync and nothing to get wrong.
+/
enum SERVERINO_VERSION = format!"v%d.%d.%d"(SERVERINO_MAJOR, SERVERINO_MINOR, SERVERINO_REVISION);

/+ The files an agent is told to fetch, served from this site rather than from
 + somewhere else: they are baked into the binary at compile time, straight
 + from docs/, so what you download is what this build knows.
+/
@endpoint @route!"/llms.txt"
void llmsTxt(Request request, Output output) { asText(output, import("llms.txt")); }

@endpoint @route!"/llms-full.txt"
void llmsFull(Request request, Output output) { asText(output, import("llms-full.txt")); }

@endpoint @route!"/AGENTS.md"
void agentsMd(Request request, Output output) { asText(output, import("AGENTS.md")); }

/+ The same text with the front matter that makes it a skill an agent can
 + install by itself. One source, two shapes: tools that want a plain rules
 + file take AGENTS.md, tools that want a skill take this.
+/
@endpoint @route!"/SKILL.md"
void skillMd(Request request, Output output)
{
   // The body already points at the reference, by name and by address, so it
   // reads correctly whether it was installed from here or unzipped from the
   // bundle. Nothing to add but the front matter.
   asText(output,
      "---\n"
      ~ "name: serverino-dlang\n"
      ~ "description: Official reference for Serverino, a zero-dependency HTTP/WebSocket "
      ~ "server library for the D programming language. Use it whenever the user asks about "
      ~ "Serverino or about writing a web server in D.\n"
      ~ "---\n\n"
      ~ import("AGENTS.md"));
}

void asText(Output output, string body_)
{
   output.addHeader("content-type", "text/plain; charset=utf-8");
   output.addHeader("cache-control", "no-cache");
   output ~= body_;
}

@endpoint @route!"/api/version"
void apiVersion(Request request, Output output)
{
   output.addHeader("content-type", "text/plain");
   output.addHeader("cache-control", "no-cache");
   output ~= SERVERINO_VERSION;
}

@endpoint @route!"/api/examples"
void apiExamples(Request request, Output output)
{
   JSONValue[] list;

   foreach(e; examples)
      list ~= JSONValue([
         "id": e.id, "title": e.title, "summary": e.summary, "code": e.code
      ]);

   output.addHeader("content-type", "application/json");
   output.addHeader("cache-control", "public, max-age=600");
   output ~= JSONValue(list).toString;
}

@endpoint @route!"/api/demos"
void apiDemos(Request request, Output output)
{
   JSONValue[string] snippets;

   static foreach(id; demoIds)
      snippets[id] = JSONValue(snippet(id));

   output.addHeader("content-type", "application/json");
   output.addHeader("cache-control", "public, max-age=600");
   output ~= JSONValue(snippets).toString;
}

/+ Cuts the region between `// snippet:<id>` and `// snippet-end` out of
 + demos.d. Done at compile time: the string ends up in the binary.
+/
string snippet(string id)()
{
   enum source = import("demos.d");
   enum begin = "// snippet:" ~ id ~ "\n";
   enum end = "// snippet-end";

   enum start = source.indexOf(begin);
   static assert(start >= 0, "No snippet named `" ~ id ~ "` in demos.d");

   enum body_ = source[start + begin.length .. $];
   enum stop = body_.indexOf(end);
   static assert(stop >= 0, "Snippet `" ~ id ~ "` is not closed in demos.d");

   return body_[0 .. stop].stripRight;
}

/// Ditto, chosen at run time among the known ids.
string snippet(string id)
{
   switch(id)
   {
      static foreach(known; demoIds)
         case known: return snippet!known;

      default: return string.init;
   }
}
