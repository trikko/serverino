module serverino.tests.order;

version(unittest):

import serverino.tests.common;

int[] history;

@endpoint
void test_1(Request r, Output o) { history ~= 1; }

@endpoint @priority(-15)
void test_2(Request r, Output o) { history ~= 2; }

@endpoint @priority(-7)
void test_3(Request r, Output o) { history ~= 3; }

@endpoint @priority(-9)
void test_4(Request r, Output o) { history ~= 4; }

@endpoint @priority(-2)
void test_5(Request r, Output o) { history ~= 5; }

@endpoint @priority(-30)
void test_6(Request r, Output o) { o ~= history; }

unittest
{
    import std.net.curl;
    mixin ServerinoTest;

    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/") == "[1, 5, 3, 4, 2]");
}