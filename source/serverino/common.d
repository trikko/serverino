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

/// Common defs for workers and daemon
module serverino.common;

import core.sys.posix.unistd : pid_t;
import std.socket : Socket, InternetAddress, Address;
import std.stdio : File;
import std.datetime : Duration, dur;
import std.traits : ReturnType;

package enum SERVERINO_MAJOR     = 0;
package enum SERVERINO_MINOR     = 2;
package enum SERVERINO_REVISION  = 0;


public struct priority { long priority; } /// UDA. Set @endpoint priority

public enum endpoint;         /// UDA. Attach @endpoint to functions worker should call
public enum onWorkerStart;    /// UDA. Functions with @onWorkerStart attached are called when worker is started
public enum onWorkerStop;     /// UDA. Functions with @onWorkerStop attached are called when worker is stopped
public enum onServerInit;     /// UDA. SeeAlso:ServerinoConfig

/++
   Struct used to setup serverino.
   You must return this struct from a function with @onServerInit UDA attached.
---
@onServerInit
auto configure()
{
   auto config = ServerinoConfig.create();
   config.setWorkers(5);

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

      sc.setReturnCode();
      sc.setMaxWorkers();
      sc.setMinWorkers();
      sc.setMaxWorkerLifetime();
      sc.setMaxWorkerIdling();
      sc.setListenerBacklog();

      sc.setMaxRequestTime();
      sc.setMaxRequestSize();
      sc.setWorkerUser();
      sc.setWorkerGroup();
      sc.setWorkerMinBufferSize();
      sc.setWorkerMaxBufferSize();
      sc.setHttpTimeout();

      sc.enableKeepAlive();

      return sc;
   }

   /// Every value != 0 is used to terminate server immediatly.
   @safe void setReturnCode(int retCode = 0) { returnCode = retCode; }
   /// Max number of workers
   @safe void setMaxWorkers(size_t val = 5)  { daemonConfig.maxWorkers = val; }
   /// Min number of workers
   @safe void setMinWorkers(size_t val = 5)  { daemonConfig.minWorkers = val; }

   /// Same as setMaxWorkers(v); setMinWorkers(v);
   @safe void setWorkers(size_t val) { setMinWorkers(val); setMaxWorkers(val); }

   ///
   @safe void setMaxWorkerLifetime(Duration dur = 1.dur!"hours")  { workerConfig.maxWorkerLifetime = dur; }
   ///
   @safe void setMaxWorkerIdling(Duration dur = 1.dur!"minutes")  { workerConfig.maxWorkerIdling = dur; }
   ///
   @safe void setListenerBacklog(int val = 20)                    { daemonConfig.listenerBacklog = val; }

   ///
   @safe void setMaxRequestTime(Duration dur = 5.dur!"seconds")   { workerConfig.maxRequestTime = dur; }
   ///
   @safe void setMaxRequestSize(size_t bytes = 1024*1024*10)      { workerConfig.maxRequestSize = bytes; }

   /// For example: "www-data"
   @safe void setWorkerUser(string s = string.init)  { workerConfig.user = s; }
   /// For example: "www-data"
   @safe void setWorkerGroup(string s = string.init) { workerConfig.group = s; }

   @safe void setWorkerMinBufferSize(size_t sz = 1024*64)    { workerConfig.minBufferSize = sz; }
   @safe void setWorkerMaxBufferSize(size_t sz = 1024*1024)  { workerConfig.maxBufferSize = sz; }

   /// How long the socket will wait for a request after the connection?
   @safe void setHttpTimeout(Duration dur = 1.dur!"seconds") { daemonConfig.maxHttpWaiting = dur; workerConfig.maxHttpWaiting = dur; }

   /// Enable/Disable keep-alive for http/1.1
   @safe void enableKeepAlive(bool enable = true) { workerConfig.keepAlive = enable; }
   @safe void disableKeepAlive() { enableKeepAlive(false); }

   /// Add a new listener. Https protocol is used if certPath and privkeyPath are set.
   @safe void addListener(ListenerProtocol p = ListenerProtocol.IPV4)(string address, ushort port, string certPath = string.init, string privkeyPath = string.init)
   {

      if (certPath.length > 0 || privkeyPath.length > 0)
      {
         version(WithTLS) { }
         else { assert(0, "TLS is disabled. Use config=WithTLS with dub or set version=WithTLS."); }
      }

      enum LISTEN_IPV4 = (p == ListenerProtocol.IPV4 || p == ListenerProtocol.BOTH);
      enum LISTEN_IPV6 = (p == ListenerProtocol.IPV6 || p == ListenerProtocol.BOTH);

      static if(LISTEN_IPV4) daemonConfig.listeners ~= Listener(daemonConfig.listeners.length, new InternetAddress(address, port), certPath, privkeyPath);
      static if(LISTEN_IPV6) daemonConfig.listeners ~= Listener(daemonConfig.listeners.length, new Internet6Address(address, port), certPath, privkeyPath);
   }

   ///
   enum ListenerProtocol
   {
      IPV4,
      IPV6,
      BOTH
   }

   package:

   void validate()
   {
      if (daemonConfig.minWorkers == 0 || daemonConfig.minWorkers > 1024)
         throw new Exception("Configuration error. Must be 1 <= minWorkers <= 1024");

      if (daemonConfig.minWorkers > daemonConfig.maxWorkers)
         throw new Exception("Configuration error. Must be minWorkers <= maxWorkers");

      if (daemonConfig.maxWorkers == 0 || daemonConfig.maxWorkers > 1024)
         throw new Exception("Configuration error. Must be 1 <= maxWorkers <= 1024");

      if (daemonConfig.listeners.length == 0)
         addListener("0.0.0.0", 8080);

      foreach(idx, const l; daemonConfig.listeners)
      {
         if (l.isHttps)
         {
            import std.file : exists, readText;

            if (!exists(l.certPath))
               throw new Exception("Configuration error. " ~ l.certPath ~ " can't be read.");

            if (!exists(l.privkeyPath))
               throw new Exception("Configuration error. " ~ l.privkeyPath ~ " can't be read.");


            import std.string : representation;

            certsData[idx] = CertData
            (
               readText(l.certPath).representation,
               readText(l.privkeyPath).representation
            );
         }
      }

      daemonConfig.certsData = &certsData;
      workerConfig.certsData = &certsData;
   }

   DaemonConfig       daemonConfig;
   WorkerConfig       workerConfig;
   CertData[size_t]   certsData;

   int returnCode;
}

// To avoid errors/mistakes copying data around
import std.typecons : Typedef;
package alias DaemonConfigPtr = Typedef!(DaemonConfig*);
package alias WorkerConfigPtr = Typedef!(WorkerConfig*);
package alias CertDataPtr     = Typedef!(CertData[size_t]*);

package struct Listener
{
   @safe:

   @disable this();

   this(size_t index, Address address, string certPath = string.init, string privkeyPath = string.init)
   {
      this.address = address;
      this.privkeyPath = privkeyPath;
      this.certPath = certPath;
      this.index = index;
   }

   bool isHttps() const { return certPath.length > 0; }

   Address  address;
   string   certPath;
   string   privkeyPath;
   size_t   index;

   Socket   socket;
}

package struct CertData
{
   @safe this(const (ubyte[]) cert, const (ubyte[]) privkey)
   {
      this.certData.length = cert.length;
      this.privkeyData.length = privkey.length;

      this.certData[] = cert[];
      this.privkeyData[] = privkey[];
   }

   ubyte[] certData;
   ubyte[] privkeyData;
}

package struct WorkerConfig
{

   Duration    maxRequestTime;
   Duration    maxHttpWaiting;
   Duration    maxWorkerLifetime;
   Duration    maxWorkerIdling;

   bool        keepAlive;
   size_t      maxRequestSize;
   size_t      minBufferSize;
   size_t      maxBufferSize;
   string      user;
   string      group;

   CertDataPtr certsData;
}

package struct DaemonConfig
{
    Duration   maxHttpWaiting;
    size_t     minWorkers;
    size_t     maxWorkers;
    int        listenerBacklog;

    Listener[]    listeners;
    CertDataPtr   certsData;
}

package struct WorkerInfo
{
   bool     persistent;
   pid_t    pid;
   Socket   ipcSocket;
   File     pipe;
}

package union IPCMessage
{
   struct Data
   {
      ubyte[4]    magic = [0x19, 0x83, 0x05, 0x31];
      char[4]     command = "NOOP";
      size_t      payload = 0;
   }

   Data                 data;
   ubyte[Data.sizeof]   raw;

   void validate()
   {
      bool valid =
      (
         data.magic == [0x19, 0x83, 0x05, 0x31] &&
         (data.command == "RQST" || data.command == "ALIV" || data.command == "SWCH")
      );

      if (!valid)
         throw new Exception("Invalid message");
   }
}

package union IPCRequestMessage
{
   struct Data
   {
      bool    isHttps;
      bool    isIPV4;
      size_t  certIdx;
   }

   Data                 data;
   ubyte[Data.sizeof]   raw;
}