/++
 A page inspector: give it a url, it downloads the page and tells you what's inside.

 - parserino reads the page as a browser would: any html, broken or not, in any encoding.
   CSS selectors find what we need, and the parse errors say what's wrong with the html.
 - The report is a plain html page too (views/index.html, open it in a browser): parsed at
   compile time, filled by id and class, rows cloned from the examples in it. Texts and
   attributes are escaped by parserino: a page can't inject html into the report.
 - The QR code of the page is generated here with qr, inline as SVG or as a PNG download.

 Run with `dub` and open http://localhost:8080
+/
module app;

import std;

// Docs: https://serverino.dev
// Tips and tricks: https://github.com/trikko/serverino/wiki/
import serverino;

// HTML5 parser and DOM editor. Docs: https://trikko.github.io/parserino/
import parserino;
import parserino.encoding : sniffEncoding, toUtf8;

// QR codes. Docs: https://github.com/trikko/qr
import qr;

mixin ServerinoMain;

@onServerInit ServerinoConfig configure()
{
   return ServerinoConfig.create()
      .addListener("0.0.0.0", 8080)
      .setMaxRequestTime(20.seconds);   // we wait for other servers: the default (5s) is too short
}

@endpoint @route!"/"
void inspect(Request request, Output output)
{
   // A new copy of the template, parsed at compile time: no parsing at runtime
   Document report = ctDocument!(import("index.html"));
   string url = request.get.read("url").strip;

   if (url.empty)
   {
      report.byId("error").remove();
      report.byId("report").remove();
      report.bySelector("footer").front.remove();
   }
   else
   {
      report.byId("url").setAttribute("value", url);

      try
      {
         auto start = MonoTime.currTime;
         auto page = download(url);
         auto downloaded = MonoTime.currTime;

         fill(report, page);

         report.byId("bytes").textContent = format("%,d", page.size);
         report.byId("download-ms").textContent = (downloaded - start).total!"msecs".to!string;
         report.byId("parse-ms").textContent = format("%.1f", (MonoTime.currTime - downloaded).total!"usecs" / 1000.0);
         report.byId("error").remove();
      }
      catch (Exception e)
      {
         report.byId("error").textContent = e.msg;
         report.byId("report").remove();
         report.bySelector("footer").front.remove();
      }
   }

   output.addHeader("content-type", "text/html; charset=utf-8");
   output ~= report.toString;
}

// The QR code as a PNG, to download it
@endpoint @route!"/qr.png"
void qrPng(Request request, Output output)
{
   string data = request.get.read("data");

   if (data.empty || data.length > 1024)
   {
      output.status = 400;
      return;
   }

   output.addHeader("content-type", "image/png");
   output.addHeader("content-disposition", `attachment; filename="qrcode.png"`);
   output ~= QrCode(data).toBytes(10, 4, "#1f3b53", "#ffffff", OutputFormat.PNG);
}

@endpoint @priority(-1)
void notFound(Output output)
{
   output.status = 404;
   output.addHeader("content-type", "text/plain");
   output ~= "Page not found!";
}

struct Page
{
   string url;       // after the redirects
   string html;      // converted to UTF-8
   string encoding;  // the original one
   size_t size;      // bytes downloaded
}

// Put what we find in `page` into the report
void fill(Document report, Page page)
{
   ParseOptions options;
   options.collectErrors = true;
   Document doc = Document(page.html, options);

   // The summary. Every search can find nothing: frontOrInit gives an invalid element (== null)
   // instead of throwing, and a missing attribute is null.
   string title = doc.title;
   string lang = doc.documentElement.getAttribute("lang");

   report.title = "Page inspector: " ~ (title.empty ? page.url : title);
   report.byId("title").textContent = title.empty ? "(no title)" : title;
   report.byId("final-url").textContent = page.url;
   report.byId("encoding").textContent = page.encoding;
   report.byId("lang").textContent = lang.empty ? "not set" : lang;

   auto description = doc.bySelector(`meta[name="description" i], meta[property="og:description"]`).frontOrInit;
   if (description != null) report.byId("description").textContent = description.getAttribute("content");
   else report.byId("description").remove();

   // Attributes are escaped, but a link can still be a "javascript:" url: keep only web addresses
   auto canonical = doc.bySelector(`link[rel~="canonical" i]`).frontOrInit;
   string canonicalUrl = canonical != null ? absolute(page.url, canonical.getAttribute("href")) : null;
   if (canonicalUrl.isWebUrl)
   {
      report.byId("canonical").textContent = canonicalUrl;
      report.byId("canonical").setAttribute("href", canonicalUrl);
   }
   else report.byId("canonical-row").remove();

   auto image = doc.bySelector(`meta[property="og:image"], meta[name="twitter:image"]`).frontOrInit;
   string imageUrl = image != null ? absolute(page.url, image.getAttribute("content")) : null;
   if (imageUrl.isWebUrl) report.byId("preview").setAttribute("src", imageUrl);
   else report.byId("preview").remove();

   // The QR code: qr writes an SVG, parserino puts it in the page as html
   report.byId("qr").innerHTML = cast(string) QrCode(page.url).toBytes(4, 2, "#1f3b53", "#ffffff", OutputFormat.SVG);
   report.byId("qr-download").setAttribute("href", "/qr.png?data=" ~ encodeComponent(page.url));

   // Links: to this site, or to the others (counted by domain)
   string host = hostOf(page.url);
   size_t internal;
   size_t[string] domains;

   foreach (a; doc.bySelector("a[href]"))
   {
      string href = absolute(page.url, a.getAttribute("href").strip);
      if (!href.isWebUrl) continue;   // mailto:, tel:, javascript:, ...

      string target = hostOf(href);
      if (target == host) internal++;
      else domains[target]++;
   }

   report.byId("links-internal").textContent = format("%,d", internal);
   report.byId("links-external").textContent = format("%,d", domains.byValue.sum(size_t(0)));

   auto topDomains = domains.byKeyValue
      .map!(d => tuple(d.key, d.value))
      .array
      .sort!((a, b) => a[1] > b[1] || (a[1] == b[1] && a[0] < b[0]))
      .take(10)
      .array;

   fillRows(report.byId("domains"), topDomains, (Element row, typeof(topDomains[0]) d) {
      row.byClass("domain").front.textContent = d[0];
      row.byClass("count").front.textContent = d[1].to!string;
   });
   if (topDomains.empty) report.byId("domains").remove();
   else report.byId("no-domains").remove();

   // Images and scripts: counting what a selector finds
   report.byId("images").textContent = doc.byTagName("img").walkLength.to!string;
   report.byId("images-no-alt").textContent = doc.bySelector("img:not([alt])").walkLength.to!string;
   report.byId("scripts").textContent = doc.byTagName("script").walkLength.to!string;
   report.byId("scripts-inline").textContent = doc.bySelector("script:not([src])").walkLength.to!string;

   // The outline. A selector list gives the elements in document order, whatever the selector.
   auto headings = doc.bySelector("h1, h2, h3")
      .map!(h => tuple(h.localName, h.textContent.split.join(" ")))
      .filter!(h => !h[1].empty)
      .take(40)
      .array;

   fillRows(report.byId("outline"), headings, (Element row, typeof(headings[0]) h) {
      row.setAttribute("class", h[0]);
      row.byClass("tag").front.textContent = h[0];
      row.byClass("text").front.textContent = h[1].walkLength > 120 ? h[1].take(120).to!string ~ "…" : h[1];
   });
   if (headings.empty) report.byId("outline").remove();
   else report.byId("no-headings").remove();

   // The html errors, found while parsing: the page was fixed as a browser would
   auto errors = doc.parseErrors;
   report.byId("html-errors").textContent = format("%,d", errors.length);

   fillRows(report.byId("errors"), errors.take(8).array, (Element row, ParseError e) { row.textContent = e.toString; });
   if (errors.length > 8) report.byId("errors-more").textContent = format("… and %,d more.", errors.length - 8);
   else report.byId("errors-more").remove();
   if (errors.empty) report.byId("errors-card").remove();

   // The words a reader sees: remove what isn't text, then count. Take the nodes with .array
   // first: removing them while walking the (live) range would skip some.
   foreach (e; doc.bySelector("script, style, noscript, template, svg").array)
      e.remove();

   size_t words = doc.body != null ? doc.body.textContent.splitter.walkLength : 0;
   report.byId("words").textContent = format("%,d", words);
}

// Fill `list` with one row for each item, cloned from its first child. The example rows go.
void fillRows(T)(Element list, T[] items, void delegate(Element, T) fillRow)
{
   auto examples = list.children.array;

   foreach (item; items)
   {
      auto row = examples[0].dup;
      fillRow(row, item);
      list.append(row);
   }

   foreach (example; examples)
      example.remove();
}

// Download a web page. The redirects are followed here, to check every address we go to.
Page download(string url)
{
   enum maxSize = 5 * 1024 * 1024;

   foreach (redirect; 0 .. 5)
   {
      checkUrl(url);

      ubyte[] data;
      string[string] headers;
      bool tooBig;

      auto http = HTTP(url);
      http.handle.set(CurlOption.followlocation, 0);
      http.connectTimeout = 5.seconds;
      http.operationTimeout = 15.seconds;
      http.setUserAgent("serverino page inspector (https://serverino.dev)");
      http.onReceiveHeader = (in char[] key, in char[] value) { headers[key.toLower.idup] = value.idup; };
      http.onReceive = (ubyte[] chunk) {
         if (data.length + chunk.length > maxSize) { tooBig = true; return size_t(0); }   // 0 stops curl
         data ~= chunk;
         return chunk.length;
      };

      try http.perform();
      catch (CurlException e) throw new Exception(tooBig ? "The page is too big." : "Download failed: " ~ e.msg);

      auto status = http.statusLine.code;

      if (status >= 300 && status < 400 && "location" in headers)
      {
         url = absolute(url, headers["location"]);
         continue;
      }

      if (status != 200)
         throw new Exception(format("The server answered %s %s", status, http.statusLine.reason).strip ~ ".");

      string contentType = headers.get("content-type", "text/html");
      if (!contentType.canFind("html"))
         throw new Exception("That's not a web page: it's " ~ contentType ~ ".");

      // The charset from the http header, if any. Otherwise parserino looks for a BOM or
      // a <meta charset> in the page, as a browser does.
      string charset = contentType.findSplitAfter("charset=")[1].until(';').to!string.strip(`"' `);
      string encoding = sniffEncoding(data, charset);

      return Page(url, toUtf8(data, encoding), encoding, data.length);
   }

   throw new Exception("Too many redirects.");
}

// This server downloads what anybody asks for: don't let it reach our own network.
// A minimal check, as fits an example: a real service should also pin the address curl uses.
void checkUrl(string url)
{
   if (!url.isWebUrl) throw new Exception("Only http:// and https:// addresses, please.");

   string host = hostOf(url);
   if (host.empty) throw new Exception("That address has no host.");

   Address[] addresses;
   try addresses = getAddress(host);
   catch (Exception e) throw new Exception("Unknown host: " ~ host);

   foreach (address; addresses)
      if (!isPublic(address))
         throw new Exception("That address is not on the public internet.");
}

bool isPublic(Address address)
{
   // getAddress gives generic addresses: read them back from their text form
   if (address.addressFamily == AddressFamily.INET)
   {
      immutable uint ip = InternetAddress.parse(address.toAddrString);
      bool inRange(string net, uint bits) { return (ip >> (32 - bits)) == (InternetAddress.parse(net) >> (32 - bits)); }

      return !(inRange("0.0.0.0", 8) || inRange("10.0.0.0", 8) || inRange("100.64.0.0", 10)
         || inRange("127.0.0.0", 8) || inRange("169.254.0.0", 16) || inRange("172.16.0.0", 12)
         || inRange("192.168.0.0", 16) || inRange("224.0.0.0", 3));
   }

   // IPv6: global unicast only (2000::/3)
   if (address.addressFamily == AddressFamily.INET6)
      return (Internet6Address.parse(address.toAddrString)[0] & 0xE0) == 0x20;

   return false;
}

bool isWebUrl(string url) { return url.startsWith("http://", "https://") != 0; }

// "https://user@Example.com:8080/path" => "example.com"
string hostOf(string url)
{
   string authority = url.findSplitAfter("://")[1].until!(c => c == '/' || c == '?' || c == '#').to!string;
   if (auto credentials = authority.findSplitAfter("@")) authority = credentials[1];

   if (authority.startsWith("[")) return authority[1 .. $].until(']').to!string;   // IPv6
   return authority.until(':').to!string.toLower;
}

// A link of the page, as an absolute url
string absolute(string base, string href)
{
   if (href.empty || href.canFind("://") || href.startsWith("mailto:", "tel:", "javascript:", "data:")) return href;

   string scheme = base[0 .. base.indexOf("://")];
   auto pathStart = base.indexOf('/', scheme.length + 3);
   string origin = pathStart < 0 ? base.until!(c => c == '?' || c == '#').to!string : base[0 .. pathStart];
   string path = pathStart < 0 ? "/" : base[pathStart .. $].until!(c => c == '?' || c == '#').to!string;

   if (href.startsWith("//")) return scheme ~ ":" ~ href;
   if (href.startsWith("/")) return origin ~ href;
   if (href.startsWith("?", "#")) return origin ~ path ~ href;
   return origin ~ path[0 .. path.lastIndexOf('/') + 1] ~ href;
}
