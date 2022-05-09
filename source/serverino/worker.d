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

/// All about worker
module serverino.worker;

import std.conv : to;
import std.string : format, representation, indexOf, lastIndexOf, toLower, toStringz, strip;
import std.range : empty, assumeSorted;
import std.algorithm : map, canFind, splitter, startsWith;
import core.thread : Thread;
import std.datetime : SysTime, Clock, dur, Duration, DateTime;
import std.experimental.logger : log, warning, fatal, critical;
import std.socket : Address, Socket, SocketShutdown, socket_t, SocketOptionLevel, SocketOption, Linger, AddressFamily;

import serverino.common;
import serverino.sockettransfer;
import serverino.c.libtls;  // Source: https://git.causal.agency/libretls/about/

private struct HttpStream
{
   Socket         socket;

   private tls*   gCtx;
   private tls*   ctx = null;
   private bool   withTls = false;
   private bool   hasWritten = false;

   void setSocket(Socket s, TLS *t = null)
   {
      this.socket = s;

      if (t !is null)
      {
         withTls = true;
         this.gCtx = t.ctx;
         tls_accept_socket(gCtx, &ctx, socket.handle);
         tls_handshake(ctx);
      }
   }

   ~this() { uninit(); }


   void uninit()
   {
      if (ctx != null)
      {
         tls_close(ctx);
         tls_free(ctx);
         ctx = null;
      }


      if (socket !is null)
      {
         socket.shutdown(SocketShutdown.BOTH);
         socket.close();
         socket = null;
      }

   }

   @safe void sendError(string s)
   {
      if (hasWritten) return;
      send(format("HTTP/1.1 %s\r\nConnection: close\r\n\r\n%s\n", s, s).representation);
   }

   @trusted void send(const void[] data)
   {
      hasWritten = true;

      if (withTls) tls_write(ctx, &data[0], data.length);
      else socket.send(data);
   }

   @safe void clear() { hasWritten = false; }

   auto receive(void[] buf)
   {
      if (withTls) return tls_read(ctx, buf.ptr, buf.length);
      else return socket.receive(buf);
   }

}


private struct TLS
{

   tls*        ctx;
   tls_config* cert;
}

package class Worker
{

   private:

   WorkerInfo        workerInfo;
   WorkerConfigPtr   config;

   HttpStream        http;
   Request           request;
   Output            output;

   bool       exitRequested = false;
   bool       persistent = false;
   SysTime    lastUpdate;
   SysTime    timeout;
   Duration   maxWorkerLifetime;
   Duration   maxRequestTime;
   Duration   maxWorkerIdling;
   State      status;
   Thread     killer;

   TLS[size_t] tls;

   enum State
   {
      PROCESSING = 0,
      KILLING,
      IDLING
   }

   static void killerThread()
   {
      import std.datetime : SysTime, Clock, dur, Duration, DateTime;
      import std.process : thisProcessID;
      import core.sys.posix.signal : kill, SIGTERM, SIGINT, sigset;
      import core.atomic : cas;
      import std.stdio : stderr;


      SysTime started = Clock.currTime();
      Worker worker = Worker.instance;

      while(!worker.exitRequested)
      {
         Thread.sleep(250.dur!"msecs");

         Duration maxT = worker.maxRequestTime;
         if (worker.output._internal._timeout > 0.dur!"seconds")
            maxT = worker.output._internal._timeout;

         if (Clock.currTime - worker.lastUpdate > maxT && cas(&worker.status, State.PROCESSING, State.KILLING))
         {
            log("Worker killed. Reason: MAX_REQUEST_TIME"); stderr.flush();
            Thread.sleep(1.dur!"msecs");
            kill(thisProcessID, SIGTERM);
            break;
         }

         if (Clock.currTime - started > worker.maxWorkerLifetime && cas(&worker.status, State.IDLING, State.KILLING))
         {
            log("Worker stopped. Reason: MAX_WORKER_LIFETIME"); stderr.flush();
            Thread.sleep(1.dur!"msecs");
            kill(thisProcessID, SIGTERM);
            break;
         }

         if (!worker.persistent && Clock.currTime - worker.lastUpdate > worker.maxWorkerIdling && cas(&worker.status, State.IDLING, State.KILLING))
         {
            log("Worker stopped. Reason: MAX_WORKER_IDLING"); stderr.flush();
            Thread.sleep(1.dur!"msecs");
            kill(thisProcessID, SIGTERM);
            break;
         }

         if (worker.timeout != SysTime.init && Clock.currTime > worker.timeout)
         {
            worker.http.socket.shutdown(SocketShutdown.BOTH);
            worker.http.socket.close();
         }

         Thread.yield();
      }
   }


   package:

   static auto instance()
   {
      __gshared Worker i = null;

      if (i is null)
         i = new Worker();

      return i;
   }

   void wake(Modules...)(WorkerConfigPtr cfg, WorkerInfo wi)
   {
      config = cfg;
      workerInfo = wi;

      import core.sys.posix.pwd;
      import core.sys.posix.grp;
      import core.sys.posix.unistd;
      import core.stdc.string : strlen;
      import core.atomic : cas;
      import std.random : uniform;

      maxWorkerLifetime = dur!"seconds"(config.maxWorkerLifetime.total!"seconds" * uniform(100,115) / 100);
      maxRequestTime = config.maxRequestTime;
      maxWorkerIdling = config.maxWorkerIdling;

      lastUpdate = Clock.currTime();
      persistent = wi.persistent;
      status = State.IDLING;

      killer = new Thread(&killerThread).start();

      request._internal = new Request.RequestImpl();
      output._internal = new Output.OutputImpl(&http);

      if (config.group.length > 0)
      {
         auto gi = getgrnam(config.group.toStringz);
         if (gi !is null) setgid(gi.gr_gid);
         else fatal("Can't find group ", config.group);
      }

      if (config.user.length > 0)
      {
         auto ui = getpwnam(config.user.toStringz);
         if (ui !is null) setuid(ui.pw_uid);
         else fatal("Can't find user ", config.user);
      }

      auto ui = getpwuid(getuid());
      auto gr = getgrgid(getgid());

      if (ui.pw_uid == 0) critical("Worker running as root. Is this intended? Set user/group from config to run worker as unprivileged user.");
      else log("Worker started. (user=", ui.pw_name[0..ui.pw_name.strlen], " group=", gr.gr_name[0..gr.gr_name.strlen], ")");

      tryInit!Modules();

      scope(exit) onExit!Modules(0);

      // TLS support
      foreach(k, c; *config.certsData)
      {
         TLS t;
         t.ctx = tls_server();
         t.cert = tls_config_new();
         tls_config_set_cert_mem(t.cert, c.certData.ptr, c.certData.length);
         tls_config_set_key_mem(t.cert, c.privkeyData.ptr, c.privkeyData.length);
         tls_configure(t.ctx, t.cert);
         tls[k] = t;
      }

      workerInfo = wi;

      import core.sys.posix.signal : sigset, SIGTERM, SIGINT;
      sigset(SIGINT, &onExit!Modules);
      sigset(SIGTERM, &onExit!Modules);

      Socket socket;

      while(true)
      {
         IPCMessage msg;
         {
            auto received = wi.ipcSocket.receive(msg.raw);
            assert(received == msg.sizeof, "WRONG HEADER");
            msg.validate();
         }

         if (msg.data.command == "SWCH")
            continue;

         IPCRequestMessage req;
         {
            auto received = wi.ipcSocket.receive(req.raw);
            assert(received == req.sizeof, "WRONG REQUEST");
         }

         AddressFamily af = AddressFamily.INET;

         if(!req.data.isIPV4)
            af = AddressFamily.INET6;

         import core.sys.posix.sys.socket : linger;
         socket_t socket_handler = cast(socket_t)SocketTransfer.receive(wi.ipcSocket);
         socket = new Socket(socket_handler, af);

         if (msg.data.command == "RQST")
         {
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, Linger(linger(1,0)));
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
         }

         if (req.data.isHttps) http.setSocket(socket, &tls[req.data.certIdx]);
         else http.setSocket(socket);

         lastUpdate = Clock.currTime();
         if (!cas(&status, State.IDLING, State.PROCESSING))
            break;

         bool keepAlive = true;
         size_t maxRequest = 0;

         import core.time;

         wi.ipcSocket.blocking = false;

         while(keepAlive)
         {
            auto received = wi.ipcSocket.receive(msg.raw);
            if (received > 0)
            {
               assert(received == msg.sizeof, "WRONG HEADER");
               assert(msg.data.command == "SWCH", "Wrong command");
               break;
            }

            output._internal.clear();
            request._internal.clear();
            http.clear();

            if (config.bufferSize != output._internal._bufferSize)
               output.setBufferSize(config.bufferSize);

            keepAlive = parseHttpRequest!Modules(config, req.data.isHttps);
            lastUpdate = Clock.currTime;
            maxRequest++;
         }

         wi.ipcSocket.blocking = true;

         status = State.IDLING;

         // DO NOT CLOSE `Socket socket` HERE.

         if (keepAlive) wi.ipcSocket.send("A"); // KEEP *A*LIVE
         else wi.ipcSocket.send("D"); // *D*ONE
      }
   }


   private:

   this() { }

   bool parseHttpRequest(Modules...)(WorkerConfigPtr config, bool isHttps)
   {

      scope(failure)
      {
         warning("Exception during http request parsing");
         http.sendError("500 Internal Server Error");
      }

      ubyte[16*1024] 	buffer;
      ubyte[]			   data;
      size_t			   contentLength = 0;

      char[]			method;
      char[]			path;
      char[]			httpVersion;

      char[]			requestLine;
      char[]			headers;

      bool			headersParsed = false;
      bool 			hasContentLength = false;

      timeout = (Clock.currTime + config.maxHttpWaiting);
      // FIXME: Support pipelining
      // Read data

      data.reserve = buffer.length*10;

      while(http.socket.isAlive)
      {

         auto received = http.receive(buffer);
         if (received <= 0) return false;

         data ~= buffer[0..received];

         // Too much data read
         if (data.length > config.maxRequestSize)
         {
            http.sendError("413 Request Entity Too Large");
            return false;
         }

         // If we have content length, we read just what declared.
         if (hasContentLength && data.length >= contentLength)
         {
            data.length = contentLength;
            break;
         }

         // Have we finished with headers?
         if (!headersParsed)
         {
            headers = cast(char[]) data;
            auto headersEnd = headers.indexOf("\r\n\r\n");

            // Headers completed?
            if (headersEnd > 0)
            {
               headers.length = headersEnd;
               data = data[headersEnd+4..$];
               headersParsed = true;

               auto headersLines = headers.splitter("\r\n");

               if (headersLines.empty)
               {
                  warning("HTTP Request: empty request");
                  http.sendError("400 Bad Request");
                  return false;
               }

               requestLine = headersLines.front;

               if (requestLine.length < 14)
               {
                  warning("HTTP request line too short: ", requestLine);
                  http.sendError("400 Bad Request");
                  return false;
               }

               auto fields = requestLine.splitter(" ");
               size_t popped = 0;

               if (!fields.empty)
               {
                  method = fields.front;
                  fields.popFront;
                  popped++;
               }

               if (!fields.empty)
               {
                  path = fields.front;
                  fields.popFront;
                  popped++;
               }

               if (!fields.empty)
               {
                  httpVersion = fields.front;
                  fields.popFront;
                  popped++;
               }

               if (popped != 3 || !fields.empty)
               {
                  warning("HTTP request invalid: ", requestLine);
                  http.sendError("400 Bad Request");
                  return false;
               }

               if (path.startsWith("http://") || path.startsWith("https://"))
               {
                  warning("Can't use absolute uri");
                  http.sendError("400 Bad Request");
                  return false;
               }

               if (httpVersion != "HTTP/1.1" && httpVersion != "HTTP/1.0")
               {
                  warning("HTTP request bad http version: ", httpVersion);
                  http.sendError("400 Bad Request");
                  return false;
               }

               if (["CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"].assumeSorted.contains(method) == false)
               {
                  warning("HTTP method unknown: ", method);
                  http.sendError("400 Bad Request");
                  return false;
               }

               headersLines.popFront;
               foreach(const ref l; headersLines)
               {
                  auto firstColon = l.indexOf(':');
                  if (firstColon > 0 && l[0..firstColon].toLower == "content-length")
                  {
                     contentLength = l[firstColon+1..$].strip.to!size_t;
                     hasContentLength = true;
                     break;
                  }
               }

               // If no content-length, we don't read body.
               if (contentLength == 0)
               {
                  data.length = 0;
                  break;
               }
               else if (data.length >= contentLength)
               {
                  data.length = contentLength;
                  break;
               }

            }
         }
      }

      if (!http.socket.isAlive)
         return false;

      timeout = SysTime.init;

      if (headersParsed)
      {
         import std.regex : ctRegex, matchFirst;
         import std.algorithm : max;
         import std.uni : sicmp;

         request._internal._httpVersion    = (httpVersion == "HTTP/1.1")?(HttpVersion.HTTP11):(HttpVersion.HTTP10);
         request._internal._remoteAddress  = http.socket.remoteAddress;
         request._internal._localAddress   = http.socket.localAddress;
         request._internal._data           = cast(char[])data;
         request._internal._rawHeaders     = headers.to!string;
         request._internal._rawRequestLine = requestLine.to!string;
         request._internal._isHttps        = isHttps;

         auto uriRegex = ctRegex!(`^(([^:/?#]+):)?(//([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?`, "g");
         auto matches = path.to!string.matchFirst(uriRegex);

         if (!matches[2].empty || !matches[4].empty)
         {
            warning("HTTP Request with absolute uri");
            http.sendError("400 Bad Request");
            return false;
         }

         request._internal._uri            = matches[5];
         request._internal._rawQueryString = matches[7];
         request._internal._method         = method.to!string;
         request._internal.process();

         output._internal._httpVersion = request._internal._httpVersion;

         output._internal._keepAlive =
            config.keepAlive &&
            output._internal._httpVersion == HttpVersion.HTTP11 &&
            sicmp(request.header.read("connection", "keep-alive").strip, "keep-alive") == 0;

         if (output._internal._keepAlive)
            output._internal._headers ~= Output.KeyValue("transfer-encoding", "chunked");

         if (request._internal._parsingStatus == Request.ParsingStatus.OK)
         {
            scope(exit) { output.flush(true); }

            try
            {
               callHandlers!Modules(request, output);

               if (!output._internal._dirty && !output.headersSent)
               {
                  http.sendError("404 Not Found");
                  return false;
               }
               else
               {
                  if (!output._internal._headersSent)
                     output.sendHeaders();

                  if (output._internal._keepAlive)
                  {
                     output.sendData([]);
                     return true;
                  }

                  return false;
               }
            }

            // Unhandled Exception escaped from user code
            catch (Exception e)
            {
               if (!output.headersSent)
                  http.sendError("500 Internal Server Error");

               critical(format("%s:%s Uncatched exception: %s", e.file, e.line, e.msg));
               critical(e.info);
            }

            // Even worse.
            catch (Throwable t)
            {
               if (!output.headersSent)
                  http.sendError("500 Internal Server Error");

               critical(format("%s:%s Throwable: %s", t.file, t.line, t.msg));
               critical(t.info);

               // Rethrow
               throw t;
            }
         }
         else
         {
            if (!output.headersSent)
                  http.sendError("400 Bad Request");

            critical("Parsing error:", request._internal._parsingStatus);
         }

      }
      else if (data.length > 0)
      {
         http.sendError("400 Bad Request");
         critical("Can't parse http headers");
      }

      return false;
   }

   void callHandlers(modules...)(Request request, Output output)
   {
      import std.algorithm : sort;
      import std.array : array;
      import std.traits : getUDAs, ParameterStorageClass, ParameterStorageClassTuple, fullyQualifiedName, getSymbolsByUDA;

      struct FunctionPriority
      {
         string   name;
         long     priority;
         string   mod;
      }

      auto getUntaggedHandlers()
      {
         FunctionPriority[] fps;
         static foreach(m; modules)
         {{
            alias globalNs = m;

            foreach(sy; __traits(allMembers, globalNs))
            {
               alias s = __traits(getMember, globalNs, sy);
               static if
               (
                  (
                     __traits(compiles, s(request, output)) ||
                     __traits(compiles, s(request)) ||
                     __traits(compiles, s(output))
                  )
               )
               {


                  static foreach(p; ParameterStorageClassTuple!s)
                  {
                     static if (p == ParameterStorageClass.ref_)
                     {
                        static if(!is(typeof(ValidSTC)))
                           enum ValidSTC = false;
                     }
                  }

                  static if(!is(typeof(ValidSTC)))
                     enum ValidSTC = true;


                  static if (ValidSTC)
                  {
                     FunctionPriority fp;
                     fp.name = __traits(identifier,s);
                     fp.priority = 0;
                     fp.mod = fullyQualifiedName!m;

                     fps ~= fp;
                  }
               }
            }
         }}

         return fps.sort!((a,b) => a.priority > b.priority).array;
      }

      auto getTaggedHandlers()
      {
         FunctionPriority[] fps;

         static foreach(m; modules)
         {{
            alias globalNs = m;

            foreach(s; getSymbolsByUDA!(globalNs, endpoint))
            {
               static if
               (
                  !__traits(compiles, s(request, output)) &&
                  !__traits(compiles, s(request)) &&
                  !__traits(compiles, s(output))
               )
               {
                  static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, Output output)`.");
               }

               static foreach(p; ParameterStorageClassTuple!s)
               {
                  static if (p == ParameterStorageClass.ref_)
                  {
                     static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong storage class for params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, Output output)`.");
                  }
               }

               FunctionPriority fp;

               fp.name = __traits(identifier,s);
               fp.mod = fullyQualifiedName!m;

               static if (getUDAs!(s, priority).length > 0 && !is(getUDAs!(s, priority)[0]))
                  fp.priority = getUDAs!(s, priority)[0].priority;


               fps ~= fp;
            }
         }}

         return fps.sort!((a,b) => a.priority > b.priority).array;

      }

      enum taggedHandlers = getTaggedHandlers();
      enum untaggedHandlers = getUntaggedHandlers();


      static if (taggedHandlers !is null && taggedHandlers.length>0)
      {
         bool callUntilIsDirty(FunctionPriority[] taggedHandlers)()
         {
            static foreach(ff; taggedHandlers)
            {
               {
                  mixin(`import ` ~ ff.mod ~ ";");
                  alias currentMod = mixin(ff.mod);
                  alias f = __traits(getMember,currentMod, ff.name);

                  static if (__traits(compiles, f(request, output))) f(request, output);
                  else static if (__traits(compiles, f(request))) f(request);
                  else f(output);
               }

               if (output._internal._dirty) return true;
            }

            return false;
         }

        callUntilIsDirty!taggedHandlers;
      }
      else static if (untaggedHandlers !is null)
      {

         static if (untaggedHandlers.length != 1)
         {
            static assert(0, "Please tag each valid endpoint with @endpoint UDA.");
         }
         else
         {
            {
               mixin(`import ` ~ untaggedHandlers[0].mod ~ ";");
               alias currentMod = mixin(untaggedHandlers[0].mod);
               alias f = __traits(getMember,currentMod, untaggedHandlers[0].name);

               if (!output._internal._dirty)
               {
                  static if (__traits(compiles, f(request, output))) f(request, output);
                  else static if (__traits(compiles, f(request))) f(request);
                  else f(output);
               }
            }
         }
      }
      else static assert(0, "Please add at least one endpoint. Try this: `void hello(Request req, Output output) { output ~= req.dump(); }`");
   }


}


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
   @safe string dump(bool html = true) const
   {
      import std.string : replace;
      string d = toString();

      if (html) d = `<pre style="padding:10px;background:#DDD">` ~ d.replace("<", "&lt").replace(">", "&gt").replace(";", "&amp;") ~ "</pre>";

      return d;
   }

   /// ditto
   @safe string toString() const
   {

      string output;
      output ~= format("Worker: #%s\n", worker.to!string);
      output ~= format("Build Version: %s\n", buildVersion);
      output ~= "\n";
      output ~= "Request:\n";
      output ~= format("- Protocol: %s\n",_internal._isHttps?"https":"http");
      output ~= format("- Method: %s\n", method.to!string);
      output ~= format("- Host: %s (%s)\n", host, localAddress.toPortString);
      output ~= format("- Uri: %s\n", uri);
      output ~= format("- Remote Address: %s\n", remoteAddress.toAddrString);

      if (!_internal._user.empty)
         output ~= format("- Authorization: user => `%s` password => `%s`\n",_internal._user,_internal._password.map!(x=>'*'));

      if (!get.data.empty)
      {
         output ~= "\nQuery Params:\n";
         foreach(k,v; get.data)
         {
            output ~= format(" - %s => %s\n", k, v);
         }
      }

      if (!body.data.empty)
         output ~= "\nContent-type: " ~ body.contentType ~ " (size: %s bytes)\n".format(body.data.length);

      if (!post.data.empty)
      {
         output ~= "\nPost Params:\n";
         foreach(k,v; post.data)
         {
            output ~= format(" - %s => %s\n", k, v);
         }
      }

      if (!form.data.empty)
      {
         output ~= "\nForm Data:\n";
         foreach(k,v; form.data)
         {
            import std.file : getSize;

            if (v.isFile) output ~= format(" - `%s` (content-type: %s, size: %s bytes, path: %s)\n", k, v.contentType, getSize(v.path), v.path);
            else output ~= format(" - `%s` (content-type: %s, size: %s bytes)\n", k, v.contentType, v.data.length);
         }
      }

      if (!cookie.data.empty)
      {
         output ~= "\nCookies:\n";
         foreach(k,v; cookie.data)
         {
            output ~= format(" - %s => %s\n", k, v);
         }
      }

      output ~= "\nHeaders:\n";
      foreach(k,v; header.data)
      {
         output ~= format(" - %s => %s\n", k, v);
      }

      return output;
   }

   /// HTTP methods
   public enum Method
	{
		Get, ///
      Post, ///
      Head, ///
      Delete, ///
      Put, ///
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

   ///
   @safe @nogc @property nothrow public auto remoteAddress() const { return _internal._remoteAddress; }

   ///
   @safe @nogc @property nothrow public auto localAddress() const { return _internal._localAddress; }

   /// Http or Https
   @safe @nogc @property nothrow public auto protocol() const { return _internal._isHttps?"https":"http"; }

   /// Basic http authentication user. Safe only if sent thru https!
   @safe @nogc @property nothrow public auto user() const { return _internal._user; }

   /// Basic http authentication password. Safe only if sent thru https!
   @safe @nogc @property nothrow public auto password() const { return _internal._password; }

   /// Current sessionId, if set and valid.
   @safe @nogc @property nothrow public auto sessionId() const { return _internal._sessionId; }

   static private string simpleNotSecureCompileTimeHash()
   {
      // A stupid and simple hash function I create.
      // CTFE likes it.
      // It's more or less another way to represent a timestamp :)

      string h,h2;

      auto s = __TIMESTAMP__.representation;
      auto hex = "0123456789abcdef".representation;

      ulong sc = 104_059;

      foreach_reverse(c; s)
      {
         sc += 1+(cast(ushort)c);
         sc *= 79_193;
         h ~= cast(char)(sc%255);
      }

      foreach(c; h)
      {
         sc += 1+(cast(ushort)c);
         sc *= 96_911;
         h2 ~= hex[(sc%256)/16];
         h2 ~= hex[(sc%256)%16];
      }

      return h2;
   }

   /// Every time you compile the app this value will change
   enum buildVersion = simpleNotSecureCompileTimeHash();

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
         default: return Method.Unknown;
		}
	}


   private enum ParsingStatus
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

   private struct RequestImpl
   {
      private void process()
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

            _header[h[0..first].toLower] = h[first+1..$];
         }

         _worker = myPID;

         {
            import std.array : array, join;
            if ("host" in _header) _host = _header["host"];

            auto colon = _host.lastIndexOf(':') >= 0;

            if (colon >= 0)
               _host.length = colon;
         }

         // Read get params
         if (!_rawQueryString.empty)
            foreach(m; match(_rawQueryString, ctRegex!("([^=&]+)(?:=([^&]+))?&?", "g")))
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

         if ("__SESSION_ID__" in _cookie)
         {
            import std.string : indexOf;
            import std.digest.sha;

            auto sessionId  = _cookie["__SESSION_ID__"];

            auto separator = sessionId.indexOf('-');

            if (separator > 0 && sessionId.length > separator + 1)
            {
               auto signature = sessionId[0..separator];
               auto uuid = sessionId[separator+1..$];

               string ua = "NO-UA";
               string al = "NO-AL";

               if("user-agent" in _header) ua = _header["user-agent"];
               if("accept-language" in _header) al = _header["accept-language"];

               auto sign = cast(string)sha224Of(ua ~ "_" ~ al ~ "_" ~ _remoteAddress.toAddrString ~ "_" ~ uuid).toHexString.toLower;

               if (sign == signature) _sessionId = sessionId;
               else warning("Is someone trying to spoof sessionId? ", sessionId);
            }
         }

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
         import std.file : remove;
         foreach(f; _form)
            try {remove(f.path); } catch(Exception e) { }
      }

      ~this() { clearFiles(); }


      private char[] _data;
      private string[string]  _get;
      private string[string]  _post;
      private string[string]  _header;
      private string[string]  _cookie;

      private string _uri;
      private string _method;
      private string _host;
      private string _postDataContentType;
      private bool   _isHttps;
      private string _worker;
      private string _user;
      private string _password;
      private string _sessionId;
      private size_t _uploadId;

      private Address _remoteAddress;
      private Address _localAddress;

      private string _rawQueryString;
      private string _rawHeaders;
      private string _rawRequestLine;

      private HttpVersion _httpVersion;

      private FormData[string]   _form;
      private ParsingStatus      _parsingStatus = ParsingStatus.OK;

      private size_t    _requestId;

      void clear()
      {
         _form    = null;
         _data    = null;
         _get     = null;
         _post    = null;
         _header  = null;
         _cookie  = null;
         _uri     = string.init;

         _isHttps       = false;
         _method        = string.init;
         _host          = string.init;
         _remoteAddress = null;
         _localAddress  = null;
         _user          = string.init;
         _password      = string.init;
         _sessionId     = string.init;
         _httpVersion   = HttpVersion.HTTP10;

         _rawQueryString   = string.init;
         _rawHeaders       = string.init;
         _rawRequestLine   = string.init;

         _postDataContentType = string.init;

         _parsingStatus = ParsingStatus.OK;

         clearFiles();
      }
   }

   private RequestImpl* _internal;
   private size_t       _requestId;
}

/// Your reply.
struct Output
{

	public:

   /// Set buffer for data output (0 = disabled)
   @safe void setBufferSize(size_t sz = 0)
   {
      if (_internal._dirty)
         throw new Exception("Can't change buffer size. Too late");

      _internal._bufferSize = sz;

      if (sz>0)
         _internal._sendBuffer.reserve(sz);
   }

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
   @safe bool serveFile(const string path, bool guessMime = true)
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

      size_t fs = path.getSize();

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
               ".ts" : "video/mp2t", ".ttf" : "font/ttf", ".txt" : "text/plain", ".vsd" : "application/vnd.visio", ".wav" : "audio/wav",
               ".weba" : "audio/webm", ".webm" : "video/webm", ".webp" : "image/webp", ".woff" : "font/woff", ".woff2" : "font/woff2",
               ".xhtml" : "application/xhtml+xml", ".xls" : "application/vnd.ms-excel", ".xlsx" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
               ".xml" : "application/xml", ".xul" : "application/vnd.mozilla.xul+xml", ".zip" : "application/zip", ".3gp" : "video/3gpp",
               ".3g2" : "video/3gpp2", ".7z" : "application/x-7z-compressed"
            ];

            if (path.extension in mimes)
               header = mimes[path.extension];
         }

         addHeader("Content-Type", header);
      }

      ubyte[1024*32] buffer;
      File toSend = File(path, "r");

      while(true)
      {
         auto bytesRead = toSend.rawRead(buffer);
         write(bytesRead);

         if (bytesRead.length < buffer.length)
            break;
      }

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

      string output;
      auto builder = appender(output);
      builder.reserve(1024);

      immutable string[short] StatusCode =
      [
         200: "OK", 201 : "Created", 202 : "Accepted", 203 : "Non-Authoritative Information", 204 : "No Content", 205 : "Reset Content", 206 : "Partial Content",

         300 : "Multiple Choices", 301 : "Moved Permanently", 302 : "Found", 303 : "See Other", 304 : "Not Modified", 305 : "Use Proxy", 307 : "Temporary Redirect",

         400 : "Bad Request", 401 : "Unauthorized", 402 : "Payment Required", 403 : "Forbidden", 404 : "Not Found", 405 : "Method Not Allowed",
         406 : "Not Acceptable", 407 : "Proxy Authentication Required", 408 : "Request Timeout", 409 : "Conflict", 410 : "Gone",
         411 : "Lenght Required", 412 : "Precondition Failed", 413 : "Request Entitty Too Large", 414 : "Request-URI Too Long", 415 : "Unsupported Media Type",
         416 : "Requested Range Not Satisfable", 417 : "Expectation Failed",

         500 : "Internal Server Error", 501 : "Not Implemented", 502 : "Bad Gateway", 503 : "Service Unavailable", 504 : "Gateway Timeout", 505 : "HTTP Version Not Supported"
      ];

      string statusDescription;

      auto item = _internal._status in StatusCode;
      if (item != null) statusDescription = *item;
      else statusDescription = "Unknown";

      bool has_content_type = false;
      builder.put(format("%s %s %s\r\n", _internal._httpVersion, status, statusDescription));
      builder.put("server: serverino/%02d.%02d.%02d\r\n".format(SERVERINO_MAJOR, SERVERINO_MINOR, SERVERINO_REVISION));

      if (!_internal._keepAlive) builder.put("connection: close\r\n");
      else builder.put("connection: keep-alive\r\n");

      // send user-defined headers
      foreach(const ref header;_internal._headers)
      {
         builder.put(format("%s: %s\r\n", header.key, header.value));
         if (header.key == "content-type") has_content_type = true;
      }

      // Default content-type is text/html if not defined by user
      if (!has_content_type)
         builder.put(format("content-type: text/html;charset=utf-8\r\n"));

      // If required, I add headers to write cookies
      foreach(Cookie c;_internal._cookies)
      {
         builder.put(format("set-cookie: %s=%s", c.name.encode(), c.value.encode()));

         if (!c.session)
         {
            string[] mm = ["", "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];
            string[] dd = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

            SysTime gmt = c.expire.toUTC();

            string data = format("%s, %s %s %s %s:%s:%s GMT",
               dd[gmt.dayOfWeek], gmt.day, mm[gmt.month], gmt.year,
               gmt.hour, gmt.minute, gmt.second
            );

            builder.put(format("; Expires=%s", data));
         }

         if (!c.path.length == 0) builder.put(format("; path=%s", c.path));
         if (!c.domain.length == 0) builder.put(format("; domain=%s", c.domain));
         if (c.secure) builder.put(format("; Secure"));
         if (c.httpOnly) builder.put(format("; HttpOnly"));
         builder.put("\r\n");
      }

      builder.put("\r\n");
      sendData(builder.data);
     _internal._headersSent = true;
   }


   @safe string createSessionIdFromRequest(Request req, string cookiePath = string.init, string cookieDomain = string.init)
   {
      import std.random : unpredictableSeed, Xorshift192;
      import std.digest.sha;
      import std.uuid : randomUUID;

      auto gen = Xorshift192(unpredictableSeed);
      auto uuid = randomUUID(gen).toString;

      // A simple way to help reduce spoofing of sessionId between different machines.
      auto sign = cast(string)sha224Of
      (
         req.header.read("user-agent", "NO-UA") ~ "_" ~
         req.header.read("accept-language", "NO-AL") ~ "_" ~
         req.remoteAddress.toAddrString ~ "_" ~ uuid
      ).toHexString.toLower;

      string sessionId = sign ~ "-" ~ uuid;

      setCookie("__SESSION_ID__", sessionId, cookiePath, cookieDomain);

      return sessionId;
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
	@safe void opOpAssign(string op, T)(T data) if (op == "~")  { write(data.to!string); }

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

   private:

   @safe void sendData(const string data) { sendData(data.representation); }
   @safe void sendData(const void[] data)
   {
      _internal._dirty = true;

      if (_internal._keepAlive && _internal._headersSent)
      {
         if (_internal.isBuffered()) _internal._sendBuffer ~= format("%X\r\n%s\r\n", data.length, cast(const char[])data);
         else _internal._http.send(format("%X\r\n%s\r\n", data.length, cast(const char[])data));
      }
      else
      {
         if (_internal.isBuffered()) _internal._sendBuffer ~= cast(const char[])data;
         else  _internal._http.send(data);
      }

      flush();
   }

   @safe void flush(const bool force = false)
   {
      if (_internal.isBuffered() && (force || _internal._sendBuffer.data.length >= _internal._bufferSize))
            _internal._http.send(_internal._sendBuffer.data);
   }

   import std.array : Appender, appender;

   struct OutputImpl
   {

      this(HttpStream* w) { _http = w; }
      private Cookie[string]  _cookies;
      private KeyValue[]  	   _headers;

      private bool            _keepAlive;
      private string          _httpVersion;
      private ushort          _status;
      private bool			   _headersSent;
      private Duration        _timeout;
      private bool            _dirty;

      private HttpStream*     _http;

      private size_t          _requestId;
      private size_t          _bufferSize;
      private Appender!string _sendBuffer;
      private string          _buffer;

      @safe nothrow @nogc isBuffered() { return _bufferSize > 0; }

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
         _bufferSize = 0;
         _buffer.length = 0;
         _sendBuffer = appender(_buffer);
      }
   }

   OutputImpl* _internal;
   size_t      _requestId;
}

extern(C) private void onExit(Modules...)(int value)
{
   import core.stdc.stdlib : exit;
   import std.stdio : stderr;

   tryUninit!Modules();
   stderr.flush;

   with(Worker.instance)
   {
      exitRequested = true;

      if (workerInfo.ipcSocket !is null)
      {
         workerInfo.ipcSocket.send("S"); // *S*TOPPED
         workerInfo.ipcSocket.shutdown(SocketShutdown.BOTH);
         workerInfo.ipcSocket.close();
         workerInfo.ipcSocket = null;
      }

      foreach(t; tls)
      {
         tls_close(t.ctx);
         tls_free(t.ctx);
         tls_config_free(t.cert);
      }

      tls = null;

      {
         if (!http.hasWritten)
            http.sendError("504 Gateway Timeout");

         http.destroy();
      }
   }

   Thread.yield();
   exit(0);
}

void tryInit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onWorkerStart))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStart but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStart but it is not callable");

      }}
   }
}

void tryUninit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onWorkerStop))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStop but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerStop but it is not callable");

      }}
   }
}