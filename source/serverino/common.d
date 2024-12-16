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

// Serverino can be built using two different backends: select or epoll
public enum BackendType
{
   SELECT,
   EPOLL
}

// The backend is selected using the version directive or by checking the OS
version(use_select) { enum Backend = BackendType.SELECT; }
else version(use_epoll) { enum Backend = BackendType.EPOLL; }
else {
   version(linux) enum Backend = BackendType.EPOLL;
   else enum Backend = BackendType.SELECT;
}

static if(Backend == BackendType.EPOLL)
{
	version(linux) { }
	else static assert(false, "epoll backend is only available on Linux");
}

// The time type used in the serverino library
alias CoarseTime = MonoTimeImpl!(ClockType.coarse);

// Serverino version
public static int SERVERINO_MAJOR = 0;
public static int SERVERINO_MINOR = 7;
public static int SERVERINO_REVISION = 11;

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
		WEBSOCKET_UPGRADE = 1 << 4
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
	import core.thread;

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