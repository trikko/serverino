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

module serverino.tests;

template ServerinoTest(Modules...)
{
   mixin ServerinoLoop!Modules;

   void main(string[] args)
   {
      import serverino.daemon;
      import core.thread : Thread;

      if (environment.get("SERVERINO_DAEMON") == null)
      {
         new Thread({
            import serverino.daemon;
            import core.thread;

            Thread.getThis().isDaemon = true;

            scope(exit) Daemon.instance.shutdown();
            while(!Daemon.isReady) { Thread.sleep(10.dur!"msecs");}

            try { test(); writeln("All tests passed!"); }
            catch (Throwable t)
            {
               writeln("Test failed");
               writeln(t);
            }

         }).start();
      }

      mainServerinoLoop(args);
   }
}