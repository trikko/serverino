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

    import core.sys.posix.unistd : STDERR_FILENO, dup, dup2;
    import core.sys.posix.fcntl;

    import std.process : pipe;

    auto http = HTTP("http://localhost:8080/");
    http.onReceiveHeader = (in char[] key, in char[] value) { headers ~= key~":"~value~"\n"; };
    http.onReceive = (ubyte[] data) { content ~= cast(const char[]) data; return data.length; };
    http.verbose(true);

    stderr.flush();

    auto debugPipe = pipe();
    int stderrCopy = dup(STDERR_FILENO);
    dup2(debugPipe.writeEnd.fileno, STDERR_FILENO);
    int flags = fcntl(debugPipe.readEnd.fileno, F_GETFL, 0);
    fcntl(debugPipe.readEnd.fileno, F_SETFL, flags | O_NONBLOCK);

    http.perform();
    assert(content == "HELLO");
    content = string.init;
    http.perform();

    dup2(stderrCopy, STDERR_FILENO);

    bool reusingConnection = false;
    foreach(l; debugPipe.readEnd.byLine())
    {
        if (l.empty) break;
        if (l.canFind("Re-using existing connection"))
        {
            reusingConnection = true;
            break;
        }
    }

    assert(reusingConnection == true);
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