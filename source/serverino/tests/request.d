module serverino.tests.request;


version(unittest):
import serverino.tests.common;
import std;

@endpoint
void test_1(Request r, Output o)
{
    if (r.uri == "/401")
        o.status = 401;
}

@endpoint
void test_2(Request r, Output o)
{
    if (r.uri != "/test_get") return;

    o.addHeader("content-type", "text-plain");
    o ~= r.get.read("hello", "world");
    o ~= r.get.read("hllo", "world");
}

@endpoint
void test_3(Request r, Output o)
{
    if (r.uri != "/long") return;

    import core.thread;

    Thread.sleep(2000.dur!"msecs");

}


@onServerInit auto setup()
{
    ServerinoConfig sc = ServerinoConfig.create();

    sc.addListener("0.0.0.0", 8080);
    sc.addListener("0.0.0.0", 8081);
    sc.setMaxRequestSize(1024);
    sc.setMaxRequestTime(1.dur!"seconds");
    return sc;
}

unittest
{
    mixin ServerinoTest;
    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    assert(get("http://localhost:8080/test_get?hello=123") == "123world");
    assert(get("http://localhost:8081/test_get?hello=123") == "123world");

    {
        auto http = HTTP("http://localhost:8080/401");
        http.perform();
        assert(http.statusLine.code == 401);
    }


    {
        auto http = HTTP("http://localhost:8080/");
        http.onReceive = (ubyte[] data) { return data.length; };
        http.perform();
        assert(http.statusLine.code == 404);
    }

    {
        auto http = HTTP("http://localhost:8080/long");
        http.onReceive = (ubyte[] data) { return data.length; };
        http.perform();
        assert(http.statusLine.code == 504);
    }

    {
        auto http = HTTP("http://localhost:8080/test_get");
        http.postData = "hello".repeat(5000).join.to!string;
        http.onReceive = (ubyte[] data) { return data.length; };
        http.perform();
        assert(http.statusLine.code == 413);
    }

    {
        auto http = HTTP("http://localhost:8080/test_get");
        http.postData = "hello".repeat(100).join.to!string;
        http.onReceive = (ubyte[] data) { return data.length; };
        http.perform();
        assert(http.statusLine.code == 200);
    }
}
