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
void test_6(Request r, Output o) { import std.conv:to; o ~= history; o ~= "\n" ~ r.route().to!string; history.length = 0; }

@endpoint @priority(-50)
void test_7(Request r, Output o) { o ~= "This will not be called."; }

unittest
{
    import std.net.curl;
    mixin ServerinoTest;

    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/") == "[1, 5, 3, 4, 2]\n" ~ `["serverino.tests.order.test_1", "serverino.tests.order.test_5", "serverino.tests.order.test_3", "serverino.tests.order.test_4", "serverino.tests.order.test_2"]`);
    assert(get("http://localhost:8080/") == "[1, 5, 3, 4, 2]\n" ~ `["serverino.tests.order.test_1", "serverino.tests.order.test_5", "serverino.tests.order.test_3", "serverino.tests.order.test_4", "serverino.tests.order.test_2"]`);
}