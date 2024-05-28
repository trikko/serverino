/*
Copyright (c) 2023-2024 Andrea Fontana

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

module app;

import serverino;
import tagged;

import std;

mixin ServerinoMain!tagged;

@onDaemonStart void run_tests()
{
   import core.thread;
   import serverino.daemon;
   import core.stdc.stdlib : exit;

   new Thread({

      Thread.getThis().isDaemon = true;

      // Is serverino ready?
      while(!Daemon.bootCompleted)
         Thread.sleep(10.msecs);

      // Run the tests
      try {
         test();
         writeln("All tests passed!");
      }
      catch (Throwable t)
      {
         writeln("Test failed");
         writeln(t);
         exit(-1);
      }

      Daemon.shutdown();

   }).start();
}

@endpoint @priority(15000) @route!"/servefile"
void serve_file(Request r, Output o)
{
   import std.file : write;
   write("test_serverino_file.json", `{"test":1}`);
   o.serveFile("test_serverino_file.json");
}

@endpoint @priority(15000) @route!"/big-data"
void big_data(Request r, Output o)
{
   iota(64_000).each!(i => o ~= "Hello World!");
}

@endpoint @priority(15000) @route!"/headers-editing"
void headers_editing(Request r, Output o)
{
   o.status = 500;
   o ~= "Hello World!";
   o.addHeader("Content-Type", "text/plain");
   o.status = 200;
   o = false;
}

@endpoint @priority(15000) @route!"/set cookies"
void cookie_test(Request r, Output o)
{
   o.setCookie(
      Cookie("test1", "value")
      .domain("cookie.localhost")
      .path("/")
      .secure(false)
      .httpOnly(false)
      .sameSite(Cookie.SameSite.Lax)
   );

   o.setCookie(
      Cookie("test2", "value")
      .secure(false)
      .sameSite(Cookie.SameSite.None)
   );

   o.setCookie(
      Cookie("test3", "value")
      .maxAge(10.seconds)
      .secure(false)
   );

   o.setCookie(
      Cookie("test4", "value")
      .httpOnly()
      .secure(true)
   );

   o.setCookie(
      Cookie("test5", "value")
      .domain("cookie.localhost")
      .path("/")
      .secure(false)
      .httpOnly(false)
      .sameSite(Cookie.SameSite.Lax)
      .invalidate()
   );

   Cookie c = Cookie.init;
   c.secure();

   assertThrown(o.setCookie(c));

}

@endpoint @priority(15000) @route!"/test_content_type"
void test_content_type(Request r, Output o)
{
   o ~= r.body.contentType;
}

@endpoint @priority(10000) @route!"/hello_routing"
void test_routing_1(Request r, Output o)
{
   JSONValue v = parseJSON(`{"route" : "hello"}`);
   o.addHeader("content-type", "application/json");
   o ~= v.toString();
}

@endpoint @priority(10000)
@route!(r => r.path == "/world_routing")
@route!(r => r.path == "/blah_routing")
void test_routing_2(Request r, Output o)
{
   JSONValue v = parseJSON(`{"route" : "world"}`);
   o.addHeader("content-type", "application/json");
   o ~= v.toString();
}


@endpoint @priority(12000)
@route!(r => r.get.read("key") == "value" )
void test_routing_3(Request r, Output o)
{
   JSONValue v = parseJSON(`{"route" : "get"}`);
   o.addHeader("content-type", "application/json");
   o ~= v.toString();
}

@endpoint @priority(5)
void json(Request r, Output o)
{
   if (r.path != "/json/dump/test") return;

   o.addHeader("content-type", "application/json");

   JSONValue v = parseJSON("{}");

   v.object["get"] = r.get.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
   v.object["post"] = r.post.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
   v.object["cookie"] = r.cookie.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
   v.object["headers"] = r.header.data.byKeyValue.map!(x => x.key ~ ":" ~ x.value).array;
   v.object["method"] = r.method.to!string.toUpper;
   v.object["host"] = r.host;
   v.object["path"] = r.path;
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


@endpoint @priority(5)
void test_1(Request r, Output o)
{
   if (r.path == "/401")
      o.status = 401;
}

@endpoint @priority(5)
void test_2(Request r, Output o)
{
   if (r.path != "/test_get") return;

   o.addHeader("content-type", "text-plain");
   o ~= r.get.read("hello", "world");
   o ~= r.get.read("hllo", "world");
}

@endpoint @priority(5)
void test_3(Request r, Output o)
{
   if (r.path != "/long") return;

   import core.thread;

   Thread.sleep(10000.msecs);

}

@onServerInit
ServerinoConfig conf()
{
   return ServerinoConfig
      .create()
      .setMaxRequestTime(1.seconds)
      .setMaxRequestSize(2000)
      .addListener("0.0.0.0", 8080)
      .addListener("0.0.0.0", 8081)
      .setWorkers(4);
}

void test()
{


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
      assert(j["path"].str == "/json/dump/test");
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
      assert(j["path"].str == "/json/dump/test");
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
      assert(http.statusLine.code == 422);
   }

   {
      assert(get("http://localhost:8080") == "[5, 3]");
   }

   assert(get("http://localhost:8080/test_get?hello=123") == "123world");
   assert(get("http://localhost:8081/test_get?hello=123") == "123world");

   {
      auto http = HTTP("http://localhost:8080/401");
      http.perform();
      assert(http.statusLine.code == 401);
   }


   {
      string body;
      auto http = HTTP("http://localhost:8080/error");
      http.onReceive = (ubyte[] data) { body ~= data; return data.length; };
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

   {
      string content;
      auto http = HTTP("http://localhost:8080/hello_routing");
      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();
      assert(http.statusLine.code == 200);

      auto j = parseJSON(content);
      assert(j["route"].str == "hello");
   }

   {
      string content;
      auto http = HTTP("http://localhost:8080/blah_routing");
      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();
      assert(http.statusLine.code == 200);

      auto j = parseJSON(content);
      assert(j["route"].str == "world");
   }

   {
      string content;
      auto http = HTTP("http://localhost:8080/blah_routing");
      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();
      assert(http.statusLine.code == 200);

      auto j = parseJSON(content);
      assert(j["route"].str == "world");
   }

   {
      string content;
      auto http = HTTP("http://localhost:8080/blah_routing?key=value");
      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();
      assert(http.statusLine.code == 200);

      auto j = parseJSON(content);
      assert(j["route"].str == "get");
   }

   // Post content-type tests
   {
      string request = "POST /test_content_type HTTP/1.0\r\nContent-Type:   \r\nHost: localhost:57123\r\nUser-Agent: curl/7.81.0\r\nAccept: */*\r\n\r\n123";
      auto socket = new TcpSocket();
      socket.connect(new InternetAddress("localhost", 8080));
      socket.send(request);

      ubyte[4096] buffer;
      auto r = socket.receive(buffer[]);
      socket.close();

      auto responseLines = (cast(string)(buffer[0..r])).split("\r\n");
      assert(responseLines[0] == "HTTP/1.0 400 Bad Request");
   }

   {
      string request = "POST /test_content_type HTTP/1.0\r\nHost: localhost:57123\r\nUser-Agent: curl/7.81.0\r\nAccept: */*\r\n\r\n123";
      auto socket = new TcpSocket();
      socket.connect(new InternetAddress("localhost", 8080));
      socket.send(request);

      ubyte[4096] buffer;
      auto r = socket.receive(buffer[]);
      socket.close();

      auto responseLines = (cast(string)(buffer[0..r])).split("\r\n");
      assert(responseLines[0] == "HTTP/1.0 200 OK");
      assert(responseLines[$-1] == "application/octet-stream");
   }

   {
      string request = "POST /test_content_type HTTP/1.0\r\nContent-Type:  blah/blah\r\nHost: localhost:57123\r\nUser-Agent: curl/7.81.0\r\nAccept: */*\r\n\r\n123";
      auto socket = new TcpSocket();
      socket.connect(new InternetAddress("localhost", 8080));
      socket.send(request);

      ubyte[4096] buffer;
      auto r = socket.receive(buffer[]);
      socket.close();

      auto responseLines = (cast(string)(buffer[0..r])).split("\r\n");
      assert(responseLines[0] == "HTTP/1.0 200 OK");
      assert(responseLines[$-1] == "blah/blah");
   }

   ///Authorization Base64 Test
   {
      string content;

      auto http = HTTP("http://myuser@127.0.0.1:8080/json/dump/test");
      http.method = HTTP.Method.post;
      http.addRequestHeader("Authorization", "Basic msnmsknkjs");
      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();

      auto j = parseJSON(content);
      assert(j["method"].str == "POST");
      assert(j["path"].str == "/json/dump/test");
      assert(j["host"].str == "127.0.0.1:8080");
      assert(j["username"].str ==  string.init);
      assert(j["password"].str ==  string.init);

      assert(http.statusLine.code == 200);
   }

   //Blank space on Content-Disposition in multipart/form-data

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
Content-Disposition: form-data; name=\"myfile\"; filename=\"file1.txt\";\"   \"\r
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
      assert(j["path"].str == "/json/dump/test");
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

   // Check cookies
   {
      string[] cookies;

      auto http = HTTP("http://myuser@127.0.0.1:8080/set%20cookies");
      http.onReceiveHeader((key, value) { if (key.toLower == "set-cookie") cookies ~= value.to!string; });
      http.onReceive = (ubyte[] data) { return data.length; };
      http.perform();

      assert(cookies.canFind("test1=value; path=%2F; domain=cookie.localhost; SameSite=Lax"));
      assert(cookies.canFind("test2=value; SameSite=None; Secure"));
      assert(cookies.canFind("test3=value; Max-Age=10"));
      assert(cookies.canFind("test4=value; Secure; HttpOnly"));
      assert(cookies.canFind("test5=; Max-Age=-1; path=%2F; domain=cookie.localhost; SameSite=Lax"));
   }

   // Headers editing
   {
      string content;

      auto http = HTTP("http://127.0.0.1:8080/headers-editing");
      http.onReceiveHeader((key, value) {
         if (key.toLower == "content-type") assert(value == "text/plain");
         if (key.toLower == "content-length") assert(value == "0");
      });

      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();

      assert(content.length == 0);
      assert(http.statusLine.code == 200);
   }

   // Big
   {
      string content;

      auto http = HTTP("http://127.0.0.1:8080/big-data");
      http.onReceive = (ubyte[] data) { content ~= data; return data.length; };
      http.perform();

      assert(content.length == "Hello World!".length * 64_000);
      assert(http.statusLine.code == 200);
   }

   // ServeFile
   {
      import std.stdio : remove;

      bool hasContentType = false;

      auto http = HTTP("http://localhost:8080/servefile");
      http.onReceiveHeader((key, value)
      {
         if (key.toLower == "content-type")
         {
            hasContentType = true;
            assert(value == "application/json");
         }
      });

      http.onReceive = (ubyte[] data) { return data.length; };

      http.perform();

      assert(hasContentType == true);

      remove("test_serverino_file.json");

   }
}