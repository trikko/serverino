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

module serverino.common;

import std.datetime : MonoTimeImpl, ClockType;
import std.stdio : File;

alias CoarseTime = MonoTimeImpl!(ClockType.coarse);

// Serverino version
public static int SERVERINO_MAJOR = 0;
public static int SERVERINO_MINOR = 6;
public static int SERVERINO_REVISION = 5;

// Struct WorkerPayload is used to pass data from the worker to the daemon
// It is prepended to the actual response payload
package struct WorkerPayload
{
	bool isKeepAlive = false;
	size_t contentLength = 0;
}

// An implementation of unix domain sockets for Windows
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

// ProcessInfo is a simple class to manage processes in a cross-platform way
// It is used to check if a worker is running, to kill it and so on...
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
