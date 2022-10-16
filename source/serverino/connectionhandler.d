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

module serverino.connectionhandler;

import serverino.common;
import serverino.databuffer;
import serverino.daemon : WorkerInfo;
import serverino.config : DaemonConfigPtr;
import std.socket;


import std.string : toLower, strip, join;
import std.conv : text, to;
import std.format : format;
import std.experimental.logger : log, info, warning;

extern(C) long syscall(long number, ...);


package class ProtoRequest
{
   enum Connection
   {
      Unknown = "unknown",
      KeepAlive = "keep-alive",
      Close = "close"
   }

   enum HttpVersion
   {
      Unknown = "unknown",
      HTTP_10 = "HTTP/1.0",
      HTTP_11 = "HTTP/1.1"
   }

   override string toString()
   {
      string s;
      s ~= text("VALID: ", isValid, "\n");
      s ~= text("VER: ", httpVersion, "\n");
      s ~= text("METHOD: ", method, "\n");
      s ~= text("PATH: ", path, "\n");
      s ~= text("BODY: ", contentLength, "\n");
      s ~= text("HEADERS:", "\n");
      s ~= (data[uint.sizeof..headersLength]);
      s ~= "\n";

      return s;
   }

   bool     isValid = false;

   bool     headersDone = false;
   bool     expect100 = false;
   size_t   contentLength = 0;

   char[]   method;
   char[]   path;

   Connection  connection = Connection.Unknown;
   HttpVersion httpVersion = HttpVersion.Unknown;

   //char[]   body;
   char[]   data;

   size_t   headersLength;
   ProtoRequest next = null;
}

package class ConnectionHandler
{
   enum State
   {
      READY = 0,
      ASSIGNED,
      READING_HEADERS,
      READING_BODY,
      KEEP_ALIVE,
      ERROR
   }

   bool waitingFromWorker = false;
   DaemonConfigPtr config;

   this(DaemonConfigPtr config) {
      id = instances.length;
      instances ~= this;
      dead.insertBack(id);
      this.config = config;
   }


   void setResponseLength(size_t s) { responseLength = s; responseSent = 0; }
   bool completed() { return responseLength == responseSent; }

   void assignSocket(Socket s, ulong requestId)
   {
      if (requestId != ulong.max)
         this.requestId = format("%06s", requestId);

      status = State.ASSIGNED;

      if (s is null && this.socket !is null)
      {
         alive.remove(id);
         dead.insertBack(id);
      }

      if (s !is null && this.socket is null)
      {
         dead.remove(id);
         alive.insertFront(id);
         s.blocking = false;
      }

      this.socket = s;
   }

   void reset()
   {
      if (socket !is null)
      {
         socket.shutdown(SocketShutdown.BOTH);
         socket.close();
         assignSocket(null, ulong.max);
      }

      status = State.READY;
      responseLength = 0;
      responseSent = 0;
      leftover.length = 0;

      // Clear requests queue
      while(requestToProcess !is null)
      {
         auto tmp = requestToProcess;
         requestToProcess = requestToProcess.next;
         tmp.next = null;
      }

      requestToProcess = null;

      started = false;
      lastRecv = CoarseTime.zero;
      lastRequest = CoarseTime.zero;
   }

   void detachWorker()
   {
      this.assignedWorker.assignedConnectionHandler = null;
      this.assignedWorker.setStatus(WorkerInfo.State.IDLING);
      this.assignedWorker = null;

      responseLength = 0;
      responseSent = 0;
   }

   void assignWorker(ref WorkerInfo wi)
   {

      this.assignedWorker = wi;
      wi.assignedConnectionHandler = this;

      wi.setStatus(WorkerInfo.State.PROCESSING);
      auto current = requestToProcess;
      uint len = cast(uint)(current.data.length) - cast(uint)uint.sizeof;
      current.data[0..uint.sizeof] = (cast(char*)&len)[0..uint.sizeof];

      wi.channel.send(current.data);

      requestToProcess = requestToProcess.next;
      lastRequest = CoarseTime.currTime;
   }

   void write()
   {
      auto maxToSend = bufferSent + 32*1024;
      if (maxToSend > sendBuffer.length) maxToSend = sendBuffer.length;

      if (maxToSend == 0)
         return;

      auto sent = socket.send(sendBuffer.array[bufferSent..maxToSend]);

      if (sent == Socket.ERROR)
      {
         if(!wouldHaveBlocked)
         {
            log("SOCKET ERROR?");
            reset();
         }
      }
      else
      {
         bufferSent += sent;
         responseSent += sent;
         if(bufferSent == sendBuffer.length)
         {
            bufferSent = 0;
            sendBuffer.clear();

            if (!isKeepAlive)
                  reset();
         }
      }
   }

   void write(char[] data)
   {
      if (socket is null)
      {
         status = State.ERROR;
         reset();
         return;
      }

      if (sendBuffer.length == 0)
      {
         auto sent = socket.send(data);

         if (sent == Socket.ERROR)
         {
            if(!wouldHaveBlocked)
            {
               log("Socket error on write. ", lastSocketError);
               reset();
               return;
            }
            else sendBuffer.append(data);
         }
         else
         {
            responseSent += sent;
            if (sent < data.length) sendBuffer.append(data[sent..data.length]);
            else
            {
               if (!isKeepAlive)
                  reset();
            }
         }
      }
      else
      {
         sendBuffer.append(data);
         write();
      }
   }

   void read()
   {
      import std.string: indexOf;

      if (status == State.ASSIGNED || status == State.KEEP_ALIVE)
      {
         if (requestToProcess is null) requestToProcess = new ProtoRequest();
         else
         {
            ProtoRequest tmp = requestToProcess;
            while(tmp.next !is null)
               tmp = tmp.next;

            tmp.next = new ProtoRequest();
         }
         status = State.READING_HEADERS;

         uint len = 0;
         requestToProcess.data.reserve(1024*10);
         requestToProcess.data ~= (cast(char*)(&len))[0..uint.sizeof];
      }

      if (requestToProcess is null)
      {
         reset();
         return;
      }

      ProtoRequest request = requestToProcess;
      while(request.next !is null)
         request = request.next;

      request.data.reserve(32*1024);

      char[32*1024] buffer;
      auto bytesRead = socket.receive(buffer);

      if (bytesRead < 0)
      {
         status = State.READY;
         log("Socket error on read. ", lastSocketError);
         reset();
         return;
      }

      if (bytesRead == 0)
      {
         // Connection closed.
         status = State.READY;
         reset();
         return;
      }
      else if (bytesRead == Socket.ERROR && wouldHaveBlocked)
      {
         assert(0, "wouldHaveBlocked");
      }
      else if (started == false) started = true;

      auto bufferRead = buffer[0..bytesRead];

      if (leftover.length)
      {
         bufferRead = leftover ~ bufferRead;
         leftover.length = 0;
      }

      bool doAgain;

      while(true)
      {
         doAgain = false;

         if (status == State.READING_HEADERS)
         {
            if (!request.headersDone)
            {
               auto headersEnd = bufferRead.indexOf("\r\n\r\n");

               if (headersEnd >= 0)
               {
                  if (headersEnd > config.maxRequestSize)
                  {
                     socket.send("HTTP/1.1 413 Request Entity Too Large\r\nserver: serverino/%02d.%02d.%02d\r\nconnection: close\r\n\r\n413 Request Entity Too Large");
                     socket.shutdown(SocketShutdown.BOTH);
                     reset();
                     return;
                  }

                  import std.algorithm : splitter, map, joiner;

                  request.data ~= bufferRead[0..headersEnd];
                  leftover = bufferRead[headersEnd+4..$];
                  bufferRead.length = 0;
                  doAgain = leftover.length > 0;
                  request.headersDone = true;
                  request.isValid = true;

                  auto firstLine = request.data.indexOf("\r\n");

                  if (firstLine < 14)
                  {
                     request.isValid = false;
                     socket.send("HTTP/1.1 400 Bad Request\r\nserver: serverino/%02d.%02d.%02d\r\nconnection: close\r\n\r\n400 Bad Request");
                     log("Bad Request. Status line too short.");
                     status = State.ERROR;
                     reset();
                     return;
                  }

                  auto fields = request.data[uint.sizeof..firstLine].splitter(' ');
                  size_t popped = 0;

                  if (!fields.empty)
                  {
                     request.method = fields.front;
                     fields.popFront;
                     popped++;
                  }

                  if (!fields.empty)
                  {
                     request.path = fields.front;
                     fields.popFront;
                     popped++;
                  }

                  if (!fields.empty)
                  {
                     request.httpVersion = cast(ProtoRequest.HttpVersion)fields.front;
                     fields.popFront;
                     popped++;
                  }

                  if (request.httpVersion != ProtoRequest.HttpVersion.HTTP_10 && request.httpVersion != ProtoRequest.HttpVersion.HTTP_11)
                  {
                     request.isValid = false;
                     status = ConnectionHandler.status.ERROR;
                     socket.send("HTTP/1.1 400 Bad Request\r\nserver: serverino/%02d.%02d.%02d\r\nconnection: close\r\n\r\n400 Bad Request");
                     warning("Bad Request. Http version unknown.");
                     reset();
                     return;
                  }

                  if (popped != 3 || !fields.empty)
                  {
                     request.isValid = false;
                     status = ConnectionHandler.status.ERROR;
                     socket.send("HTTP/1.1 400 Bad Request\r\nserver: serverino/%02d.%02d.%02d\r\nconnection: close\r\n\r\n400 Bad Request");
                     warning("Bad Request. Malformed status line.");
                     reset();
                     return;
                  }

                  auto hdrs = request.data[firstLine+2..$]
                  .splitter("\r\n")
                  .map!((char[] row)
                  {
                     if (!request.isValid)
                        return (char[]).init;

                     auto headerColon = row.indexOf(':');

                     if (headerColon < 0)
                     {
                        request.isValid = false;
                        return (char[]).init;
                     }

                     char[] key = cast(char[])row[0..headerColon].toLower.strip;
                     char[] value = cast(char[])row[headerColon+1..$].strip;

                     if (key == "expect" && value.toLower == "100-continue") request.expect100 = true;
                     else if (key == "connection") request.connection = cast(ProtoRequest.Connection)value.toLower;
                     else
                     try { if (key == "content-length") request.contentLength = value.to!size_t; }
                     catch (Exception e) { request.isValid = false; return (char[]).init; }

                     return key ~ ":" ~ value;
                  })
                  .join("\r\n") ~ "\r\n\r\n";

                  request.data.length = firstLine+2 + hdrs.length;
                  request.data[firstLine+2..firstLine+2+hdrs.length] = hdrs[0..$];

                  if (request.isValid == false)
                  {
                     status = ConnectionHandler.status.ERROR;
                     socket.send("HTTP/1.1 400 Bad Request\r\nserver: serverino/%02d.%02d.%02d\r\nconnection: close\r\n\r\n400 Bad Request");
                     warning("Bad Request. Malformed request.");
                     reset();
                     return;
                  }

                  if (request.connection == ProtoRequest.Connection.Unknown)
                  {
                     if (request.httpVersion == ProtoRequest.HttpVersion.HTTP_11) request.connection = ProtoRequest.Connection.KeepAlive;
                     else request.connection = ProtoRequest.Connection.Close;
                  }

                  request.headersLength = request.data.length;

                  if (request.contentLength != 0)
                  {
                     if (request.headersLength + request.contentLength  > config.maxRequestSize)
                     {
                        socket.send("HTTP/1.1 413 Request Entity Too Large\r\nserver: serverino/%02d.%02d.%02d\r\nconnection: close\r\n\r\n413 Request Entity Too Large");
                        socket.shutdown(SocketShutdown.BOTH);
                        reset();
                        return;
                     }

                     request.data.reserve(request.headersLength + request.contentLength);
                     request.isValid = false;
                     status = State.READING_BODY;

                     if (request.expect100)
                        socket.send(cast(char[])(request.httpVersion ~ " 100 continue\r\n\r\n"));
                  }
                  else
                  {
                     if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
                     else status = State.READY;
                  }
               }
               else request.data ~= bufferRead;
            }
         }
         else if (status == State.READING_BODY)
         {
            request.data ~= leftover;
            request.data ~= bufferRead;

            leftover.length = 0;

            if (request.data.length >= request.headersLength + request.contentLength)
            {
               leftover = request.data[request.headersLength + request.contentLength..$];
               doAgain = leftover.length > 0;
               request.data = request.data[0..request.headersLength + request.contentLength];
               request.isValid = true;
               if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
               else status = State.READY;
            }
         }

         if (!doAgain)
            break;
      }

   }

   DataBuffer!char   sendBuffer;
   size_t            bufferSent;
   string            requestId;

   bool              started;
   bool              isKeepAlive;
   size_t            responseSent;
   size_t            responseLength;
   size_t            id;
   Socket            socket;

   ProtoRequest      requestToProcess;
   WorkerInfo        assignedWorker;
   char[]            leftover;

   CoarseTime          lastRecv    = CoarseTime.zero;
   CoarseTime          lastRequest = CoarseTime.zero;

   static SimpleList          alive;
   static SimpleList          dead;
   ConnectionHandler.State    status;
   static ConnectionHandler[] instances;
}