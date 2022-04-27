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

module serverino.common;

import core.sys.posix.unistd;
import core.stdc.stdlib;
import core.sys.posix.signal; 
import std.socket;
import std.stdio : File;
import std.datetime : Duration, dur;
import std.traits : ReturnType;

package enum SERVERINO_MAJOR     = 0;
package enum SERVERINO_MINOR     = 1;
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
   @safe:

   ///
   enum ListenerProtocol
   {
      IPV4,
      IPV6,
      BOTH
   }
   
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

      return sc;
   }

   void setReturnCode(int retCode = 0) { returnCode = retCode; }  /// Every value != 0 is used to terminate server immediatly.
   void setMaxWorkers(size_t val = 5)  { daemonConfig.maxWorkers = val; } /// Max number of workers 
   void setMinWorkers(size_t val = 3)  { daemonConfig.minWorkers = val; } /// Min number of workers 
   
   void setWorkers(size_t val) { setMinWorkers(val); setMaxWorkers(val); } /// Same as setMaxWorkers(v); setMinWorkers(v);

   void setMaxWorkerLifetime(Duration dur = 1.dur!"hours")  { daemonConfig.maxWorkerLifetime = dur; } /// 
   void setMaxWorkerIdling(Duration dur = 5.dur!"minutes")  { daemonConfig.maxWorkerIdling = dur; } ///  
   void setListenerBacklog(int val = 20)                    { daemonConfig.listenerBacklog = val; } ///

   void setMaxRequestTime(Duration dur = 5.dur!"seconds")   { daemonConfig.maxRequestTime = dur; }   ///
   void setMaxRequestSize(size_t bytes = 1024*1024*10)      { workerConfig.maxRequestSize = bytes; } ///
   
   void setWorkerUser(string s = string.init)  { workerConfig.user = s; }  /// For example: www-data
   void setWorkerGroup(string s = string.init) { workerConfig.group = s; } /// For example: www-data

   /// Add a new listener. Https protocol is used if certPath and privkeyPath are set.
   void addListener(ListenerProtocol p = ListenerProtocol.IPV4)(string address, ushort port, string certPath = string.init, string privkeyPath = string.init) 
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

   package void validate()
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

   package DaemonConfig       daemonConfig;
   package WorkerConfig       workerConfig;
   package CertData[size_t]   certsData;

   package int returnCode;
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
   size_t maxRequestSize;
   string user;
   string group;

   CertDataPtr certsData;
}

package struct DaemonConfig
{
    size_t   minWorkers;
    size_t   maxWorkers;
    int      listenerBacklog;

    Duration maxWorkerLifetime;
    Duration maxWorkerIdling;

    Duration maxRequestTime;

    Listener[]    listeners;
    CertDataPtr   certsData;
}

package struct WorkerInfo
{
    pid_t   pid;
    Socket  ipcSocket;
    File    pipe;
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
         data.command == "RQST"
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