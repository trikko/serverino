/*
Copyright (c) 2023-2025 Andrea Fontana

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

/// Configuration module for serverino.
module serverino.config;

import std.experimental.logger : LogLevel;
import std.socket : Socket, InternetAddress, Internet6Address, Address;
import std.stdio : File;
import std.datetime : Duration, seconds, hours, msecs;
import std.traits : ReturnType;

import serverino.common : Backend, BackendType;

/++ Used as optional return type for functions with `@endpoint`` UDA attached.
 It is used to override the default behavior of serverino: if an endpoint returns Fallthrough.Yes, the next endpoint is called even if the current one has written to the output.
 ---
 // Doing a request to the server will return "Hello world!"

 // Will continue with the next function
 @endpoint @priority(3) auto test_1(Request r, Output o) { output ~= "Hello"; return Fallthrough.Yes; }

 // This blocks the chain (default behavior when output is written)
 @endpoint @priority(2) auto test_2(Request r, Output o) { output ~= " world!"; }

 // Never executed (blocked by test_2)
 @endpoint @priority(1) auto test_3(Request r, Output o) { output ~= "Not executed!"; }
 ---
 +/
public enum Fallthrough : bool
{
	Yes   = true,  /// Continue with the next function
   No    = false  /// Stop the chain
}

public struct priority { long priority; } /// UDA. Set @endpoint priority

public enum endpoint;            /// UDA. Functions with @endpoint attached are called when a request is received
public enum onDaemonStart;       /// UDA. Called when daemon start. Running in main thread, not in worker.
public enum onDaemonStop;        /// UDA. Called when daemon exit. Running in main thread, not in worker.
public enum onWorkerStart;       /// UDA. Functions with @onWorkerStart attached are called when worker is started
public enum onWorkerStop;        /// UDA. Functions with @onWorkerStop attached are called when worker is stopped
public enum onServerInit;        /// UDA. Used to setup serverino. Must return a ServerinoConfig struct. See `ServerinoConfig` struct.
public enum onWebSocketUpgrade;  /// UDA. Functions with @onWebSocketUpgrade attached are called when a websocket upgrade is requested
public enum onWebSocketStart;    /// UDA. Functions with @onWebSocketStart attached are called when a websocket is started
public enum onWebSocketStop;     /// UDA. Functions with @onWebSocketStop attached are called when a websocket is stopped

/++ UDA. Functions with @onWorkerException attached are called when worker throws an exception
   ---
   @onWorkerException bool myExceptionHandler(Request r, Output o, Exception e)
   {
      o.status = 500;
      info("Oh no! An exception occurred: ", e.msg);
      return true; // This means the exception is handled, if false, the exception is rethrown
   }
   ---
++/
public enum onWorkerException;

/++ UDA. Global variables marked with @requestScope are automatically
   reset (via destroy) at the beginning and end of each request, ensuring that
   no data leaks between requests.
   Example:
   ---
   @requestScope UserData currentUser;

   @endpoint
   void handler(Request r, Output o) {
      currentUser.name = r.get("name");  // reset at start of each request
      o ~= currentUser.name;
   }
   ---
+/
public enum requestScope;

import serverino.interfaces : Request;

/++ UDA. You can use to filter requests using a function `bool(Request request) { }`
+ Example:
+ ---
+ @endpoint
+ @route!(x => x.path.startsWith("/api"))
+ void api(Request r, Output o) { ... }
+ ---
+/
public struct route(alias T)
{
   static bool apply(const Request r) { return T(r); }
}

private template comparePath(string _path)
{
   import std.uri : encode;
   enum encodedPath = _path.encode();
   enum comparePath = (const Request r){
      static assert(_path[0] == '/', "Every route must begin with a '/'");
      return r.path == encodedPath;
   };
}

/++ UDA. You can use to filter requests using a path.
+ Example:
+ ---
+ @endpoint
+ @route!"/hello.html"
+ void api(Request r, Output o) { ... }
+ ---
+/
public alias route(string path) = route!(r => comparePath!path(r));

// Catch involuntarily use of `@route("...")`
public void route(string s) { assert(false, "Do not use `@route(\"" ~ s ~ "\")`: try `@route!\"" ~ s ~ "\"` instead."); }

/++
   Struct used to setup serverino.
   You must return this struct from a function with @onServerInit UDA attached.
---
@onServerInit
auto configure()
{
   // You can chain methods
   ServerinoConfig config =
      ServerinoConfig.create()
      .setWorkers(5)
      .enableKeepAlive();

   return config;
}
---
++/
struct ServerinoConfig
{

   public:

   @disable this();

   /// Create a new instance of ServerinoConfig
   static ServerinoConfig create()
   {
      ServerinoConfig sc = ServerinoConfig.init;

      sc.setLogLevel();
      sc.setReturnCode();
      sc.setDaemonInstances();
      sc.setMaxWorkers();
      sc.setMinWorkers();
      sc.setMaxWorkerLifetime();
      sc.setMaxWorkerIdling();
      sc.setMaxDynamicWorkerIdling();
      sc.setListenerBacklog();

      sc.setMaxRequestTime();
      sc.setMaxRequestSize();

      version(Windows) { }
      else
      {
         sc.setWorkerUser();
         sc.setWorkerGroup();
      }

      sc.setHttpTimeout();

      sc.enableKeepAlive();

      sc.disableRemoteIp();

      sc.enableLoggerOverride();

      sc.disableServerSignature();

      sc.disableWorkersAutoReload();

      return sc;
   }

   /// Sets the minimum log level to display. The default is LogLevel.all.
   @safe ref ServerinoConfig setLogLevel(LogLevel level = LogLevel.all) return { daemonConfig.logLevel = level; return this; }

   /// Any non-zero value will cause the server to terminate immediately. If forceExit is true, the server will terminate even if retCode is 0.
   @safe ref ServerinoConfig setReturnCode(int retCode = 0, bool forceExit = false) return
   {
      this.forceExit = forceExit;
      this.returnCode = retCode;
      return this;
   }

   /// Sets the number of daemon instances (accept/event loops). Default is 1.
   @safe ref ServerinoConfig setDaemonInstances(size_t val = 1) return { daemonConfig.daemonInstances = val; return this;}

   /// Sets the maximum number of worker processes.
   @safe ref ServerinoConfig setMaxWorkers(size_t val = 5) return { daemonConfig.maxWorkers = val; return this; }

   /// Sets the minimum number of worker processes.
   @safe ref ServerinoConfig setMinWorkers(size_t val = 0) return  { daemonConfig.minWorkers = val; return this; }

   /// Same as setMaxWorkers(v); setMinWorkers(v);
   @safe ref ServerinoConfig setWorkers(size_t val) return { setMinWorkers(val); setMaxWorkers(val); return this; }

   /// Sets the maximum lifetime for a worker. After this duration, the worker is terminated.
   @safe ref ServerinoConfig setMaxWorkerLifetime(Duration dur = 6.hours) return  { workerConfig.maxWorkerLifetime = dur; return this; }

   /// Sets the maximum idle time for a worker. After this duration, the worker is terminated.
   @safe ref ServerinoConfig setMaxWorkerIdling(Duration dur = 1.hours) return  { workerConfig.maxWorkerIdling = dur; return this; }

   /// Automatic hot reload of workers when the main executable is modified. Be careful: daemon is not reloaded and its code (eg: config) is not updated.
   @safe ref ServerinoConfig enableWorkersAutoReload(bool enable = true) return { daemonConfig.autoReload = enable; return this; }

   /// Ditto
   @safe ref ServerinoConfig disableWorkersAutoReload() return { return enableWorkersAutoReload(false); }

   /***
      Max time a dynamic worker can be idle. After this time, worker is terminated.
      This is used only if the number of workers is greater than minWorkers.
   ***/
   @safe ref ServerinoConfig setMaxDynamicWorkerIdling(Duration dur = 60.seconds) return  { workerConfig.maxDynamicWorkerIdling = dur; return this; }

   /// Sets the maximum number of pending connections in the listener's backlog.
   @safe ref ServerinoConfig setListenerBacklog(int val = 2048) return                   { daemonConfig.listenerBacklog = val; return this; }

   /// Sets the maximum duration a request can take. After this time, the worker handling the request is terminated.
   @safe ref ServerinoConfig setMaxRequestTime(Duration dur = 5.seconds) return  { workerConfig.maxRequestTime = dur; return this; }

   /// Sets the maximum allowable size for a request. Requests exceeding this size will return a 413 error.
   @safe ref ServerinoConfig setMaxRequestSize(size_t bytes = 1024*1024*10) return     { daemonConfig.maxRequestSize = bytes;  return this;}

   /// For example: "www-data"
   @safe ref ServerinoConfig setWorkerUser(string s = string.init) return { workerConfig.user = s; return this; }
   /// For example: "www-data"
   @safe ref ServerinoConfig setWorkerGroup(string s = string.init) return { workerConfig.group = s; return this;}

   /// Sets the maximum duration the socket will wait for a request after the connection.
   @safe ref ServerinoConfig setHttpTimeout(Duration dur = 10.seconds) return { daemonConfig.maxHttpWaiting = dur; workerConfig.maxHttpWaiting = dur; return this;}

   /// Enables or disables the override of std.logger.
   @safe ref ServerinoConfig enableLoggerOverride(bool enable = true) return { daemonConfig.overrideLogger = enable; return this; }

   /// Ditto
   @safe ref ServerinoConfig disableLoggerOverride() return { daemonConfig.overrideLogger = false; return this; }

   /// Enable/Disable keep-alive for http/1.1
   @safe ref ServerinoConfig enableKeepAlive(bool enable = true, Duration timeout = 3.seconds) return { workerConfig.keepAlive = enable; daemonConfig.keepAliveTimeout = timeout; return this; }

   /// Ditto
   @safe ref ServerinoConfig enableKeepAlive(Duration timeout) return { enableKeepAlive(true, timeout); return this; }

   /// Ditto
   @safe ref ServerinoConfig disableKeepAlive() return { enableKeepAlive(false); return this; }

   /// Add a x-remote-ip header
   @safe ref ServerinoConfig enableRemoteIp(bool enable = true) return { daemonConfig.withRemoteIp = enable; return this; }

   ///
   @safe ref ServerinoConfig disableRemoteIp() return { return enableRemoteIp(false); }

   /// Enable/Disable serverino signature
   @safe ref ServerinoConfig enableServerSignature(bool enable = true) return { workerConfig.serverSignature = enable; return this; }

   /// Ditto
   @safe ref ServerinoConfig disableServerSignature() return { return enableServerSignature(false); }

   /// Add a new listener.
   @safe ref ServerinoConfig addListener(ListenerProtocol p = ListenerProtocol.IPV4)(string address, ushort port) return
   {
      enum LISTEN_IPV4 = (p == ListenerProtocol.IPV4 || p == ListenerProtocol.BOTH);
      enum LISTEN_IPV6 = (p == ListenerProtocol.IPV6 || p == ListenerProtocol.BOTH);

      try {
         static if(LISTEN_IPV4) daemonConfig.listeners ~= new Listener(daemonConfig.listeners.length, new InternetAddress(address, port));
         static if(LISTEN_IPV6) daemonConfig.listeners ~= new Listener(daemonConfig.listeners.length, new Internet6Address(address, port));
      } catch (Exception e) {
         import std.format : format;
         failedListeners ~=  format(`"%s:%d" (%s)`, address, port, e.msg);
      }

      return this;
   }

   /// Protocol used by listener
   enum ListenerProtocol
   {
      IPV4, /// Listen on IPV4
      IPV6, /// Listen on IPV6
      BOTH  /// Listen on both IPV4 and IPV6
   }

   package:

   void validate()
   {
      import std.string : join;

      if (daemonConfig.minWorkers > 1024)
         throw new Exception("Configuration error. Must be 0 <= minWorkers <= 1024");

      if (daemonConfig.maxWorkers == 0)
         throw new Exception("Configuration error. At least one worker is required");

      if (daemonConfig.minWorkers > daemonConfig.maxWorkers)
         throw new Exception("Configuration error. Must be minWorkers <= maxWorkers");

      if (daemonConfig.maxWorkers == 0 || daemonConfig.maxWorkers > 1024)
         throw new Exception("Configuration error. Must be 1 <= maxWorkers <= 1024");

      if (daemonConfig.daemonInstances == 0)
         throw new Exception("Configuration error. Must be 1 <= daemonInstances");

      version(Windows)
      {
         if (daemonConfig.daemonInstances > 1)
            throw new Exception("Configuration error. daemonInstances > 1 is not available on Windows");
      }

      version(Windows) {
         if (workerConfig.user.length > 0 || workerConfig.group.length > 0)
            throw new Exception("Configuration error. user/group is not available on Windows");
      }

      if (failedListeners.length > 0)
         throw new Exception("Configuration error. Cannot listen on " ~ failedListeners.join(", "));

      if (daemonConfig.listeners.length == 0)
         addListener("0.0.0.0", 8080);
   }

   DaemonConfig       daemonConfig;
   WorkerConfig       workerConfig;

   string[] failedListeners;

   int   returnCode;
   bool  forceExit;
}

// To avoid errors/mistakes copying data around
import std.typecons : Typedef;
package alias DaemonConfigPtr = Typedef!(DaemonConfig*);
package alias WorkerConfigPtr = Typedef!(WorkerConfig*);


package class Listener
{
   void onConnectionAvailable()
   {
      import serverino.communicator : Communicator;
      import serverino.daemon : now;

      // We have an incoming connection to handle
      Communicator communicator;

      // First: check if any idling communicator is available
      auto dead = Communicator.deads;

      if (dead !is null) communicator = dead;
      else communicator = new Communicator(config);

      communicator.lastRecv = now;
      communicator.setClientSocket(socket.accept());
   }

   @safe:

   @disable this();

   this(size_t index, Address address)
   {
      this.address = address;
      this.index = index;
   }

   DaemonConfigPtr config;
   Address  address;
   size_t   index;

   Socket   socket;
}

package struct WorkerConfig
{

   Duration    maxRequestTime;
   Duration    maxHttpWaiting;
   Duration    maxWorkerLifetime;
   Duration    maxWorkerIdling;
   Duration    maxDynamicWorkerIdling;

   bool        keepAlive;
   string      user;
   string      group;

   bool        serverSignature;

}

package struct DaemonConfig
{
   LogLevel    logLevel;
   size_t      maxRequestSize;
   Duration    maxHttpWaiting;
   Duration    keepAliveTimeout;
   size_t      daemonInstances;
   size_t      minWorkers;
   size_t      maxWorkers;
   int         listenerBacklog;
   bool        withRemoteIp;
   bool        overrideLogger;
   bool        autoReload;
   Listener[]  listeners;
}
