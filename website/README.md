# The serverino website

The website of [serverino](https://github.com/trikko/serverino), served by serverino.

Nothing on the site is a mock-up: the live demos are real endpoints of this process
(`source/demos.d`), the code shown next to them is cut out of that same file, the
example sources come from `../examples`. Plain http: the host it runs on is shared,
so TLS belongs to the proxy in front — see below.

## Run it

```bash
dub run --root=website                                          # quick look, debug
dub build --root=website --build=small --compiler=ldc2          # what to deploy
```

Plain http on http://127.0.0.1:8080. `--host` and `--port` move it.

Serverino can terminate TLS by itself (`examples/12_https` and
`examples/13_letsencrypt` do exactly that), and on a machine of its own this site
would. It does not because it shares a host with other sites: something already
holds port 443 and routes by name, so there is nothing left for a second TLS
stack to do.

## Behind a reverse proxy

The proxy must pass the client address, or every visitor arrives as the proxy
itself and the rate limiter in `limits.d` puts them all in one bucket. It must
also let WebSockets through, and wait long enough for them: the telemetry demo
holds a connection for three minutes and the chat for ten.

**caddy** — the upgrade and `X-Forwarded-For` are handled for you:

```caddyfile
serverino.dev {
	reverse_proxy 127.0.0.1:8080 {
		header_up X-Forwarded-For {remote_host}
	}
}
```

**nginx**:

```nginx
server {
	listen 443 ssl http2;
	server_name serverino.dev;

	# certificates here

	location / {
		proxy_pass http://127.0.0.1:8080;

		proxy_set_header Host $host;
		proxy_set_header X-Forwarded-For $remote_addr;   # overwrite, do not append
		proxy_set_header X-Forwarded-Proto $scheme;

		# the WebSocket demos
		proxy_http_version 1.1;
		proxy_set_header Upgrade $http_upgrade;
		proxy_set_header Connection "upgrade";
		proxy_read_timeout 900s;
	}
}
```

Both snippets **overwrite** `X-Forwarded-For` with the address of whoever
connected, rather than appending to whatever the client sent. `visitor()` in
`limits.d` reads the *last* entry of that header, so nginx's more common
`$proxy_add_x_forwarded_for` (which appends) works just as well — but a header
you overwrite is one less thing to reason about.

Without any proxy the header is absent and the site falls back to
`x-remote-ip`, which serverino fills in because of `enableRemoteIp()`.

## Building it small

The site shows its own executable size, so it is worth building it properly. The
`small` build type uses LDC with `-Oz`, section garbage collection, identical code
folding and a final `strip`. Measured on this site:

| Build | Size |
|-------|------|
| dmd, debug | 9.6 MB |
| dmd, release | 6.4 MB |
| ldc, release | 2.3 MB |
| ldc, release + strip | 1.75 MB |
| **`--build=small --compiler=ldc2`** | **1.45 MB** |

Linkers, same flags, stripped: lld 1,522,968 · mold 1,544,992 · gold 1,607,672 ·
bfd 1,693,416. Hence `-linker=lld`. Full LTO was tried and made the binary *bigger*
(2.1 MB), so it is not used.

**UPX is deliberately not used.** It does compress the binary to 391 KB, but this is
a multi-process server, and that changes the arithmetic:

| | size on disk | memory, 11 processes | startup |
|---|---|---|---|
| plain | 1.45 MB | 37.4 MB | 2 ms |
| `upx --best --lzma` | 0.38 MB | 51.2 MB | 44 ms |

A packed executable is decompressed into private memory in every process, so the
text pages the daemon and its workers would otherwise share are paid for once per
worker: about 1.4 MB each. Saving one megabyte of disk costs fourteen of RAM, and
every worker spawn pays the unpacking. For a single-process CLI tool the trade would
go the other way.

Development mode is the default: one plain listener on localhost, no certificate,
nothing asked to any certificate authority.

## Layout

| Path | What it is |
|------|------------|
| `source/app.d` | Configuration, listeners, static file serving |
| `source/demos.d` | The live demos, one endpoint each, between `// snippet:` markers |
| `source/sources.d` | `/api/demos` and `/api/examples`: the code the site displays |
| `source/limits.d` | Rate limiting, WebSocket caps: what keeps the demos from taking the site down |
| `source/procinfo.d` | Memory and process count, read from `/proc` |
| `static/` | The site itself: HTML, one stylesheet, two scripts, no dependencies |

The site also serves three files straight from `../docs`, compiled into the binary:
`/llms.txt`, `/llms-full.txt` and `/AGENTS.md`. The last one is the rules file an
agent is told to fetch, and it is the same file the Claude skill bundles — one
source, no drift.

## The demos

| Demo | What it shows |
|------|---------------|
| `hello` | An endpoint is a function |
| `footprint` | Memory, processes and binary size of the running server, read from `/proc` |
| `crash` | A worker fails an assert; the daemon answers 500 for it and the site carries on |
| `pool` | Sixty concurrent requests: which workers answer, and what the pool does |
| `telemetry` | Memory and process count pushed over a WebSocket |
| `slow` | A per-request timeout: the stuck worker is killed |
| `upload` | Multipart uploads against a deliberately small 64 KB limit |
| `chat` | A room shared through a file; only the phrases the server knows are accepted |
| `chain` | `@priority` and `Fallthrough` |

Every demo endpoint sits behind the rate limiter described below.

Adding one means writing the endpoint in `demos.d` between `// snippet:<id>` and
`// snippet-end`, listing `<id>` in `demoIds` (`sources.d`), describing it in `DEMOS`
(`static/js/site.js`) and dropping `<article data-demo="<id>"></article>` in a page.

Note that `setMaxRequestSize(64 * 1024)` in `app.d` is part of the upload demo: raise
it if you ever need this site to accept anything bigger.

## The leash

The demos invite visitors to flood the server and to open WebSockets, so `limits.d`
holds them back:

| Limit | Value | Why |
|-------|-------|-----|
| Requests to `/demo/*` | 600 per visitor per 10 s | A burst demo fits in one window; a sustained flood does not |
| `/demo/crash` | 30 per visitor per 30 s | Starting a worker is cheap, so this one is generous |
| WebSocket upgrades | 6 per visitor per minute | Each one is a process |
| WebSockets open | 24 site-wide | Counted from `/proc`, so nothing leaks when a process is killed |
| Connection lifetime | 3 min telemetry, 10 min chat | An abandoned tab must not own a process forever |
| Request body | 64 KB | `setMaxRequestSize`, answered by the daemon with a 413 |
| Endpoint time | 5 s by default, 50 ms for `/demo/slow` | A hung request cannot hold a worker |
| Worker pool | up to 20, idle ones retire after 10 s | A quiet site is the daemon and little else; the pool is rebuilt on demand |

The counters are files, not variables: workers are separate processes, and one byte
appended per request is atomic, while a read-modify-write loses almost every update
under exactly the load that matters.

Visitors are told apart by `x-remote-ip`, which the daemon adds when
`enableRemoteIp()` is on. `x-forwarded-for` is deliberately ignored: nothing but the
client sets it here, so trusting it would hand everyone a way around the limits. Put
this site behind a reverse proxy and that changes — read the forwarded header there,
and only from the proxy.
