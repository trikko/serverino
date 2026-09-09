/* serverino.dev — no framework, no build step, no dependencies. */

(function () {
   "use strict";

   /* ------------------------------------------------------------ helpers */

   const h = (tag, attrs, ...kids) => {
      const el = document.createElement(tag);
      for (const k in (attrs || {})) {
         if (k === "class") el.className = attrs[k];
         else if (k === "text") el.textContent = attrs[k];
         else if (k.startsWith("on")) el.addEventListener(k.slice(2), attrs[k]);
         else if (attrs[k] !== null && attrs[k] !== undefined) el.setAttribute(k, attrs[k]);
      }
      for (const kid of kids.flat()) if (kid) el.append(kid);
      return el;
   };

   const wsURL = path => (location.protocol === "https:" ? "wss://" : "ws://") + location.host + path;

   function copyButton(getText) {
      return h("button", {
         class: "btn btn-small", type: "button",
         onclick: function () {
            navigator.clipboard.writeText(getText()).then(() => {
               const old = this.textContent;
               this.textContent = "Copied";
               setTimeout(() => { this.textContent = old; }, 1200);
            }, () => {});
         }
      }, "Copy");
   }

   /* ------------------------------------------------------------ the demos */

   const DEMOS = {
      hello: {
         title: "Read a query parameter",
         desc: "A function taking a Request and an Output. That is the whole API.",
         kind: "http", method: "GET", path: "/demo/hello",
         params: [{ name: "name", value: "andrea" }]
      },
      chain: {
         title: "Priority and fallthrough",
         desc: "Three endpoints on the same route, in the order you decide.",
         kind: "http", method: "GET", path: "/demo/chain"
      },
      footprint: {
         title: "What this website costs to run",
         desc: "Measured right now, on the machine serving you this page.",
         kind: "footprint", path: "/demo/footprint"
      },
      pool: {
         title: "Where the workers come from",
         desc: "Sixty requests at once, the way a page load asks for its assets.",
         kind: "pool", path: "/demo/ping"
      },
      crash: {
         title: "Break a worker on purpose",
         desc: "One failed assert, one dead process, one clean 500.",
         kind: "crash", path: "/demo/crash"
      },
      slow: {
         title: "An endpoint that never finishes",
         desc: "It sleeps for a minute. It is given fifty milliseconds.",
         kind: "http", method: "GET", path: "/demo/slow",
         note: "The worker is killed and recycled, and what you get back is a 504. It does not "
            + "arrive after fifty milliseconds but when the daemon noticed and reaped the "
            + "worker, which is a second or so later."
      },
      upload: {
         title: "Uploads, and a 64 KB limit",
         desc: "Small on purpose: try to go over it and watch the daemon refuse.",
         kind: "upload", method: "POST", path: "/demo/upload"
      },
      telemetry: {
         title: "The server, watching itself",
         desc: "Memory and process count, pushed over a WebSocket twice a second.",
         kind: "telemetry", path: "/demo/telemetry"
      },
      chat: {
         title: "A room shared by processes that share nothing",
         desc: "One process per connection. Open this page in a second tab.",
         kind: "chat", path: "/demo/chat",
         /* The same tokens the server knows: it accepts these and nothing
            else, so the buttons are a convenience and not a fence. */
         says: [
            { token: "wave", label: "👋" }, { token: "party", label: "🎉" },
            { token: "coffee", label: "☕" }, { token: "bug", label: "🐛" },
            { token: "heart", label: "❤️" },
            { token: "hello", label: "hello from another tab" },
            { token: "works", label: "it works!" },
            { token: "dlang", label: "greetings from D" }
         ]
      }
   };

   /* Snippets come from the server, cut out of the very file that runs. */
   let snippetsPromise = null;
   const snippets = () => (snippetsPromise = snippetsPromise || fetch("/api/demos").then(r => r.json()));

   const BUILDERS = {
      http: buildHttp, upload: buildUpload, footprint: buildFootprint,
      pool: buildPool, crash: buildCrash, telemetry: buildTelemetry, chat: buildChat
   };

   /* ------------------------------------------------------------ mounting */

   function mountDemo(host) {
      const id = host.dataset.demo;
      const demo = DEMOS[id];
      if (!demo) return;

      const codeEl = h("code");
      const lines = h("span", { class: "lines" });
      const live = h("div", { class: "demo-live" });

      host.classList.add("demo");
      host.append(
         h("header", { class: "demo-title" },
            h("h3", { text: demo.title }),
            h("p", { text: demo.desc }),
            lines),
         h("div", { class: "demo-body" },
            h("div", { class: "demo-source" }, h("pre", null, codeEl)),
            live)
      );

      codeEl.textContent = "loading…";

      snippets().then(all => {
         const code = all[id] || "";
         codeEl.innerHTML = window.dhighlight(code);
         lines.textContent = code.split("\n").length + " lines of D";
      }).catch(() => { codeEl.textContent = "(source unavailable: this page is not served by the demo server)"; });

      (BUILDERS[demo.kind] || buildHttp)(live, demo);

      if (demo.note) live.append(h("p", { class: "demo-note", text: demo.note }));
   }

   /* Shared bits of a live panel: the response bar and the output box. */
   function responseArea(live, placeholder) {
      /* The bar keeps its place from the start, with a quiet placeholder: a row
         that appears out of nowhere would push everything below it. */
      const status = h("span", { class: "status", text: "no answer yet" });
      const ctype = h("span", { class: "ctype" });
      const bar = h("div", { class: "respbar idle" }, status, ctype);
      const out = h("div", { class: "output empty", text: placeholder });

      live.append(bar, out);

      return {
         bar: bar, status: status, ctype: ctype, out: out,
         show: (code, ok, type) => {
            bar.classList.remove("idle");
            status.textContent = code;
            status.className = "status" + (ok ? "" : " err");
            ctype.textContent = type || "";
         },
         text: t => { out.classList.remove("empty"); out.textContent = t; },
         node: n => { out.classList.remove("empty"); out.textContent = ""; out.append(n); }
      };
   }

   /* An upgrade that never opened was refused by @onWebSocketUpgrade: the
      handshake carries no reason, so ask the server what the state is. */
   function refusalReason(then) {
      fetch("/demo/footprint").then(r => r.json()).then(d => {
         then("refused. " + d.websockets + " of 24 WebSockets are open on the whole site, " +
            "and one visitor may open 6 per minute. Both caps are there so a few open tabs " +
            "cannot take the demos down — each connection is a process of its own.");
      }).catch(() => then("refused, and the server cannot be reached for the reason."));
   }

   /* A 429 is an answer, not a breakdown: say what it means and for how long. */
   function limitedError(response, body) {
      const wait = response.headers.get("retry-after");
      const err = new Error(body.trim() ||
         "Too many requests: this site limits what one visitor may ask for.");
      err.limited = true;
      err.retry = wait;
      return err;
   }

   /* Reads a JSON answer, turning a rate limit into a labelled error. */
   const readJson = url => fetch(url).then(r => r.status === 429
      ? r.text().then(b => { throw limitedError(r, b); })
      : r.json());

   const showError = (res, err) => {
      if (err && err.limited) {
         res.show("429 Too Many Requests", false, "");
         res.text(err.message + (err.retry ? "\n\nTry again in " + err.retry + " seconds." : ""));
         return;
      }

      res.show("failed", false, "");
      res.text(failureHint(err));
   };

   const failureHint = err =>
      "The request failed (" + err.message + ").\n\n" +
      "The live demos need the site to be served by the serverino website server:\n" +
      "  dub run --root=website";

   /* Big numbers, for the panels that measure something. */
   function tiles(specs) {
      const box = h("div", { class: "tiles" });

      specs.forEach(spec => box.append(
         h("div", { class: "tile" },
            h("div", { class: "tile-value", text: spec.value }),
            h("div", { class: "tile-label", text: spec.label }))));

      return box;
   }

   /* ------------------------------------------------------------ http demos */

   function buildHttp(live, demo) {
      const inputs = [];
      const controls = h("div", { class: "demo-controls" });

      (demo.params || []).forEach(p => {
         const input = h("input", { type: "text", value: p.value || "", "data-param": p.name });
         inputs.push(input);
         controls.append(h("div", { class: "field" }, h("label", { text: p.name }), input));
      });

      const run = h("button", { class: "btn btn-primary", type: "button" }, "Run");
      controls.append(h("div", { class: "field" }, h("label", { text: " " }), run));

      const reqline = h("div", { class: "reqline" });
      live.append(controls, reqline);

      const res = responseArea(live, "Press Run to call this endpoint.");
      const curl = h("code");
      live.append(h("div", { class: "curl" }, curl, copyButton(() => curl.textContent)));

      const target = () => {
         const qs = inputs.filter(i => i.value !== "")
            .map(i => encodeURIComponent(i.dataset.param) + "=" + encodeURIComponent(i.value)).join("&");
         return demo.path + (qs ? "?" + qs : "");
      };

      const refresh = () => {
         reqline.textContent = "GET " + target();
         curl.textContent = "curl -s '" + location.origin + target() + "'";
      };

      inputs.forEach(i => i.addEventListener("input", refresh));
      refresh();

      run.addEventListener("click", () => {
         run.disabled = true;
         res.text("…");

         fetch(target()).then(r => r.text().then(body => {
            res.show(r.status + " " + r.statusText, r.ok,
               (r.headers.get("content-type") || "").split(";")[0]);
            const wait = r.status === 429 ? r.headers.get("retry-after") : null;

            res.text((body.trim() || "(empty body)") +
               (wait ? "\n\nTry again in " + wait + " seconds." : ""));
         })).catch(err => showError(res, err))
            .finally(() => { run.disabled = false; });
      });
   }

   /* ------------------------------------------------------------ upload */

   function buildUpload(live, demo) {
      const file = h("input", { type: "file" });
      const run = h("button", { class: "btn btn-primary", type: "button" }, "Upload");
      const over = h("button", { class: "btn", type: "button" }, "Send 200 KB instead");

      live.append(h("div", { class: "demo-controls" },
         h("div", { class: "field" }, h("label", { text: "file" }), file),
         h("div", { class: "field" }, h("label", { text: " " }), run),
         h("div", { class: "field" }, h("label", { text: " " }), over)));

      const res = responseArea(live, "Pick a small file, or send an oversized one.");

      const post = (blob, name) => {
         const fd = new FormData();
         fd.append("file", blob, name);
         fd.append("sent_by", "the website");

         run.disabled = over.disabled = true;
         res.text("…");

         fetch(demo.path, { method: "POST", body: fd }).then(r => r.text().then(body => {
            res.show(r.status + " " + r.statusText, r.ok, "");
            res.text(r.status === 413
               ? body.trim() + "\n\nRefused by the daemon before any worker was involved:\n"
                  + "setMaxRequestSize(64 * 1024) in the configuration."
               : (body.trim() || "(empty body)"));
         })).catch(err => {
            // An oversized body is often cut short: the browser reports a network error.
            res.show("refused", false, "");
            res.text("The connection was closed before the body was accepted.\n\n" +
               "That is the 64 KB limit at work (" + err.message + ").");
         }).finally(() => { run.disabled = over.disabled = false; });
      };

      run.addEventListener("click", () => {
         if (!file.files[0]) { res.text("Choose a file first — anything under 64 KB."); return; }
         post(file.files[0], file.files[0].name);
      });

      over.addEventListener("click", () => post(new Blob([new Uint8Array(200 * 1024)]), "too-big.bin"));
   }

   /* ------------------------------------------------------------ footprint */

   const mb = kb => (kb / 1024).toFixed(1);

   function buildFootprint(live, demo) {
      const run = h("button", { class: "btn btn-primary", type: "button" }, "Measure now");
      live.append(h("div", { class: "demo-controls" }, h("div", { class: "field" },
         h("label", { text: " " }), run)));

      const res = responseArea(live, "Press to read /proc on the server.");

      const measure = () => {
         run.disabled = true;

         readJson(demo.path).then(d => {
            res.show("200 OK", true, "application/json");
            res.node(h("div", null,
               tiles([
                  { value: mb(d.memory_kb) + " MB", label: "memory, whole server" },
                  { value: String(d.processes), label: "processes (daemon + workers)" },
                  { value: mb(d.binary_kb) + " MB", label: "the executable" },
                  { value: String(d.dependencies), label: "packages installed" }
               ]),
               h("p", { class: "tiles-note", text:
                  "Memory is the proportional set size: pages shared between the daemon and its " +
                  "workers are counted once. Deploying this site means copying one file — there is " +
                  "no runtime, no package tree, nothing to install on the machine." })));
         }).catch(err => showError(res, err))
            .finally(() => { run.disabled = false; });
      };

      run.addEventListener("click", measure);
      measure();
   }

   /* ------------------------------------------------------------ the pool */

   const BURST = 60;

   function buildPool(live, demo) {
      const run = h("button", { class: "btn btn-primary", type: "button" },
         "Ask for " + BURST + " at once");

      live.append(h("div", { class: "demo-controls" },
         h("div", { class: "field" }, h("label", { text: " " }), run)));

      const res = responseArea(live, "One click, " + BURST + " requests, no waiting in between.");

      run.addEventListener("click", () => {
         const n = BURST;

         run.disabled = true;
         res.text("asking…");

         const before = readJson("/demo/footprint").catch(() => null);

         before.then(startStats => {
            const jobs = [];

            for (let i = 0; i < n; i++)
               jobs.push(fetch(demo.path)
                  .then(r => r.text().then(body => ({ status: r.status, body: body.trim() })))
                  .catch(() => null));

            return Promise.all(jobs).then(answers => {
               const done = answers.filter(Boolean);
               const ok = done.filter(a => a.status === 200);
               const limited = done.filter(a => a.status === 429).length;
               const workers = new Set(ok.map(a => a.body));

               return readJson("/demo/footprint").catch(() => null).then(endStats => {
                  res.show(ok.length + "/" + n + " answered", ok.length === n, "");
                  res.node(h("div", null,
                     tiles([
                        { value: String(workers.size), label: "workers shared the batch" },
                        { value: (startStats ? startStats.processes + " → " : "") +
                           (endStats ? String(endStats.processes) : "?"), label: "processes" },
                        { value: (startStats ? mb(startStats.memory_kb) + " → " : "") +
                           (endStats ? mb(endStats.memory_kb) : "?") + " MB", label: "memory" },
                        { value: String(limited), label: "turned away (rate limit)" }
                     ]),
                     h("p", { class: "tiles-note", text:
                        "Requests are handed to whichever worker is free, and the daemon starts a " +
                        "few more when they are all busy. Ten seconds after the last request the " +
                        "extra ones retire by themselves — the demo below draws that, if you leave " +
                        "it connected. Nothing here is a benchmark: your browser opens a handful of " +
                        "connections at a time, and the site limits what one visitor may ask for." })));
               });
            });
         }).finally(() => { run.disabled = false; });
      });
   }

   /* ------------------------------------------------------------ crash */

   function buildCrash(live, demo) {
      const run = h("button", { class: "btn btn-primary", type: "button" }, "Kill a worker");
      live.append(h("div", { class: "demo-controls" }, h("div", { class: "field" },
         h("label", { text: " " }), run)));

      const res = responseArea(live, "Nothing bad will happen. That is the point.");
      const log = [];

      const step = t => { log.push(t); res.text(log.join("\n")); };
      const pid = () => fetch("/demo/ping", { cache: "no-store" }).then(r => r.text())
         .then(t => t.trim());

      run.addEventListener("click", () => {
         run.disabled = true;
         log.length = 0;
         res.show("running", true, "");

         let victim = null, before = 0;

         readJson("/demo/footprint").then(stats => {
            before = stats.crashes;
            return pid();
         }).then(p => {
            victim = p;
            step("worker " + victim + " is answering requests");
            step("calling /demo/crash …");

            return fetch(demo.path).then(
               r => r.status === 429
                  ? r.text().then(b => { throw limitedError(r, b); })
                  : step("answered with " + r.status + " (that worker was already gone)"),
               () => step("the request never came back: the worker died holding it"));
         }).then(() => readJson("/demo/footprint")).then(stats => {
            const died = stats.crashes - before;

            return pid().then(now => {
               step("worker " + now + " answered the next one" +
                  (now === victim ? " (same one: it survived, try again)" : ", a new process"));
               step("");

               if (died > 1)
                  step(died + " workers went down, not one: your browser quietly retried the " +
                     "request it saw drop, " + (died - 1) + " time(s), and each retry took " +
                     "another worker with it.");
               else
                  step("one worker went down.");

               step("The page you are reading never went down, and no other request was touched.");
               res.show("still up", true, "");
            });
         }).catch(err => showError(res, err))
            .finally(() => { run.disabled = false; });
      });
   }

   /* ------------------------------------------------------------ telemetry */

   function buildTelemetry(live, demo) {
      const dot = h("span", { class: "dot" });
      const state = h("span", { text: "not connected" });
      const reading = h("span", { class: "timing" });
      const connect = h("button", { class: "btn btn-small", type: "button" }, "Connect");

      const canvas = h("canvas", { class: "plot" });

      /* One series at a time: two lines on two scales in one box is a puzzle,
         not a chart. */
      const tabs = h("div", { class: "seg" });

      live.append(
         h("div", { class: "wsbar" }, dot, state, h("span", { class: "spacer" }), reading, connect),
         h("div", { class: "plotbar" }, tabs),
         canvas,
         h("p", { class: "demo-note", text:
            "One measure at a time, so the scale means something. Leave this connected and run " +
            "the demo above: the line climbs as workers are started for the batch, then drops " +
            "back about ten seconds after the last request, when they retire on their own." }));

      const MEMORY = "#31a3e1", WORKERS = "#254c6b", AXIS = "#537193";
      const SLOTS = 60;                     // how many readings the chart holds

      const SERIES = {
         memory: { label: "Memory", unit: "MB", colour: MEMORY, fill: "rgba(49,163,225,.12)",
            top: vals => Math.max(16, ...vals) * 1.2, format: v => v.toFixed(0) },
         procs:  { label: "Processes", unit: "proc", colour: WORKERS, fill: "rgba(37,76,107,.10)",
            top: vals => Math.max(4, ...vals) + 1, format: v => v.toFixed(0) }
      };

      let ws = null, memory = [], procs = [], raf = 0, showing = "memory";

      const draw = () => {
         const dpr = window.devicePixelRatio || 1;
         const w = canvas.clientWidth, hgt = canvas.clientHeight;

         if (canvas.width !== w * dpr) { canvas.width = w * dpr; canvas.height = hgt * dpr; }

         const ctx = canvas.getContext("2d");
         ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
         ctx.clearRect(0, 0, w, hgt);

         const kind = SERIES[showing];
         const data = showing === "memory" ? memory : procs;

         /* The scale is written on its axis, at both ends: a lone number in a
            corner reads as the current value, which it is not. */
         const left = 34, right = w - 8, floor = hgt - 12, ceiling = 10;
         const top = kind.top(data);

         const at = i => left + (right - left) * (i / (SLOTS - 1));
         const y = v => floor - (v / top) * (floor - ceiling);

         if (data.length > 1)
         {
            ctx.beginPath();
            data.forEach((v, i) => { i ? ctx.lineTo(at(i), y(v)) : ctx.moveTo(at(i), y(v)); });
            ctx.strokeStyle = kind.colour;
            ctx.lineWidth = 2;
            ctx.stroke();

            ctx.lineTo(at(data.length - 1), floor); ctx.lineTo(at(0), floor); ctx.closePath();
            ctx.fillStyle = kind.fill;
            ctx.fill();

            // Where the line is now, so the reading in the bar has a place here.
            ctx.beginPath();
            ctx.arc(at(data.length - 1), y(data[data.length - 1]), 3, 0, Math.PI * 2);
            ctx.fillStyle = kind.colour;
            ctx.fill();
         }

         /* Axes last: the filled area of the series would otherwise wash them out,
            and an axis you cannot see is a number floating in a corner. */
         ctx.font = "10px ui-monospace, monospace";
         ctx.strokeStyle = "#bfd0dd";
         ctx.lineWidth = 1;

         ctx.beginPath();
         ctx.moveTo(left, ceiling + .5); ctx.lineTo(left, floor + .5);   // the scale itself
         ctx.lineTo(right, floor + .5);                                  // and the ground
         ctx.stroke();

         ctx.save();
         ctx.setLineDash([3, 4]);
         ctx.beginPath(); ctx.moveTo(left, ceiling + .5); ctx.lineTo(right, ceiling + .5); ctx.stroke();
         ctx.restore();

         // Ticks, so the two numbers below are clearly the ends of that line.
         ctx.beginPath();
         ctx.moveTo(left - 3, ceiling + .5); ctx.lineTo(left, ceiling + .5);
         ctx.moveTo(left - 3, floor + .5); ctx.lineTo(left, floor + .5);
         ctx.stroke();

         ctx.textAlign = "right";
         ctx.fillStyle = kind.colour;
         ctx.fillText(kind.format(top), left - 6, ceiling + 4);
         ctx.fillStyle = AXIS;
         ctx.fillText("0", left - 6, floor + 4);
         ctx.fillText(kind.unit, left - 6, hgt - 1);

         raf = ws ? requestAnimationFrame(draw) : 0;
      };

      const setState = (on, label) => {
         dot.className = "dot" + (on ? " on" : "");
         state.textContent = label;
         connect.textContent = on ? "Disconnect" : "Connect";
         connect.disabled = false;
      };

      const buttons = Object.keys(SERIES).map(key => {
         const b = h("button", { class: "btn btn-small" + (key === showing ? " on" : ""),
            type: "button" }, SERIES[key].label);

         b.addEventListener("click", () => {
            showing = key;
            buttons.forEach(other => other.classList.toggle("on", other === b));
            requestAnimationFrame(draw);
         });

         tabs.append(b);
         return b;
      });

      setState(false, "not connected");
      requestAnimationFrame(draw);

      connect.addEventListener("click", () => {
         if (ws) {
            connect.textContent = "disconnecting…";
            connect.disabled = true;
            ws.close();
            return;
         }

         ws = new WebSocket(wsURL(demo.path));
         memory = []; procs = [];

         let opened = false;

         ws.onopen = () => { opened = true; setState(true, "streaming"); raf = requestAnimationFrame(draw); };
         ws.onmessage = e => {
            let d = null;
            try { d = JSON.parse(e.data); } catch (err) { return; }

            if (d.bye) { state.textContent = d.bye; return; }

            memory.push(d.memory_kb / 1024);
            procs.push(d.processes);
            if (memory.length > SLOTS) { memory.shift(); procs.shift(); }

            reading.innerHTML =
               '<b style="color:' + MEMORY + '">' + mb(d.memory_kb) + " MB</b> · " +
               '<b style="color:' + WORKERS + '">' + d.processes + " processes</b> · " +
               "<b>" + (d.websockets || 0) + "</b> ws";
         };
         ws.onclose = () => {
            ws = null;
            setState(false, opened ? "closed" : "refused");
            if (raf) { cancelAnimationFrame(raf); raf = 0; }
            requestAnimationFrame(draw);

            if (!opened) refusalReason(t => { state.textContent = t; });
         };
         ws.onerror = () => { if (opened) setState(false, "connection error"); };
      });

      window.addEventListener("beforeunload", () => { if (ws) ws.close(); });
   }

   /* ------------------------------------------------------------ chat */

   function buildChat(live, demo) {
      const dot = h("span", { class: "dot" });
      const state = h("span", { text: "not connected" });
      const connect = h("button", { class: "btn btn-small", type: "button" }, "Join");

      const console_ = h("div", { class: "output console" });
      const buttons = [];

      const says = h("div", { class: "says" },
         demo.says.map(s => {
            const b = h("button", { class: "btn btn-small say", type: "button" }, s.label);
            b.addEventListener("click", () => {
               if (!ws || ws.readyState !== 1) return;
               ws.send(s.token);
            });
            buttons.push(b);
            return b;
         }));

      live.append(
         h("div", { class: "wsbar" }, dot, state, h("span", { class: "spacer" }), connect),
         says,
         console_);

      let ws = null;

      const log = (cls, text) => {
         console_.append(h("div", { class: "line " + cls, text: text }));
         console_.scrollTop = console_.scrollHeight;
      };

      const setState = (on, label) => {
         dot.className = "dot" + (on ? " on" : "");
         state.textContent = label;
         connect.textContent = on ? "Leave" : "Join";
         connect.disabled = false;
         buttons.forEach(b => { b.disabled = !on; });
      };

      setState(false, "not connected");

      connect.addEventListener("click", () => {
         if (ws) {
            connect.textContent = "leaving…";
            connect.disabled = true;
            ws.close();
            return;
         }

         log("sys", "connecting …");
         ws = new WebSocket(wsURL(demo.path));

         let opened = false;

         ws.onopen = () => {
            opened = true;
            setState(true, "in the room");
            log("sys", "you are in — this connection has a process of its own");
         };
         ws.onmessage = e => log("in", e.data);
         ws.onclose = () => {
            ws = null;
            setState(false, opened ? "left" : "refused");

            if (opened) log("sys", "connection closed");
            else refusalReason(t => log("sys", t));
         };
         ws.onerror = () => { if (opened) log("sys", "connection error"); };
      });

      window.addEventListener("beforeunload", () => { if (ws) ws.close(); });
   }

   /* One width for every snippet on the page: the widest of them. Each demo
      would otherwise size its own column, which fits but leaves the dividers
      staggered down the page. */
   function alignDemoColumns() {
      const panels = Array.from(document.querySelectorAll(".demo-source pre"));
      if (!panels.length) return;

      snippets().then(() => requestAnimationFrame(() => {
         const widest = Math.max(...panels.map(p => p.scrollWidth));
         const room = document.querySelector(".demo-body").clientWidth - 360;

         document.documentElement.style.setProperty("--code-col",
            Math.min(widest, Math.max(360, room)) + "px");
      })).catch(() => {});
   }

   /* ------------------------------------------------------------ examples page */

   function mountExamples(host, toc) {
      fetch("/api/examples").then(r => r.json()).then(list => {
         host.textContent = "";
         if (toc) toc.textContent = "";

         list.forEach(ex => {
            const code = h("code");
            code.innerHTML = window.dhighlight(ex.code);

            const dir = "examples/" + ex.id;

            host.append(h("article", { class: "example", id: ex.id },
               h("h3", { text: ex.title }),
               h("p", { class: "summary", text: ex.summary }),
               h("div", { class: "code" },
                  h("div", { class: "code-head" },
                     h("span", { text: dir + "/source/app.d" }),
                     h("span", { class: "spacer" }),
                     h("a", {
                        href: "https://github.com/trikko/serverino/tree/master/" + dir,
                        target: "_blank", rel: "noopener"
                     }, "on GitHub"),
                     copyButton(() => ex.code)),
                  h("pre", null, code))));

            if (toc) toc.append(h("li", null, h("a", { href: "#" + ex.id, text: ex.title })));
         });

         if (location.hash) {
            const el = document.getElementById(location.hash.slice(1));
            if (el) el.scrollIntoView();
         }

         spyOnHeadings();
      }).catch(() => {
         host.textContent = "";
         host.append(h("div", { class: "note" },
            h("p", { text: "The examples are read from the repository by the website server. " +
               "Start it with: dub run --root=website" })));
      });
   }

   function spyOnHeadings() {
      const links = Array.from(document.querySelectorAll(".toc a"));
      if (!links.length) return;

      const targets = links.map(a => document.getElementById(a.getAttribute("href").slice(1))).filter(Boolean);

      const observer = new IntersectionObserver(entries => {
         entries.forEach(entry => {
            if (!entry.isIntersecting) return;
            links.forEach(a => a.classList.toggle("active", a.getAttribute("href") === "#" + entry.target.id));
         });
      }, { rootMargin: "-80px 0px -70% 0px" });

      targets.forEach(t => observer.observe(t));
   }

   /* ------------------------------------------------------------ boot */

   document.addEventListener("DOMContentLoaded", () => {
      const version = document.getElementById("version");
      if (version)
         fetch("/api/version").then(r => r.text())
            .then(v => { version.textContent = v.trim(); })
            .catch(() => { version.remove(); });

      // The addresses on the page are the address you are reading it from.
      document.querySelectorAll(".origin").forEach(el => { el.textContent = location.origin; });

      const inline = document.getElementById("version-inline");
      if (inline)
         fetch("/api/version").then(r => r.text()).then(v => { inline.textContent = v.trim(); })
            .catch(() => {});

      document.querySelectorAll("[data-demo]").forEach(mountDemo);
      alignDemoColumns();

      const examples = document.getElementById("examples");
      if (examples) mountExamples(examples, document.getElementById("examples-toc"));

      document.querySelectorAll("pre[data-copy]").forEach(pre => {
         const code = pre.querySelector("code") || pre;
         code.innerHTML = window.dhighlight(code.textContent);
      });

      document.querySelectorAll("[data-copy-target]").forEach(btn => {
         const target = document.querySelector(btn.dataset.copyTarget);
         if (target) btn.replaceWith(copyButton(() => target.textContent));
      });

      if (!document.getElementById("examples")) spyOnHeadings();
   });
})();
