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
import std.string : format, representation, indexOf, toLower, strip;
import std.range : empty;
import std.algorithm : map, canFind, splitter, startsWith;
import core.thread : Thread;
import std.datetime : SysTime, Clock, seconds, Duration;
import std.experimental.logger : log, warning;
import std.socket : Address, Socket, SocketShutdown, socket_t, SocketOptionLevel, SocketOption, Linger, AddressFamily;

import serverino.databuffer;
import serverino.common;

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
+    info("You asked for ", request.path, " with method ", request.method, " and params ", request.get.data);
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
      output ~= format("Worker ID:  %s\n", worker.to!string);
      output ~= format("Request ID: %s\n", id());
      output ~= format("Build ID:   %s\n", buildId);

      output ~= "\n";
      output ~= "Request:\n";
      output ~= format(" • Method: %s\n", method.to!string);
      output ~= format(" • Path: %s\n", path);

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

   /// The request ID. It is unique for each request.
   @safe @property public auto id() const
   {
      auto hash = simpleNotSecureCompileTimeHash(worker.to!string ~ "." ~ _internal._requestId.to!string)[0..8];
      return hash[0..4] ~ format("-%04d", _internal._requestId%10000);
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

   /// The path requested by user
   @safe @nogc @property nothrow public const(string) path() const { return _internal._path; }

   deprecated("Use `request.path` instead") alias uri = path;

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

   @safe nothrow static package string simpleNotSecureCompileTimeHash(string seed = "")
   {
      // Definetely not a secure hash function
      // Created just to give a unique ID to each build / request

      char[16] h = "SimpleNotSecure!";
      char[32] h2;

      auto  s = (seed ~ "_" ~  __TIMESTAMP__).representation;
      static immutable hex = "0123456789abcdef".representation;

      ulong sc = 104_059;

      foreach_reverse(idx, c; s)
      {
         sc += 1+(cast(ushort)c);
         sc *= 79_193;
         h[15-idx%16] ^= cast(char)(sc%256);
      }

      foreach(idx, c; h)
      {
         sc += 1+(cast(ushort)c);
         sc *= 96_911;
         h2[idx] = hex[(sc%256)/16];
         h2[$-idx-1]= hex[(sc%256)%16];
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
         import std.string : split, strip;
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
            parseArgsString(_rawQueryString, _get);

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
                  // Ok that's easy...
                  parseArgsString(_data, _post);
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

			                  if(nextLine < 0)
                             throw new Exception("Invalid boundaries delimitation.");

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
                           import std.datetime : ClockType;

                           string now = Clock.currTime!(ClockType.coarse).toUnixTime.to!string;
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
            parseArgsString!true(_header["cookie"], _cookie);

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


      string serialize()
      {
         DataBuffer!char buffer;
         buffer.append(_method ~ "\n");
         buffer.append(_path ~ "\n");
         buffer.append(_httpVersion ~ "\n");
         buffer.append(_host ~ "\n");
         buffer.append(_user ~ "\n");
         buffer.append(_password ~ "\n");
         buffer.append(_worker ~ "\n");

         buffer.append(_header.length.to!string ~ "\n");
         foreach(k,v; _header)
            buffer.append(k ~ "\n" ~ v ~ "\n");

         buffer.append(_cookie.length.to!string ~ "\n");
         foreach(k,v; _cookie)
            buffer.append(k ~ "\n" ~ v ~ "\n");

         buffer.append(_get.length.to!string ~ "\n");
         foreach(k,v; _get)
            buffer.append(k ~ "\n" ~ v ~ "\n");

         buffer.append(_post.length.to!string ~ "\n");
         foreach(k,v; _post)
            buffer.append(k ~ "\n" ~ v ~ "\n");

         return cast(string)buffer.array;
      }

      void deserialize(string s)
      {
         import std.conv: to;
         import std.string: split;

         auto lines = s.split("\n");

         _method = lines[0];
         _path = lines[1];
         _httpVersion = cast(HttpVersion)lines[2];
         _host = lines[3];
         _user = lines[4];
         _password = lines[5];
         _worker = lines[6];

         size_t index = 7;
         size_t headerLength = lines[index].to!size_t;
         index++;

         for(size_t i = 0; i < headerLength; i++)
         {
            _header[lines[index]] = lines[index + 1];
            index += 2;
         }

         size_t cookieLength = lines[index].to!size_t;
         index++;

         for(size_t i = 0; i < cookieLength; i++)
         {
            _cookie[lines[index]] = lines[index + 1];
            index += 2;
         }

         size_t getLength = lines[index].to!size_t;
         index++;

         for(size_t i = 0; i < getLength; i++)
         {
            _get[lines[index]] = lines[index + 1];
            index += 2;
         }

         size_t postLength = lines[index].to!size_t;
         index++;

         for(size_t i = 0; i < postLength; i++)
         {
            _post[lines[index]] = lines[index + 1];
            index += 2;
         }
      }

      pragma(inline, true)
      private void parseArgsString(bool isCookie = false)(in char[] s, ref string[string] output)
      {
         import std.uri : decodeComponent;
         import std.string : translate, split, strip;

         string key;
         size_t curIdx = 0;
         size_t lastIdx = 0;

         static if (isCookie) { bool isSeparator(in char c) { return c == ';' || c == ' '; } }
         else { bool isSeparator(in char c) { return c == '&'; } }

         searchKey:
            if (curIdx >= s.length)
            {
               if (curIdx != lastIdx) output[s[lastIdx..curIdx].decodeComponent] = "";
               return;
            }
            else if(isSeparator(s[curIdx]))
            {
               if (curIdx != lastIdx) output[s[lastIdx..curIdx].decodeComponent] = "";

               curIdx++;
               lastIdx = curIdx;
               goto searchKey;
            }
            else if (s[curIdx] == '=')
            {
               key = s[lastIdx..curIdx].decodeComponent;
               curIdx++;
               lastIdx = curIdx;
               goto searchValue;
            }
            else
            {
               curIdx++;
               goto searchKey;
            }

         searchValue:
            if (curIdx >= s.length)
            {
               if (curIdx != lastIdx) output[key] = translate(s[lastIdx..curIdx],['+':' ']).decodeComponent;
               else output[key] = "";
               return;
            }
            else if(isSeparator(s[curIdx]))
            {
               if (curIdx != lastIdx) output[key] = translate(s[lastIdx..curIdx],['+':' ']).decodeComponent;
               else output[key] = "";

               curIdx++;
               lastIdx = curIdx;
               goto searchKey;
            }
            else
            {
               curIdx++;
               goto searchValue;
            }
      }

      char[] _data;
      string[string]  _get;
      string[string]  _post;
      string[string]  _header;
      string[string]  _cookie;

      string _path;
      string _method;
      string _host;
      string _postDataContentType;
      string _worker;
      string _user;
      string _password;
      size_t _uploadId;
      size_t _requestId;

      string _rawQueryString;
      string _rawHeaders;
      string _rawRequestLine;

      string[]  _route;

      HttpVersion _httpVersion;

      FormData[string]   _form;
      ParsingStatus      _parsingStatus = ParsingStatus.OK;

      void clear()
      {
         clearFiles();

         _form    = null;
         _data    = null;
         _get     = null;
         _post    = null;
         _header  = null;
         _cookie  = null;
         _path    = string.init;

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

         _requestId = 0;
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
   + You can't set `content-length`, `date`, `status` or `transfer-encoding` headers. They are managed by serverino internally.
   + ---
   + // Set content-type to json, default is text/html
   + output.addHeader("content-type", "application/json");
   + output.addHeader("expire", 3.days);
   + ---
   +/
	@safe void addHeader(in string key, in string value)
   {
      string k = key.toLower;

      debug if (["content-length", "date", "status", "transfer-encoding"].canFind(k))
      {
         warning("You can't set `", key, "` header. It's managed by serverino internally.");
         if (k == "status") warning("Use `output.status = XXX` instead.");
         return;
      }

      _internal._dirty = true;
      _internal._headers ~= KeyValue(k, value);
   }

   /// Ditto
   @safe void addHeader(in string key, in Duration dur) {
      import std.datetime : ClockType;
      addHeader(key, Clock.currTime!(ClockType.coarse) + dur);
   }

   /// Ditto
   @safe void addHeader(in string key, in SysTime time) { addHeader(key, toHTTPDate(time)); }

   /** Serve a file from disk. If you want to delete the file after serving it, use `serveFile!(OnFileServed.deleteFile)`.
    * ---
    * // Serve a file from disk
    * output.serveFile("path/to/file.html");
    * ---
    */
   bool serveFile(OnFileServed action = OnFileServed.KeepFile)(const string path, bool guessMime = true)
   {
      _internal._dirty = true;

      import std.file : exists, getSize, isFile;
      import std.path : extension, baseName;
      import std.stdio : File;

      if (!exists(path) || !isFile(path))
      {
         warning("Trying to serve file `", baseName(path),"` (absolute path: `" ~ path ~ "`), but it doesn't exists on disk.");

         if (path.startsWith("/") && exists("." ~ path) && isFile("." ~ path))
            warning("Do you mean `." ~ path ~ "`, maybe?");

         return false;
      }

      if (!_internal._headers.canFind!(x=>x.key == "content-type"))
      {
         string header = "application/octet-stream";

         if (guessMime)
         {
            immutable mimes =
            [
               // Text/document formats
               ".html" : "text/html", ".htm" : "text/html", ".shtml" : "text/html", ".css" : "text/css", ".xml" : "text/xml",
               ".txt" : "text/plain", ".md" : "text/markdown", ".csv" : "text/csv", ".yaml" : "text/yaml", ".yml" : "text/yaml",
               ".jad" : "text/vnd.sun.j2me.app-descriptor", ".wml" : "text/vnd.wap.wml", ".htc" : "text/x-component",

               // Image formats
               ".gif" : "image/gif", ".jpeg" : "image/jpeg", ".jpg" : "image/jpeg", ".png" : "image/png",
               ".tif" : "image/tiff", ".tiff" : "image/tiff", ".wbmp" : "image/vnd.wap.wbmp",
               ".ico" : "image/x-icon", ".jng" : "image/x-jng", ".bmp" : "image/x-ms-bmp",
               ".svg" : "image/svg+xml", ".svgz" : "image/svg+xml", ".webp" : "image/webp",
               ".avif" : "image/avif", ".heic" : "image/heic", ".heif" : "image/heif", ".jxl" : "image/jxl",

               // Web fonts
               ".woff" : "application/font-woff", ".woff2": "font/woff2", ".ttf" : "font/ttf", ".otf" : "font/otf",
               ".eot" : "application/vnd.ms-fontobject",

               // Archives and applications
               ".jar" : "application/java-archive", ".war" : "application/java-archive", ".ear" : "application/java-archive",
               ".json" : "application/json", ".hqx" : "application/mac-binhex40", ".doc" : "application/msword",
               ".pdf" : "application/pdf", ".ps" : "application/postscript", ".eps" : "application/postscript",
               ".ai" : "application/postscript", ".rtf" : "application/rtf", ".m3u8" : "application/vnd.apple.mpegurl",
               ".xls" : "application/vnd.ms-excel", ".ppt" : "application/vnd.ms-powerpoint", ".wmlc" : "application/vnd.wap.wmlc",
               ".kml" : "application/vnd.google-earth.kml+xml", ".kmz" : "application/vnd.google-earth.kmz",
               ".7z" : "application/x-7z-compressed", ".cco" : "application/x-cocoa",
               ".jardiff" : "application/x-java-archive-diff", ".jnlp" : "application/x-java-jnlp-file",
               ".run" : "application/x-makeself", ".pl" : "application/x-perl", ".pm" : "application/x-perl",
               ".prc" : "application/x-pilot", ".pdb" : "application/x-pilot", ".rar" : "application/x-rar-compressed",
               ".rpm" : "application/x-redhat-package-manager", ".sea" : "application/x-sea",
               ".swf" : "application/x-shockwave-flash", ".sit" : "application/x-stuffit", ".tcl" : "application/x-tcl",
               ".tk" : "application/x-tcl", ".der" : "application/x-x509-ca-cert", ".pem" : "application/x-x509-ca-cert",
               ".crt" : "application/x-x509-ca-cert", ".xpi" : "application/x-xpinstall", ".xhtml" : "application/xhtml+xml",
               ".xspf" : "application/xspf+xml", ".zip" : "application/zip",
               ".br" : "application/x-brotli", ".gz" : "application/gzip",
               ".bz2" : "application/x-bzip2", ".xz" : "application/x-xz",

               // Generic binary files
               ".bin" : "application/octet-stream", ".exe" : "application/octet-stream", ".dll" : "application/octet-stream",
               ".deb" : "application/octet-stream", ".dmg" : "application/octet-stream", ".iso" : "application/octet-stream",
               ".img" : "application/octet-stream", ".msi" : "application/octet-stream", ".msp" : "application/octet-stream",
               ".msm" : "application/octet-stream",

               // Office documents
               ".docx" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
               ".xlsx" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
               ".pptx" : "application/vnd.openxmlformats-officedocument.presentationml.presentation",

               // Audio formats
               ".mid" : "audio/midi", ".midi" : "audio/midi", ".kar" : "audio/midi",
               ".mp3" : "audio/mpeg", ".ogg" : "audio/ogg", ".m4a" : "audio/x-m4a",
               ".ra" : "audio/x-realaudio", ".opus" : "audio/opus", ".aac" : "audio/aac",
               ".flac" : "audio/flac",

               // Video
               ".3gpp" : "video/3gpp", ".3gp" : "video/3gpp", ".ts" : "video/mp2t", ".mp4" : "video/mp4",
               ".mpeg" : "video/mpeg", ".mpg" : "video/mpeg", ".mov" : "video/quicktime",
               ".webm" : "video/webm", ".flv" : "video/x-flv", ".m4v" : "video/x-m4v",
               ".mng" : "video/x-mng", ".asx" : "video/x-ms-asf", ".asf" : "video/x-ms-asf",
               ".wmv" : "video/x-ms-wmv", ".avi" : "video/x-msvideo",
               ".mkv" : "video/x-matroska", ".ogv" : "video/ogg",

               // Web development
               ".js" : "application/javascript", ".wasm" : "application/wasm",
               ".ts" : "application/typescript",
               ".atom" : "application/atom+xml", ".rss" : "application/rss+xml",
               ".mml" : "text/mathml"
            ];

            if (path.extension in mimes)
               header = mimes[path.extension];
         }

         addHeader("content-type", header);
      }

      import std.path : absolutePath;

      _internal._deleteOnClose = action == OnFileServed.DeleteFile;
      _internal._sendFile = absolutePath(path);

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

      string data;
      data.reserve(32);

      // Get the time in GMT
      SysTime gmt = t.toUTC();

      // Lookup tables for days and months and time
      enum lookup_dd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
      enum lookup_mm = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      enum lookup_60 = ["00", "01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31", "32", "33", "34", "35", "36", "37", "38", "39", "40", "41", "42", "43", "44", "45", "46", "47", "48", "49", "50", "51", "52", "53", "54", "55", "56", "57", "58", "59"];

      // Format the time in GMT
      return lookup_dd[gmt.dayOfWeek] ~ ", " ~ lookup_60[gmt.day] ~ " " ~ lookup_mm[gmt.month-1] ~ " " ~ gmt.year.to!string ~ " "
         ~ lookup_60[gmt.hour] ~ ":"
         ~ lookup_60[gmt.minute] ~ ":"
         ~ lookup_60[gmt.second] ~ " GMT";
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
      DataBuffer!char _sendBuffer;
      DataBuffer!char _headersBuffer;
      string          _buffer;
      string          _sendFile;
      Socket          _channel;
      bool            _flushed;
      bool            _sendBody;
      bool            _websocket;
      bool            _deleteOnClose;


      private static immutable string[ushort] StatusCode;

      private shared static this() {

         StatusCode = [
            101: "Switching Protocols",

            200: "OK", 201 : "Created", 202 : "Accepted", 203 : "Non-Authoritative Information", 204 : "No Content", 205 : "Reset Content", 206 : "Partial Content",

            300 : "Multiple Choices", 301 : "Moved Permanently", 302 : "Found", 303 : "See Other", 304 : "Not Modified", 305 : "Use Proxy", 307 : "Temporary Redirect",

            400 : "Bad Request", 401 : "Unauthorized", 402 : "Payment Required", 403 : "Forbidden", 404 : "Not Found", 405 : "Method Not Allowed",
            406 : "Not Acceptable", 407 : "Proxy Authentication Required", 408 : "Request Timeout", 409 : "Conflict", 410 : "Gone",
            411 : "Lenght Required", 412 : "Precondition Failed", 413 : "Request Entity Too Large", 414 : "Request-URI Too Long", 415 : "Unsupported Media Type",
            416 : "Requested Range Not Satisfable", 417 : "Expectation Failed", 422 : "Unprocessable Content", 426 : "Upgrade Required",

            500 : "Internal Server Error", 501 : "Not Implemented", 502 : "Bad Gateway", 503 : "Service Unavailable", 504 : "Gateway Timeout", 505 : "HTTP Version Not Supported"
         ];

      }


      @safe void buildHeaders()
      {
         import std.uri : encodeComponent, encode;
         import std.array : appender;
         import std.datetime : ClockType;

         bool has_content_type = false;

         _headersBuffer.clear();

         if (_status == 200) _headersBuffer.append(_httpVersion ~ " 200 OK\r\n");
         else
         {
            string statusDescription;
            immutable item = _status in StatusCode;
            if (item != null) statusDescription = *item;
            else statusDescription = "Unknown";

            _headersBuffer.append(_httpVersion ~ " " ~ _status.to!string ~ " " ~ statusDescription ~ "\r\n");
         }

         version(SERVERINO_TESTS) { }
         else _headersBuffer.append("date: " ~ Output.toHTTPDate(Clock.currTime!(ClockType.coarse)) ~ "\r\n");

         // These headers are ignored if we are sending a websocket response
         if (!_websocket)
         {
            if (!_keepAlive) _headersBuffer.append("connection: close\r\n");
            else _headersBuffer.append("connection: keep-alive\r\n");

            if (_sendFile.length > 0)
            {
               import std.file : getSize;
               size_t fs = _sendFile.getSize().to!size_t;
               _headersBuffer.append("content-length: " ~ fs.to!string ~ "\r\n");
            }
            else if (!_sendBody) _headersBuffer.append("content-length: 0\r\n");
            else _headersBuffer.append("content-length: " ~ _sendBuffer.length.to!string ~ "\r\n");
         }

         // send user-defined headers
         foreach(const ref header;_headers)
         {
            if (!_sendBody && header.key == "content-length")
               continue;

            _headersBuffer.append(header.key ~ ": " ~ header.value ~ "\r\n");
            if (header.key == "content-type") has_content_type = true;
         }

         // Default content-type is text/html if not defined by user
         if (!has_content_type && _sendBody)
            _headersBuffer.append("content-type: text/html;charset=utf-8\r\n");

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

            if (!c._path.length == 0) _headersBuffer.append(format("; path=%s", c._path.encode));
            if (!c._domain.length == 0) _headersBuffer.append(format("; domain=%s", c._domain));

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
         _websocket = false;
         _sendFile = null;
         _deleteOnClose = false;
      }
   }

   OutputImpl* _internal;
}

/** A low-level representation of a WebSocket message. Probably you don't need to use this directly.
* ---
* auto msg = WebSocketMessage("Hello world");
* auto msg2 = WebSocketMessage(WebSocketMessage.OpCode.Text, "Hello world");
* auto msg3 = WebSocketMessage(WebSocketMessage.OpCode.Ping, "Ping me back!");
* auto msg4 = WebSocketMessage(WebSocketMessage.OpCode.Binary, [1, 2, 3, 4]);
* ---
**/
struct WebSocketMessage
{
   import std.traits : isSomeString, isBasicType, isArray;
   import std.range : ElementType;

   enum OpCode : ushort
   {
      Continue = 0x0 << 8,   /// If you send a message in parts, you must use this opcode for all parts except the first one.
      Text = 0x1 << 8,       /// Text message
      Binary = 0x2 << 8,     /// Binary message
      Close = 0x8 << 8,      /// Close connection
      Ping = 0x9 << 8,       /// Ping message
      Pong = 0xA << 8,       /// Pong (response to ping)
   }

   /// Build a WebSocket message.
   this(OpCode opcode, string payload)
   {
      this._opcode = opcode;
      this.payload = payload.representation.dup;
   }

   /// Ditto
   this(OpCode opcode, ubyte[] payload)
   {
      this._opcode = opcode;
      this.payload = payload.dup;
   }

   /// Ditto
   this(T)(OpCode opcode, T payload)
   if (isSomeString!T) { this(opcode, cast(string)payload); }

   this(T)(OpCode opcode, T payload)
   if (isBasicType!T) { this(opcode, (cast(ubyte*)(&payload))[0..T.sizeof]); }

   this(T)(OpCode opcode, T payload)
   if (isArray!T && isBasicType!(ElementType!T)) { this(opcode, cast(ubyte[])payload);}

   /// Ditto
   this(T)(T payload) { this(OpCode.Binary, payload); }

   /// Ditto
   this(string payload) { this(OpCode.Text, payload); }

   // Ditto
   this(ubyte[] payload) { this(OpCode.Binary, payload); }

   /// Return a string representation of the payload.
   string asString() const { return cast(string)cast(char[])payload; }

   /** Return the payload as a specific type.
   * ---
   * auto msg = WebSocketMessage("Hello world");
   * auto str = msg.as!string;
   * ---
   **/
   T as(T)() const
   if (!isArray!T)
   {
      static if (is(T == string)) return asString();
      else return *cast(T*)payload.ptr;
   }

   /// Ditto
   T as(T)() const
   if (isArray!T)
   {
      return cast(T)payload;
   }

   auto opcode() const { return this._opcode; }

   /// Is this message valid?
   bool     isValid = false;

   private:
   OpCode   _opcode;
   ubyte[]  payload;

   alias isValid this;
}

/** A WebSocket. You can use this to send and receive WebSocket messages.
* ---
* websocket.send("Hello world");      // Send a message to client
* auto msg = websocket.receiveMessage();  // Receive a message from client
* ---
**/
class WebSocket
{
   /// Create a WebSocket. If you are using this as client, you should pass WebSocket.Role.Client as second parameter.
   this(Socket socket, WebSocket.Role role = WebSocket.Role.Server) { _socket = socket; _role = role; }

   /// Return the underlying socket.
   Socket socket() { _isDirty = true; return this._socket; }

   /// Set a callback to be called when a message is received. Return true to propagate the message to the next callback.
   bool delegate(in WebSocketMessage msg) onMessage;

   /// Set a callback to be called when a close message is received. Return true to propagate the message to the next callback.
   bool delegate(in WebSocketMessage msg) onCloseMessage;

   /// Set a callback to be called when a text message is received. Return true to propagate the message to the next callback.
   bool delegate(in string msg) onTextMessage;

   /// Set a callback to be called when a binary message is received. Return true to propagate the message to the next callback.
   bool delegate(in ubyte[] msg) onBinaryMessage;

   /** Try to send buffered data, if any. Returns false if there is still data to send. (only for non-blocking sockets) */
   bool send() { trySend(); return _leftover.length == 0; }

   /** Send a message. You can send a string, a basic type or an array of a basic type.
   * ---
   * websocket.send(cast(int)123456);
   * websocket.send("Hello!");
   * ---
   **/
   auto send(T)(T data) {  return sendMessage(WebSocketMessage(data)); }

   /// Send a close message.
   auto sendClose() { return sendMessage(WebSocketMessage(WebSocketMessage.OpCode.Close)); }

   /// Send a ping message. The peer should reply with a pong.
   auto sendPing() {
      import std.uuid : randomUUID;
      return sendMessage(WebSocketMessage(WebSocketMessage.OpCode.Ping, randomUUID.data));
   }

   /** Send a custom message. flagFIN is true by default and should be true for most cases.
   *   You want to set it to false if you are sending a message in parts. The last part should have flagFIN set to true.
   *   The masked parameter is false by default and should be false for most cases. It is used if a message is sent from a client to a server.
   * Returns: false if the message is partially sent. The leftover data will be sent on the next sending cycle or using sendLeftover()
   * ---
   * auto msg = WebSocketMessage(WebSocketMessage.OpCode.Text, "Hello world");
   * ws.sendMessage(msg);
   * ---
   **/
   auto sendMessage(WebSocketMessage message, bool flagFIN = true)
   {
      bool masked = (_role == WebSocket.Role.Client);

      _isDirty = true;

      ubyte[] buffer;
      ubyte[4] mask = void;

      buffer.length = 2 + 8 + 4 + message.payload.length;

      ushort header = 0;

      if (flagFIN) header |= Flags.FIN;
      header |= message.opcode;

      import std.system : endian, Endian;
      import std.bitmanip : swapEndian;
      import std.random : uniform;

      static if (endian == Endian.littleEndian)
         header = swapEndian(header);

      buffer[0..2] = (cast(ubyte*)(&header))[0..2];

      size_t curIdx = 2;

      if (message.payload.length < 126) buffer[1] = cast(ubyte)message.payload.length & ~Flags.MASK;
      else if (message.payload.length < 65_536)
      {
         static if(endian == Endian.littleEndian) const ushort len = swapEndian(cast(ushort) message.payload.length);
         else const ushort len = cast(ushort) message.payload.length;

         buffer[1] = 126 & ~Flags.MASK;
         buffer[2..4] = (cast(ubyte*)(&len))[0..2];

         curIdx = 4;
      }
      else
      {
         static if(endian == Endian.littleEndian) const size_t len = swapEndian(cast(size_t) message.payload.length);
         else const size_t len = cast(ushort) message.payload.length;

         buffer[1] = 127 & ~Flags.MASK;
         buffer[2..10] = (cast(ubyte*)(&len))[0..8];

         curIdx = 10;
      }

      if (masked)
      {
         uint rnd = uniform(0, uint.max);
         buffer[1] |= Flags.MASK;
         mask[0..4] = (cast(ubyte*)(&rnd))[0..4];
         buffer[curIdx..curIdx+4] = mask[0..4];
         curIdx += 4;
      }

      buffer[curIdx..curIdx+message.payload.length] = message.payload;

      if (masked)
         foreach(i, ref b; buffer[curIdx..$])
            b ^= mask[i % 4];

      curIdx += message.payload.length;

      return trySend(buffer[0..curIdx]);
   }

   /** If there is any data to send, it will be sent on next send() call **/
   bool isSendBufferEmpty() const { return _leftover.length == 0; }

   /** Receive a message from the WebSocket. There could be more than one message in the buffer
   *   so you should call this function in a loop until it returns an invalid message.
   * ---
   * auto msg = ws.receiveMessage();
   * if (msg.isValid) writeln("Received: ", msg.as!string);
   * ---
   **/
   WebSocketMessage receiveMessage()
   {
      import std.socket : wouldHaveBlocked;
      WebSocketMessage msg = tryParse();

      if (msg.isValid)
         return msg;

      ubyte[4096] buffer = void;
      again: auto received = _socket.receive(buffer);

      if (received == 0)
      {
         kill("connection closed");
         return WebSocketMessage.init;
      }

      if (received < 0)
      {
         version(Posix)
         {
            import core.stdc.errno : errno, EINTR;
            if (errno == EINTR) goto again;
         }

         if (!_socket.isAlive || !wouldHaveBlocked) kill("error receiving data");
         return WebSocketMessage.init;
      }

      _toParse ~= buffer[0..received];
      return tryParse();
   }

   /// Close the WebSocket connection.
   static void kill(string reason) { _killReason = reason; _kill = true; }

   /// Is the WebSocket connection closed?
   static bool killRequested() { return _kill; }

   /// Why the WebSocket connection was closed?
   static string killReason() { return _killReason; }

   /// Returns true if the WebSocket is dirty.
   bool isDirty() { return _isDirty; }

   enum Role
   {
      Server,
      Client
   }

   private:

   bool trySend(ubyte[] data = [])
   {
      import std.socket : wouldHaveBlocked;

      if (_leftover.length > 0)
      {
         leftover_again: auto ret = _socket.send(_leftover);

         // Not sent
         if (ret < 0)
         {
            version(Posix)
            {
               import core.stdc.errno : errno, EINTR;
               if (errno == EINTR) goto leftover_again;
            }

            if (wouldHaveBlocked())
            {
               _leftover ~= data;
               return true; // Partial
            }

            WebSocket.kill("error sending data");
            return false;
         }

         // Data sent
         else
         {
            _leftover = _leftover[ret..$];

            // Partial sent
            if (_leftover.length > 0)
            {
               _leftover ~= data;
               return true; // partial
            }
         }
      }

      if (data.length > 0)
      {
         again: auto ret = _socket.send(data);

         // Not sent
         if (ret < 0)
         {
            version(Posix)
            {
               import core.stdc.errno : errno, EINTR;
               if (errno == EINTR) goto again;
            }

            if (wouldHaveBlocked())
            {
               _leftover ~= data;
               return true; // Partial
            }

            WebSocket.kill("error sending data");
            return false;
         }

         // Data sent
         else
         {
            // Partial sent
            if (ret < data.length)
            {
               _leftover ~= data[ret..$];
               return true; // partial
            }
         }
      }

      _leftover.length = 0;
      return true; // All sent
   }

   WebSocketMessage tryParse()
   {
      _isDirty = true;

      while(true)
      {
         if (_toParse.length == 0) return WebSocketMessage.init;


         ubyte[] cursor = _toParse;

         if (cursor.length < 2)
         {
            return WebSocketMessage.init;
         }

         import std.system : endian, Endian;
         import std.bitmanip : swapEndian;

         static if(endian == Endian.littleEndian)
            const ushort header = swapEndian((cast(ushort[])(cursor[0..2]))[0]);
         else
            const ushort header = (cast(ushort[])(cursor[0..2]))[0];

         cursor = cursor[2..$];

         bool flagFIN   = (header & Flags.FIN) == Flags.FIN;
         bool flagMASK  = (header & Flags.MASK) == Flags.MASK;

         auto opcode = cast(ushort)(header & (0xF << 8)); // MASK = 0xF<<8

         auto payloadLength = cast(size_t)cast(byte)(header & Flags.PAYLOAD_MASK);
         ubyte[] payload;
         ubyte[] mask = [0, 0, 0, 0];

         if (payloadLength == 126)
         {
            if (cursor.length < ushort.sizeof)
               return WebSocketMessage.init;

            static if (endian == Endian.littleEndian)
               payloadLength = swapEndian((cast(ushort[])(cursor[0..ushort.sizeof]))[0]);
            else
               payloadLength = (cast(ushort[])(cursor[0..ushort.sizeof]))[0];

            cursor = cursor[ushort.sizeof..$];
         }
         else if (payloadLength == 127)
         {
            if (cursor.length < size_t.sizeof)
               return WebSocketMessage.init;

            payloadLength = (cast(size_t[])(cursor[0..size_t.sizeof]))[0];

            static if (endian == Endian.littleEndian)
               payloadLength = swapEndian((cast(size_t[])(cursor[0..size_t.sizeof]))[0]);
            else
               payloadLength = (cast(size_t[])(cursor[0..size_t.sizeof]))[0];

            cursor = cursor[size_t.sizeof..$];
         }

         if (flagMASK)
         {
            if (cursor.length < 4)
               return WebSocketMessage.init;

            mask = cursor[0..4];
            cursor = cursor[4..$];
         }


         if (cursor.length < payloadLength)
            return WebSocketMessage.init;

         payload = cursor[0..payloadLength];

         if (flagMASK)
            foreach(i, ref ubyte b; payload)
               b ^= mask[i % 4];

         _parsedData ~= payload;
         _toParse = cursor[payloadLength..$];

         if (flagFIN)
         {
            scope(exit) _parsedData = null;

            if (opcode == WebSocketMessage.OpCode.Ping)
            {
               debug log("PING received, sending PONG");
               sendMessage(WebSocketMessage(WebSocketMessage.OpCode.Pong, _parsedData));
               return WebSocketMessage.init;
            }

            auto msg = WebSocketMessage
            (
               cast(WebSocketMessage.OpCode)opcode,
               _parsedData
            );

            msg.isValid = true;

            bool propagate = true;

            switch(cast(WebSocketMessage.OpCode)opcode)
            {
               case WebSocketMessage.OpCode.Binary:
                  if (propagate && onBinaryMessage !is null) propagate = onBinaryMessage(msg.as!(ubyte[]));
                  break;

               case WebSocketMessage.OpCode.Text:
                  if (propagate && onTextMessage !is null) propagate = onTextMessage(msg.as!string);
                  break;

               case WebSocketMessage.OpCode.Close:
                  if (propagate && onCloseMessage !is null) propagate = onCloseMessage(msg);
                  break;
               default: break;
            }

            if (propagate && onMessage !is null) propagate = onMessage(msg);

            return msg;
         }
      }

      assert(false);
   }

   enum Flags : ushort
   {
      FIN = 0x1 << 15,
      MASK = 0x1 << 7,
      PAYLOAD_MASK = 0x7F
   }

   ubyte[]   _toParse;
   ubyte[]   _parsedData;
   ubyte[]   _leftover;
   Socket    _socket;

   bool      _isDirty = false;
   Role      _role = Role.Server;

   __gshared  string _killReason = string.init;
   __gshared  bool   _kill = false;
}

/// Used by Output.serveFile
enum OnFileServed
{
   KeepFile,   /// Keep the file on disk
   DeleteFile  /// Delete the file after sending it
}


/// Some useful functions to get information about the current serverino process
static struct ServerinoProcess
{
   import std.process : environment, thisProcessID;

   public static:

      /// Returns the PID of the serverino daemon
      int daemonPID() {
         import std.conv : to;
         if (ServerinoProcess.isDaemon) return thisProcessID();
         else return environment.get("SERVERINO_DAEMON_PID").to!int;
      }

      /// Returns true if the current process is the serverino daemon
      bool isDaemon() { return environment.get("SERVERINO_COMPONENT") == "D"; }

      /// Returns true if the current process is a serverino websocket
      bool isWebSocket() { return environment.get("SERVERINO_COMPONENT") == "WS"; }

      /// Returns true if the current process is a serverino worker
      bool isWorker() { return environment.get("SERVERINO_COMPONENT") == "WK"; }

      /// Returns true if the current process is a serverino dynamic component (websocket or worker)
      bool isDynamicComponent() { return isWorker() || isWebSocket(); }
}