module serverino.websocket;

import serverino.common;
import serverino.config;
import serverino.daemon;
import serverino.interfaces : Request, WebSocketProxy, WebSocketMessage;

import std.socket : Socket, AddressFamily, SocketType, socket_t, SocketShutdown;
import std.experimental.logger : critical, log, warning;
import std.file : tempDir;
import std.path : buildPath;

version(Posix) import std.socket : UnixAddress;

import std.process : environment;

struct WebSocket
{
   package:
   static:

   void wake(Modules...)()
   {
      import std.conv : to;
      import std.stdio;
      import std.format : format;

      daemonProcess = new ProcessInfo(environment.get("SERVERINO_DAEMON").to!int);

      version(linux) auto socketAddress = new UnixAddress("\0%s".format(environment.get("SERVERINO_SOCKET")));
      else auto socketAddress = new UnixAddress(buildPath(tempDir, environment.get("SERVERINO_SOCKET")));

      Socket listener = new Socket(AddressFamily.UNIX, SocketType.STREAM);
      listener.bind(socketAddress);

      // TODO: Max accept time
      // Wait for the connection check
      listener.listen(1);
      listener.accept();

      // Wait for the daemon connection
      listener.listen(1);
      channel = listener.accept();

      // Wait for socket transfer
      version(Windows)
      {
         WSAPROTOCOL_INFOW wi;
         channel.receive((cast(ubyte*)&wi)[0..wi.sizeof]);
      }
      else
      {
         auto handle = socketTransferReceive(channel);

         if (handle <= 0)
            throw new Exception("Invalid socket transfer");
      }

       // Wait for socket protocol (AF_INET or AF_INET6)
      AddressFamily af;
      auto recv = channel.receive((&af)[0..1]);

      // Wait for headers
      ubyte[32*1024] buffer;
      recv = channel.receive(buffer);
      char[] headers = cast(char[])buffer[0..recv];

      version(Windows)
         auto handle = WSASocketW(-1, -1, -1, &wi, 0, WSA_FLAG_OVERLAPPED);

      // Sending connection upgrade response to the client
      Socket client = new Socket(cast(socket_t)handle, af);
      client.send(headers);
      client.blocking = true;

      auto proxy = new WebSocketProxy(client);

      Request r = Request();
      r._internal = new Request.RequestImpl();
      r._internal.deserialize(environment.get("SERVERINO_REQUEST"));

      log("WebSocket started.");
      scope(exit) log("WebSocket stopped.");

      import core.thread;
      import core.stdc.stdlib : exit;

      new Thread({

         Thread.getThis().isDaemon = true;

         // Check if the server is still alive
         while (!WebSocketProxy.killRequested)
            Thread.sleep(1.seconds);

         log("Killing websocket. [REASON: broken pipe?]");

         exit(0);

      }).start();

      try {
         tryInit!(Modules)();
         callHandlers!Modules(r, proxy);
      }
       // Unhandled Exception escaped from user code
      catch (Exception e)
      {
         critical(format("%s:%s Uncatched exception: %s", e.file, e.line, e.msg));
         critical(format("-------\n%s",e.info));
      }
      // Even worse.
      catch (Throwable t)
      {
         critical(format("%s:%s Throwable: %s", t.file, t.line, t.msg));
         critical(format("-------\n%s",t.info));

         // Rethrow
         throw t;
      }

      tryUninit!(Modules)();

      // Send a close message to the client
      proxy.sendClose();
      proxy.socket.close();
      proxy.socket.shutdown(SocketShutdown.BOTH);
   }

   void callHandlers(modules...)(Request request, WebSocketProxy socket)
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
                  !__traits(compiles, s(request, socket)) &&
                  !__traits(compiles, s(request)) &&
                  !__traits(compiles, s(socket))
               )
               {
                  import serverino.interfaces : Output;
                  Output o = Output.init;

                  static if (!__traits(compiles, s(request, o)) && !__traits(compiles, s(o)))
                     static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, WebSocketProxy socket)`.");

                  continue;
               }

               static foreach(p; ParameterStorageClassTuple!s)
               {
                  static if (p == ParameterStorageClass.ref_)
                  {
                     static assert(0, fullyQualifiedName!s ~ " is not a valid endpoint. Wrong storage class for params. Try to change its signature to `" ~ __traits(identifier,s) ~ "(Request request, WebSocketProxy socket)`.");
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

                  import std.traits : hasUDA, TemplateOf, getUDAs;

                  bool willLaunch = true;
                  static if (hasUDA!(f, route))
                  {
                     willLaunch = false;
                     static foreach(attr;  getUDAs!(f, route))
                     {
                        {
                           if(attr.apply(request)) willLaunch = true;
                        }
                     }
                  }

                  if (willLaunch)
                  {
                     static if (__traits(compiles, f(request, socket))) f(request, socket);
                     else static if (__traits(compiles, f(request))) f(request);
                     else f(socket);
                  }
               }

               if (socket.isDirty) return true;
            }

            return false;
         }

        callUntilIsDirty!taggedHandlers;
      }
      else
      {
         static bool warningShown = false;

         if (!warningShown)
         {
            warningShown = true;
            warning("No handlers found. Try `@endpoint your_function(Request r, WebSocketProxy socket) { socket.sendText(\"Hello Websocket!\"); }` to handle requests.");
         }
      }
   }


   Socket      channel;
   ProcessInfo daemonProcess;
}



void tryInit(Modules...)()
{
   import std.traits : getSymbolsByUDA, isFunction;

   static foreach(m; Modules)
   {
      static foreach(f;  getSymbolsByUDA!(m, onWebSocketStart))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWebSocketStart but it is not a function");

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
      static foreach(f;  getSymbolsByUDA!(m, onWebSocketStop))
      {{
         static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onWebSocketStop but it is not a function");

         static if (__traits(compiles, f())) f();
         else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onWebSocketStop but it is not callable");

      }}
   }
}
