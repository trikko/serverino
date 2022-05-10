module serverino.tests.keepalive;


version(unittest):
import serverino.tests.common;
import std;

void test_1(Request r, Output o) { o ~= "HELLO"; }

__gshared bool enableKeepAlive;

@onServerInit auto setup()
{
    ServerinoConfig sc = ServerinoConfig.create();

    if (enableKeepAlive) sc.enableKeepAlive();
    else sc.disableKeepAlive();

    return sc;
}

unittest
{
    enableKeepAlive = true;

    mixin ServerinoTest;
    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    string headers;
    string content;

    auto http = HTTP("http://localhost:8080/");

    http.onReceiveHeader = (in char[] key, in char[] value) { headers ~= key~":"~value~"\n"; };
    http.onReceive = (ubyte[] data) { content ~= cast(const char[]) data; return data.length; };
    http.perform();

    assert(content == "HELLO");
    assert(headers.toLower.canFind("connection:keep-alive\n"));
}

unittest
{
    enableKeepAlive = false;

    mixin ServerinoTest;
    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    string headers;
    string content;

    auto http = HTTP("http://localhost:8080/");

    http.onReceiveHeader = (in char[] key, in char[] value) { headers ~= key~":"~value~"\n"; };
    http.onReceive = (ubyte[] data) { content ~= cast(const char[]) data; return data.length; };
    http.perform();

    assert(content == "HELLO");
    assert(headers.toLower.canFind("connection:close\n"));
}