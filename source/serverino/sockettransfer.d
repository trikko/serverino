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

module serverino.sockettransfer;

version(darwin)
{
   import std.socket : Socket, socket_t,
   iovec, SOL_SOCKET, SCM_RIGHTS;

   alias socklen_t = uint;
   alias ssize_t = uint;

   struct msghdr
   {
      void*     msg_name;
      socklen_t msg_namelen;
      iovec*    msg_iov;
      int       msg_iovlen;
      void*     msg_control;
      socklen_t msg_controllen;
      int       msg_flags;
   }

   struct cmsghdr
   {
      socklen_t  cmsg_len;
      int        cmsg_level;
      int        cmsg_type;
   }

   extern (D)
   {
      socklen_t CMSG_ALIGN(socklen_t len) pure nothrow @nogc { return (len + socklen_t.sizeof - 1) & cast(socklen_t) (~(socklen_t.sizeof - 1)); }
      socklen_t CMSG_SPACE(socklen_t len) pure nothrow @nogc { return CMSG_ALIGN(len) + CMSG_ALIGN(cmsghdr.sizeof); }
      socklen_t CMSG_LEN(socklen_t len) pure nothrow @nogc { return CMSG_ALIGN(cmsghdr.sizeof) + len; }

      inout(ubyte)*   CMSG_DATA( return scope inout(cmsghdr)* cmsg ) pure nothrow @nogc { return cast(ubyte*)( cmsg + 1 ); }

      inout(cmsghdr)* CMSG_FIRSTHDR( inout(msghdr)* mhdr ) pure nothrow @nogc
      {
         return ( cast(socklen_t)mhdr.msg_controllen >= cmsghdr.sizeof ? cast(inout(cmsghdr)*) mhdr.msg_control : cast(inout(cmsghdr)*) null );
      }
   }

   extern(C) {
      ssize_t recvmsg(int, scope msghdr*, int); 
      ssize_t sendmsg(int, const scope msghdr*, int);
   }

}
else
{
   import std.socket : Socket, socket_t, cmsghdr, msghdr,
   sendmsg, recvmsg, iovec,
   CMSG_FIRSTHDR, CMSG_SPACE, CMSG_DATA, CMSG_LEN,
   SOL_SOCKET, SCM_RIGHTS;

}

class SocketTransfer
{

   static int receive(Socket socket)
   {

      try
      {
         char [256] buf;
         char [256] c_buf;

         msghdr msgh;
         msgh.msg_name = null;
         msgh.msg_namelen = 0;

         iovec iov;

         msgh.msg_iov = &iov;
         msgh.msg_iovlen = 1;
         iov.iov_base = cast(char*)&buf;
         iov.iov_len = buf.sizeof;

         msgh.msg_control = c_buf.ptr;
         msgh.msg_controllen = c_buf.sizeof;

         auto nr = recvmsg(socket.handle, &msgh, 0);

         if (nr == -1)
            return -1;

         cmsghdr *cmsgp = CMSG_FIRSTHDR(&msgh);

         int fd = *(cast(int*)CMSG_DATA(cmsgp));
         //import core.stdc.string : memcpy;
         //memcpy(&fd, CMSG_DATA(cmsgp), int.sizeof);

         return fd;
      }
      catch (Exception e) { return -1; }

   }

   static bool send(socket_t s, Socket thru)
   {
      msghdr   msg;
      cmsghdr  *cmsg;

      int fd = cast(int)s;
      char [CMSG_SPACE(fd.sizeof)] buf;

      iovec io;
      io.iov_base = null;
      io.iov_len = 0;

      msg.msg_iov = &io;
      msg.msg_iovlen = 1;
      msg.msg_control = buf.ptr;
      msg.msg_controllen = buf.sizeof;

      cmsg = CMSG_FIRSTHDR(&msg);
      cmsg.cmsg_level = SOL_SOCKET;
      cmsg.cmsg_type = SCM_RIGHTS;
      cmsg.cmsg_len = CMSG_LEN(fd.sizeof);
      *(cast(int *) CMSG_DATA(cmsg)) = fd;
      sendmsg(thru.handle, &msg, 0);

      return true;
   }
}
