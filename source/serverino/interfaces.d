/*
Copyright (c) 2023-2024 Andrea Fontana

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
*/

/// Everything you need to communicate.
module serverino.interfaces;

import std.conv : to;
import std.string : format, representation, indexOf, lastIndexOf, toLower, toStringz, strip;
import std.range : empty, assumeSorted;
import std.algorithm : map, canFind, splitter, startsWith;
import core.thread : Thread;
import std.datetime : SysTime, Clock, seconds, Duration, DateTime;
import std.experimental.logger : log, warning, fatal, critical;
import std.socket : Address, Socket, SocketShutdown, socket_t, SocketOptionLevel, SocketOption, Linger, AddressFamily;

import serverino.databuffer;
import serverino.common;
import core.stdc.ctype;

/++ A cookie. Use `Cookie("key", "value")` to create a cookie. You can chain methods.
+ ---
+ auto cookie = Cookie("name", "value").path("/").domain("example.com").secure().maxAge(1.days);
+ output.setCookie(cookie);
+ ---
+/
struct Cookie
{
   /// Cookie SameSite flag
   enum SameSite
   {
      NotSet = "NotSet",   /// SameSite flag will not be set.
      Strict = "Strict",   /// Strict value. Cookie will be sent only if the request is from the same site.
      Lax = "Lax",         /// Lax value. Cookie will be sent only if the request is from the same site, except for links from external sites.
      None = "None"        /// None value. Cookie will be sent always. Secure flag will be set.
   }

   @disable this();

   /// Build a cookie with name and value
   @safe @nogc nothrow this(string name, string value) { _name = name; _value = value; _valid = true; }

   /// Set cookie path
   @safe @nogc nothrow @property ref Cookie path(string path) scope return { _path = path; return this; }

   /// Set cookie domain
   @safe @nogc nothrow @property ref Cookie domain(string domain) scope return { _domain = domain; return this; }

   /// Set cookie secure flag. This cookie will be sent only thru https.
   @safe @nogc nothrow @property ref Cookie secure(bool secure = true) scope return { _secure = secure; return this; }

   /// Set cookie httpOnly flag. This cookie will not be accessible from javascript.
   @safe @nogc nothrow @property ref Cookie httpOnly(bool httpOnly = true) scope return { _httpOnly = httpOnly; return this; }

   /// Set cookie expire time. It overrides maxAge.
   @safe @nogc nothrow @property ref Cookie expire(SysTime expire) scope return { _maxAge = Duration.zero; _expire = expire; return this; }

   /// Set cookie max age. It overrides expire.
   @safe @nogc nothrow @property ref Cookie maxAge(Duration maxAge) scope return { _expire = SysTime.init; _maxAge = maxAge; return this; }

   /// Set cookie SameSite flag
   @safe @nogc nothrow @property ref Cookie sameSite(SameSite sameSite) scope return { _sameSite = sameSite; return this; }

   /// Invalidate cookie. It will be deleted from browser on output.setCookie() request.
   @safe @nogc nothrow @property ref Cookie invalidate() scope return
   {
      _value = string.init;
      _expire = SysTime.init;
      _maxAge = Duration.min;
      return this;
   }

   private:

   string   _name;
   string   _value;
   string   _path;
   string   _domain;
   bool     _secure     = false;
   bool     _httpOnly   = false;
   SysTime  _expire     = SysTime.init;
   Duration _maxAge     = Duration.zero;
   SameSite _sameSite   = SameSite.NotSet;

   bool _valid = false;
}

/// HTTP version used in request
enum HttpVersion
{
   HTTP10 = "HTTP/1.0",
   HTTP11 = "HTTP/1.1"
}

/++ A request from user. Do not store ref to this struct anywhere.
+ ---
+ void handler(Request request, Output output)
+ {
+    info("You asked for ", request.uri, " with method ", request.method, " and params ", request.get.data);
+ }
+ ---
+/
struct Request
{
   /// Print request data
   @safe string dump()(bool html = true) const
   {
      import std.string : replace;
      string d = toString();

      if (html) d = `<img src="data:image/png;base64,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" alt="" style="display:flex;margin-right:auto; text-align: center;margin-bottom:10px;"><pre style="width:auto;border-radius:4px;padding:10px;background:#eff1ecff;overflow-x:auto">` ~ d.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") ~ "</pre>";

      return d;
   }

   /// ditto
   @safe string toString()() const
   {

      string output;
      output ~= format("Serverino %s.%s.%s\n\n", SERVERINO_MAJOR, SERVERINO_MINOR, SERVERINO_REVISION);
      output ~= format("Worker: #%s\n", worker.to!string);
      output ~= format("Build ID: %s\n", buildId);
      output ~= "\n";
      output ~= "Request:\n";
      output ~= format(" • Method: %s\n", method.to!string);
      output ~= format(" • Uri: %s\n", uri);

      if (!_internal._user.empty)
         output ~= format(" • Authorization: user => `%s` password => `%s`\n",_internal._user,_internal._password.map!(x=>'*'));

      if (!get.data.empty)
      {
         output ~= "\nQuery Params:\n";
         foreach(k,v; get.data)
         {
            output ~= format(" • %s => %s\n", k, v);
         }
      }

      if (!body.data.empty)
         output ~= "\nContent-type: " ~ body.contentType ~ " (size: %s bytes)\n".format(body.data.length);

      if (!post.data.empty)
      {
         output ~= "\nPost Params:\n";
         foreach(k,v; post.data)
         {
            output ~= format(" • %s => %s\n", k, v);
         }
      }

      if (!form.data.empty)
      {
         output ~= "\nForm Data:\n";
         foreach(k,v; form.data)
         {
            import std.file : getSize;

            if (v.isFile) output ~= format(" • `%s` (content-type: %s, size: %s bytes, path: %s)\n", k, v.contentType, getSize(v.path), v.path);
            else output ~= format(" • `%s` (content-type: %s, size: %s bytes)\n", k, v.contentType, v.data.length);
         }
      }

      if (!cookie.data.empty)
      {
         output ~= "\nCookies:\n";
         foreach(k,v; cookie.data)
         {
            output ~= format(" • %s => %s\n", k, v);
         }
      }

      output ~= "\nHeaders:\n";
      foreach(k,v; header.data)
      {
         output ~= format(" • %s => %s\n", k, v);
      }

      return output;
   }

   /// HTTP methods
   public enum Method
	{
		Get, /// GET
      Post, /// POST
      Head, /// HEAD
      Put, /// PUT
      Delete, /// DELETE
      Connect, /// CONNECT
      Options, /// OPTIONS
      Patch, /// PATCH
      Trace, /// TRACE
      Unknown = -1 /// Unknown method
	}

   /++ Params from query string
    + ---
    + request.get.has("name"); // true for http://localhost:8000/page?name=hello
    + request.get.read("name", "blah") // returns "Karen" for http://localhost:8000/page?name=Karen
    + request.get.read("name", "blah") // returns "blah" for http://localhost:8000/page?test=123
    + ---
    +/
   @safe @nogc @property nothrow public auto get() const { return SafeAccess!string(_internal._get); }

   /++ Params from post if content-type is "application/x-www-form-urlencoded"
   + ---
   + request.post.has("name");
   + request.post.read("name", "Anonymous") // returns "Anonymous" if name was not posted
   + ---
   +/
   @safe @nogc @property nothrow public auto post()  const { return SafeAccess!string(_internal._post); }

   /++
    + The fields from a form. Only if content-type is "multipart/form-data".
    + ---
    + FormData fd = request.form.read("form_id");
    + if (fd.isFile)
    + {
    +   // We have a file attached
    +   info("File name: ", fd.filename);
    +   info("File path: ", fd.path);
    + }
    + else
    + {
    +   // We have data inlined
    +   into("Content-Type: ", fd.contentType, " Size: ", fd.data.length, " bytes")
    +   info("Data: ", fd.data);
    + }
    ---
    +/
   @safe @nogc @property nothrow public auto form() const { return SafeAccess!FormData(_internal._form); }

   /++ Raw posted data
   ---
   import std.experimental.logger;
   info("Content-Type: ", request.body.contentType, " Size: ", request.body.data.length, " bytes");
   ---
   +/
   @safe @nogc @property nothrow public auto body() const { import std.typecons: tuple; return tuple!("data", "contentType")(_internal._data,_internal._postDataContentType); }

   /++
   Http headers, always lowercase
   ---
   request.header.read("user-agent");
   ---
   +/
   @safe @nogc @property nothrow public auto header() const { return SafeAccess!(string)(_internal._header); }

   /// Cookies received from user
   @safe @nogc @property nothrow public auto cookie() const { return SafeAccess!string(_internal._cookie); }

   /// The uri requested by user
   @safe @nogc @property nothrow public const(string) uri() const { return _internal._uri; }

   /// Which worker is processing this request?
   @safe @nogc @property nothrow public auto worker() const { return _internal._worker; }

   /// The host that received the request
   @safe @nogc @property nothrow public auto host() const { return _internal._host; }

   /// Use at your own risk! Raw data from user.
   @safe @nogc @property nothrow public auto requestLine() const { return _internal._rawRequestLine; }

   /// Basic http authentication user. Safe only if sent thru https!
   @safe @nogc @property nothrow public auto user() const { return _internal._user; }

   /// Basic http authentication password. Safe only if sent thru https!
   @safe @nogc @property nothrow public auto password() const { return _internal._password; }

   /// The sequence of endpoints called so far
   @safe @nogc @property nothrow public auto route() const { return _internal._route; }

   static package string simpleNotSecureCompileTimeHash(string seed = "")
   {
      // Definetely not a secure hash function
      // Created just to give a unique ID to each build.

      char[16] h = "SimpleNotSecure!";
      char[32] h2;

      auto  s = (seed ~ "_" ~  __TIMESTAMP__).representation;
      static immutable hex = "0123456789abcdef".representation;

      ulong sc = 104_059;

      foreach_reverse(idx, c; s)
      {
         sc += 1+(cast(ushort)c);
         sc *= 79_193;
         h[15-idx%16] ^= cast(char)(sc%255);
      }

      foreach(idx, c; h)
      {
         sc += 1+(cast(ushort)c);
         sc *= 96_911;
         h2[idx*2] = hex[(sc%256)/16];
         h2[idx*2+1]= hex[(sc%256)%16];
      }

      return h2.dup;
   }

   /// Every time you compile the app this value will change
   enum buildId = simpleNotSecureCompileTimeHash();

	/// HTTP method
   @safe @property @nogc nothrow public Method method() const
	{
		switch(_internal._method)
		{
			case "GET": return Method.Get; /// GET
			case "POST": return Method.Post; /// POST
			case "HEAD": return Method.Head; /// HEAD
			case "PUT": return Method.Put; /// PUT
			case "DELETE": return Method.Delete; /// DELETE
         case "CONNECT": return Method.Connect; /// CONNECT
         case "OPTIONS": return Method.Options; /// OPTIONS
         case "PATCH": return Method.Patch; /// PATCH
         case "TRACE": return Method.Trace; /// TRACE
         default: return Method.Unknown; /// Unknown
		}
	}


   package enum ParsingStatus
   {
      OK = 0,                 ///
      MaxUploadSizeExceeded,  ///
      InvalidBody,            ///
      InvalidRequest          ///
   }

   /++ Simple structure to safely access data from an associative array.
   + ---
   + // request.cookie returns a SafeAccess!string
   + // get a cookie named "user", default to "anonymous"
   + auto user = request.cookie.read("user", "anonymous");
   +
   + // Access the underlying AA
   + auto data = request.cookie.data;
   + foreach(k,v; data) info(k, " => ", v);
   + ---
   +/
   struct SafeAccess(T)
   {
      public:

      /++
         Read a value. Return defaultValue if k does not exist.
         ---------
         request.cookie.read("user", "anonymous");
         ---------
      +/
      @safe @nogc nothrow auto read(string key, T defaultValue = T.init) const
      {
         auto v = key in _data;

         if (v == null) return defaultValue;
         return *v;
      }

      /// Check if value exists
      @safe @nogc nothrow bool has(string key) const
      {
         return (key in _data) != null;
      }

      /// Return the underlying AA
      @safe @nogc nothrow @property auto data() const { return _data; }

      auto toString() const { return _data.to!string; }

      private:

      @safe @nogc nothrow this(const ref T[string] data) { _data = data; }
      const T[string] _data;
   }

   /++ Data sent through multipart/form-data.
   +/
   public struct FormData
   {
      string name;         /// Form field name

      string contentType;  /// Content type
      char[] data;         /// Data, if inlined (empty if `isFile() == true`)

      string filename;     /// We have a file attached. Its name.
      string path;         /// If we have a file attached, here it is saved.

      /// Is it a file or is data inlined?
      @safe @nogc nothrow @property bool isFile() const { return !filename.empty; }
   }

   package struct RequestImpl
   {
      void process()
      {
         import std.algorithm : splitter;
         import std.regex : match, ctRegex;
         import std.uri : decodeComponent;
         import std.string : translate, split, strip;
         import std.process : thisProcessID;

         static string myPID;
         if (myPID.length == 0) myPID = thisProcessID().to!string;

         foreach(ref h; _rawHeaders.splitter("\r\n"))
         {
            auto first = h.indexOf(":");
            if (first < 0) continue;
            _header[h[0..first]] = h[first+1..$];
         }

         _worker = myPID;

         if ("host" in _header) _host = _header["host"];

         // Read get params
         if (!_rawQueryString.empty)
            foreach(m; match(_rawQueryString, ctRegex!("([^=&]*)(?:=([^&]*))?&?", "g")))
               _get[m.captures[1].decodeComponent] = translate(m.captures[2],['+':' ']).decodeComponent;

         // Read post params
         try
         {
            import std.algorithm : filter, endsWith, countUntil;
            import std.range : drop, takeOne;
            import std.array : array;

            if (_method == "POST")
            {
               auto contentType = "application/octet-stream";

               if ("content-type" in _header && !_header["content-type"].empty)
                  contentType = _header["content-type"];

               auto cSplitted = contentType.splitter(";");

               _postDataContentType = cSplitted.front.toLower.strip;
               cSplitted.popFront();

               if (_postDataContentType == "application/x-www-form-urlencoded")
               {
                  import std.stdio;

                  // Ok that's easy...
                  foreach(m; match(_data, ctRegex!("([^=&]+)(?:=([^&]+))?&?", "g")))
                     _post[m.captures[1].decodeComponent] = translate(m.captures[2], ['+' : ' ']).decodeComponent;
               }
               else if (_postDataContentType == "multipart/form-data")
               {
                  // The hard way
                  string boundary;

                  // Usually they declare the boundary
                  if (!cSplitted.empty)
                  {
                     boundary = cSplitted.front.strip;

                     if (boundary.startsWith("boundary=")) boundary = boundary[9..$].strip().strip(`"`);
                     else boundary = string.init;
                  }

                  // Sometimes they write it on the first line.
                  if (boundary.empty)
                  {
                     auto lines = _data.splitter("\r\n").filter!(x => !x.empty).takeOne;

                     if (!lines.empty)
                     {
                        auto firstLine = lines.front;

                        if (firstLine.length < 512 && firstLine.startsWith("--"))
                           boundary = firstLine[2..$].to!string;
                     }
                  }

                  if (!boundary.empty)
                  {
                     bool lastBoundary = false;
                     foreach(chunk; _data.splitter("--" ~ boundary))
                     {
                        // All chunks must end with \r\n
                        if (!chunk.endsWith("\r\n"))
                           continue;

                        // The last one is --boundary--
                        chunk = chunk[0..$-2];
                        if (chunk.length == 2 && chunk == "--")
                        {
                           lastBoundary = true;
                           break;
                        }

                        // All chunks must start with \r\n
                        if (!chunk.startsWith("\r\n"))
                           continue;

                        chunk = chunk[2..$];

                        bool done = false;
                        string content_disposition;
                        string content_type = "text/plain";

                        // "Headers"
                        while(true)
                        {

                           auto nextLine = chunk.countUntil("\n");
                           auto line = chunk[0..nextLine];

                           // All lines must end with \r\n
                           if (!line.endsWith("\r"))
                              break;

                           line = line[0..$-1];

                           if (line == "\r")
                           {
                              done = true;
                              break;
                           }
                           else if (line.toLower.startsWith("content-disposition:"))
                              content_disposition = line.to!string;
                           else if (line.toLower.startsWith("content-type:"))
                              content_type = line.to!string["content-type:".length..$].strip;
                           else break;

                           if (nextLine + 1 >= chunk.length)
                              break;

                           chunk = chunk[nextLine+1 .. $];
                        }

                        // All chunks must start with \r\n
                        if (!chunk.startsWith("\r\n")) continue;
                        chunk = chunk[2..$];

                        if (content_disposition.empty) continue;

                        // content-disposition fields
                        auto form_data_raw = content_disposition.splitter(";").drop(1).map!(x=>x.split("=")).array;
                        string[string] form_data;

                        foreach(f; form_data_raw)
                        {
                           if (f.length > 1)
                           {
                              auto k = f[0].strip;
                              auto v = f[1].strip;

                              if (v.length < 2) continue;
                              form_data[k] = v[1..$-1];
                           }
                        }

                        if ("name" !in form_data) continue;

                        FormData fd;
                        fd.name = form_data["name"];
                        fd.contentType = content_type;

                        if ("filename" !in form_data) fd.data = chunk.to!(char[]);
                        else
                        {
                           fd.filename = form_data["filename"];
                           import core.atomic : atomicFetchAdd;
                           import std.path : extension, buildPath;
                           import std.file : tempDir;


                           string now = Clock.currTime.toUnixTime.to!string;
                           string uploadId = "%05d".format(atomicFetchAdd(_uploadId, 1));
                           string path = tempDir.buildPath("upload_%s_%s_%s%s".format(now, myPID, uploadId, extension(fd.filename)));

                           fd.path = path;

                           import std.file : write;
                           write(path, chunk);
                        }

                        _form[fd.name] = fd;

                     }

                     if (!lastBoundary)
                     {
                        debug warning("Can't parse multipart/form-data content");
                        _parsingStatus = ParsingStatus.InvalidBody;

                        // Something went wrong with parsing, we ignore data.
                        clearFiles();
                        _post = typeof(_post).init;
                        _form = typeof(_form).init;
                     }

                  }
               }
            }
         }
         catch (Exception e) { _parsingStatus = ParsingStatus.InvalidBody; }

         // Read cookies
         if ("cookie" in _header)
            foreach(m; match(_header["cookie"], ctRegex!("([^=]+)=([^;]+)?;? ?", "g")))
               _cookie[m.captures[1].decodeComponent] = m.captures[2].decodeComponent;

         if ("authorization" in _header)
         {
            import std.base64 : Base64, Base64Exception;
            import std.string : indexOf;
            auto auth = _header["authorization"];

            if (auth.length > 6 && auth[0..6].toLower == "basic ")
            {
               try
               {
                  auth = (cast(char[])Base64.decode(auth[6..$])).to!string;
                  auto delim = auth.indexOf(":");

                     if (delim < 0) _user = auth;
                     else
                     {
                        _user = auth[0..delim];

                        if (delim + 1 < auth.length)
                           _password = auth[delim+1..$];
                     }

               }
               catch(Base64Exception e)
               {
                  _user = string.init;
                  _password = string.init;
                  debug warning("Authorization header ignored. Error decoding base64.");
               }
            }
         }


      }

      void clearFiles() {
         import std.file : remove, exists;
         foreach(f; _form)
            try {if (exists(f.path)) remove(f.path); } catch(Exception e) { }
      }

      ~this() { clearFiles(); }


      char[] _data;
      string[string]  _get;
      string[string]  _post;
      string[string]  _header;
      string[string]  _cookie;

      string _uri;
      string _method;
      string _host;
      string _postDataContentType;
      string _worker;
      string _user;
      string _password;
      size_t _uploadId;

      string _rawQueryString;
      string _rawHeaders;
      string _rawRequestLine;

      string[]  _route;

      HttpVersion _httpVersion;

      FormData[string]   _form;
      ParsingStatus      _parsingStatus = ParsingStatus.OK;

      size_t    _requestId;

      void clear()
      {
         clearFiles();

         _form    = null;
         _data    = null;
         _get     = null;
         _post    = null;
         _header  = null;
         _cookie  = null;
         _uri     = string.init;

         _method        = string.init;
         _host          = string.init;
         _user          = string.init;
         _password      = string.init;
         _httpVersion   = HttpVersion.HTTP10;

         _rawQueryString   = string.init;
         _rawHeaders       = string.init;
         _rawRequestLine   = string.init;

         _postDataContentType = string.init;

         _parsingStatus = ParsingStatus.OK;

         _route.length = 0;
         _route.reserve(10);
      }
   }

   package RequestImpl* _internal;
}

/++ A response to user. Default content-type is "text/html".
+ ---
+ // Set status code to 404
+ output.status = 404
+
+ // Send a response. Same as: output.write("Sorry, page not found.");
+ output ~= "Sorry, page not found.";
+ ---
+/
struct Output
{

	public:

   /// Override timeout for this request
   @safe void setTimeout(Duration max) {  _internal._timeout = max; }

   /++
   + Add a http header.
   + You can't set `content-length`, `status` or `transfer-encoding` headers. They are managed by serverino internally.
   + ---
   + // Set content-type to json, default is text/html
   + output.addHeader("content-type", "application/json");
   + output.addHeader("expire", 3.days);
   + ---
   +/
	@safe void addHeader(in string key, in string value)
   {
      string k = key.toLower;

      debug if (["content-length", "status", "transfer-encoding"].canFind(k))
      {
         warning("You can't set `", key, "` header. It's managed by serverino internally.");
         if (k == "status") warning("Use `output.status = XXX` instead.");
         return;
      }

      _internal._dirty = true;
      _internal._headers ~= KeyValue(k, value);
   }

   /// Ditto
   @safe void addHeader(in string key, in Duration dur) { addHeader(key, Clock.currTime + dur); }

   /// Ditto
   @safe void addHeader(in string key, in SysTime time) { addHeader(key, toHTTPDate(time)); }

   /// You can reply with a file. Automagical mime-type detection.
   bool serveFile(const string path, bool guessMime = true)
   {
      _internal._dirty = true;

      import std.file : exists, getSize, isFile;
      import std.path : extension, baseName;
      import std.stdio : File;

      if (!exists(path) || !isFile(path))
      {
         warning("Trying to serve `", baseName(path) ,"`, but it doesn't exists.");
         return false;
      }

      size_t fs = path.getSize().to!size_t;
      _internal._headers ~= KeyValue("content-length", fs.to!string);

      if (!_internal._headers.canFind!(x=>x.key == "content-type"))
      {
         string header = "application/octet-stream";

         if (guessMime)
         {
            immutable mimes =
            [
               ".html" : "text/html", ".htm" : "text/html", ".shtml" : "text/html", ".css" : "text/css", ".xml" : "text/xml",
               ".gif" : "image/gif", ".jpeg" : "image/jpeg", ".jpg" : "image/jpeg", ".js" : "application/javascript",
               ".atom" : "application/atom+xml", ".rss" : "application/rss+xml", ".mml" : "text/mathml", ".txt" : "text/plain",
               ".jad" : "text/vnd.sun.j2me.app-descriptor", ".wml" : "text/vnd.wap.wml", ".htc" : "text/x-component",
               ".png" : "image/png", ".tif" : "image/tiff", ".tiff" : "image/tiff", ".wbmp" : "image/vnd.wap.wbmp",
               ".ico" : "image/x-icon", ".jng" : "image/x-jng", ".bmp" : "image/x-ms-bmp", ".svg" : "image/svg+xml",
               ".svgz" : "image/svg+xml", ".webp" : "image/webp", ".woff" : "application/font-woff",
               ".jar" : "application/java-archive", ".war" : "application/java-archive", ".ear" : "application/java-archive",
               ".json" : "application/json", ".hqx" : "application/mac-binhex40", ".doc" : "application/msword",
               ".pdf" : "application/pdf", ".ps" : "application/postscript", ".eps" : "application/postscript",
               ".ai" : "application/postscript", ".rtf" : "application/rtf", ".m3u8" : "application/vnd.apple.mpegurl",
               ".xls" : "application/vnd.ms-excel", ".eot" : "application/vnd.ms-fontobject",
               ".ppt" : "application/vnd.ms-powerpoint", ".wmlc" : "application/vnd.wap.wmlc",
               ".kml" : "application/vnd.google-earth.kml+xml", ".kmz" : "application/vnd.google-earth.kmz",
               ".7z" : "application/x-7z-compressed", ".cco" : "application/x-cocoa",
               ".jardiff" : "application/x-java-archive-diff", ".jnlp" : "application/x-java-jnlp-file",
               ".run" : "application/x-makeself", ".pl" : "application/x-perl", ".pm" : "application/x-perl",
               ".prc" : "application/x-pilot", ".pdb" : "application/x-pilot", ".rar" : "application/x-rar-compressed",
               ".rpm" : "application/x-redhat-package-manager", ".sea" : "application/x-sea",
               ".swf" : "application/x-shockwave-flash", ".sit" : "application/x-stuffit", ".tcl" : "application/x-tcl",
               ".tk" : "application/x-tcl", ".der" : "application/x-x509-ca-cert", ".pem" : "application/x-x509-ca-cert",
               ".crt" : "application/x-x509-ca-cert", ".xpi" : "application/x-xpinstall", ".xhtml" : "application/xhtml+xml",
               ".xspf" : "application/xspf+xml", ".zip" : "application/zip", ".bin" : "application/octet-stream",
               ".exe" : "application/octet-stream", ".dll" : "application/octet-stream", ".deb" : "application/octet-stream",
               ".dmg" : "application/octet-stream", ".iso" : "application/octet-stream", ".img" : "application/octet-stream",
               ".msi" : "application/octet-stream", ".msp" : "application/octet-stream", ".msm" : "application/octet-stream",
               ".docx" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
               ".xlsx" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
               ".pptx" : "application/vnd.openxmlformats-officedocument.presentationml.presentation", ".mid" : "audio/midi",
               ".midi" : "audio/midi", ".kar" : "audio/midi", ".mp3" : "audio/mpeg", ".ogg" : "audio/ogg", ".m4a" : "audio/x-m4a",
               ".ra" : "audio/x-realaudio", ".3gpp" : "video/3gpp", ".3gp" : "video/3gpp", ".ts" : "video/mp2t", ".mp4" : "video/mp4",
               ".mpeg" : "video/mpeg", ".mpg" : "video/mpeg", ".mov" : "video/quicktime", ".webm" : "video/webm", ".flv" : "video/x-flv",
               ".m4v" : "video/x-m4v", ".mng" : "video/x-mng", ".asx" : "video/x-ms-asf", ".asf" : "video/x-ms-asf",
               ".wmv" : "video/x-ms-wmv", ".avi" : "video/x-msvideo"
            ];

            if (path.extension in mimes)
               header = mimes[path.extension];
         }

         addHeader("content-type", header);
      }

      ubyte[] buffer;
      buffer.length = fs;
      File toSend = File(path, "r");

      auto bytesRead = toSend.rawRead(buffer);

      if (bytesRead.length != fs)
      {
         sendData("HTTP/1.0 500 Internal server error\r\n");
         return false;
      }

      //sendHeaders();
      sendData(bytesRead);
      return true;
    }


   /++ Add or edit a cookie.
   + To delete a cookie, use cookie.invalidate() and then setCookie(cookie)
   +/
   @safe void setCookie(Cookie c)
   {
      _internal._dirty = true;

      if (!c._valid)
         throw new Exception("Invalid cookie. Please use Cookie(name, value) to create a valid cookie.");

     _internal._cookies ~= c;
   }


   /// Read status.
   @safe @nogc @property nothrow ushort status() 	{ return _internal._status; }

   /// Set response status. 200 by default.
   @safe @property void status(ushort status)
   {
      _internal._dirty = true;
     _internal._status = status;
   }

   /**
   * Syntax sugar. Easier way to write output.
   * Example:
   * --------------------
   * output ~= "Hello world";
   * --------------------
   */
	void opOpAssign(string op, T)(T data) if (op == "~")  { write(data.to!string); }

   /**
   * Mute/unmute output. If false, serverino will not send any data to user.
   * --------------------
   * output = false; // Mute the output.
   * output ~= "Hello world"; // Serverino will not send this to user.
   * --------------------
   */
   void opAssign(in bool v) {
      _internal._sendBody = v;
   }

   /// Write data to output. You can write as many times as you want.
   @safe void write(string data = string.init) { write(data.representation); }

   /// Ditto
   @safe void write(in void[] data)
   {
      _internal._dirty = true;
      sendData(data);
   }

   struct KeyValue
	{
		@safe this (in string key, in string value) { this.key = key; this.value = value; }
		string key;
		string value;
	}

   package:

   @safe void sendData(const string data) { sendData(data.representation); }
   @safe void sendData(bool force = false)(const void[] data)
   {
      _internal._dirty = true;
      _internal._sendBuffer.append(cast(const char[])data);
   }

   @safe static string toHTTPDate(SysTime t) {
      immutable mm = ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
      immutable dd = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

      SysTime gmt = t.toUTC();

      return format("%s, %s %s %s %s:%s:%s GMT",
         dd[gmt.dayOfWeek], gmt.day, mm[gmt.month], gmt.year,
         gmt.hour, gmt.minute, gmt.second
      );
   }

   struct OutputImpl
   {
      Cookie[]        _cookies;
      KeyValue[]  	 _headers;
      bool            _keepAlive;
      string          _httpVersion;
      ushort          _status;
      Duration        _timeout;
      bool            _dirty;
      size_t          _requestId;
      DataBuffer!char _sendBuffer;
      DataBuffer!char _headersBuffer;
      string          _buffer;
      Socket          _channel;
      bool            _flushed;
      bool            _sendBody;


      @safe void buildHeaders()
      {
         import std.uri : encodeComponent;
         import std.array : appender;

         _headersBuffer.reserve(1024, true);
         _headersBuffer.clear();

         immutable string[short] StatusCode =
         [
            200: "OK", 201 : "Created", 202 : "Accepted", 203 : "Non-Authoritative Information", 204 : "No Content", 205 : "Reset Content", 206 : "Partial Content",

            300 : "Multiple Choices", 301 : "Moved Permanently", 302 : "Found", 303 : "See Other", 304 : "Not Modified", 305 : "Use Proxy", 307 : "Temporary Redirect",

            400 : "Bad Request", 401 : "Unauthorized", 402 : "Payment Required", 403 : "Forbidden", 404 : "Not Found", 405 : "Method Not Allowed",
            406 : "Not Acceptable", 407 : "Proxy Authentication Required", 408 : "Request Timeout", 409 : "Conflict", 410 : "Gone",
            411 : "Lenght Required", 412 : "Precondition Failed", 413 : "Request Entity Too Large", 414 : "Request-URI Too Long", 415 : "Unsupported Media Type",
            416 : "Requested Range Not Satisfable", 417 : "Expectation Failed", 422 : "Unprocessable Content",

            500 : "Internal Server Error", 501 : "Not Implemented", 502 : "Bad Gateway", 503 : "Service Unavailable", 504 : "Gateway Timeout", 505 : "HTTP Version Not Supported"
         ];

         string statusDescription;

         immutable item = _status in StatusCode;
         if (item != null) statusDescription = *item;
         else statusDescription = "Unknown";

         bool has_content_type = false;
         _headersBuffer.append(format("%s %s %s\r\n", _httpVersion, _status, statusDescription));

         if (!_keepAlive) _headersBuffer.append("connection: close\r\n");
         else _headersBuffer.append("connection: keep-alive\r\n");

         // send user-defined headers
         foreach(const ref header;_headers)
         {
            if (!_sendBody && (header.key == "content-length" || header.key == "transfer-encoding"))
               continue;

            _headersBuffer.append(format("%s: %s\r\n", header.key, header.value));
            if (header.key == "content-type") has_content_type = true;
         }

         if (!_sendBody)
            _headersBuffer.append(format("content-length: 0\r\n"));
         else
         {
            _headersBuffer.append("content-length: ");
            _headersBuffer.append(_sendBuffer.length.to!string);
            _headersBuffer.append("\r\n");
         }

         // Default content-type is text/html if not defined by user
         if (!has_content_type && _sendBody)
            _headersBuffer.append(format("content-type: text/html;charset=utf-8\r\n"));

         // If required, I add headers to write cookies
         foreach(Cookie c;_cookies)
         {
            _headersBuffer.append(format("set-cookie: %s=%s", encodeComponent(c._name), encodeComponent(c._value)));

            if (c._maxAge != Duration.zero)
            {
               if (c._maxAge.isNegative) _headersBuffer.append("; Max-Age=-1");
               else _headersBuffer.append(format("; Max-Age=%s", c._maxAge.total!"seconds"));
            }
            else if (c._expire != SysTime.init)
            {
               _headersBuffer.append(format("; Expires=%s",  Output.toHTTPDate(c._expire)));
            }

            if (!c._path.length == 0) _headersBuffer.append(format("; path=%s", c._path.encodeComponent()));
            if (!c._domain.length == 0) _headersBuffer.append(format("; domain=%s", c._domain.encodeComponent()));

            if (c._sameSite != Cookie.SameSite.NotSet)
            {
               if (c._sameSite == Cookie.SameSite.None) c._secure = true;
               _headersBuffer.append(format("; SameSite=%s", c._sameSite.to!string));
            }

            if (c._secure) _headersBuffer.append(format("; Secure"));
            if (c._httpOnly) _headersBuffer.append(format("; HttpOnly"));

            _headersBuffer.append("\r\n");
         }

         _headersBuffer.append("\r\n");
      }

      void clear()
      {
         // HACK
         _timeout = 0.seconds;
         _httpVersion = HttpVersion.HTTP10;
         _dirty = false;
         _status = 200;
         _cookies = null;
         _headers = null;
         _keepAlive = false;
         _flushed = false;
         _headersBuffer.clear();
         _sendBuffer.clear();
         _sendBody = true;
      }
   }

   OutputImpl* _internal;
}

