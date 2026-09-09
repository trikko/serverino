/+
 + Keeping the demos from taking the site down.
 +
 + The demos invite you to flood the server and to open WebSockets, so they
 + need a leash. Three of them, actually:
 +
 +   - a counter per visitor, for the http demos;
 +   - a much tighter one for opening WebSockets;
 +   - a cap on how many WebSocket processes may exist at once.
 +
 + Workers are separate processes, so the counters live in small files: one
 + in memory would only ever see one worker's share of the traffic.
+/
module limits;

import std;
import serverino;

import procinfo : measure;

enum
{
   HTTP_LIMIT     = 600,      /// Requests one visitor may make...
   HTTP_WINDOW    = 10,       /// ...in this many seconds. A burst demo fits in one window.

   CRASH_LIMIT    = 30,       /// Workers a visitor may kill...
   CRASH_WINDOW   = 30,       /// ...in this many seconds, on a budget of its own

   WS_LIMIT       = 6,        /// WebSockets one visitor may open...
   WS_WINDOW      = 60,       /// ...per minute

   MAX_WEBSOCKETS = 24        /// Open at once, site-wide, whoever opened them
}

/+ Who is asking, as far as this process can tell.
 +
 + This site runs behind nginx or caddy, so the address serverino sees
 + (x-remote-ip, added by enableRemoteIp) is the proxy's, the same for
 + everybody: rate limiting on that would put every visitor in one bucket and
 + lock the site for all of them at once.
 +
 + The client is in x-forwarded-for, and the entry to trust is the LAST one:
 + the proxy appends the address it actually received the connection from,
 + while anything before it was supplied by the client and can say whatever it
 + likes. With no proxy in front the header is absent and x-remote-ip is right.
+/
string visitor(Request request)
{
   immutable forwarded = request.header.read("x-forwarded-for");

   if (!forwarded.empty)
   {
      immutable last = forwarded.splitter(',').array[$ - 1].strip;
      if (!last.empty) return last;
   }

   immutable ip = request.header.read("x-remote-ip");
   return ip.empty ? "unknown" : ip;
}

/// Refuses the request with a 429 when the visitor is going too fast.
@endpoint @priority(800)
@route!(r => r.path.startsWith("/demo/"))
auto rateLimit(Request request, Output output)
{
   immutable who = visitor(request);

   /+ Killing workers has a budget of its own, a generous one: starting a
    + worker costs the machine very little, and the demo is the point.
    + It used to cost sixty requests out of the allowance below, which
    + meant that a visitor pressing that button ten times locked
    + themselves out of every other demo until the window rolled over.
   +/
   if (request.path == "/demo/crash")
      if (!allow(who ~ ":crash", CRASH_LIMIT, CRASH_WINDOW))
         return tooFast(output, CRASH_WINDOW,
            "Give the poor thing a moment: this demo allows "
            ~ CRASH_LIMIT.to!string ~ " kills every "
            ~ CRASH_WINDOW.to!string ~ " seconds.");

   if (!allow(who ~ ":http", HTTP_LIMIT, HTTP_WINDOW))
      return tooFast(output, HTTP_WINDOW,
         "Slow down: this site allows " ~ HTTP_LIMIT.to!string
         ~ " requests every " ~ HTTP_WINDOW.to!string ~ " seconds per visitor.");

   return Fallthrough.Yes;
}

/// The 429 the demos know how to explain.
Fallthrough tooFast(Output output, size_t seconds, string why)
{
   output.status = 429;
   output.addHeader("content-type", "text/plain");
   output.addHeader("retry-after", seconds.to!string);
   output ~= why ~ "\n";

   return Fallthrough.No;
}

/+ May this visitor open another WebSocket?
 +
 + Called from @onWebSocketUpgrade. A refusal is answered with a 403: there is
 + no way to explain why in the handshake, so the page says it for us.
+/
bool acceptWebSocket(Request request)
{
   if (measure().webSockets >= MAX_WEBSOCKETS)
   {
      info("WebSocket refused: ", MAX_WEBSOCKETS, " are already open.");
      return false;
   }

   if (!allow(visitor(request) ~ ":ws", WS_LIMIT, WS_WINDOW))
   {
      info("WebSocket refused: too many from ", visitor(request));
      return false;
   }

   return true;
}

// ----------------------------------------------------------------------------
// A counter per key and per time window, in a file
// ----------------------------------------------------------------------------

/+ Counts `cost` against a visitor's allowance for the current window, and
 + says whether they may go on.
 +
 + The count is the size of a file, and it grows by appending to it. That
 + matters: workers are separate processes, and a read-modify-write would lose
 + almost every update exactly when the traffic is heavy enough to matter,
 + while an append is atomic and cannot be lost.
 +
 + Windows are fixed, so somebody straddling a boundary can get away with up
 + to twice the allowance. This is a leash, not an accountant.
+/
bool allow(string key, size_t limit, size_t windowSeconds, size_t cost = 1)
{
   immutable window = Clock.currTime.toUnixTime!long / windowSeconds;
   immutable file = counterFile(key, window);

   try
   {
      append(file, new ubyte[cost]);
      return file.getSize <= limit;
   }
   catch (Exception e)
   {
      // A broken counter must not take the site down with it.
      warning("Rate limiter: ", e.msg);
      return true;
   }
}

string counterFile(string key, long window)
{
   import std.digest.md : md5Of, toHexString;

   immutable dir = buildPath(tempDir, "serverino-website-limits");

   if (!dir.exists)
   {
      try mkdirRecurse(dir);
      catch (Exception e) { }
   }

   sweep(dir);

   return buildPath(dir, (key ~ "/" ~ window.to!string).md5Of.toHexString.idup);
}

/// Every now and then, throw away the windows that have gone by.
void sweep(string dir)
{
   import std.random : uniform;

   if (uniform(0, 500) != 0) return;

   try
   {
      foreach(entry; dirEntries(dir, SpanMode.shallow))
         if (Clock.currTime - entry.timeLastModified > 5.minutes)
            entry.name.remove;
   }
   catch (Exception e) { }
}
