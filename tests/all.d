/*
Copyright (c) 2023-2026 Andrea Fontana

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

// `dub test` builds the tests in tests/ and the examples, then runs the tests.
// The tests listen on port 8080: it must be free.
// The compiler is the one in $DC, or the one that built this file.
module tests.all;

import std.process;
import std.path : buildPath, dirName;
import std.stdio : writeln, stdout;
import std.algorithm : canFind;
import std.string : format;

private immutable root = __FILE_FULL_PATH__.dirName.dirName;

version(Posix) private enum https = true;
else private enum https = false;

// Runs a command from the root of the package, returns its output. Throws if it fails.
private string run(string[] cmd, string[string] env = null)
{
   writeln("> ", cmd);
   stdout.flush();
   auto r = execute(cmd, env, Config.none, size_t.max, root);
   assert(r.status == 0, format("%s: exit code %s\n%s", cmd, r.status, r.output));
   return r.output;
}

private string compiler()
{
   version(LDC) enum fallback = "ldc2";
   else version(GNU) enum fallback = "gdc";
   else enum fallback = "dmd";

   return environment.get("DC", fallback);
}

private void build(string path, string buildType = "debug")
{
   run(["dub", "build", "--root=" ~ path, "--compiler=" ~ compiler, "--build=" ~ buildType]);
}

// The binary of a test in tests/
private string binary(string name)
{
   version(Windows) return buildPath(root, "tests", name, name ~ ".exe");
   else return buildPath(root, "tests", name, name);
}

// Runs a test already built: it must end with "All tests passed!"
private void test(string name, string[string] env = null)
{
   auto cmd = [binary(name)];
   auto output = run(cmd, env);
   assert(output.canFind("All tests passed!"), format("%s: no \"All tests passed!\"\n%s", cmd, output));
   waitWorkers(name);
}

// The workers of a run can outlive it for a moment: wait for them before the next one
private void waitWorkers(string name)
{
   import core.thread : Thread;
   import core.time : seconds;

   foreach (i; 0 .. 30)
   {
      version(Windows) auto r = execute(["tasklist", "/FI", "IMAGENAME eq " ~ name ~ ".exe"]);
      else auto r = execute(["pgrep", "-x", name]);

      version(Windows) bool running = r.output.canFind(name ~ ".exe");
      else bool running = r.status == 0;

      if (!running) return;
      Thread.sleep(1.seconds);
   }

   writeln("Warning: ", name, " processes still running 30s after the end of the test");
}

unittest
{
   string[] tests = ["test-01", "test-02", "test-03", "test-05"];
   if (https) tests ~= "test-04";

   string[] examples = [
      "01_hello_world", "02_priority", "03_form", "04_html_dom", "05_websocket_echo",
      "06_websocket_noise_stream", "07_websocket_callback", "08_cmdline_args",
      "09_simple_session", "10_diet_ng_templates", "11_elemi_integration"
   ];
   if (https) examples ~= ["12_https", "13_letsencrypt"];

   // Everything is built first: a test runs only if all of them and all the examples compile
   foreach (t; tests)
      build(buildPath("tests", t));

   foreach (e; examples)
      build(buildPath("examples", e), e == "01_hello_world" || e == "12_https" || e == "13_letsencrypt" ? "release" : "debug");

   // Then the tests run (the examples don't)
   foreach (t; ["test-01", "test-02", "test-03"])
      test(t);

   if (https) test("test-04");

   foreach (workers; ["1", "2"])
      foreach (backlog; ["0", "1"])
         test("test-05", ["SERVERINO_TEST_WORKERS" : workers, "SERVERINO_TEST_BACKLOG" : backlog]);

   foreach (t; ["test-01", "test-02"])
      test(t, ["SERVERINO_TEST_BACKLOG" : "1"]);
}
