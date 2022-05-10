module serverino.tests.modules;

version(unittest):

import serverino.tests.common;

void test_1(Request r, Output o) { o ~= "1"; }

unittest
{
    import std.net.curl;

    // On this module we have a high priority function
    import serverino.tests.tagged;
    mixin ServerinoTest!(serverino.tests.tagged);

    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/") == "3");
}

unittest
{
    import std.net.curl;

    mixin ServerinoTest;

    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/") == "1");
}