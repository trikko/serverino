# Serverino

Serverino is a zero-dependency HTTP and WebSocket server library for the D
programming language. Version 0.8.0.

Read the reference before writing serverino code. It is two files:

- **`llms-full.txt`** — the whole API in one file: configuration, every attribute,
  `Request`, `Output`, `FormData`, WebSockets, worked examples. This is the one
  to read. <https://serverino.dev/llms-full.txt>
- **`llms.txt`** — a page of overview, when the full one is more than you need.
  <https://serverino.dev/llms.txt>

In the packaged skill both sit next to this file; installed from the web, fetch
them from the addresses above.

What follows are the rules that are easiest to get wrong.

## Shape of a program

```d
import serverino;
mixin ServerinoMain;

@onServerInit
ServerinoConfig configure()
{
   return ServerinoConfig.create()
      .addListener("127.0.0.1", 8080)
      .setMaxWorkers(10);
}

@endpoint @route!"/hello"
void hello(Request request, Output output)
{
   output ~= "Hello, " ~ request.get.read("name", "world") ~ "!";
}
```

With a single handler `@endpoint` may be left out. With two or more, every one
of them must be tagged, or the untagged ones are never called.

## Requests

- `request.get`, `request.post`, `request.form`, `request.header`,
  `request.cookie` are **not** associative arrays. Use `.read("key", "default")`
  and `.has("key")`; `.data` gives the underlying map for iteration.
- Multipart fields **and** uploaded files are in `request.form`, never in
  `request.post`. A `FormData` has `.isFile`, `.filename`, `.contentType` and
  `.path`, the temporary file the daemon already saved.
- `request.path`, `request.method` (`Request.Method.Get`, `.Post`, …),
  `request.host`, `request.isSecure`, `request.dump()`.
- `request.path` arrives **already normalized**: serverino collapses `.` and
  `..` before your endpoint sees it. It is **not** percent-decoded — and you
  must not decode it, because `/%2e%2e/%2e%2e/etc/passwd` survives the
  normalization encoded and becomes a traversal the moment you decode it. If
  you need a decoded path, normalize or confine it *again* after decoding.

## Responses

- `output ~= data` appends to the body; the default content type is `text/html`.
- `output.status = 404` sets the code. `output.addHeader("content-type", …)`,
  `output.setCookie(Cookie("k", "v").path("/").maxAge(1.hours))`.
- `content-length`, `date`, `server`, `status` and `transfer-encoding` are
  managed by serverino and cannot be set.
- `output.serveFile("path")` streams a file and guesses its content type. It
  returns `false` when the file is missing — there is no automatic 404 — and it
  does **not** check the path it is given: whatever you build from user input
  (after decoding, joining, or reading a form field) must be confined yourself,
  e.g. `buildNormalizedPath` plus a `startsWith` on your root.
  The disposal action is a **template** parameter:
  `output.serveFile!(OnFileServed.DeleteFile)("/tmp/x.pdf")`.

## Routing

- `@route!"/exact"` matches one path. `@route!(r => r.path.startsWith("/api/"))`
  matches whatever you can express in D.
- Endpoints run in descending `@priority` (zero by default). The first one that
  writes something ends the chain, unless it returns `Fallthrough.Yes`.

## Workers are processes, not threads

- No state is shared between requests: a global set in one request may be gone
  in the next, and two requests may be served by different processes. Anything
  shared belongs in a file, a database or a cache.
- `@requestScope` on a global means "reset this after every request" — it is not
  a way to keep state around.
- A crash costs one request: the daemon answers `500` for the dead worker and
  starts another one.

## WebSockets

- A `@onWebSocketUpgrade bool(Request)` function is **required**. Without one,
  every upgrade is refused with a 403.
- The handler is an `@endpoint` taking `(Request, WebSocket)` and normally loops
  forever: `while(true) if (auto msg = ws.receiveMessage()) ws.send(…);`
- `@onWebSocketStart` and `@onWebSocketStop` take **no arguments**: they cannot
  receive the socket.
- The socket is blocking. To read and write in the same loop, set
  `ws.socket.blocking = false` and poll.
- A close frame arrives like any other message: check
  `msg.opcode == WebSocketMessage.OpCode.Close` and leave the loop, or the
  connection lingers until it times out.
- Do not run background work in a worker thread; it is not reliably scheduled.
  Long-lived tasks belong in the daemon (`@onDaemonStart`).

## Configuration

One `@onServerInit` function returning a `ServerinoConfig`. Common settings:
`addListener(address, port)` (call it more than once for more listeners),
`setMaxWorkers`, `setMinWorkers`, `setMaxDynamicWorkerIdling`,
`setMaxRequestTime`, `setMaxRequestSize`, `enableKeepAlive`, `enableRemoteIp`,
`setWorkerUser`/`setWorkerGroup`. Take `string[] args` as a parameter to read
the command line.

## HTTPS

A build configuration, POSIX only: `dub build --config=https`, or
`"subConfigurations": { "serverino": "https" }`. A certificate belongs to a
listener: `addListener("0.0.0.0", 443, Https("cert.pem", "key.pem"))`.
`Daemon.reloadCertificates()` (or SIGHUP) swaps it without a restart.

## Common mistakes

| Wrong | Right |
|---|---|
| `request.get["name"]` | `request.get.read("name", "")` |
| `request.post.read("file")` for an upload | `request.form.read("file").path` |
| `serveFile(path, OnFileServed.DeleteFile)` | `serveFile!(OnFileServed.DeleteFile)(path)` |
| A WebSocket endpoint with no upgrade handler | `@onWebSocketUpgrade bool(Request)` is required |
| `@onWebSocketStart(WebSocket ws)` | those hooks take no arguments |
| A global cache shared between requests | workers are processes: use a file, a database, a cache server |
