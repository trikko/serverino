/*
Copyright (c) 2022 Andrea Fontana

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

module serverino.common;

import std.datetime : MonoTimeImpl, ClockType;
import std.stdio : File;

alias CoarseTime = MonoTimeImpl!(ClockType.coarse);

public static int SERVERINO_MAJOR = 0;
public static int SERVERINO_MINOR = 4;
public static int SERVERINO_REVISION = 4;


version(Windows)
{
	import core.sys.windows.winsock2;
	import std.socket;

	struct sockaddr_un
	{
		ushort sun_family;     /* AF_UNIX */
		byte[108] sun_path;  /* pathname */
	}

	class UnixAddress: Address
		{
		protected:
			socklen_t _nameLen;

			struct
			{
			align (1):
				sockaddr_un sun;
				char unused = '\0'; // placeholder for a terminating '\0'
			}

			this() pure nothrow @nogc
			{
				sun.sun_family = 1;
				sun.sun_path = '?';
				_nameLen = sun.sizeof;
			}

			override void setNameLen(socklen_t len) @trusted
			{
				if (len > sun.sizeof)
						throw new SocketParameterException("Not enough socket address storage");
				_nameLen = len;
			}

		public:
			override @property sockaddr* name() return
			{
				return cast(sockaddr*)&sun;
			}

			override @property const(sockaddr)* name() const return
			{
				return cast(const(sockaddr)*)&sun;
			}

			override @property socklen_t nameLen() @trusted const
			{
				return _nameLen;
			}

			this(scope const(char)[] path) @trusted pure
			{
				import std.exception : enforce;
				enforce(path.length <= sun.sun_path.sizeof, new SocketParameterException("Path too long"));
				sun.sun_family = 1;
				sun.sun_path.ptr[0 .. path.length] = (cast(byte[]) path)[];
				_nameLen = cast(socklen_t)
						{
							auto len = sockaddr_un.init.sun_path.offsetof + path.length;
							// Pathname socket address must be terminated with '\0'
							// which must be included in the address length.
							if (sun.sun_path.ptr[0])
							{
								sun.sun_path.ptr[path.length] = 0;
								++len;
							}
							return len;
						}();
			}

			this(sockaddr_un addr) pure nothrow @nogc
			{
				assert(addr.sun_family == 1);
				sun = addr;
			}

			@property string path() @trusted const pure
			{
				auto len = _nameLen - sockaddr_un.init.sun_path.offsetof;
				if (len == 0)
						return null; // An empty path may be returned from getpeername
				// For pathname socket address we need to strip off the terminating '\0'
				if (sun.sun_path.ptr[0])
						--len;
				return (cast(const(char)*) sun.sun_path.ptr)[0 .. len].idup;
			}

			override string toString() const pure
			{
				return path;
			}
		}
}

package struct SimpleList
{
   private struct SLElement
   {
      size_t v;
      size_t prev = size_t.max;
      size_t next = size_t.max;
   }

   auto asRange()
   {
      struct Range
      {
        bool empty() {
            return tail == size_t.max || elements[tail].next == head;
        }

         void popFront() { head = elements[head].next; if (head == size_t.max) tail = size_t.max; }
         size_t front() { return elements[head].v; }

         void popBack() { tail = elements[tail].prev;  if (tail == size_t.max) head = size_t.max; }
         size_t back() { return elements[tail].v; }

         private:
         size_t head;
         size_t tail;
         SLElement[] elements;
      }

      return Range(head, tail, elements);
   }

   size_t insert(size_t e, bool prepend)
   {
      count++;

      enum EOL = size_t.max;

      size_t selected = EOL;

      if (free == EOL)
      {
         elements ~= SLElement(e, EOL, EOL);
         selected = elements.length - 1;
      }
      else {
         selected = free;
         elements[selected].v = e;
         free = elements[selected].next;

         if (free != EOL)
            elements[free].prev = EOL;
      }


      if (head == EOL)
      {
         head = selected;
         tail = selected;
         elements[selected].next = EOL;
         elements[selected].prev = EOL;
      }
      else
      {
         if (prepend)
         {
            size_t oldHead = head;
            head = selected;
            elements[selected].next = oldHead;
            elements[selected].prev = EOL;
            elements[oldHead].prev = selected;
         }
         else
         {
            size_t oldTail = tail;
            tail = selected;
            elements[selected].prev = oldTail;
            elements[selected].next = EOL;
            elements[oldTail].next = selected;
         }
      }

      return selected;
   }

   size_t insertBack(size_t e) { return insert(e, false); }
   size_t insertFront(size_t e) { return insert(e, true); }

   size_t remove(size_t e)
   {
      enum EOL = size_t.max;

      auto t = head;
      while(t != EOL)
      {
         if (elements[t].v == e)
         {
            count--;

            if (elements[t].prev == EOL) head = elements[t].next;
            else elements[elements[t].prev].next = elements[t].next;

            if (elements[t].next == EOL) tail = elements[t].prev;
            else elements[elements[t].next].prev = elements[t].prev;

            elements[t].prev = EOL;
            elements[t].next = free;

            if (free != EOL)
               elements[free].prev = t;

            free = t;
            return t;
         }

         t = elements[t].next;
      }

      return EOL;
   }

   size_t length() { return count; }
   bool empty() { return head == size_t.max; }

   private:


   SLElement[] elements;
   size_t head = size_t.max;
   size_t tail = size_t.max;
   size_t free = size_t.max;
   size_t count = 0;
}

class ProcessInfo
{
	this(int pid) { this.pid =  pid; }

	int  id() { return this.pid; }

	bool isValid() { return pid >= 0; }
	bool isRunning() { return !isTerminated; }
	bool isTerminated()
	{
		version(Posix)
		{
			import core.sys.posix.signal : kill;
			import core.stdc.errno : errno, ESRCH;

			kill(pid, 0);

			return (errno == ESRCH);
		}
		else
		{
			import core.sys.windows.winbase : STILL_ACTIVE, GetExitCodeProcess;
			import core.sys.windows.windef : LPDWORD;

			if (processHandle)
			{
				int ec;
				GetExitCodeProcess(processHandle, cast(LPDWORD)&ec);
				return(ec != STILL_ACTIVE);
			}
			else return false;
		}
	}

	void kill()
	{
		version (Posix)
		{
			import core.sys.posix.signal : kill, SIGTERM;
			kill(pid, SIGTERM);
		}
		else
		{
			import core.sys.windows.winbase : TerminateProcess;
			import core.sys.windows.windef : HANDLE;

			TerminateProcess(processHandle, 1);
		}
	}

	~this()
	{
		version(Windows)
		{
			if (processHandle != null)
			{
				import core.sys.windows.winbase : CloseHandle;
				CloseHandle(processHandle);
			}
		}
	}

	@disable this();


	version(Windows)
	{
		import core.sys.windows.windef : HANDLE;

		HANDLE processHandle()
		{
			import core.sys.windows.winbase : OpenProcess;
			import core.sys.windows.windef : PROCESS_QUERY_INFORMATION, PROCESS_ALL_ACCESS, FALSE;

			if (_processHandle == null)
				_processHandle = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pid);

			return _processHandle;
		}

		HANDLE _processHandle = null;
	}

	private:
		int pid = -1;
}
