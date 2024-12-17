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

module serverino.main;

import serverino;

import std.experimental.logger : Logger, LogLevel;
import std.stdio : File, stderr;
import std.compiler : version_minor;

// This is a custom logger for the serverino application
class ServerinoLogger : Logger
{
   static if (version_minor > 100) this(LogLevel lv) shared { super(lv); }
   else this(LogLevel lv) { super(lv); }

   @trusted
   override void writeLogMsg(scope ref LogEntry payload)
   {
      import std.path : baseName;
      import std.conv : text;
      import std.format : format;

      string t = payload.timestamp.toISOExtString;
      string msg = payload.msg;

      if(payload.logLevel >= LogLevel.critical)
         msg = "\x1b[1;31m" ~ msg ~ "\x1b[0m";

      auto str = text(logPrefix, " ", LLSTR[payload.logLevel], " \x1b[1m", t[0..10]," ", t[11..16], "\x1b[0m ", "[", baseName(payload.file),":",format("%04d", payload.line), "] ", msg, "\n");
      stderr.write(str);
   }

   // A random color for the log
   shared static this()
   {
      import std.digest.sha : sha1Of;
      import std.process : thisProcessID;
      import std.conv : to, text;
      import std.algorithm : map;
      import std.array : array;
      import std.conv : text;
      import std.format : format;
      import std.process : environment;

      immutable int        processId   = thisProcessID;
      immutable uint[3]    logColor    = sha1Of(processId.to!string)[0..3].map!(x => (x.to!uint/20 + 1)*19).array;

      LLSTR = [
         LogLevel.all : "[\x1b[1ml\x1b[0m]",
         LogLevel.trace : "[\x1b[1;32mt\x1b[0m]", LogLevel.info : "[\x1b[1;32mi\x1b[0m]",
         LogLevel.warning : "[\x1b[1;33mw\x1b[0m]", LogLevel.error : "[\x1b[1;31me\x1b[0m]",
         LogLevel.critical : "[\x1b[1;31mc\x1b[0m]", LogLevel.fatal : "[\x1b[1;31mf\x1b[0m]"
      ];

      string prefix;

      if (ServerinoProcess.isDynamicComponent == false)
      {
         version(Windows){ prefix = "\x1b[1m*\x1b[0m "; }
         else { prefix = "\x1b[1m*\x1b[0m "; }
      }
      else {
         version(Windows){ prefix = text("\x1b[48;2;", logColor[0], ";", logColor[1], ";", logColor[2],"m \x1b[0m "); }
         else { prefix = text("\x1b[48;2;", logColor[0], ";", logColor[1], ";", logColor[2],"m \x1b[0m "); }
      }

      prefix ~= format("[%06d]", processId);
      logPrefix = prefix;
   }

   private static immutable string[LogLevel]   LLSTR;
   private static immutable string             logPrefix;
   private File outputStream;
}

enum OnMainThread;      /// Let serverino run in the main thread (default)
enum OnSecondaryThread; /// Let serverino run in a secondary thread

// This is the main entry point for the serverino application
template ServerinoMain(Modules...)
{
   mixin ServerinoLoop!Modules;

   int main(string[] args)
   {
      import std.base64 : Base64;
      if (!ServerinoProcess.isDaemon)
         args = (cast(string)Base64.decode(environment.get("SERVERINO_ARGS"))).split("\0");

      return mainServerinoLoop!OnMainThread(args);
   }
}

// This is the main loop for the serverino application
template ServerinoLoop(Modules...)
{
   import std.meta : AliasSeq;
   import std.traits : moduleName;

   alias allModules = AliasSeq!(mixin(moduleName!mainServerinoLoop), Modules);

   static assert (moduleName!mainServerinoLoop != "main", "Please, don't use `main` as module name.");

   static foreach(m; allModules)
      static assert(__traits(isModule, m), "All ServerinoMain params must be modules");

   int mainServerinoLoop(RunMode)(string[] args)
   {
      static if (is (RunMode == OnSecondaryThread)) enum runAsSecondaryThread = true;
      else static if (is (RunMode == OnMainThread)) enum runAsSecondaryThread = false;
      else static assert(0, "Invalid run mode. It must be `OnSecondaryThread` or `OnMainThread`");

      // Docker container has a too generous limit of open files, it slows down the server
      // NOTE: Workaround for #issue 24524
      // NOTE: Waiting for https://github.com/dlang/phobos/pull/8990
      version(Posix)
      {
         import core.sys.posix.sys.resource : rlimit, setrlimit, getrlimit, RLIMIT_NOFILE;
         import std.algorithm : min;

         rlimit rlim;
         getrlimit(RLIMIT_NOFILE, &rlim);

         // 16k seems to be a good value that balances performance and resources
         // until the issue is fixed
         rlim.rlim_cur = min(rlim.rlim_max, 16_384);

         setrlimit(RLIMIT_NOFILE, &rlim);
      }

      // Enable terminal colors on older windows
      version(Windows)
      {
         import core.sys.windows.windows;

         DWORD dwMode;
         HANDLE hOutput = GetStdHandle(STD_OUTPUT_HANDLE);

         GetConsoleMode(hOutput, &dwMode);
         dwMode |= ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
         SetConsoleMode(hOutput, dwMode);
      }

      import std.traits : getSymbolsByUDA, isFunction, ReturnType, Parameters;
      ServerinoConfig config = ServerinoConfig.create();

      // Call ServerinoConfig func(); or ServerinoConfig func(args);
      static foreach(m; allModules)
      {
         static foreach(f; getSymbolsByUDA!(m, onServerInit))
         {
            static assert(isFunction!f, "`" ~ __traits(identifier, f) ~ "` is marked with @onServerInit but it is not a function");
            static assert(is(ReturnType!f == ServerinoConfig), "`" ~ __traits(identifier, f) ~ "` is " ~ ReturnType!f.toString ~ " but should be `ServerinoConfig`");

            static if (is(Parameters!f == AliasSeq!(string[])))  config = f(args);
            else static if (is(Parameters!f == AliasSeq!()))  config = f();
            else static assert(0, "`" ~ __traits(identifier, f) ~ "` is marked with @onServerInit but it is not callable");

            static if (!__traits(compiles, hasSetup)) { enum hasSetup; }
            else static assert(0, "You can't mark more than one function with @onServerInit");
         }
      }

      static if (runAsSecondaryThread == false) return wakeServerino!allModules(config);
      else
      {
         import core.thread : Thread;
         if (ServerinoProcess.isDynamicComponent) return wakeServerino!allModules(config);
         else
         {
            new Thread({ Thread.getThis.isDaemon = true; wakeServerino!allModules(config); }).start();
            return 0;
         }
      }
   }
}


int wakeServerino(Modules...)(ref ServerinoConfig config)
{
   import std.experimental.logger : sharedLog;

   static if (version_minor > 100)
      sharedLog = new shared ServerinoLogger(config.daemonConfig.logLevel);
   else
      sharedLog = new ServerinoLogger(config.daemonConfig.logLevel);

   if (config.returnCode != 0)
      return config.returnCode;

   config.validate();

   DaemonConfigPtr daemonConfig = &config.daemonConfig;
   WorkerConfigPtr workerConfig = &config.workerConfig;

   // Let's wake up the daemon or the worker
   import serverino.daemon;
   import serverino.worker;
   import serverino.websocket;
   import std.process : environment;


   if (ServerinoProcess.isWorker) Worker.wake!Modules(workerConfig);
   else if (ServerinoProcess.isWebSocket) WebSocketWorker.wake!Modules();
   else Daemon.wake!Modules(daemonConfig);

   return 0;
}