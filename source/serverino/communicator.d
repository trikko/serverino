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

module serverino.communicator;

import serverino.common;
import serverino.databuffer;
import serverino.daemon : WorkerInfo;
import serverino.config : DaemonConfigPtr;
import std.socket;


import std.ascii : toLower;
import std.string: join;
import std.algorithm : strip;
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

package class Communicator
{
   enum State
   {
      READY = 0,
      ASSIGNED,
      READING_HEADERS,
      READING_BODY,
      KEEP_ALIVE
   }

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

      hasQueuedRequests = false;
   }

   void detachWorker()
   {
      if (this.assignedWorker !is null)
      {
         this.assignedWorker.assignedCommunicator = null;
         this.assignedWorker.setStatus(WorkerInfo.State.IDLING);
         this.assignedWorker = null;
      }

      responseLength = 0;
      responseSent = 0;
   }

   void assignWorker(ref WorkerInfo wi)
   {
      this.assignedWorker = wi;
      wi.assignedCommunicator = this;

      wi.setStatus(WorkerInfo.State.PROCESSING);
      auto current = requestToProcess;
      uint len = cast(uint)(current.data.length) - cast(uint)uint.sizeof;
      current.data[0..uint.sizeof] = (cast(char*)&len)[0..uint.sizeof];

      isKeepAlive = current.connection == ProtoRequest.Connection.KeepAlive;
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
            log("Socket Error");
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
         }
      }

      if (completed())
      {
         detachWorker();

         if (!isKeepAlive)
            reset();
      }
   }

   void write(char[] data)
   {
      if (socket is null)
      {
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
         }

         if (completed())
         {
            detachWorker();

            if (!isKeepAlive)
               reset();
         }
      }
      else
      {
         sendBuffer.append(data);
         write();
      }
   }

   void read(bool fromBuffer = false)
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
      }

      if (requestToProcess is null)
      {
         reset();
         return;
      }

      ProtoRequest request = requestToProcess;
      while(request.next !is null)
         request = request.next;

      uint len = 0;
      if(request.data.length == 0)
      {
	      request.data ~= (cast(char*)(&len))[0..uint.sizeof];
      }

      char[32*1024] buffer;
      ptrdiff_t bytesRead = 0;

      if (!fromBuffer)
      {
         bytesRead = socket.receive(buffer);

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
         else if (started == false) started = true;

      }
      else
      {
         bytesRead = 0;
         started = true;
      }

      auto bufferRead = buffer[0..bytesRead];

      if (leftover.length)
      {
         bufferRead = leftover ~ bufferRead;
         leftover.length = 0;
      }

      bool doAgain = true;

      while(doAgain)
      {
         bool newRequest = false;
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
                     socket.send("HTTP/1.0 413 Request Entity Too Large\r\n");
                     reset();
                     return;
                  }

                  import std.algorithm : splitter, map, joiner;

                  request.data ~= bufferRead[0..headersEnd];
                  leftover = bufferRead[headersEnd+4..$];
                  bufferRead.length = 0;
                  request.headersDone = true;
                  request.isValid = true;

                  auto firstLine = request.data.indexOf("\r\n");

                  // HACK: A single line (http 1.0?) request.
                  if (firstLine < 0)
                  {
                     firstLine = request.data.length;
                     request.data ~= "\r\n";
                  }

                  if (firstLine < 18)
                  {
                     request.isValid = false;
                     socket.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Request line too short.");
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
                     socket.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Http version unknown.");
                     reset();
                     return;
                  }

                  if (popped != 3 || !fields.empty)
                  {
                     request.isValid = false;
                     socket.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Malformed request line.");
                     reset();
                     return;
                  }

                  if (request.path[0] != '/')
                  {
                     request.isValid = false;
                     socket.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Absolute uri?");
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

                     char[] key = cast(char[])row[0..headerColon].strip!(x =>x==' ' || x=='\t');
                     char[] value = cast(char[])row[headerColon+1..$].strip!(x =>x==' '|| x=='\t');

                     foreach(idx, ref k; key)
                     {
                        if (k > 0xF9)
                        {
                           request.isValid = false;
                           return (char[]).init;
                        }
                        else if (k >= 'A' && k <= 'Z')
                          k |= 32;
                     }

                     foreach(idx, ref k; value)
                     {
                        if (k > 0xF9)
                        {
                           request.isValid = false;
                           return (char[]).init;
                        }
                     }

                     if (key.length == 0 || value.length == 0)
                     {
                        request.isValid = false;
                        return (char[]).init;
                     }

                     // 100-continue
                     if (key == "expect" && value.length == 12 && value[0..4] == "100-") request.expect100 = true;
                     else if (key == "connection")
                     {
                        import std.uni: sicmp;

                        if (sicmp(value, "keep-alive") == 0) request.connection = ProtoRequest.Connection.KeepAlive;
                        else if (sicmp(value, "close") == 0) request.connection = ProtoRequest.Connection.Close;
                        else request.connection = ProtoRequest.connection.Unknown;
                     }
                     else
                     try { if (key == "content-length") request.contentLength = value.to!size_t; }
                     catch (Exception e) { request.isValid = false; return (char[]).init; }

                     return key ~ ":" ~ value;
                  })
                  .join("\r\n") ~ "\r\n\r\n";


                  request.data.length = firstLine+2 + hdrs.length;

                  string ra = string.init;

                  if(config.withRemoteIp)
                  {
                     ra = "x-remote-ip:" ~ socket.remoteAddress().toAddrString() ~ "\r\n";
                     request.data.length += ra.length;
                     request.data[firstLine+2..firstLine+2+ra.length] = ra;
                  }

                  request.data[firstLine+2+ra.length..$] = hdrs[0..$];

                  if (request.isValid == false)
                  {
                     socket.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Malformed request.");
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
                        socket.send("HTTP/1.0 413 Request Entity Too Large\r\n");
                        reset();
                        return;
                     }

                     request.data.reserve(request.headersLength + request.contentLength);
                     request.isValid = false;
                     doAgain = true;
		               status = State.READING_BODY;

                     if (request.expect100)
                        socket.send(cast(char[])(request.httpVersion ~ " 100 continue\r\n\r\n"));
                  }
                  else
                  {
                     hasQueuedRequests = leftover.length > 0;

                     // New request read, without body

                     if (hasQueuedRequests)
                     {
                        // Partial request in queue, parse again
                        doAgain = true;
                        newRequest = true;
                     }
                     else
                     {
                        doAgain = false;
                        newRequest = false;
                     }

                     if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
                     else status = State.READY;

                  }
               }
               else leftover = bufferRead.dup;
            }

         }
         else if (status == State.READING_BODY)
         {
            request.data ~= leftover;
            request.data ~= bufferRead;

            leftover.length = 0;
            bufferRead.length = 0;

            if (request.data.length >= request.headersLength + request.contentLength)
            {
               // New request read, with body
               leftover = request.data[request.headersLength + request.contentLength..$];
               request.data = request.data[0..request.headersLength + request.contentLength];
               request.isValid = true;

               hasQueuedRequests = leftover.length > 0;

               if (hasQueuedRequests)
               {
                  // Partial request in queue, parse again
                  doAgain = true;
                  newRequest = true;
               }
               else
               {
                  // No more data
                  doAgain = false;
                  newRequest = false;
               }

               if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
               else status = State.READY;

            }
         }

         if (doAgain && newRequest)
         {
            // New request
            request.next = new ProtoRequest();
            request = request.next;
            status = State.READING_HEADERS;

            len = 0;
            request.data.reserve(1024*10);
            request.data ~= (cast(char*)(&len))[0..uint.sizeof];

            bufferRead = leftover;
            leftover.length = 0;

         }
      }

   }

   DataBuffer!char   sendBuffer;
   size_t            bufferSent;
   string            requestId;

   bool              hasQueuedRequests = false;
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
   Communicator.State    status;
   static Communicator[] instances;
}