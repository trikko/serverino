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

module tagged;

import serverino;
import std.conv : to;

int[] history;

@endpoint
void test_1(Request r, Output o) { if (r.path == "/error") return; history ~= 1; o ~= "1"; }

@endpoint @priority(-1)
void test_2(Request r, Output o) { if (r.path == "/error") return; history ~= 2; o ~= "2"; }

@endpoint @priority(3)
void test_3(Request r, Output o) { if (r.path == "/error") return; history ~= 3; o ~= history.to!string; }

@endpoint @priority(2)
void test_4(Request r, Output o) { if (r.path == "/error") return;  history ~= 4; o ~= "4"; }

@endpoint @priority(4)
void test_5(Request r, Output o) { history ~= 5; }

// Functions missing the @endpoint attribute
@priority(4) void wrong_function(Request r) { return; }
@route!"/hello" void wrong_function_2(Request r) { return; }