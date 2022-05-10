module serverino.tests.simple;

version(unittest):

import serverino.tests.common;

void simple(Request r, Output o) { o ~= "Hello World!"; }

unittest
{
    import std.net.curl;

    mixin ServerinoTest;
    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/") == "Hello World!");
}