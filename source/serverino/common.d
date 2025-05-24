/*
Copyright (c) 2023-2025 Andrea Fontana

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

// Serverino can be built using two different backends: select or epoll
public enum BackendType
{
   SELECT = "select",
   EPOLL = "epoll",
	KQUEUE = "kqueue"
}

// The backend is selected using the version directive or by checking the OS
version(use_select) { enum Backend = BackendType.SELECT; }
else version(use_epoll) { enum Backend = BackendType.EPOLL; }
else version(use_kqueue) { enum Backend = BackendType.KQUEUE; }
else {
   version(linux) enum Backend = BackendType.EPOLL;
	else version(BSD) enum Backend = BackendType.SELECT;
	else version(OSX) enum Backend = BackendType.KQUEUE;
	else version(Windows) enum Backend = BackendType.SELECT;
   else enum Backend = BackendType.SELECT;
}

static if(Backend == BackendType.EPOLL)
{
	version(linux) { }
	else static assert(false, "epoll backend is only available on Linux");
}

static if (Backend == BackendType.KQUEUE)
{
	version(linux) enum IS_KQUEUE_AVAILABLE = true;
	else version(BSD) enum IS_KQUEUE_AVAILABLE = true;
	else version(OSX) enum IS_KQUEUE_AVAILABLE = true;
	else enum IS_KQUEUE_AVAILABLE = false;

	static if (IS_KQUEUE_AVAILABLE)
	{
		struct timespec {
			long tv_sec;  // seconds
			long tv_nsec; // nanoseconds
		}

		extern(C)
		{
			alias uintptr_t = size_t;
			alias intptr_t = ptrdiff_t;

			struct kevent {
				uintptr_t ident;
				short filter;
				ushort flags;
				uint fflags;
				intptr_t data;
				void* udata;
			}

			enum EV_ADD = cast(ushort)0x0001;
			enum EV_DELETE = cast(ushort)0x0002;
			enum EV_ENABLE = cast(ushort)0x0004;
			enum EV_DISABLE = cast(ushort)0x0008;
			enum EV_ONESHOT = cast(ushort)0x0010;
			enum EV_CLEAR = cast(ushort)0x0020;
			enum EV_EOF = cast(ushort)0x0080;
			enum EV_ERROR = cast(ushort)0x4000;

			enum EVFILT_READ = cast(short)-1;
			enum EVFILT_WRITE = cast(short)-2;
			enum EVFILT_AIO = cast(short)-3;
			enum EVFILT_VNODE = cast(short)-4;
			enum EVFILT_PROC = cast(short)-5;
			enum EVFILT_SIGNAL = cast(short)-6;
			enum EVFILT_TIMER = cast(short)-7;
			enum EVFILT_MACHPORT = cast(short)-8;
			enum EVFILT_FS = cast(short)-9;
			enum EVFILT_USER = cast(short)-10;
			enum EVFILT_SYSCOUNT = cast(short)11;


			version(linux)
			{
				// On linux kqueue is loaded as a shared library
				// so we need to use dlsym to get the function pointers

				__gshared int function() kqueue;

				__gshared int function(
					int 	kq,
					const kevent* changelist,
					int nchanges,
					kevent* eventlist,
					int nevents,
					const timespec* timeout
				) kevent_f;
			}
			else
			{
				// On BSD kqueue is a system call

				int kqueue();

				pragma(mangle, "kevent")
				int kevent_f(
					int 	kq,
					const kevent* changelist,
					int nchanges,
					kevent* eventlist,
					int nevents,
					const timespec* timeout
				);
			}
		}
	}
	else static assert(false, "kqueue backend is only available on Linux and BSD");
}

// The time type used in the serverino library
alias CoarseTime = MonoTimeImpl!(ClockType.coarse);

// Serverino version
public enum SERVERINO_MAJOR = 0;
public enum SERVERINO_MINOR = 7;
public enum SERVERINO_REVISION = 17;

package string simpleNotSecureCompileTimeHash(string seed = "") @safe nothrow
{
	import std.string : representation;

	// Definetely not a secure hash function
	// Created just to give a unique ID to each build / request

	char[16] h = "SimpleNotSecure!";
	char[32] h2;

	auto  s = (seed ~ "_" ~  __TIMESTAMP__).representation;
	static immutable hex = "0123456789abcdef".representation;

	ulong sc = 104_059;

	foreach_reverse(idx, c; s)
	{
		sc += 1+(cast(ushort)c);
		sc *= 79_193;
		h[15-idx%16] ^= cast(char)(sc%256);
	}

	foreach(idx, c; h)
	{
		sc += 1+(cast(ushort)c);
		sc *= 96_911;
		h2[idx] = hex[(sc%256)/16];
		h2[$-idx-1] = hex[(sc%256)%16];
	}

	return h2.dup;
}

// Struct WorkerPayload is used to pass data from the worker to the daemon
// It is prepended to the actual response payload
package struct WorkerPayload
{
	enum Flags : typeof(WorkerPayload.flags)
	{
		HTTP_RESPONSE_INLINE = 1 << 0,
		HTTP_RESPONSE_FILE = 1 << 1,
		HTTP_RESPONSE_FILE_DELETE = 1 << 2,
		HTTP_KEEP_ALIVE = 1 << 3,
		WEBSOCKET_UPGRADE = 1 << 4,
		DAEMON_SHUTDOWN = 1 << 5,
		DAEMON_SUSPEND = 1 << 6,
	}

	ubyte 	flags = 0;
	size_t 	contentLength = 0;
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


version(Posix)
{
   import std.socket : Socket, socket_t, cmsghdr, msghdr,
   sendmsg, recvmsg, iovec,
   CMSG_FIRSTHDR, CMSG_SPACE, CMSG_DATA, CMSG_LEN,
   SOL_SOCKET, SCM_RIGHTS;

}
else version(Windows)
{
	import core.sys.windows.windef;
	import core.sys.windows.basetyps: GUID;

	alias GROUP = uint;

	enum INVALID_SOCKET = 0;
	enum MAX_PROTOCOL_CHAIN = 7;
	enum WSAPROTOCOL_LEN = 255;
	enum WSA_FLAG_OVERLAPPED = 0x01;

	struct WSAPROTOCOLCHAIN
	{
		int ChainLen;
		DWORD[MAX_PROTOCOL_CHAIN] ChainEntries;
	}

	struct WSAPROTOCOL_INFOW
	{
		DWORD dwServiceFlags1;
		DWORD dwServiceFlags2;
		DWORD dwServiceFlags3;
		DWORD dwServiceFlags4;
		DWORD dwProviderFlags;
		GUID ProviderId;
		DWORD dwCatalogEntryId;
		WSAPROTOCOLCHAIN ProtocolChain;
		int iVersion;
		int iAddressFamily;
		int iMaxSockAddr;
		int iMinSockAddr;
		int iSocketType;
		int iProtocol;
		int iProtocolMaxOffset;
		int iNetworkByteOrder;
		int iSecurityScheme;
		DWORD dwMessageSize;
		DWORD dwProviderReserved;
		WCHAR[WSAPROTOCOL_LEN+1] szProtocol;
	}

	extern(Windows) nothrow @nogc
	{
		import core.sys.windows.winsock2: WSAGetLastError;
		int WSADuplicateSocketW(SOCKET s, DWORD dwProcessId, WSAPROTOCOL_INFOW* lpProtocolInfo);
		SOCKET WSASocketW(int af, int type, int protocol, WSAPROTOCOL_INFOW*, GROUP, DWORD dwFlags);
	}
}

version(Posix)
{
	import std.experimental.logger;
	import core.sys.dragonflybsd.pthread_np;
	import core.sys.freebsd.pthread_np;

	int socketTransferReceive(Socket socket)
	{

		try
		{
			union ControlMsg {
				char[CMSG_SPACE(int.sizeof)] buf;
				cmsghdr tmp;
			}
			ControlMsg controlMsg;

			char data;

			msghdr msgh;
			msgh.msg_name = null;
			msgh.msg_namelen = 0;

			iovec iov;

			msgh.msg_iov = &iov;
			msgh.msg_iovlen = 1;
			iov.iov_base = &data;
			iov.iov_len = 1;

			msgh.msg_control = controlMsg.buf.ptr;
			msgh.msg_controllen = controlMsg.buf.length;

			auto nr = recvmsg(socket.handle, &msgh, 0);

			if (nr < 0)
			{
				return -1;
			}

			cmsghdr *cmsgp = CMSG_FIRSTHDR(&msgh);

			return *(cast(int*)CMSG_DATA(cmsgp));
		}
		catch (Exception e) { return -1; }

	}

	bool socketTransferSend(socket_t s, Socket thru, int pid)
	{

		union ControlMsg {
			char[CMSG_SPACE(int.sizeof)] buf;
			cmsghdr tmp;
		}

		ControlMsg controlMsg;

		int fd = cast(int)s;

		msghdr   msgh;
		msgh.msg_name = null;
		msgh.msg_namelen = 0;

		char data = '\1';

		iovec iov;
		iov.iov_base = &data;
		iov.iov_len = 1;

		msgh.msg_iov = &iov;
		msgh.msg_iovlen = 1;
		msgh.msg_control = controlMsg.buf.ptr;
		msgh.msg_controllen = controlMsg.buf.length;

		auto cmsgp = CMSG_FIRSTHDR(&msgh);
		cmsgp.cmsg_level = SOL_SOCKET;
		cmsgp.cmsg_type = SCM_RIGHTS;
		cmsgp.cmsg_len = CMSG_LEN(int.sizeof);
		*(cast(int *) CMSG_DATA(cmsgp)) = fd;

		return sendmsg(thru.handle, &msgh, 0) != -1;
	}
}

version(Posix)
{
	import core.sys.posix.pthread : pthread_self, pthread_t;
	extern(C) void pthread_setname_np(pthread_t, const(char)*);
}

version(Posix) package void setProcessName(string[] names)
{
	import core.thread : Thread;

	// We don't want to set the name of the process if we are running in a thread
	if (!Thread.getThis().isMainThread)
		return;

   import core.runtime : Runtime, CArgs;

   char** argv = Runtime.cArgs.argv;
   size_t argc = Runtime.cArgs.argc;

   // Get the longer contiguous arrray from start
   size_t currentarg = 0;
   size_t i = 0;
   char* max = argv[currentarg];

   while(true)
   {
      max = argv[currentarg] + i;

      if (*(argv[currentarg] + i) != 0)
      {
         i++;
         continue;
      }

      if (currentarg+1 < argc && max+1 == argv[currentarg+1])
      {
         currentarg++;
         i = 0;
      }
      else break;
   }

   size_t maxLen = max-argv[0];
   currentarg++;

	// Clear the remaining arguments
   while(currentarg < argc)
   {
      argv[currentarg][0] = 0;
      currentarg++;
   }

	// Set the new name searching for the first argument that fits the space
   import std.algorithm : map;
   foreach(n; names.map!(x => cast(char[])x))
   {
      if (n.length < maxLen)
      {
         argv[0][0..n.length] = n;
         argv[0][n.length..maxLen] = 0;
         break;
      }
   }

	import std.string : toStringz;
	pthread_setname_np(pthread_self(), names[0].toStringz);
}

package immutable static DEFAULT_BUFFER_SIZE = 32*1024;


// Load the kqueue shared library on linux
version(linux)
{
	static if (Backend == BackendType.KQUEUE)
	{
		__gshared void* kqueue_handle = null;

		shared static this()
		{
			import core.sys.posix.dlfcn;

			kqueue_handle = dlopen("libkqueue.so", RTLD_LAZY);

			if (!kqueue_handle)
				assert(false, "Failed to load libkqueue.so. Please install the libkqueue library or use one of the other backends (select or epoll)");

			kqueue = cast(typeof(kqueue))dlsym(kqueue_handle, "kqueue");
			kevent_f = cast(typeof(kevent_f))dlsym(kqueue_handle, "kevent");

			if(!kqueue || !kevent_f)
				assert(false, "Failed to load kqueue or kevent functions");
		}

		shared static ~this()
		{
			import core.sys.posix.dlfcn;
			dlclose(kqueue_handle);
		}
	}
}

pragma(inline, true)
ptrdiff_t indexOfSeparator(const char[] s) @nogc nothrow pure
{
	if (s.length < 4) return -1;

	size_t index = 0;
	while (index + 4 <= s.length)
	{
		auto fourth = s[index + 3];

		if (fourth == '\n')
		{
			// Controlla se la sequenza è "\r\n\r\n"
			if (s[index] == '\r' && s[index + 1] == '\n' && s[index + 2] == '\r')
				return index;
			index++;
		}
		else if (fourth == '\r') index++;
		else index += 4;
	}

	return -1;
}

pragma(inline, true)
ptrdiff_t indexOfNewline(const char[] s) @nogc nothrow pure
{
	if (s.length < 2) return -1;

	size_t index = 0;
	while (index + 2 <= s.length)
	{
		if (s[index + 1] == '\n')
		{
			if (s[index] == '\r')
				return index;

			index += 2;
		}
		else if (s[index + 1] == '\r') index += 1;
		else index += 2;

	}

	return -1;
}

pragma(inline, true)
auto newlineSplitter(T)(T data) @nogc nothrow pure
{

	import std.traits : isSomeString;

	struct NewlineSplitter(T) if (isSomeString!T)
	{
		@nogc nothrow pure:

		private:
		T input;
		T current;

		size_t currentPos		= 0;
		bool complete 			= false;
		bool last 				= false;

		public:
		pragma(inline, true):

		@disable this();

		this(T input)
		{
			this.input = input;
			if (input.length == 0) last = true;
			popFront();
		}

		auto front() @property { return current; }

		bool empty() const @property { return complete; }

		void popFront()
		{
			if (last)
			{
				current = input[0..0];
				complete = true;
				return;
			}

			auto remainder = input[currentPos..$];
			auto idx = indexOfNewline(remainder);

			if (idx == -1)
			{
				current = remainder;
				currentPos = input.length;
				last = true;
			}
			else
			{
				current = remainder[0..idx];
				currentPos += idx + 2;
			}
		}
	}

	return NewlineSplitter!T(data);
}

string thisExePathWithFallback()
{
	try
	{
		import std.file : thisExePath;
		return thisExePath();
	}
	catch(Exception e)
	{
		// This could happen if /proc/self/exe is not available
		import std.file : getcwd;
		import core.runtime : Runtime;
		import std.path : buildNormalizedPath;
		import std.conv : to;

		auto path = Runtime.cArgs.argv[0].to!string;

		if (path.length > 0)
		{
			if (path[0] == '/') return path;
			else if (path[0] == '.') return buildNormalizedPath(getcwd(), path);
		}

		throw new Exception("Can't get executable path");
	}
}
