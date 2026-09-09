/+
 + The live demos of the website.
 +
 + Every demo below is a real endpoint of this very process: what the site
 + shows in the "Live" panel is this code running. The snippets displayed on
 + the page are extracted from this file (see sources.d), so they cannot drift
 + away from what actually runs.
+/
module demos;

import std;
import serverino;

import procinfo : measure;
import limits : acceptWebSocket;

// ----------------------------------------------------------------------------
// The basics
// ----------------------------------------------------------------------------

// snippet:hello
@endpoint @route!"/demo/hello"
void hello(Request request, Output output)
{
   auto name = request.get.read("name", "world");
   output ~= "Hello, " ~ name ~ "!";
}
// snippet-end

// snippet:chain
@endpoint @priority(30) @route!"/demo/chain"
auto guard(Request request, Output output)
{
   output ~= "1. highest priority endpoint runs first\n";
   return Fallthrough.Yes;   // keep going anyway
}

@endpoint @priority(20) @route!"/demo/chain"
auto middle(Request request, Output output)
{
   output ~= "2. then this one\n";
   return Fallthrough.Yes;
}

@endpoint @priority(10) @route!"/demo/chain"
void last(Request request, Output output)
{
   output ~= "3. and this one stops the chain.\n";
}
// snippet-end

// ----------------------------------------------------------------------------
// What a process per request buys you
// ----------------------------------------------------------------------------

// snippet:crash
@endpoint @route!"/demo/crash"
void crash(Request request, Output output)
{
   countIt();   // for the panel on the right

   // One line, and this worker is gone. It never gets to answer,
   // so the daemon answers for it: the client gets a 500, and
   // the next request is served by a brand new process. The
   // crash costs the request you made, and nothing else.
   //
   // A real bug looks more like this, same ending:
   //
   //    int* nowhere = null; *nowhere = 42;
   //
   assert(false, "this worker was asked to crash. Bye!");
}

// snippet-end

// snippet:slow
@endpoint @route!"/demo/slow"
void slow(Request request, Output output)
{
   import core.thread : Thread;

   // Fifty milliseconds, for this request only. Short on purpose: a
   // public demo that hangs must not tie a worker up for long.
   output.setMaxRequestTime(50.msecs);

   Thread.sleep(1.minutes);   // a bug, basically

   output ~= "you will never read this";
}

// snippet-end

// snippet:pool
@endpoint @route!"/demo/ping"
void ping(Request request, Output output)
{
   // Nothing to it: the point is who answers. The panel
   // sends sixty of these, as many at a time as you pick,
   // and the pool grows only if they really overlap.
   output ~= thisProcessID.to!string;
}

// snippet-end

// ----------------------------------------------------------------------------
// How much of your machine this takes
// ----------------------------------------------------------------------------

// snippet:footprint
@endpoint @route!"/demo/footprint"
void footprint(Request request, Output output)
{
   auto now = measure();   // daemon + workers, read from /proc

   JSONValue answer = [
      "memory_kb":    now.memoryKb,
      "processes":    now.processes,
      "websockets":   now.webSockets,
      "crashes":      crashCount,
      "binary_kb":    thisExePath.getSize / 1024,
      "dependencies": 0
   ];

   output.addHeader("content-type", "application/json");
   output ~= answer.toString;
}

// snippet-end

// snippet:telemetry
/+ Without this, every upgrade is refused: it is the one
 + thing a WebSocket server must have.
 +
 + Each accepted upgrade costs a process, so this is also
 + where the site says no: see limits.d for the cap on
 + open connections and on how often one visitor may
 + open them. +/
@onWebSocketUpgrade
bool upgrade(Request request)
{
   if (request.path != "/demo/telemetry"
      && request.path != "/demo/chat") return false;

   return acceptWebSocket(request);
}

@endpoint @route!"/demo/telemetry"
void telemetry(Request request, WebSocket ws)
{
   import core.thread : Thread;

   // This one only ever sends, but it has to listen too: a browser
   // closing the tab says so with a close frame, and a loop that
   // never reads would keep this process alive without noticing.
   ws.socket.blocking = false;

   // Nothing here runs forever either: an abandoned tab would hold
   // the process until the browser gives up. Say goodbye and go.
   immutable until = Clock.currTime + TELEMETRY_LIFETIME;

   while(Clock.currTime < until && !WebSocket.killRequested)
   {
      if (WebSocketMessage msg = ws.receiveMessage())
         if (msg.opcode == WebSocketMessage.OpCode.Close) break;

      auto now = measure();

      JSONValue reading = [
         "memory_kb":  now.memoryKb,
         "processes":  now.processes,
         "websockets": now.webSockets
      ];

      ws.send(reading.toString);

      Thread.sleep(500.msecs);
   }

   ws.send(`{"bye": "connections are capped at three minutes"}`);
   ws.sendClose();
}
// snippet-end

// ----------------------------------------------------------------------------
// Uploads, with a deliberately small limit
// ----------------------------------------------------------------------------

// snippet:upload
@endpoint @route!"/demo/upload"
void upload(Request request, Output output)
{
   // This server is configured with setMaxRequestSize(64 * 1024).
   // Anything bigger is answered with a 413 by the daemon and never
   // reaches this function: your code is not even woken up.
   if (request.method != Request.Method.Post)
   {
      output.status = 405;
      return;
   }

   output.addHeader("content-type", "text/plain");

   foreach(name, field; request.form.data)
   {
      output ~= name ~ ": ";

      if (!field.isFile) output ~= field.data.to!string ~ "\n";
      else output ~= field.filename ~ ", "
         ~ field.path.getSize.to!string ~ " bytes, saved for you in "
         ~ field.path.baseName ~ "\n";
   }
}
// snippet-end

// ----------------------------------------------------------------------------
// A room, shared by processes that share nothing
// ----------------------------------------------------------------------------

// snippet:chat
/+ The room only speaks these. The buttons on the page are a
 + convenience; this table is the rule, because a WebSocket is
 + open to anyone with a client, not just to our own page.
+/
immutable string[string] PHRASES;

shared static this()
{
   PHRASES = [
      "wave": "👋", "party": "🎉", "coffee": "☕",
      "bug": "🐛", "heart": "❤️",
      "hello": "hello from another tab",
      "works": "it works!",
      "dlang": "greetings from D"
   ];
}

@endpoint @route!"/demo/chat"
void chat(Request request, WebSocket ws)
{
   import core.thread : Thread;

   // One process per connection, so the room cannot live in a
   // variable: it is a file, and everyone tails it. Open this
   // page in a second tab to see it.
   ws.socket.blocking = false;

   immutable me = "guest-%04d".format(thisProcessID % 10_000);
   immutable until = Clock.currTime + CHAT_LIFETIME;
   size_t seen = 0;

   say(me ~ " joined");

   while(Clock.currTime < until && !WebSocket.killRequested)
   {
      if (WebSocketMessage msg = ws.receiveMessage())
      {
         // A close frame arrives like any other message: without
         // this, leaving would take until the deadline above.
         if (msg.opcode == WebSocketMessage.OpCode.Close) break;

         if (msg.opcode == WebSocketMessage.OpCode.Text)
            if (auto phrase = msg.asString in PHRASES)
               say(me ~ ": " ~ *phrase);   // anything else: ignored
      }

      foreach(line; unread(seen))
         ws.send(line);

      Thread.sleep(120.msecs);
   }

   say(me ~ " left");
   ws.sendClose();
}

// snippet-end

// ----------------------------------------------------------------------------
// Helpers used by the demos above
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// Counting the crashes
//
// The endpoint above never returns, so it cannot report anything: it writes
// one byte here first, and the count outlives the process that made it. A
// variable would not do — this worker is about to stop existing, and the next
// request will be served by another one.
// ----------------------------------------------------------------------------

string crashFile() { return buildPath(tempDir, "serverino-website-crashes"); }

void countIt()
{
   try append(crashFile, [cast(ubyte) 0]);
   catch (Exception e) { }
}

size_t crashCount()
{
   try return crashFile.exists ? crashFile.getSize : 0;
   catch (Exception e) { return 0; }
}

// ----------------------------------------------------------------------------
// The chat room: a file in the temporary directory.
// ----------------------------------------------------------------------------

enum TELEMETRY_LIFETIME = 3.minutes;
enum CHAT_LIFETIME = 10.minutes;

enum ROOM_LINES = 40;

string roomFile() { return buildPath(tempDir, "serverino-website-room.txt"); }

/// Adds a line to the room, keeping only the last ROOM_LINES of it.
void say(string line)
{
   line = line.filter!(c => c != '\n' && c != '\r').to!string.strip;

   if (line.empty) return;
   if (line.length > 160) line = line[0 .. 160];

   try
   {
      append(roomFile, Clock.currTime.toISOExtString[11 .. 19] ~ " " ~ line ~ "\n");

      auto lines = roomFile.readText.splitLines;

      if (lines.length > ROOM_LINES * 2)
         std.file.write(roomFile, lines[$ - ROOM_LINES .. $].join("\n") ~ "\n");
   }
   catch (Exception e) { warning("Chat room: ", e.msg); }
}

/// The lines added since the last call. On the first call, the tail of the room.
string[] unread(ref size_t seen)
{
   try
   {
      if (!roomFile.exists) return null;

      auto lines = roomFile.readText.splitLines;

      if (seen == 0 && lines.length > 12) seen = lines.length - 12;
      if (seen >= lines.length) { seen = lines.length; return null; }

      auto fresh = lines[seen .. $].dup;
      seen = lines.length;

      return fresh;
   }
   catch (Exception e) { return null; }
}
