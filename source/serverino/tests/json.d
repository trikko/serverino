module serverino.tests.json;

version(unittest):
import serverino.tests.common;
import std;

@endpoint
void json(Request r, Output o)
{
    if (r.uri != "/json/dump/test") return;

    o.addHeader("content-type", "application/json");

    JSONValue v = parseJSON("{}");

    v.object["get"] = r.get.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
    v.object["post"] = r.post.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
    v.object["cookie"] = r.cookie.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
    v.object["headers"] = r.header.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
    v.object["protocol"] = r.protocol;
    v.object["method"] = r.method.to!string.toUpper;
    v.object["host"] = r.host;
    v.object["uri"] = r.uri;
    v.object["username"] = r.user;
    v.object["password"] = r.password;
    v.object["content-type"] = r.body.contentType;
    v.object["content-body"] = r.body.data;

    v.object["form-file"] = JSONValue[].init;
    v.object["form-data"] = JSONValue[].init;

    foreach(k,val; r.form.data)
    {
        if (val.isFile) v.object["form-file"].array ~= JSONValue("%s,%s,%s,%s".format(k, val.filename, val.contentType, readText(val.path)));
        else v.object["form-data"].array ~= JSONValue("%s,%s,%s".format(k, val.contentType, cast(const char[])val.data));
    }

    o ~= v.toPrettyString();
}

unittest
{
    mixin ServerinoTest;
    runOnBackgroundThread();
    scope(exit) terminateBackgroundThread();

    {
        string content;

        auto http = HTTP("http://myuser:mypassword@localhost:8080/json/dump/test?hello=123&world");
        http.setPostData("test1=hello&test2=world", "application/x-www-form-urlencoded");
        http.method = HTTP.Method.post;
        http.addRequestHeader("Cookie", "a=value; b=value2; c=value3");
        http.addRequestHeader("X-random-header", "blah");
        http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
        http.perform();

        auto j = parseJSON(content);

        assert(j["method"].str == "POST");
        assert(j["protocol"].str == "http");
        assert(j["uri"].str == "/json/dump/test");
        assert(j["host"].str == "localhost:8080");

        assert(j["get"].array.map!(x=>x.str).array.sort.array == ["hello:123", "world:"]);
        assert(j["post"].array.map!(x=>x.str).array.sort.array == ["test1:hello", "test2:world"]);
        assert(j["cookie"].array.map!(x=>x.str).array.sort.array == ["a:value", "b:value2", "c:value3"]);

        assert(j["headers"].array.map!(x=>x.str).canFind("x-random-header:blah"));

        assert(j["username"].str == "myuser");
        assert(j["password"].str == "mypassword");

        assert(j["content-body"].str == "test1=hello&test2=world");
        assert(j["content-type"].str == "application/x-www-form-urlencoded");
    }

    {
        string content;
        string postBody =
"-----------------------------blahblahblah\r
Content-Disposition: form-data; name=\"field1\"\r
\r
first value\r
-----------------------------blahblahblah\r
Content-Disposition: form-data; name=\"field2\"\r
\r
second value\r
-----------------------------blahblahblah\r
Content-Disposition: form-data; name=\"myfile\"; filename=\"file1.txt\"\r
Content-Type: application/json\r
\r
{}
\r
-----------------------------blahblahblah--\r
";

        auto http = HTTP("http://myuser@127.0.0.1:8080/json/dump/test?");
        http.setPostData(postBody,"multipart/form-data; boundary=---------------------------blahblahblah");
        http.method = HTTP.Method.post;
        http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
        http.perform();

        auto j = parseJSON(content);

        assert(j["method"].str == "POST");
        assert(j["protocol"].str == "http");
        assert(j["uri"].str == "/json/dump/test");
        assert(j["host"].str == "127.0.0.1:8080");

        assert(j["get"].array.map!(x=>x.str).array.sort.array == []);
        assert(j["post"].array.map!(x=>x.str).array.sort.array == []);
        assert(j["cookie"].array.map!(x=>x.str).array.sort.array == []);

        assert(j["username"].str == "myuser");
        assert(j["password"].str == string.init);

        assert(j["form-data"].array.map!(x=>x.str).array.sort.array == ["field1,text/plain,first value", "field2,text/plain,second value"]);
        assert(j["form-file"].array.map!(x=>x.str).array.sort.array == ["myfile,file1.txt,application/json,{}\n"]);

        assert(j["content-type"].str == "multipart/form-data");
    }


    {
        string content;
        string postBody =
"-----------------------------blahblahblah\r
Content-Disposition: form-data; name=\"field1\"\r
\r\r"; // INVALID BODY

        auto http = HTTP("http://myuser@127.0.0.1:8080/json/dump/test?");
        http.setPostData(postBody,"multipart/form-data; boundary=---------------------------blahblahblah");
        http.method = HTTP.Method.post;
        http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
        http.perform();

        auto j = parseJSON(content);

        assert(j["post"].array.map!(x=>x.str).array.sort.array == []);
        assert(j["form-data"].array.map!(x=>x.str).array.sort.array == []);
        assert(j["form-file"].array.map!(x=>x.str).array.sort.array == []);
    }



}
