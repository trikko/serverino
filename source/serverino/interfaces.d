/*
Copyright (c) 2022 Andrea Fontana

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

module serverino.interfaces;



import std.conv : to;
import std.string : format, representation, indexOf, lastIndexOf, toLower, toStringz, strip;
import std.range : empty, assumeSorted;
import std.algorithm : map, canFind, splitter, startsWith;
import core.thread : Thread;
import std.datetime : SysTime, Clock, dur, Duration, DateTime;
import std.experimental.logger : log, warning, fatal, critical;
import std.socket : Address, Socket, SocketShutdown, socket_t, SocketOptionLevel, SocketOption, Linger, AddressFamily;

import serverino.databuffer;
import serverino.common;

/// A cookie
struct Cookie
{
   /// Create a cookie with an expire time
   @safe static Cookie create(string name, string value, SysTime expire, string path = string.init, string domain = string.init, bool secure = false, bool httpOnly = false)
   {
      Cookie c = Cookie.init;
      c.name = name;
      c.value = value;
      c.path = path;
      c.domain = domain;
      c.secure = secure;
      c.httpOnly = httpOnly;
      c.expire = expire;
      c.session = false;
      return c;
   }

   /// Create a cookie with a duration
   @safe static Cookie create(string name, string value, Duration duration, string path = string.init, string domain = string.init, bool secure = false, bool httpOnly = false)
   {
      import std.datetime : Clock;
      return create(name, value, Clock.currTime + duration, path, domain, secure, httpOnly);
   }

   /// Create a session cookie. (no expire time)
   @safe static Cookie create(string name, string value, string path = string.init, string domain = string.init, bool secure = false, bool httpOnly = false)
   {
      Cookie c = create(name, value, SysTime.init, path, domain, secure, httpOnly);
      c.session = true;
      return c;
   }

   @disable this();

   string      name;       /// key
   string      value;      /// Value
   string      path;       ///
   string      domain;     ///

   SysTime     expire;     /// Expiration date. Ignored if cookie.session == true

   bool        session     = true;  /// Is this a session cookie?
   bool        secure      = false; /// Send only thru https
   bool        httpOnly    = false; /// Not visible from JS

   /// Invalidate cookie
   @safe public void invalidate() { expire = SysTime(DateTime(1970,1,1,0,0,0)); }
}

enum HttpVersion
{
   HTTP10 = "HTTP/1.0",
   HTTP11 = "HTTP/1.1"
}

/// A request from user. Do not store ref to this struct anywhere.
struct Request
{
   /// Print request data
   @safe string dump()(bool html = true) const
   {
      import std.string : replace;
      string d = toString();

      if (html) d = `<pre style="padding:10px;background:#DDD;overflow-x:auto">` ~ d.replace("<", "&lt").replace(">", "&gt").replace(";", "&amp;") ~ "</pre>";

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
		Get, ///
      Post, ///
      Head, ///
      Put, ///
      Delete, ///
      Connect, ///
      Options, ///
      Patch, ///
      Trace, ///
      Unknown = -1 ///
	}

   /// Raw data from request body
   @safe @nogc @property nothrow public const(char[]) data() const  { return _internal._data; }

   /++ Params from query string
    + ---
    + request.get.has("name"); // true for http://localhost:8000/page?name=hello
    + request.get.read("name", "blah") // returns "Karen" for http://localhost:8000/page?name=Karen
    + request.get.read("name", "blah") // returns "blah" for http://localhost:8000/page?test=123
    + ---
    +/
   @safe @nogc @property nothrow public auto get() const { return SafeAccess!string(_internal._get); }

   /// Params from post if content-type is "application/x-www-form-urlencoded"
   @safe @nogc @property nothrow public auto post()  const { return SafeAccess!string(_internal._post); }

   /// Form data if content-type is "multipart/form-data"
   @safe @nogc @property nothrow public auto form() const { return SafeAccess!FormData(_internal._form); }

   /++ Raw posted data
   ---
   import std.experimental.logger;
   log("Content-Type: ", request.body.contentType, " Size: ", request.body.data.length, " bytes");
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

   ///
   @safe @nogc @property nothrow public auto cookie() const { return SafeAccess!string(_internal._cookie); }

   ///
   @safe @nogc @property nothrow public const(string) uri() const { return _internal._uri; }

   /// Which worker is processing this request?
   @safe @nogc @property nothrow public auto worker() const { return _internal._worker; }

   ///
   @safe @nogc @property nothrow public auto host() const { return _internal._host; }

   /// Use at your own risk! Raw data from user.
   @safe @nogc @property nothrow public auto requestLine() const { return _internal._rawRequestLine; }

   /// Basic http authentication user. Safe only if sent thru https!
   @safe @nogc @property nothrow public auto user() const { return _internal._user; }

   /// Basic http authentication password. Safe only if sent thru https!
   @safe @nogc @property nothrow public auto password() const { return _internal._password; }

   /// Current sessionId, if set and valid.
   @safe @nogc @property nothrow public auto sessionId() const { return _internal._sessionId; }

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

	///
   @safe @property @nogc nothrow public Method method() const
	{
		switch(_internal._method)
		{
			case "GET": return Method.Get;
			case "POST": return Method.Post;
			case "HEAD": return Method.Head;
			case "PUT": return Method.Put;
			case "DELETE": return Method.Delete;
         case "CONNECT": return Method.Connect;
         case "OPTIONS": return Method.Options;
         case "PATCH": return Method.Patch;
         case "TRACE": return Method.Trace;
         default: return Method.Unknown;
		}
	}


   package enum ParsingStatus
   {
      OK = 0,                 ///
      MaxUploadSizeExceeded,  ///
      InvalidBody,            ///
      InvalidRequest          ///
   }

   /// Simple structure to access data from an associative array.
   private struct SafeAccess(T)
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

      @safe @nogc nothrow private this(const ref T[string] data) { _data = data; }
      const T[string] _data;
   }

   /++ Data sent through multipart/form-data.
   See_Also: Request.form
   +/
   public struct FormData
   {
      string name;         /// Form field name

      string contentType;  /// Content type
      char[] data;         /// Data, if inlined (empty if isFile() == true)

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
            _header[h[0..first].toLower] = h[first+1..$].strip;
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

            if (_method == "POST" && "content-type" in _header)
            {
               auto cSplitted = _header["content-type"].splitter(";");

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
                           auto k = f[0].strip;
                           auto v = f[1].strip;

                           if (v.length < 2) continue;
                           form_data[k] = v[1..$-1];
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
                        warning("Can't parse multipart/form-data content");

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
            foreach(m; match(_header["cookie"], ctRegex!("([^=]+)=([^;]+);? ?", "g")))
               _cookie[m.captures[1].decodeComponent] = m.captures[2].decodeComponent;

         if ("authorization" in _header)
         {
            import std.base64 : Base64;
            import std.string : indexOf;
            auto auth = _header["authorization"];

            if (auth.length > 6 && auth[0..6].toLower == "basic ")
            {
               auth = (cast(char[])Base64.decode(auth[6..$])).to!string;
               auto delim = auth.indexOf(":");

               if (delim < 0) _user = auth;
               else
               {
                  _user = auth[0..delim];

                  if (delim < auth.length-1)
                     _password = auth[delim+1..$];
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
      string _sessionId;
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
         _sessionId     = string.init;
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

/// Your reply.
struct Output
{

	public:

   /// Override timeout for this request
   @safe void setTimeout(Duration max) {  _internal._timeout = max; }

   /// You can add a http header. But you can't if body is already sent.
	@safe void addHeader(in string key, in string value)
   {
      _internal._dirty = true;

      if (_internal._headersSent)
         throw new Exception("Can't add/edit headers. Too late. Just sent.");

      _internal._headers ~= KeyValue(key.toLower, value);
   }

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

      if (_internal._headersSent)
         throw new Exception("Can't add/edit headers. Too late. Just sent.");

      size_t fs = path.getSize().to!size_t;

      addHeader("Content-Length", fs.to!string);

      if (!_internal._headers.canFind!(x=>x.key == "content-type"))
      {
         string header = "application/octet-stream";

         if (guessMime)
         {
            auto mimes =
            [
               ".aac" : "audio/aac", ".abw" : "application/x-abiword", ".arc" : "application/x-freearc", ".avif" : "image/avif",
               ".bin" : "application/octet-stream", ".bmp" : "image/bmp", ".bz" : "application/x-bzip", ".bz2" : "application/x-bzip2",
               ".cda" : "application/x-cdf", ".csh" : "application/x-csh", ".css" : "text/css", ".csv" : "text/csv",
               ".doc" : "application/msword", ".docx" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
               ".eot" : "application/vnd.ms-fontobject", ".epub" : "application/epub+zip", ".gz" : "application/gzip",
               ".gif" : "image/gif", ".htm" : "text/html", ".html" : "text/html", ".ico" : "image/vnd.microsoft.icon",
               ".ics" : "text/calendar", ".jar" : "application/java-archive", ".jpeg" : "image/jpeg", ".jpg" : "image/jpeg",
               ".js" : "text/javascript", ".json" : "application/json", ".jsonld" : "application/ld+json", ".mid" : ".midi",
               ".mjs" : "text/javascript", ".mp3" : "audio/mpeg",".mp4" : "video/mp4", ".mpeg" : "video/mpeg", ".mpkg" : "application/vnd.apple.installer+xml",
               ".odp" : "application/vnd.oasis.opendocument.presentation", ".ods" : "application/vnd.oasis.opendocument.spreadsheet",
               ".odt" : "application/vnd.oasis.opendocument.text", ".oga" : "audio/ogg", ".ogv" : "video/ogg", ".ogx" : "application/ogg",
               ".opus" : "audio/opus", ".otf" : "font/otf", ".png" : "image/png", ".pdf" : "application/pdf", ".php" : "application/x-httpd-php",
               ".ppt" : "application/vnd.ms-powerpoint", ".pptx" : "application/vnd.openxmlformats-officedocument.presentationml.presentation",
               ".rar" : "application/vnd.rar", ".rtf" : "application/rtf", ".sh" : "application/x-sh", ".svg" : "image/svg+xml",
               ".swf" : "application/x-shockwave-flash", ".tar" : "application/x-tar", ".tif" : "image/tiff", ".tiff" : "image/tiff",
               ".ts" : "video/mp2t", ".ttf" : "font/ttf", ".txt" : "text/plain", ".vsd" : "application/vnd.visio", ".wasm" : "application/wasm",
               ".wav" : "audio/wav", ".weba" : "audio/webm", ".webm" : "video/webm", ".webp" : "image/webp", ".woff" : "font/woff", ".woff2" : "font/woff2",
               ".xhtml" : "application/xhtml+xml", ".xls" : "application/vnd.ms-excel", ".xlsx" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
               ".xml" : "application/xml", ".xul" : "application/vnd.mozilla.xul+xml", ".zip" : "application/zip", ".3gp" : "video/3gpp",
               ".3g2" : "video/3gpp2", ".7z" : "application/x-7z-compressed"
            ];

            if (path.extension in mimes)
               header = mimes[path.extension];
         }

         addHeader("Content-Type", header);
      }

      ubyte[] buffer;
      buffer.length = fs;
      File toSend = File(path, "r");

      auto bytesRead = toSend.rawRead(buffer);

      if (bytesRead.length != fs)
      {
         sendData("HTTP/1.0 500 Internal server error\r\nconnection: close\r\n\r\n500 Internal server error");
         return false;
      }

      sendHeaders();
      sendData(bytesRead);
      return true;
    }

	/// Force sending of headers.
	@safe void sendHeaders()
   {
     _internal._dirty = true;

      if (_internal._headersSent)
         throw new Exception("Can't resend headers. Too late. Just sent.");

      import std.uri : encode;
      import std.array : appender;

      static DataBuffer!char buffer;
      buffer.reserve(1024, true);
      buffer.clear();

      immutable string[short] StatusCode =
      [
         200: "OK", 201 : "Created", 202 : "Accepted", 203 : "Non-Authoritative Information", 204 : "No Content", 205 : "Reset Content", 206 : "Partial Content",

         300 : "Multiple Choices", 301 : "Moved Permanently", 302 : "Found", 303 : "See Other", 304 : "Not Modified", 305 : "Use Proxy", 307 : "Temporary Redirect",

         400 : "Bad Request", 401 : "Unauthorized", 402 : "Payment Required", 403 : "Forbidden", 404 : "Not Found", 405 : "Method Not Allowed",
         406 : "Not Acceptable", 407 : "Proxy Authentication Required", 408 : "Request Timeout", 409 : "Conflict", 410 : "Gone",
         411 : "Lenght Required", 412 : "Precondition Failed", 413 : "Request Entity Too Large", 414 : "Request-URI Too Long", 415 : "Unsupported Media Type",
         416 : "Requested Range Not Satisfable", 417 : "Expectation Failed",

         500 : "Internal Server Error", 501 : "Not Implemented", 502 : "Bad Gateway", 503 : "Service Unavailable", 504 : "Gateway Timeout", 505 : "HTTP Version Not Supported"
      ];

      string statusDescription;

      auto item = _internal._status in StatusCode;
      if (item != null) statusDescription = *item;
      else statusDescription = "Unknown";

      bool has_content_type = false;
      buffer.append(format("%s %s %s\r\n", _internal._httpVersion, status, statusDescription));

      if (!_internal._keepAlive) buffer.append("connection: close\r\n");
      else buffer.append("connection: keep-alive\r\n");

      // send user-defined headers
      foreach(const ref header;_internal._headers)
      {
         buffer.append(format("%s: %s\r\n", header.key, header.value));
         if (header.key == "content-type") has_content_type = true;
      }

      // Default content-type is text/html if not defined by user
      if (!has_content_type)
         buffer.append(format("content-type: text/html;charset=utf-8\r\n"));

      // If required, I add headers to write cookies
      foreach(Cookie c;_internal._cookies)
      {
         buffer.append(format("set-cookie: %s=%s", c.name.encode(), c.value.encode()));

         if (!c.session)
         {
            string[] mm = ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
            string[] dd = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

            SysTime gmt = c.expire.toUTC();

            string data = format("%s, %s %s %s %s:%s:%s GMT",
               dd[gmt.dayOfWeek], gmt.day, mm[gmt.month], gmt.year,
               gmt.hour, gmt.minute, gmt.second
            );

            buffer.append(format("; Expires=%s", data));
         }

         if (!c.path.length == 0) buffer.append(format("; path=%s", c.path));
         if (!c.domain.length == 0) buffer.append(format("; domain=%s", c.domain));
         if (c.secure) buffer.append(format("; Secure"));
         if (c.httpOnly) buffer.append(format("; HttpOnly"));
         buffer.append("\r\n");
      }

      buffer.append("\r\n");
      sendData(buffer.array);
      _internal._headersSent = true;
      buffer.clear();

   }


   @safe void deleteSessionId() { deleteCookie("__SESSION_ID__"); }

   /// You can set a cookie.  But you can't if body is already sent.
   @safe void setCookie(Cookie c)
   {
      if (_internal._headersSent)
         throw new Exception("Can't set cookies. Too late. Headers just sent.");

     _internal._cookies[c.name] = c;
   }

   /// Create & set a cookie with an expire time.
   @safe void setCookie(string name, string value, SysTime expire, string path = string.init, string domain = string.init, bool secure = false, bool httpOnly = false)
   {
      setCookie(Cookie.create(name, value, expire, path, domain, secure, httpOnly));
   }

   /// Create & set a cookie with a duration.
   @safe void setCookie(string name, string value, Duration duration, string path = string.init, string domain = string.init, bool secure = false, bool httpOnly = false)
   {
      setCookie(Cookie.create(name, value, duration, path, domain, secure, httpOnly));
   }

   /// Create & set a session cookie. (no expire time)
   @safe void setCookie(string name, string value, string path = string.init, string domain = string.init, bool secure = false, bool httpOnly = false)
   {
      setCookie(Cookie.create(name, value, path, domain, secure, httpOnly));
   }

   /// Delete a cookie
   @safe void deleteCookie(string name)
   {
      if (_internal._headersSent)
         throw new Exception("Can't delete cookies. Too late. Headers just sent.");

      Cookie c = Cookie.init;
      c.name = name;
      c.invalidate();

     _internal._cookies[c.name] = c;
   }

   /// Output status
   @safe @nogc @property nothrow ushort status() 	{ return _internal._status; }

   /// Set response status. Default is 200 (OK)
   @safe @property void status(ushort status)
   {
      _internal._dirty = true;

      if (_internal._headersSent)
         throw new Exception("Can't set status. Too late. Just sent.");

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

   /// Write data
   @safe void write(string data = string.init) { write(data.representation); }

   /// Ditto
   @safe void write(in void[] data)
   {
      _internal._dirty = true;

      if (!_internal._headersSent)
         sendHeaders();

      sendData(data);
   }

   /// Are headers already sent?
   @safe @nogc nothrow bool headersSent() { return _internal._headersSent; }

   struct KeyValue
	{
		@safe this (in string key, in string value) { this.key = key; this.value = value; }
		string key;
		string value;
	}

   package:

   @safe void sendData(const string data) { sendData(data.representation); }
   @safe void sendData(const void[] data)
   {
      _internal._dirty = true;

      if (_internal._sendBody || !_internal._headersSent)
      {
         if (_internal._keepAlive && _internal._headersSent) _internal._sendBuffer.append(format("%X\r\n%s\r\n", data.length, cast(const char[])data));
         else _internal._sendBuffer.append(cast(const char[])data);
      }
   }

   package struct OutputImpl
   {
      Cookie[string]  _cookies;
      KeyValue[]  	 _headers;
      bool            _keepAlive;
      string          _httpVersion;
      ushort          _status;
      bool			   _headersSent;
      Duration        _timeout;
      bool            _dirty;
      size_t          _requestId;
      DataBuffer!char _sendBuffer;
      string          _buffer;
      Socket          _channel;
      bool            _flushed;
      bool            _sendBody;

      void clear()
      {
         // HACK
         _timeout = 0.dur!"seconds";
         _httpVersion = HttpVersion.HTTP10;
         _dirty = false;
         _status = 200;
         _headersSent = false;
         _cookies = null;
         _headers = null;
         _keepAlive = false;
         _flushed = false;
         _sendBuffer.clear();
         _sendBody = true;
      }
   }

   package OutputImpl* _internal;
}

