/+
 + What this server is costing, read from /proc.
 +
 + Used by the footprint demo, by the telemetry stream and by the WebSocket
 + limiter, which needs to know how many connections are alive.
+/
module procinfo;

import std;

struct Measurement
{
   size_t memoryKb;     /// Proportional set size of the whole server, when available
   size_t processes;    /// The daemon plus everything it started
   size_t webSockets;   /// How many of those are serving a WebSocket
}

/+ What the whole server is costing right now.
 +
 + Pss is used rather than Rss: workers are forked, so most of their pages are
 + shared with the daemon and adding up Rss would count them many times over.
+/
Measurement measure()
{
   Measurement result;

   version(linux)
   {
      immutable group = groupOf(daemonPid);
      immutable exe = thisExePath;

      if (group == 0) return result;

      foreach(entry; dirEntries("/proc", SpanMode.shallow))
      {
         immutable name = entry.name.baseName;

         if (!name.all!isDigit) continue;

         immutable pid = name.to!size_t;

         // The daemon and everything it started share its process group.
         // The check on the executable keeps other instances out.
         if (groupOf(pid) != group) continue;
         if (!isOurs(pid, exe)) continue;

         result.processes++;
         result.memoryKb += memoryOf(pid);

         // Serverino names them "<program> / websocket [daemon: <pid>]".
         if (titleOf(pid).canFind("/ websocket")) result.webSockets++;
      }
   }

   return result;
}

/// Serverino tells every worker which process is the daemon.
size_t daemonPid()
{
   immutable exported = environment.get("SERVERINO_DAEMON_PID", "");

   if (!exported.empty)
   {
      try return exported.to!size_t;
      catch (Exception e) { }
   }

   return thisProcessID;
}

version(linux)
{
   /// The process group of a pid, or 0 if it cannot be read.
   size_t groupOf(size_t pid)
   {
      try
      {
         // /proc/<pid>/stat, after the ")": state, ppid, pgrp.
         // The name in between may contain spaces, hence the lastIndexOf.
         auto stat = readText("/proc/" ~ pid.to!string ~ "/stat");
         return stat[stat.lastIndexOf(')') + 2 .. $].splitter(' ').drop(2).front.to!size_t;
      }
      catch (Exception e) { return 0; }
   }

   bool isOurs(size_t pid, string exe)
   {
      try return readLink("/proc/" ~ pid.to!string ~ "/exe") == exe;
      catch (Exception e) { return false; }
   }

   string titleOf(size_t pid)
   {
      try return readText("/proc/" ~ pid.to!string ~ "/cmdline").replace("\0", " ");
      catch (Exception e) { return string.init; }
   }

   size_t memoryOf(size_t pid)
   {
      immutable dir = "/proc/" ~ pid.to!string ~ "/";

      try
      {
         foreach(line; File(dir ~ "smaps_rollup").byLine)
            if (line.startsWith("Pss:"))
               return line.splitter.drop(1).front.to!size_t;
      }
      catch (Exception e) { }

      // No smaps_rollup (an old kernel, or no permission): resident size.
      try return readText(dir ~ "statm").splitter(' ').drop(1).front.to!size_t * 4;
      catch (Exception e) { return 0; }
   }
}
