/+
 + The serverino website, served by serverino.
 +
 + Everything the site shows is real: the examples come from ../examples and
 + the demos are endpoints of this very process.
 +
 + Plain http only: in production this sits behind nginx or caddy, which
 + terminates TLS and forwards to the port below. Serverino can do TLS by
 + itself (see examples/12_https and examples/13_letsencrypt), but a site that
 + is already behind a proxy has no use for two of them.
 +
 +    ./serverino-website                       # http://127.0.0.1:8080
 +    ./serverino-website --port 9000           # somewhere else
 +    ./serverino-website --host 0.0.0.0        # if the proxy is on another machine
 +/
module app;

import std;
import serverino;

import demos;
import sources;
import limits;
import procinfo;

mixin ServerinoMain!(demos, sources, limits);

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

string host = "127.0.0.1";
ushort port = 8080;

@onServerInit
ServerinoConfig configure(string[] args)
{
   try
   {
      auto opts = getopt(args,
         "host", "Address to listen on (default: 127.0.0.1)", &host,
         "port", "Port to listen on (default: 8080)",         &port
      );

      if (opts.helpWanted)
      {
         defaultGetoptPrinter("The serverino website\n", opts.options);
         return ServerinoConfig.create().setReturnCode(0, true);
      }
   }
   catch (Exception e)
   {
      stderr.writeln("Invalid arguments: ", e.msg);
      return ServerinoConfig.create().setReturnCode(1);
   }

   // The pool grows and shrinks on its own: only the ceiling is set here.
   return ServerinoConfig
      .create()
      .addListener(host, port)
      .setMaxWorkers(20)
      .setMaxDynamicWorkerIdling(10.seconds)  // a quiet site should cost almost nothing
      .enableRemoteIp()                       // x-remote-ip, for when there is no proxy
      .setMaxRequestSize(64 * 1024)           // deliberately small: see the upload demo
      .setMaxRequestTime(10.seconds);
}

// ----------------------------------------------------------------------------
// Static files
// ----------------------------------------------------------------------------

/+ The catch-all: it runs after every demo endpoint. +/
@endpoint @priority(-100)
void staticFiles(Request request, Output output)
{
   immutable file = resolve(request.path);

   if (file.empty)
   {
      output.status = 404;
      output.addHeader("content-type", "text/html; charset=utf-8");

      if (!output.serveFile(buildPath(webRoot, "404.html")))
         output ~= "<h1>404 &mdash; not found</h1>";

      return;
   }

   /+ Asset names carry no fingerprint, so nothing may be cached blindly:
    + the browser keeps its copy but has to ask every time. An unchanged file
    + costs one 304 and no body at all.
   +/
   immutable tag = etagOf(file);

   output.addHeader("cache-control", "no-cache");
   output.addHeader("etag", tag);

   if (request.header.read("if-none-match") == tag)
   {
      output.status = 304;
      return;
   }

   output.serveFile(file);
}

/// A weak validator: size and modification time are enough to notice an edit.
string etagOf(string file)
{
   try return `"%x-%x"`.format(file.getSize, file.timeLastModified.toUnixTime);
   catch (Exception e) { return string.init; }
}

/+ Maps a request path to a file inside webRoot, or returns an empty string.
 + serveFile() does not protect against path traversal: that's done here.
+/
string resolve(string path)
{
   if (path.canFind('\0')) return string.init;

   string wanted = path;

   if (wanted.empty || !wanted.startsWith("/")) return string.init;
   if (wanted.endsWith("/")) wanted ~= "index.html";
   else if (wanted.extension.empty) wanted ~= ".html";      // /docs -> docs.html

   immutable root = webRoot;
   immutable full = buildNormalizedPath(root, wanted[1 .. $]);

   // Must stay inside the web root, whatever the request contained.
   if (!full.startsWith(root ~ dirSeparator)) return string.init;
   if (!full.exists || !full.isFile) return string.init;

   return full;
}

/// Where static/ lives: next to the executable, or in the current directory.
string webRoot()
{
   static string cached;

   if (cached.empty)
   {
      immutable beside = buildNormalizedPath(thisExePath.dirName, "static");
      cached = beside.exists ? beside : buildNormalizedPath(absolutePath("static"));
   }

   return cached;
}
