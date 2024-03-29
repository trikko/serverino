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
import serverino.daemon : WorkerInfo, now;
import serverino.config : DaemonConfigPtr;
import std.socket;


import std.ascii : toLower;
import std.string: join;
import std.algorithm : strip;
import std.conv : text, to;
import std.format : format;
import std.experimental.logger : log, info, warning;

extern(C) long syscall(long number, ...);

/*
 * The `ProtoRequest` class is a draft of a HTTP request.
 * Full request will be parsed by the assigned worker.
 * This is a linked list, so it can be used to store multiple requests.
 */
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

   override string toString() const
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


   bool     isValid = false;     // First checks on incoming data can invalidate request

   bool     headersDone = false; // Headers are read
   bool     expect100 = false;   // Should we send 100-continue?

   size_t   contentLength = 0;   // Content length
   size_t   headersLength;

   char[]   method;              // HTTP method
   char[]   path;                // Request path

   char[]   data = [0,0,0,0];    // Request data (first 4 bytes will be set to the length of the data)
   ProtoRequest next = null;     // Next request in the queue

   Connection  connection = Connection.Unknown;
   HttpVersion httpVersion = HttpVersion.Unknown;
}

/*
 * The `Communicator` class receives and sends data to the client.
 * It is also responsible for the first raw parsing of the incoming data.
 * It communicates thru a unix socket with the assigned worker to process the request..
*/
package class Communicator
{
   enum State
   {
      READY = 0,        // Waiting to be paired with a client
      PAIRED,           // Paired with a client
      READING_HEADERS,  // Reading headers from client
      READING_BODY,     // Reading body from client
      KEEP_ALIVE        // Keep alive if the client wants to
   }

   DaemonConfigPtr config;

   this(DaemonConfigPtr config)
   {
      // Add the new instance to the list of dead communicators
      prev = null;
      next = deads;
      if (next !is null) next.prev = this;
      deads = this;

      this.config = config;

   }

   void setResponseLength(size_t s) { responseLength = s; responseSent = 0; }
   pragma(inline, true) bool completed() { return responseLength == responseSent; }

   // Unset the client socket and move the communicator to the ready state
   void unsetClientSocket()
   {
      status = State.READY;

      if (this.clientSkt !is null)
      {
         // Remove the communicator from the list of alives
         if (prev !is null) prev.next = next;
         else alives = next;

         if (next !is null) next.prev = prev;

         // Add the communicator to the list of deads
         prev = null;
         next = deads;
         if (next !is null) next.prev = this;
         deads = this;

         this.clientSkt = null;
      }
   }

   // Assign a client socket to the communicator and move it to the paired state
   void setClientSocket(Socket s)
   {
      status = State.PAIRED;

      if (s !is null && this.clientSkt is null)
      {
         // Remove the communicator from the list of deads
         if (prev !is null) prev.next = next;
         else deads = next;

         if (next !is null) next.prev = prev;

         // Add the communicator to the list of alives
         prev = null;
         next = alives;
         if (next !is null) next.prev = this;
         alives = this;

         s.blocking = false;
      }

      this.clientSkt = s;
   }

   // Reset the communicator to the initial state and clear the requests queue
   void reset()
   {
      if (clientSkt !is null)
      {
         clientSkt.shutdown(SocketShutdown.BOTH);
         clientSkt.close();
         unsetClientSocket();
      }

      unsetWorker();

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

      requestDataReceived = false;
      lastRecv = CoarseTime.zero;
      lastRequest = CoarseTime.zero;

      hasQueuedRequests = false;
   }

   // If this communicator has a worker assigned, unset it
   void unsetWorker()
   {

      if (this.worker !is null && this.worker.communicator is this)
      {
         this.worker.communicator = null;
         this.worker.setStatus(WorkerInfo.State.IDLING);
      }

      this.worker    = null;
      lastRequest    = now;
      responseLength = 0;
      responseSent   = 0;
   }

   // Assign a worker to the communicator
   void setWorker(ref WorkerInfo worker)
   {
      this.worker = worker;
      worker.communicator = this;

      worker.setStatus(WorkerInfo.State.PROCESSING);
      auto current = requestToProcess;

      // We fill the first 4 bytes of the data with the length of the data
      uint len = cast(uint)(current.data.length - uint.sizeof);
      *(cast(uint*)(current.data.ptr)) = len;

      isKeepAlive = current.connection == ProtoRequest.Connection.KeepAlive;
      worker.unixSocket.send(current.data);

      requestToProcess = requestToProcess.next;
      lastRequest = now;
   }

   // Write the buffered data to the client socket
   void write()
   {
      auto maxToSend = bufferSent + 32*1024;
      if (maxToSend > sendBuffer.length) maxToSend = sendBuffer.length;

      if (maxToSend == 0)
         return;

      immutable sent = clientSkt.send(sendBuffer.array[bufferSent..maxToSend]);

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

      // If the response is completed, unset the worker
      // and if the client is not keep alive, reset the communicator
      if (completed())
      {
         unsetWorker();

         if (!isKeepAlive)
            reset();
      }
   }

   // Try to write the data to the client socket, it buffers the data if the socket is not ready
   void write(char[] data)
   {
      if (clientSkt is null)
      {
         reset();
         return;
      }

      if (sendBuffer.length == 0)
      {
         auto sent = clientSkt.send(data);

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

         // If the response is completed, unset the worker
         // and if the client is not keep alive, reset the communicator
         if (completed())
         {
            unsetWorker();

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

   // Read the data from the client socket and parse the incoming data
   void read(bool fromBuffer = false)
   {
      import std.string: indexOf;

      // Create a new request if the current one is completed
      if (status == State.PAIRED || status == State.KEEP_ALIVE)
      {
         // Queue a new request
         if (requestToProcess is null) requestToProcess = new ProtoRequest();
         else
         {
            ProtoRequest tmp = requestToProcess;
            while(tmp.next !is null)
               tmp = tmp.next;

            tmp.next = new ProtoRequest();
            requestToProcess = tmp.next;
         }

	      status = State.READING_HEADERS;
      }

      ProtoRequest request = requestToProcess;

      char[32*1024] buffer;
      ptrdiff_t bytesRead = 0;

      // Read the data from the client socket if it's not buffered
      // Set the requestDatareceived flag to true if the first data is read to check for timeouts
      if (!fromBuffer)
      {
         bytesRead = clientSkt.receive(buffer);

         if (bytesRead < 0)
         {
            if(!wouldHaveBlocked)
            {
               status = State.READY;
               log("Socket error on read. ", lastSocketError);
               reset();
            }

            return;
         }

         if (bytesRead == 0)
         {
            // Connection closed.
            status = State.READY;
            reset();
            return;
         }
         else if (requestDataReceived == false) requestDataReceived = true;

      }
      else
      {
         bytesRead = 0;
         requestDataReceived = true;
      }

      auto bufferRead = buffer[0..bytesRead];

      // If there's leftover data from the previous read, append it to the current buffer
      if (leftover.length)
      {
         bufferRead = leftover ~ bufferRead;
         leftover.length = 0;
      }

      bool tryParse = true;
      while(tryParse)
      {
         bool enqueueNewRequest = false;
         tryParse = false;

         if (status == State.READING_HEADERS)
         {
            // We are still waiting for the headers to be completed
            if (!request.headersDone)
            {
               auto headersEnd = bufferRead.indexOf("\r\n\r\n");

               // Are the headers completed?
               if (headersEnd >= 0)
               {
                  if (headersEnd > config.maxRequestSize)
                  {
                     clientSkt.send("HTTP/1.0 413 Request Entity Too Large\r\n");
                     reset();
                     return;
                  }

                  import std.algorithm : splitter, map, joiner;

                  // Extra data after the headers is stored in the leftover buffer
                  request.data ~= bufferRead[0..headersEnd];
                  leftover = bufferRead[headersEnd+4..$];

                  // The headers are completed
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
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n");
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

                  // HTTP version must be 1.0 or 1.1
                  if (request.httpVersion != ProtoRequest.HttpVersion.HTTP_10 && request.httpVersion != ProtoRequest.HttpVersion.HTTP_11)
                  {
                     request.isValid = false;
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Http version unknown.");
                     reset();
                     return;
                  }

                  if (popped != 3 || !fields.empty)
                  {
                     request.isValid = false;
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Malformed request line.");
                     reset();
                     return;
                  }

                  if (request.path[0] != '/')
                  {
                     request.isValid = false;
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Absolute uri?");
                     reset();
                     return;
                  }

                  // Parse headers for 100-continue, content-length and connection
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

                     // Headers keys are case insensitive, so we lowercase them
                     // We strip the leading and trailing spaces from both key and value
                     char[] key = cast(char[])row[0..headerColon].strip!(x =>x==' ' || x=='\t');
                     char[] value = cast(char[])row[headerColon+1..$].strip!(x =>x==' '|| x=='\t');

                     // Fast way to lowercase the key. Check if it is ASCII only.
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

                  // If required by configuration, add the remote ip to the headers
                  // It is disabled by default, as it is a slow operation and it is not always needed
                  string ra = string.init;
                  if(config.withRemoteIp)
                  {
                     ra = "x-remote-ip:" ~ clientSkt.remoteAddress().toAddrString() ~ "\r\n";
                     request.data.length += ra.length;
                     request.data[firstLine+2..firstLine+2+ra.length] = ra;
                  }

                  request.data[firstLine+2+ra.length..$] = hdrs[0..$];

                  if (request.isValid == false)
                  {
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n");
                     debug warning("Bad Request. Malformed request.");
                     reset();
                     return;
                  }

                  // Keep alive is the default for HTTP/1.1, close for HTTP/1.0
                  if (request.connection == ProtoRequest.Connection.Unknown)
                  {
                     if (request.httpVersion == ProtoRequest.HttpVersion.HTTP_11) request.connection = ProtoRequest.Connection.KeepAlive;
                     else request.connection = ProtoRequest.Connection.Close;
                  }

                  request.headersLength = request.data.length;

                  // If the request has a body, we need to read it
                  if (request.contentLength != 0)
                  {
                     if (request.headersLength + request.contentLength  > config.maxRequestSize)
                     {
                        clientSkt.send("HTTP/1.0 413 Request Entity Too Large\r\n");
                        reset();
                        return;
                     }

                     request.data.reserve(request.headersLength + request.contentLength);
                     request.isValid = false;
                     tryParse = true;
		               status = State.READING_BODY;

                     // If required, we send the 100-continue response now
                     if (request.expect100)
                        clientSkt.send(cast(char[])(request.httpVersion ~ " 100 continue\r\n\r\n"));
                  }
                  else
                  {
                     // No body, we can process the request
                     requestDataReceived = false;
                     hasQueuedRequests = leftover.length > 0;
                     enqueueNewRequest = hasQueuedRequests;

                     if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
                     else status = State.READY;

                  }
               }
               else leftover = bufferRead.dup;
            }

         }
         else if (status == State.READING_BODY)
         {
            // We are reading the body of the request
            request.data ~= leftover;
            request.data ~= bufferRead;

            leftover.length = 0;
            bufferRead.length = 0;

            if (request.data.length >= request.headersLength + request.contentLength)
            {
               // We read the whole body, process the request
               requestDataReceived = false;
               leftover = request.data[request.headersLength + request.contentLength..$];
               request.data = request.data[0..request.headersLength + request.contentLength];
               request.isValid = true;

               hasQueuedRequests = leftover.length > 0;
               enqueueNewRequest = hasQueuedRequests;

               if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
               else status = State.READY;

            }
         }

         if (enqueueNewRequest)
         {
            // There's a (partial) new request in the buffer, we need to create a new request
            request.next = new ProtoRequest();
            request = request.next;
            status = State.READING_HEADERS;

            bufferRead = leftover;
            leftover.length = 0;

            // We try to parse the new request immediately
            tryParse = true;
         }
      }

   }

   DataBuffer!char   sendBuffer;
   size_t            bufferSent;

   bool              hasQueuedRequests = false;
   bool              requestDataReceived;
   bool              isKeepAlive;
   size_t            responseSent;
   size_t            responseLength;
   size_t            id;
   Socket            clientSkt;

   ProtoRequest      requestToProcess;
   WorkerInfo        worker;
   char[]            leftover;

   CoarseTime        lastRecv    = CoarseTime.zero;
   CoarseTime        lastRequest = CoarseTime.zero;

   Communicator      next = null;
   Communicator      prev = null;

   static Communicator  alives   = null; // Communicators with a client socket assigned
   static Communicator  deads    = null;  // Communicators without a client socket assigned

   Communicator.State    status;
}