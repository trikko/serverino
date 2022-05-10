module serverino.tests.tagged;

version(unittest):

import serverino.tests.common;

@endpoint
void test_1(Request r, Output o) { o ~= "1"; }

@endpoint @priority(-1)
void test_2(Request r, Output o) { o ~= "2"; }

@endpoint @priority(3)
void test_3(Output o) { o ~= "3"; }

@endpoint @priority(2)
void test_4(Request r, Output o) { o ~= "4"; }

@endpoint @priority(4)
void test_5(Request r) { return; }


unittest
{
    import std.net.curl;

    mixin ServerinoTest;
    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/") == "3");
}