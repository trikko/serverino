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

/// Configuration module for serverino.
module serverino.config;

import std.experimental.logger : LogLevel;
import std.socket : Socket, InternetAddress, Internet6Address, Address;
import std.stdio : File;
import std.datetime : Duration, seconds, hours, msecs;
import std.traits : ReturnType;

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

import serverino.interfaces : Request;

/++ UDA. You can use to filter requests using a function `bool(Request request) { }`
+ Example:
+ ---
+ @endpoint
+ @route!(x => x.uri.startsWith("/api"))
+ void api(Request r, Output o) { ... }
+ ---
+/
public struct route(alias T)
{
   static bool apply(const Request r) { return T(r); }
}

private template compareUri(string _uri)
{
   import std.uri : encode;
   enum compareUri = (const Request r){
      static assert(_uri[0] == '/', "Every route must begin with a '/'");
      return r.uri == _uri.encode();
   };
}

/++ UDA. You can use to filter requests using a uri.
+ Example:
+ ---
+ @endpoint
+ @route!"/hello.html"
+ void api(Request r, Output o) { ... }
+ ---
+/
public alias route(string uri) = route!(r => compareUri!uri(r));

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

      return sc;
   }

   /// Min log level to display. Default == LogLevel.all
   @safe ref ServerinoConfig setLogLevel(LogLevel level = LogLevel.all) return { daemonConfig.logLevel = level; return this; }

   /// Every value != 0 is used to terminate server immediatly.
   @safe ref ServerinoConfig setReturnCode(int retCode = 0) return { returnCode = retCode; return this; }
   /// Max number of workers
   @safe ref ServerinoConfig setMaxWorkers(size_t val = 5) return { daemonConfig.maxWorkers = val; return this; }
   /// Min number of workers
   @safe ref ServerinoConfig setMinWorkers(size_t val = 5) return  { daemonConfig.minWorkers = val; return this; }

   /// Same as setMaxWorkers(v); setMinWorkers(v);
   @safe ref ServerinoConfig setWorkers(size_t val) return { setMinWorkers(val); setMaxWorkers(val); return this; }

   /// Max time a worker can live. After this time, worker is terminated.
   @safe ref ServerinoConfig setMaxWorkerLifetime(Duration dur = 6.hours) return  { workerConfig.maxWorkerLifetime = dur; return this; }

   /// Max time a worker can be idle. After this time, worker is terminated.
   @safe ref ServerinoConfig setMaxWorkerIdling(Duration dur = 1.hours) return  { workerConfig.maxWorkerIdling = dur; return this; }

   /***
      Max time a dynamic worker can be idle. After this time, worker is terminated.
      This is used only if the number of workers is greater than minWorkers.
   ***/
   @safe ref ServerinoConfig setMaxDynamicWorkerIdling(Duration dur = 10.seconds) return  { workerConfig.maxDynamicWorkerIdling = dur; return this; }

   /// Max number of pending connections
   @safe ref ServerinoConfig setListenerBacklog(int val = 2048) return                   { daemonConfig.listenerBacklog = val; return this; }

   /// Max time a request can take. After this time, worker is terminated.
   @safe ref ServerinoConfig setMaxRequestTime(Duration dur = 5.seconds) return  { workerConfig.maxRequestTime = dur; return this; }

   /// Max size of a request. If a request is bigger than this value, error 413 is returned.
   @safe ref ServerinoConfig setMaxRequestSize(size_t bytes = 1024*1024*10) return     { daemonConfig.maxRequestSize = bytes;  return this;}

   version(Windows) { }
   else
   {
   /// For example: "www-data"
   @safe ref ServerinoConfig setWorkerUser(string s = string.init) return { workerConfig.user = s; return this; }
   /// For example: "www-data"
   @safe ref ServerinoConfig setWorkerGroup(string s = string.init) return { workerConfig.group = s; return this;}
   }

   /// How long the socket will wait for a request after the connection?
   @safe ref ServerinoConfig setHttpTimeout(Duration dur = 10.seconds) return { daemonConfig.maxHttpWaiting = dur; workerConfig.maxHttpWaiting = dur; return this;}

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

   /// Add a new listener.
   @safe ref ServerinoConfig addListener(ListenerProtocol p = ListenerProtocol.IPV4)(string address, ushort port) return
   {
      enum LISTEN_IPV4 = (p == ListenerProtocol.IPV4 || p == ListenerProtocol.BOTH);
      enum LISTEN_IPV6 = (p == ListenerProtocol.IPV6 || p == ListenerProtocol.BOTH);

      static if(LISTEN_IPV4) daemonConfig.listeners ~= Listener(daemonConfig.listeners.length, new InternetAddress(address, port));
      static if(LISTEN_IPV6) daemonConfig.listeners ~= Listener(daemonConfig.listeners.length, new Internet6Address(address, port));

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

      if (daemonConfig.minWorkers > 1024)
         throw new Exception("Configuration error. Must be 0 <= minWorkers <= 1024");

      if (daemonConfig.maxWorkers == 0)
         throw new Exception("Configuration error. At least one worker is required");

      if (daemonConfig.minWorkers > daemonConfig.maxWorkers)
         throw new Exception("Configuration error. Must be minWorkers <= maxWorkers");

      if (daemonConfig.maxWorkers == 0 || daemonConfig.maxWorkers > 1024)
         throw new Exception("Configuration error. Must be 1 <= maxWorkers <= 1024");

      if (daemonConfig.listeners.length == 0)
         addListener("0.0.0.0", 8080);
   }

   DaemonConfig       daemonConfig;
   WorkerConfig       workerConfig;

   int returnCode;
}

// To avoid errors/mistakes copying data around
import std.typecons : Typedef;
package alias DaemonConfigPtr = Typedef!(DaemonConfig*);
package alias WorkerConfigPtr = Typedef!(WorkerConfig*);

package struct Listener
{
   @safe:

   @disable this();

   this(size_t index, Address address)
   {
      this.address = address;
      this.index = index;
   }

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

}

package struct DaemonConfig
{
   LogLevel    logLevel;
   size_t      maxRequestSize;
   Duration    maxHttpWaiting;
   Duration    keepAliveTimeout;
   size_t      minWorkers;
   size_t      maxWorkers;
   int         listenerBacklog;
   bool        withRemoteIp;

   Listener[]  listeners;
}
