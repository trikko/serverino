/*
Copyright (c) 2023-2026 Andrea Fontana

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
module serverino.databuffer;

// Apparently this custom implementation has better performance than std.array.Appender
package struct DataBuffer(T)
{
   private:
   T[]      _data;
   size_t   _length;

   public:
   pragma(inline, true):

   void append(E...)(scope const E new_data) @trusted
   {
      static foreach(e; E)
         static if (!is(e : T[]))
            static assert(false, "DataBuffer.append: `" ~ e.stringof ~ "` is not a `" ~ T[].stringof ~ "`");

      size_t total_length = _length;

      foreach(ref d; new_data)
         total_length += d.length;

      reserve(total_length);

      foreach(ref d; new_data)
      {
         _data[_length.._length+d.length] = cast(T[])d[0..$];
         _length += d.length;
      }
   }

   void append(scope const T[] new_data) @trusted
   {
      if (new_data.length == 0) return;

      reserve(_length + new_data.length);
      _data[_length.._length+new_data.length] = cast(T[])new_data[0..$];
      _length += new_data.length;
   }

   void reserve(size_t r, bool allowShrink = false)
   {
      if (!(r > _data.length || allowShrink)) return;

      size_t newCap;
      if (r < 1024) newCap = r < 64 ? 64 : r * 2;
      else if (r < 16*1024) newCap = r + r / 2;
      else newCap = ((r / (16*1024)) + 1) * (16*1024);

      _data.length = newCap;
   }

   void length(size_t l) { reserve(l); _length = l; }

   void append(scope const T new_data) {
      reserve(_length + 1);
      _data[_length] = cast(T)new_data;
      _length++;
   }

   auto capacity() { return _data.length; }
   void clear() { _length = 0; }
   auto array() { return _data[0.._length]; }
   size_t length() { return _length;}

   this(size_t initialCapacity) { reserve(initialCapacity); }

}