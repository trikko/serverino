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

module serverino.worker;

import serverino.common;
import serverino.config;
import serverino.interfaces;
import std.experimental.logger : log, warning, fatal, critical;
import std.process : environment;
import std.stdio : FILE;
import std.socket : Socket, AddressFamily, SocketType, SocketOption, SocketOptionLevel, SocketShutdown;
import std.datetime : seconds;
import std.string : toStringz, indexOf, strip, toLower;
import std.algorithm : splitter, startsWith, map;
import std.range : assumeSorted;
import std.format : format;
import std.conv : to;
import core.atomic : cas, atomicLoad, atomicStore;

extern(C) int dup2(int a, int b);
extern(C) int fileno(FILE *stream);

version(Posix) import std.socket : UnixAddress;

struct Worker
{
   static:

   void wake(Modules...)()
   {

      import std.conv : to;
      import std.format : format;
      import std.process : thisProcessID;
      import std.path : baseName;
      import core.runtime : Runtime;
      import std.datetime : msecs;

      WorkerConfig cfg = WorkerConfig();
      cfg.maxRequestTime = environment.get("SERVERINO_WORKER_CONFIG_MAX_REQUEST_TIME").to!ulong.msecs;
      cfg.maxHttpWaiting = environment.get("SERVERINO_WORKER_CONFIG_MAX_HTTP_WAITING").to!ulong.msecs;
      cfg.maxWorkerLifetime = environment.get("SERVERINO_WORKER_CONFIG_MAX_WORKER_LIFETIME").to!ulong.msecs;
      cfg.maxWorkerIdling = environment.get("SERVERINO_WORKER_CONFIG_MAX_WORKER_IDLING").to!ulong.msecs;
      cfg.maxDynamicWorkerIdling = environment.get("SERVERINO_WORKER_CONFIG_MAX_DYNAMIC_WORKER_IDLING").to!ulong.msecs;
      cfg.keepAlive = environment.get("SERVERINO_WORKER_CONFIG_KEEP_ALIVE") == "1";
      cfg.user = environment.get("SERVERINO_WORKER_CONFIG_USER");
      cfg.group = environment.get("SERVERINO_WORKER_CONFIG_GROUP");

      WorkerConfigPtr config = &cfg;

      isDynamic = environment.get("SERVERINO_DYNAMIC_WORKER") == "1";
      daemonProcess = new ProcessInfo(environment.get("SERVERINO_DAEMON_PID").to!int);

      version(Posix)
      {
         auto base = baseName(Runtime.args[0]);

         setProcessName
         (
            [
               base ~ " / worker [daemon: " ~ environment.get("SERVERINO_DAEMON_PID") ~ "]",
               base ~ " / worker",
               base ~ " [WK]"
            ]
         );
      }

      version(linux) auto socketAddress = new UnixAddress("\0%s".format(environment.get("SERVERINO_SOCKET")));
      else
      {
         import std.path : buildPath;
         import std.file : tempDir;
         auto socketAddress = new UnixAddress(buildPath(tempDir, environment.get("SERVERINO_SOCKET")));
      }

      channel = new Socket(AddressFamily.UNIX, SocketType.STREAM);
      channel.connect(socketAddress);
      channel.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 1.seconds);

      ubyte[1] ack = ['\0'];
      channel.send(ack);

      request._internal = new Request.RequestImpl();
      output._internal = new Output.OutputImpl();

      version(Windows)
      {
         log("Worker started.");
      }
      else
      {
         import core.sys.posix.pwd;
         import core.sys.posix.grp;
         import core.sys.posix.unistd;
         import core.stdc.string : strlen;

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

      }

      // Prevent read from stdin
      {
         import std.stdio : stdin, fopen;

         version(Windows)  auto nullSink = fopen("NUL", "r");
         version(Posix)    auto nullSink = fopen("/dev/null", "r");

         auto ret = dup2(fileno(nullSink), fileno(stdin.getFP));
         assert(ret != -1, "Too many open files. Can't redirect stdin to /dev/null.");
      }

      tryInit!Modules();

      import std.string : chomp;

      import core.thread : Thread;
      import core.stdc.stdlib : exit;
      __gshared bool justSent = false;

      new Thread({

         Thread.getThis().isDaemon = true;
         Thread.getThis().priority = Thread.PRIORITY_MIN;

         while(true)
         {
            Thread.yield();

            CoarseTime st = atomicLoad(processedStartedAt);

            if (!(st == CoarseTime.zero || CoarseTime.currTime - st < config.maxRequestTime))
               break;

            Thread.sleep(1.seconds);
         }

         log("Killing worker. [REASON: request timeout]");

         if (cas(&justSent, false, true))
         {
            WorkerPayload wp;

            output._internal.clear();
            output.status = 504;
            output._internal.buildHeaders();
            wp.flags = WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
            atomicStore(processedStartedAt, CoarseTime.zero);
            wp.contentLength = output._internal._headersBuffer.array.length + output._internal._sendBuffer.array.length;

            channel.send((cast(char*)&wp)[0..wp.sizeof] ~ output._internal._headersBuffer.array ~ output._internal._sendBuffer.array);
         }

         channel.close();
         exit(0);
      }).start();

      startedAt = CoarseTime.currTime;
      while(true)
      {
         import std.string : chomp;

         justSent = false;
         output._internal.clear();
         request._internal.clear();

         ubyte[DEFAULT_BUFFER_SIZE] buffer = void;

         idlingAt = CoarseTime.currTime;

         import serverino.databuffer;

         uint size;
         bool sizeRead = false;
         ptrdiff_t recv = -1;
         static DataBuffer!ubyte data;
         data.clear();

         while(sizeRead == false || size > data.length)
         {
            recv = -1;
            while(recv == -1)
            {
               recv = channel.receive(buffer);
               import core.stdc.stdlib : exit;

               if (recv == -1)
               {

                  immutable tm = CoarseTime.currTime;
                  if (tm - idlingAt > config.maxWorkerIdling)
                  {
                     log("Killing worker. [REASON: maxWorkerIdling]");
                     tryUninit!Modules();
                     channel.close();
                     exit(0);
                  }
                  else if (tm - startedAt > config.maxWorkerLifetime)
                  {
                     log("Killing worker. [REASON: maxWorkerLifetime]");
                     tryUninit!Modules();
                     channel.close();
                     exit(0);
                  }
                  else if (isDynamic && tm - idlingAt > config.maxDynamicWorkerIdling)
                  {
                     log("Killing worker. [REASON: cooling down]");
                     tryUninit!Modules();
                     channel.close();
                     exit(0);
                  }

                  continue;
               }
               else if (recv < 0)
               {
                  tryUninit!Modules();
                  log("Killing worker. [REASON: socket error]");
                  channel.close();
                  exit(cast(int)recv);
               }
            }

            if (recv == 0) break;
            else if (sizeRead == false)
            {
               size = *(cast(uint*)(buffer[0..uint.sizeof].ptr));
               data.reserve(size);
               data.append(buffer[uint.sizeof..recv]);
               sizeRead = true;
            }
            else data.append(buffer[0..recv]);
         }

         if(data.array.length == 0)
         {
            tryUninit!Modules();

            if (daemonProcess.isTerminated()) log("Killing worker. [REASON: daemon is not running]");
            else log("Killing worker. [REASON: socket closed?]");

            channel.close();
            exit(0);
         }

         ++requestId;

         WorkerPayload wp = WorkerPayload
         (
            parseHttpRequest!Modules(config, data.array),
            output._internal._sendBuffer.array.length + output._internal._headersBuffer.array.length
         );

         if (cas(&justSent, false, true))
            channel.send((cast(char*)&wp)[0..wp.sizeof] ~  output._internal._headersBuffer.array ~ output._internal._sendBuffer.array);
      }


   }

   typeof(WorkerPayload.flags) parseHttpRequest(Modules...)(WorkerConfigPtr config, ubyte[] data)
   {

      scope(exit) {
         output._internal.buildHeaders();
         if (!output._internal._sendBody)
            output._internal._sendBuffer.clear();
      }

      import std.utf : UTFException;

      version(debugRequest) log("-- START RECEIVING");
      try
      {
         size_t			contentLength = 0;

         char[]			method;
         char[]			path;
         char[]			httpVersion;

         char[]			requestLine;
         char[]			headers;

         bool 			   hasContentLength = false;


         headers = cast(char[]) data;
         auto headersEnd = headers.indexOf("\r\n\r\n");

         bool valid = true;

         // Headers completed?
         if (headersEnd > 0)
         {
            version(debugRequest) log("-- HEADERS COMPLETED");

            headers.length = headersEnd;
            data = data[headersEnd+4..$];

            auto headersLines = headers.splitter("\r\n");

            requestLine = headersLines.front;

            {
               auto fields = requestLine.splitter(' ');

               method = fields.front;
               fields.popFront;
               path = fields.front;
               fields.popFront;
               httpVersion = fields.front;

               if (["CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"].assumeSorted.contains(method) == false)
               {
                  debug warning("HTTP method unknown: ", method);
                  output._internal._httpVersion = (httpVersion == "HTTP/1.1")?HttpVersion.HTTP11:HttpVersion.HTTP10;
                  output._internal._sendBody = false;
                  output.status = 400;
                  return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
               }
            }

            headersLines.popFront;

            foreach(const ref l; headersLines)
            {
               enum CONTENT_LENGTH = "content-length:".length;

               if (l.length > CONTENT_LENGTH && l[0..CONTENT_LENGTH] == "content-length:")
               {
                  contentLength = l[CONTENT_LENGTH..$].to!size_t;
                  hasContentLength = true;
                  break;
               }
            }

            // If no content-length, we don't read body.
            if (contentLength == 0)
            {
               version(debugRequest) log("-- NO CONTENT LENGTH, SKIP DATA");
               data.length = 0;
            }

            else if (data.length >= contentLength)
            {
               version(debugRequest) log("-- DATA ALREADY READ.");
               data.length = contentLength;
            }
         }
         else return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;

         version(debugRequest) log("-- PARSING DATA");

         {
            import std.algorithm : max;
            import std.uni : sicmp;

            request._internal._requestId      = requestId;
            request._internal._httpVersion    = (httpVersion == "HTTP/1.1")?(HttpVersion.HTTP11):(HttpVersion.HTTP10);
            request._internal._data           = cast(char[])data;
            request._internal._rawHeaders     = cast(string)headers;
            request._internal._rawRequestLine = cast(string)requestLine;

            output._internal._httpVersion = request._internal._httpVersion;

            bool insidePath = true;
            size_t pathLen = 0;
            size_t queryStart = 0;
            size_t queryLen = 0;

            foreach(i, const x; path)
            {
               if (insidePath)
               {
                  if (x == '?')
                  {
                     pathLen = i;
                     queryStart = i+1;
                     insidePath = false;
                  }
                  else if (x == '#')
                  {
                     pathLen = i;
                     break;
                  }
               }
               else
               {
                  // Should not happen!
                  if (x == '#')
                  {
                     queryLen = i;
                     break;
                  }
               }
            }

            if (pathLen == 0)
            {
               pathLen = path.length;
               queryStart = path.length;
            }

            queryLen = path.length;

            // Just to prevent uri attack like
            // GET /../../non_public_file
            auto normalize(string uri)
            {
               import std.range : retro, join;
               import std.algorithm : filter;
               import std.array : array;
               import std.typecons : tuple;
               size_t skips = 0;
               string norm = uri
                  .splitter('/')
                  .retro
                  .map!(
                        (x)
                        {
                           if (x == "..") skips++;
                           else if(x != ".")
                           {
                              if (skips == 0) return tuple(x, true);
                              else skips--;
                           }

                           return tuple(x, false);
                        }
                  )
                  .filter!(x => x[1] == true)
                  .map!(x => x[0])
                  .array
                  .retro
                  .join('/');

                  if (norm.startsWith("/")) return norm;
                  else return "/" ~ norm;
            }

            request._internal._path           = normalize(cast(string)path[0..pathLen]);
            request._internal._rawQueryString = cast(string)path[queryStart..queryLen];
            request._internal._method         = cast(string)method;

            output._internal._sendBody = (!["CONNECT", "HEAD", "TRACE"].assumeSorted.contains(request._internal._method));

            import std.uri : URIException;
            try { request._internal.process(); }
            catch (URIException e)
            {
               output.status = 400;
               output._internal._sendBody = false;
               return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
            }


            import std.algorithm : canFind;

            // Websocket handling
            // ------------------
            if (
               sicmp(request.header.read("upgrade"), "websocket") == 0 &&
               request.header.read("connection").splitter(",").map!(x => x.strip.toLower).canFind("upgrade")
            )
            {
               immutable accepted = acceptWebsocket!Modules(request);

               // Check if user accepted the upgrade in the @onWebSocketUpgrade handler
               if (!accepted)
               {
                  output.status = 426;
                  output._internal._sendBody = false;
                  return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
               }

               else
               {
                  import std.string : indexOf;
                  import std.base64 : Base64;
                  import std.digest.sha : sha1Of;

                  // Serverino supports only WebSocket version 13
                  if (request.header.read("sec-websocket-version").indexOf("13") < 0)
                  {
                     output.status = 400;
                     output._internal._sendBody = false;
                     output.addHeader("Sec-WebSocket-Version", "13");
                     return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
                  }

                  import std.process : pipeProcess, Redirect, Config;
                  import std.uuid : randomUUID;

                  // Create a random address.
                  auto uuid = "serverino-" ~ randomUUID().toString()[$-12..$] ~ ".ws";

                  // We use a unix socket on both linux and macos/windows but ...
                  version(linux) auto socketAddress = new UnixAddress("\0%s".format(uuid));
                  else
                  {
                     import std.path : buildPath;
                     import std.file : tempDir;
                     auto socketAddress = new UnixAddress(buildPath(tempDir, uuid));
                  }

                  // We start a new process and pass the socket address to it.
                  import serverino.daemon : Daemon;
                  string[string] env = environment.toAA.dup;
                  env["SERVERINO_SOCKET"]    = uuid;
                  env["SERVERINO_COMPONENT"] = "WS";
                  env["SERVERINO_REQUEST"] = request._internal.serialize();

                  import std.process : pipeProcess, Redirect, Config;
                  import std.file : thisExePath;
                  import core.thread : Thread;

                  import std.range : repeat;
                  import std.array : array;

                  // Start the process
                  version(Posix) const pname = [exePath, cast(char[])(' '.repeat(30).array)];
                  else const pname = exePath;

                  auto pipes     = pipeProcess(pname, Redirect.stdin, env, Config.detached);
                  bool done      = false;
                  size_t tries   = 0;

                  Socket s = new Socket(AddressFamily.UNIX, SocketType.STREAM);

                  // Wait for the process to start
                  while(true)
                  {
                     try
                     {
                        // Check connection with websocket.
                        s.connect(socketAddress);
                     }
                     catch(Exception e)
                     {
                        import std.datetime : usecs;
                        Thread.sleep(100.usecs);
                        ++tries;

                        if(tries > 200) break;
                        else continue;
                     }

                     done = true;
                     break;
                  }

                  // No response from the process
                  if (!done)
                  {
                     output.status = 500;
                     output._internal._sendBody = false;
                     return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
                  }


                  // Ok, let's upgrade the connection
                  immutable reply = Base64.encode(sha1Of(request.header.read("sec-websocket-key") ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"));

                  output.status = 101;
                  output.addHeader("Upgrade", "websocket");
                  output.addHeader("Connection", "Upgrade");
                  output.addHeader("Sec-WebSocket-Accept", reply);
                  output.addHeader("X-Serverino-WebSocket", uuid);   // Send the address to the communicator
                  output.addHeader("X-Serverino-WebSocket-Pid", pipes.pid.processID.to!string);

                  output._internal._sendBody = false;
                  output._internal._websocket = true;

                  return WorkerPayload.Flags.WEBSOCKET_UPGRADE;
               }

            }

            // Http request handling
            // ---------------------

            output._internal._keepAlive =
               config.keepAlive &&
               output._internal._httpVersion == HttpVersion.HTTP11 &&
               sicmp(request.header.read("connection", "keep-alive"), "keep-alive") == 0;

            version(debugRequest)
            {
               log("-- REQ: ", request.path);
               log("-- PARSING STATUS: ", request._internal._parsingStatus);

               try { log("-- REQ: ", request); }
               catch (Exception e ) {log("EX:", e);}
            }

            if (request._internal._parsingStatus == Request.ParsingStatus.OK)
            {
               try
               {
                  {
                     scope(exit) atomicStore(processedStartedAt, CoarseTime.zero);

                     atomicStore(processedStartedAt, CoarseTime.currTime);

                     try { callHandlers!Modules(request, output); }
                     catch (Exception e) {

                        // If an exception is thrown, we try to call the exception handler if any.
                        bool handled = false;

                        import std.meta : AliasSeq;
                        import std.traits : moduleName, getSymbolsByUDA, isFunction, ReturnType, Parameters;
                        alias allModules = AliasSeq!Modules;

                        // Search for a function marked with @onWorkerException
                        static foreach(m; allModules)
                        {
                           static foreach(f; getSymbolsByUDA!(m, onWorkerException))
                           {
                              static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerException but it is not a function");
                              static assert(is(ReturnType!f == bool), "`" ~ __traits(identifier, f) ~ "` is " ~ ReturnType!f.toString ~ " but should be `bool`");

                              static if (is(Parameters!f == AliasSeq!(Request, Output, Exception))) handled = f(request, output, e);
                              else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onWorkerException but it is not callable");

                              static if (!__traits(compiles, hasExceptionHandler)) { enum hasExceptionHandler; }
                              else static assert(0, "You can't mark more than one function with @onWorkerException");
                           }
                        }

                        // Rethrow if no handler found or handler returned false
                        if (!handled) throw e;
                     }
                  }

                  if (!output._internal._dirty)
                  {
                     output.status = 404;
                     output._internal._sendBody = false;
                  }

                  WorkerPayload.Flags flags = (output._internal._keepAlive?WorkerPayload.Flags.HTTP_KEEP_ALIVE:WorkerPayload.Flags.init);

                  if (output._internal._sendFile.length == 0)
                  {
                     if(output._internal._sendBuffer.length > 1024*1024)
                        warning("Sending a big response. Consider using `serveFile` to avoid memory issues.");

                     flags |= WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
                  }
                  else
                  {
                     flags |= WorkerPayload.Flags.HTTP_RESPONSE_FILE;
                     output._internal._sendBuffer.clear();
                     output._internal._sendBuffer.append(output._internal._sendFile);

                     if (output._internal._deleteOnClose)
                        flags |= WorkerPayload.Flags.HTTP_RESPONSE_FILE_DELETE;
                  }

                  import serverino.daemon : Daemon;
                  if (Daemon.isExiting) flags |= WorkerPayload.Flags.DAEMON_SHUTDOWN;
                  else if (Daemon.isSuspended) flags |= WorkerPayload.Flags.DAEMON_SUSPEND;

                  return flags;

               }

               // Unhandled Exception escaped from user code
               catch (Exception e)
               {
                  critical(format("%s:%s Uncatched exception: %s", e.file, e.line, e.msg));
                  critical(format("-------\n%s",e.info));

                  output.status = 500;
                  return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
               }

               // Even worse.
               catch (Throwable t)
               {
                  critical(format("%s:%s Throwable: %s", t.file, t.line, t.msg));
                  critical(format("-------\n%s",t.info));

                  // Rethrow
                  throw t;
               }
            }
            else
            {
               debug warning("Parsing error: ", request._internal._parsingStatus);

               output.status = 400;
               output._internal._sendBody = false;
               return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
            }

         }
      }
      catch(UTFException e)
      {
         output.status = 400;
         output._internal._sendBody = false;
         debug warning("UTFException: ", e.toString);
      }
      catch(Exception e) {

         output.status = 500;
         output._internal._sendBody = false;
         debug critical("Unhandled exception: ", e.toString);
      }

      return WorkerPayload.Flags.HTTP_RESPONSE_INLINE;
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
               import std.traits : hasUDA;
               alias s = __traits(getMember, globalNs, sy);

               static if
               (
                  (
                     __traits(compiles, s(request, output)) ||
                     __traits(compiles, s(request)) ||
                     __traits(compiles, s(output))
                  )
                  && !hasUDA!(s, endpoint)
               )
               {
                  static if (getUDAs!(s, onWebSocketUpgrade).length == 0)
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
                  import serverino.interfaces : WebSocket;
                  WebSocket o;

                  static if (!__traits(compiles, s(request, o)) && !__traits(compiles, s(o)))
                     static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, Output output)`.");

                  continue;
               }
               else {

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
            }
         }}

         return fps.sort!((a,b) => a.priority > b.priority).array;

      }

      static immutable taggedHandlers = getTaggedHandlers();
      static immutable untaggedHandlers = getUntaggedHandlers();


      static if (taggedHandlers !is null && taggedHandlers.length>0)
      {
         bool callUntilIsDirty(FunctionPriority[] taggedHandlers)()
         {
            static if (untaggedHandlers !is null && untaggedHandlers.length > 0)
            {
               static bool untaggedWarningShown = false;

               if (!untaggedWarningShown)
               {
                  untaggedWarningShown = true;

                  static foreach(ff; untaggedHandlers)
                  {
                     {
                        mixin(`import ` ~ ff.mod ~ ";");
                        alias currentMod = mixin(ff.mod);
                        alias f = __traits(getMember,currentMod,ff.name);

                        import std.traits : hasUDA;
                        static if (hasUDA!(f, priority) || hasUDA!(f, route))
                        {
                           import std.logger : critical;
                           critical("Function `", ff.mod ~ "." ~ ff.name, "` is not tagged with `@endpoint`. It will be ignored.");
                        }
                     }
                  }

               }
            }

            static foreach(ff; taggedHandlers)
            {
               {
                  mixin(`import ` ~ ff.mod ~ ";");
                  alias currentMod = mixin(ff.mod);
                  alias f = __traits(getMember,currentMod, ff.name);

                  import std.traits : hasUDA, TemplateOf, getUDAs;

                  static if (hasUDA!(f, route))
                  {
                     // If one of the route UDAs returns true, we will launch the function.
                     bool willLaunchFunc()()
                     {
                        static foreach(attr;  getUDAs!(f, route))
                        {
                           { if(attr.apply(request)) return true; }
                        }

                        return false;
                     }

                     bool willLaunch = willLaunchFunc();
                  }
                  else enum willLaunch = true;

                  request._internal._route ~= ff.mod ~ "." ~ ff.name;

                  if (willLaunch)
                  {
                     // Temporarily set the dirty flag to false. It will be restored at the end of the function.
                     bool wasDirty = output._internal._dirty;
                     if (wasDirty) output._internal._dirty = false;
                     scope(exit) if (wasDirty) output._internal._dirty = true;

                     import std.meta : AliasSeq;

                     // Get the parameters of the function
                     static if (__traits(compiles, f(request, output))) auto params = AliasSeq!(request, output);
                     else static if (__traits(compiles, f(request))) auto params = AliasSeq!(request);
                     else auto params = AliasSeq!(output);

                     // Check if the function has a fallthrough return value
                     Fallthrough tmpFt;
                     enum withFallthrough = __traits(compiles,  tmpFt = f(params));

                     static if (withFallthrough)
                     {
                        if (f(params) == Fallthrough.No) return true;
                     }
                     else
                     {
                        f(params);
                        if (output._internal._dirty) return true;
                     }

                  }
               }
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

                  request._internal._route ~= untaggedHandlers[0].mod ~ "." ~ untaggedHandlers[0].name;
               }
            }
         }
      }
      else
      {
         static bool warningShown = false;

         if (!warningShown)
         {
            warningShown = true;
            warning("No handlers found. Try `@endpoint your_function(Request r, Output output) { output ~= \"Hello World!\"; }` to handle requests.");
         }
      }
   }

   private shared static this() { import std.file : thisExePath; exePath = thisExePath(); }
   private static string exePath;

   __gshared:

   ProcessInfo    daemonProcess;

   Request        request;
   Output         output;

   CoarseTime     startedAt;
   CoarseTime     idlingAt;

   Socket         channel;

   size_t        requestId = 0;
   bool          isDynamic = false;

   shared CoarseTime    processedStartedAt = CoarseTime.zero;

}


bool acceptWebsocket(Modules...)(Request request)
{
   import std.traits : getSymbolsByUDA, isFunction, ReturnType;
   bool result = false;

   static foreach(m; Modules)
   {
      static foreach(f; getSymbolsByUDA!(m, onWebSocketUpgrade))
      {
         version(disable_websockets) static assert(false, "You compiled with -version=disable_websockets. You need to remove it to use WebSockets.");
         static if (__VERSION__ < 2102) static assert(false, "You need at least DMD 2.102 to use WebSockets.");

         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWebSocketUpgrade but it is not a function");
         static assert(is(ReturnType!f == bool), "`" ~ __traits(identifier, f) ~ "` is " ~ ReturnType!f.toString ~ " but should be `bool`");
         static if(__traits(compiles, f(request))) result = f(request);

         static if (!__traits(compiles, hasSocketUpgrade)) { enum hasSocketUpgrade; }
         else static assert(0, "You can't mark more than one function with @onWebSocketUpgrade");
      }
   }

   if (!__traits(compiles, hasSocketUpgrade))
   {
      static warningShown = false;

      if (!warningShown)
      {
         warningShown = true;
         warning("A websocket request has been received but you have not defined any @onWebSocketUpgrade handler. The request will be rejected. Try to define a function like `@onWebSocketUpgrade(Request request) { return true; }` to accept the upgrade.");
      }
   }

   return result;
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

