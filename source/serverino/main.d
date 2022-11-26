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

module serverino.main;

import serverino;

import std.experimental.logger : Logger, LogLevel;
import std.stdio : File, stderr;
import std.compiler : version_minor;

class CustomLogger : Logger
{

   static if (version_minor > 100)
   {
      this(LogLevel lv) shared
      {
         super(lv);
      }
   }
   else {
      this(LogLevel lv)
      {
         super(lv);
      }
   }

   @trusted
   override void writeLogMsg(ref LogEntry payload)
   {
      import std.process : environment, thisProcessID;
      import std.conv : to;

      enum LLSTR = [
         LogLevel.all : "[\x1b[1ml\x1b[0m]", LogLevel.trace : "[\x1b[1;32mt\x1b[0m]",
         LogLevel.info : "[\x1b[1;32mi\x1b[0m]", LogLevel.warning : "[\x1b[1;33mw\x1b[0m]",
         LogLevel.critical : "[\x1b[1;31mc\x1b[0m]", LogLevel.fatal : "[\x1b[1;31mf\x1b[0m]",
      ];

      import std.path : baseName;
      import std.conv : text;
      import std.format : format;

      string t = payload.timestamp.toISOExtString;
      string msg = payload.msg;

      if(payload.logLevel >= LogLevel.critical)
         msg = "\x1b[1;31m" ~ msg ~ "\x1b[0m";

      string intro;

      if (environment.get("SERVERINO_DAEMON") == null)
      {
         version(Windows){ intro = "\x1b[1m-\x1b[0m "; }
         else { intro = "\x1b[1m★\x1b[0m "; }
      }
      else {
         import std.stdio : write, stderr;
         import std.string : indexOf;

         size_t seed = thisProcessID;

         auto r = ((seed*123467983)%15+1)     * 255/15;
         auto g = ((r*seed*123479261)%15+1)   * 255/15;
         auto b = ((g*seed*123490957)%15+1)   * 255/15;

         version(Windows){ intro = text("\x1b[38;2;", r, ";", g, ";", b,"mD\x1b[0m "); }
         else { intro = text("\x1b[38;2;", r, ";", g, ";", b,"m■\x1b[0m "); }

      }

      intro ~= format("[%06d]", thisProcessID);
      auto str = text(intro, " ", LLSTR[payload.logLevel], " \x1b[1m", t[0..10]," ", t[11..16], "\x1b[0m ", "[", baseName(payload.file),":",format("%04d", payload.line), "] ", msg, "\n");
      stderr.write(str);
   }

   private File outputStream;
}

template ServerinoMain(Modules...)
{
   mixin ServerinoLoop!Modules;

   int main(string[] args)
   {
      return mainServerinoLoop(args);
   }
}

template ServerinoLoop(Modules...)
{
   import std.meta : AliasSeq;
   import std.traits : moduleName;

   alias allModules = AliasSeq!(mixin(moduleName!mainServerinoLoop), Modules);

   static assert (moduleName!mainServerinoLoop != "main", "Please, don't use `main` as module name.");

   static foreach(m; allModules)
      static assert(__traits(isModule, m), "All ServerinoMain params must be modules");

   int mainServerinoLoop(string[] args)
   {
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

      return wakeServerino!allModules(config);
   }
}


int wakeServerino(Modules...)(ref ServerinoConfig config)
{
   import std.experimental.logger.core;
   import std.compiler : version_major;

   static if (version_minor > 100)
      sharedLog = new shared CustomLogger(LogLevel.all);
   else
      sharedLog = new CustomLogger(LogLevel.all);

   if (config.returnCode != 0)
      return config.returnCode;

   config.validate();

   DaemonConfigPtr daemonConfig = &config.daemonConfig;
   WorkerConfigPtr workerConfig = &config.workerConfig;

   // Let's wake up the daemon
   import serverino.daemon;
   import serverino.worker;
   import std.process : environment;

   if (environment.get("SERVERINO_DAEMON") == null) Daemon.instance.wake(daemonConfig);
	else Worker.instance.wake!Modules(workerConfig);

   return 0;
}