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

module serverino.communicator;

import serverino.common;
import serverino.databuffer;
import serverino.daemon : WorkerInfo, now, Daemon;
import serverino.config : DaemonConfigPtr;
import std.socket : Socket, SocketOption, SocketOptionLevel, lastSocketError, wouldHaveBlocked, SocketShutdown, socket_t;
import std.string: join;
import std.algorithm : strip;
import std.conv : text, to;
import std.experimental.logger : log, info, warning;
import std.stdio : File;
import std.file : getSize;

static if (serverino.common.Backend == BackendType.EPOLL)
{
   import core.sys.linux.epoll : EPOLLIN, EPOLLOUT;
}


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
      Close = "close",
      Upgrade = "upgrade"
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
      s ~= text("URI: ", uri, "\n");
      s ~= text("BODY: ", contentLength, "\n");
      s ~= text("HEADERS:", "\n");
      s ~= (data[uint.sizeof..headersLength]);
      s ~= "\n";

      return s;
   }


   bool     isValid = false;     // First checks on incoming data can invalidate request

   bool     expect100 = false;   // Should we send 100-continue?

   size_t   contentLength = 0;   // Content length
   size_t   headersLength;

   char[]   method;              // HTTP method
   char[]   uri;                 // Request URI

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
      KEEP_ALIVE,        // Keep alive if the client wants to
      WEBSOCKET
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
         static if (serverino.common.Backend == BackendType.EPOLL)
            Daemon.epollRemoveSocket(clientSktHandle);
         else static if (serverino.common.Backend == BackendType.KQUEUE)
         {
            Daemon.addKqueueChange(clientSktHandle, EVFILT_READ, EV_DELETE | EV_DISABLE, null);
            Daemon.addKqueueChange(clientSktHandle, EVFILT_WRITE, EV_DELETE | EV_DISABLE, null);
         }

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
         clientSktHandle = socket_t.max;
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

         s.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, 1);
         s.blocking = false;
         this.clientSkt = s;
         this.clientSktHandle = s.handle;

         static if (serverino.common.Backend == BackendType.EPOLL)
            Daemon.epollAddSocket(clientSktHandle, EPOLLIN, cast(void*) this);
         else static if (serverino.common.Backend == BackendType.KQUEUE)
         {
            Daemon.addKqueueChange(clientSktHandle, EVFILT_WRITE, EV_DELETE | EV_DISABLE, cast(void*) this);
            Daemon.addKqueueChange(clientSktHandle, EVFILT_READ, EV_ADD | EV_ENABLE, cast(void*) this);
         }
      }
      else assert(false);
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

      // It nextWaiting and prevWaiting are null, it is not in the waiting list or it is the only one
      if (prevWaiting is null && nextWaiting is null)
      {
         // Is it the only one?
         if (execWaitingListFront == this)
         {
            // If it is the only one, it is also the last one
            assert(execWaitingListBack == this);
            execWaitingListFront = null;
            execWaitingListBack = null;
         }
      }
      else // It is in the waiting list
      {
         // Remove from the waiting list, if it is there
         if (nextWaiting !is null) nextWaiting.prevWaiting = prevWaiting;
         else execWaitingListBack = prevWaiting;

         if (prevWaiting !is null) prevWaiting.nextWaiting = nextWaiting;
         else execWaitingListFront = nextWaiting;
      }


      nextWaiting = null;
      prevWaiting = null;
   }

   // If this communicator has a worker assigned, unset it
   void unsetWorker()
   {
      if (clientSkt !is null && hasBuffer)
      {
         static if (serverino.common.Backend == BackendType.EPOLL)
            Daemon.epollEditSocket(clientSktHandle, EPOLLIN, cast(void*) this);
         else static if (serverino.common.Backend == BackendType.KQUEUE)
         {
            Daemon.addKqueueChange(clientSktHandle, EVFILT_WRITE, EV_DELETE | EV_DISABLE, cast(void*) this);
            Daemon.addKqueueChange(clientSktHandle, EVFILT_READ, EV_ADD | EV_ENABLE, cast(void*) this);
         }
      }

      hasBuffer = false;

      if (this.worker !is null && this.worker.communicator is this)
      {
         this.worker.communicator = null;
         this.worker.setStatus(WorkerInfo.State.IDLING);
      }

      if (file.isOpen)
      {
         try { file.close(); }
         catch (Exception e) { warning("Error closing file: ", e.msg); }

         file = File.init;
      }

      if (fileToDelete.length > 0)
      {
         try {
            import std.file : remove;
            remove(fileToDelete);
            fileToDelete = null;
         }
         catch (Exception e) { warning("Error deleting file: ", e.msg); }
      }

      this.worker    = null;
      lastRequest    = now;
      responseLength = 0;
      responseSent   = 0;
      isSendFile     = false;
   }

   // Assign a worker to the communicator
   void setWorker(WorkerInfo worker)
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
   void onWriteAvailable()
   {
      if (isSendFile)
      {
         if (file.eof && sendBuffer.length == 0)
         {
            unsetWorker();

            if (requestToProcess !is null && requestToProcess.isValid)
                  Communicator.pushToWaitingList(this);

            if (!isKeepAlive)
               reset();

            return;
         }
         else if (sendBuffer.length > 0)
         {
            buffer_again: immutable sent = clientSkt.send(sendBuffer.array);

            if (sent == Socket.ERROR)
            {
               version(Posix)
               {
                  import core.stdc.errno : errno, EINTR;
                  if (errno == EINTR) goto buffer_again;
               }

               if(!wouldHaveBlocked)
               {
                  log("Socket Error");
                  reset();
                  return;
               }

               debug warning("Blocked buffer");
               return;
            }
            else
            {
               auto notsent = sendBuffer.length() - sent;

               if (notsent > 0)
               {
                  import std.algorithm : copy;
                  copy(sendBuffer.array[sent..$], sendBuffer.array[0..notsent]);
                  sendBuffer.length = notsent;
               }
               else sendBuffer.clear();
            }

            // Refill buffer is not so full
            if (sendBuffer.length < DEFAULT_BUFFER_SIZE)
            {
               if (!file.eof)
               {
                  char[DEFAULT_BUFFER_SIZE] buffer = void;
                  char[] read;
                  try { read = file.rawRead(buffer); }
                  catch (Exception e) { warning("Error reading file: ", e.msg); reset(); return; }

                  if (read.length > 0)
                     sendBuffer.append(read);
               }
            }

         }
      }
      else
      {
         auto maxToSend = bufferSent + DEFAULT_BUFFER_SIZE;
         if (maxToSend > sendBuffer.length) maxToSend = sendBuffer.length;

         if (maxToSend == 0)
            return;

         again: immutable sent = clientSkt.send(sendBuffer.array[bufferSent..maxToSend]);

         if (sent >= 0)
         {
            bufferSent += sent;
            responseSent += sent;

            if(bufferSent == sendBuffer.length)
            {

               if(hasBuffer)
               {
                  hasBuffer = false;

                  static if (serverino.common.Backend == BackendType.EPOLL)
                     Daemon.epollEditSocket(clientSktHandle, EPOLLIN, cast(void*) this);
                  else static if (serverino.common.Backend == BackendType.KQUEUE)
                  {
                     Daemon.addKqueueChange(clientSktHandle, EVFILT_WRITE, EV_DELETE | EV_DISABLE, cast(void*) this);
                     Daemon.addKqueueChange(clientSktHandle, EVFILT_READ, EV_ADD | EV_ENABLE, cast(void*) this);
                  }
               }

               bufferSent = 0;
               sendBuffer.clear();

               // If the response is completed, unset the worker
               // and if the client is not keep alive, reset the communicator
               if (completed())
               {
                  unsetWorker();

                  if (requestToProcess !is null && requestToProcess.isValid)
                        Communicator.pushToWaitingList(this);

                  if (!isKeepAlive)
                  {
                     // Proactively half-close the write side for connection: close
                     clientSkt.shutdown(SocketShutdown.SEND);
                     reset();
                  }
               }
            }

         }
         else
         {
            version(Posix)
            {
               import core.stdc.errno : errno, EINTR;
               if (errno == EINTR) goto again;
            }

            if(!wouldHaveBlocked)
            {
               log("Socket Error");
               reset();
               return;
            }
         }

      }
   }

   void writeFile(scope char[] data, bool deleteOnClose)
   {
      import std.string : indexOf, strip;

      if (clientSkt is null)
      {
         reset();
         return;
      }

      // Get the file name from the data, after the http headers
      auto headers = data[0..data.indexOfSeparator + 4];
      auto fileName = data[headers.length..$].strip;

      // Open the file
      try { file = File(fileName, "rb"); }
      catch(Exception e) { file = File.init; warning("Error opening file: ", e.msg); }

      if (!file.isOpen)
      {
         clientSkt.send("HTTP/1.0 404 Not Found\r\n\r\n");
         reset();
         return;
      }

      if (deleteOnClose)
         fileToDelete = fileName.to!string;

      responseLength = cast(size_t)(file.size + headers.length);

      sendBuffer.append(headers);

      hasBuffer = true;

      static if(serverino.common.Backend == BackendType.EPOLL)
         Daemon.epollEditSocket(clientSktHandle, EPOLLIN | EPOLLOUT, cast(void*) this);
      else static if(serverino.common.Backend == BackendType.KQUEUE)
      {
         Daemon.addKqueueChange(clientSktHandle, EVFILT_READ, EV_DELETE | EV_DISABLE, cast(void*) this);
         Daemon.addKqueueChange(clientSktHandle, EVFILT_WRITE, EV_ADD | EV_ENABLE, cast(void*) this);
      }

      onWriteAvailable();
   }

   // Try to write the data to the client socket, it buffers the data if the socket is not ready
   void write(scope char[] data)
   {
      if (clientSkt is null)
      {
         reset();
         return;
      }

      if (sendBuffer.length == 0)
      {
         again: auto sent = clientSkt.send(data);

         if (sent >= 0)
         {
            responseSent += sent;
            if (sent < data.length)
            {
               sendBuffer.append(data[sent..data.length]);

               hasBuffer = true;
               static if(serverino.common.Backend == BackendType.EPOLL)
                  Daemon.epollEditSocket(clientSktHandle, EPOLLIN | EPOLLOUT, cast(void*) this);
               else static if(serverino.common.Backend == BackendType.KQUEUE)
               {
                  Daemon.addKqueueChange(clientSktHandle, EVFILT_READ, EV_DELETE | EV_DISABLE, cast(void*) this);
                  Daemon.addKqueueChange(clientSktHandle, EVFILT_WRITE, EV_ADD | EV_ENABLE, cast(void*) this);
               }
            }

            // If the response is completed, unset the worker
            // and if the client is not keep alive, reset the communicator
            else if (completed())
            {
               unsetWorker();

               if (requestToProcess !is null && requestToProcess.isValid)
                  Communicator.pushToWaitingList(this);

               if (!isKeepAlive)
               {
                  // Proactively half-close the write side for connection: close
                  clientSkt.shutdown(SocketShutdown.SEND);
                  reset();
               }
            }
         }
         else
         {
            version(Posix)
            {
               import core.stdc.errno : errno, EINTR;
               if (errno == EINTR) goto again;
            }

            if(!wouldHaveBlocked)
            {
               log("Socket error on write. ", lastSocketError);
               reset();
               return;
            }
            else sendBuffer.append(data);
         }
      }
      else
      {
         sendBuffer.append(data);
         onWriteAvailable();
      }
   }

   // Read the data from the client socket and parse the incoming data
   void onReadAvailable()
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

      char[DEFAULT_BUFFER_SIZE] buffer = void;
      ptrdiff_t bytesRead = 0;

      // Read the data from the client socket if it's not buffered
      // Set the requestDatareceived flag to true if the first data is read to check for timeouts
      again: bytesRead = clientSkt.receive(buffer);
      lastRecv = now;

      if (bytesRead > 0)
      {
         if (requestDataReceived == false) requestDataReceived = true;

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
            // This is set to true if there's more data to parse after the current request (probably a pipelined request)
            bool hasMoreDataToParse = false;

            // Another cycle is needed if there's more data to parse or a body to read
            tryParse = false;

            // We are still waiting for the headers to be completed
            if (status == State.READING_HEADERS)
            {

               auto headersEnd = bufferRead.indexOfSeparator;

               enum MAX_HEADERS_SIZE = 16*1024; // This should be enough for the headers

               // Are the headers completed?
               if (headersEnd >= 0 && headersEnd < MAX_HEADERS_SIZE)
               {

                  // Extra data after the headers is stored in the leftover buffer
                  request.data ~= bufferRead[0..headersEnd];
                  leftover = bufferRead[headersEnd+4..$].dup;

                  // The headers are completed
                  bufferRead.length = 0;
                  request.isValid = true;

                  auto firstLine = request.data.indexOfNewline;

                  // HACK: A single line (http 1.0?) request.
                  if (firstLine < 0)
                  {
                     firstLine = request.data.length;
                     request.data ~= "\r\n";
                  }

                  if (firstLine < 18)
                  {
                     request.isValid = false;
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n\r\n");
                     debug warning("Bad Request. Request line too short.");
                     reset();
                     return;
                  }

                  import std.algorithm : splitter;

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
                     request.uri = fields.front;
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
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n\r\n");
                     debug warning("Bad Request. Http version unknown.");
                     reset();
                     return;
                  }

                  if (popped != 3 || !fields.empty)
                  {
                     request.isValid = false;
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n\r\n");
                     debug warning("Bad Request. Malformed request line.");
                     reset();
                     return;
                  }

                  if (request.uri[0] != '/')
                  {
                     request.isValid = false;
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n\r\n");
                     debug warning("Bad Request. Absolute uri?");
                     reset();
                     return;
                  }

                  static DataBuffer!char hdrs = DataBuffer!char(MAX_HEADERS_SIZE+2);
                  hdrs.clear();

                  // Parse headers for 100-continue, content-length and connection
                  foreach(ref char[] row; request.data[firstLine+2..$].newlineSplitter)
                  {

                     auto headerColon = row.indexOf(':');

                     if (headerColon < 0)
                     {
                        request.isValid = false;
                        break;
                     }

                     // Headers keys are case insensitive, so we lowercase them
                     // We strip the leading and trailing spaces from both key and value
                     char[] key = cast(char[])row[0..headerColon].strip!(x =>x==' ' || x=='\t');
                     char[] value = cast(char[])row[headerColon+1..$].strip!(x =>x==' '|| x=='\t');

                     // Fast way to lowercase the key. Check if it is ASCII only.
                     foreach(ref k; key)
                     {
                        if (k >= 0x7F)
                        {
                           request.isValid = false;
                           break;
                        }
                        else if (k >= 'A' && k <= 'Z')
                        k |= 32;
                     }

                     foreach(ref k; value)
                     {
                        if (k >= 0x7F)
                        {
                           request.isValid = false;
                           break;
                        }
                     }

                     if (key.length == 0)
                     {
                        request.isValid = false;
                        break;
                     }

                     // 100-continue
                     if (key == "expect" && value.length == 12 && value[0..4] == "100-") request.expect100 = true;
                     else if (key == "connection")
                     {
                        import std.uni: sicmp;
                        import std.string : CaseSensitive;

                        if (sicmp(value, "keep-alive") == 0) request.connection = ProtoRequest.Connection.KeepAlive;
                        else if (sicmp(value, "close") == 0) request.connection = ProtoRequest.Connection.Close;
                        else if (value.indexOf("upgrade", CaseSensitive.no) >= 0) request.connection = ProtoRequest.Connection.Upgrade;
                        else request.connection = ProtoRequest.connection.Unknown;
                     }
                     else
                     {
                        if (key == "content-length")
                        {
                           if (value.length == 0)
                           {
                              request.isValid = false;
                              break;
                           }

                           request.contentLength = 0;
                           foreach (c; value)
                           {
                              if (c < '0' || c > '9')
                              {
                                 request.isValid = false;
                                 break;
                              }

                              if (request.contentLength > (size_t.max - (c - '0')) / 10)
                              {
                                 request.isValid = false;
                                 break;
                              }

                              request.contentLength = request.contentLength * 10 + (c - '0');
                           }
                        }
                     }

                     hdrs.append(key, [':'], value, ['\r', '\n']);
                  }

                  hdrs.append(['\r', '\n']);

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

                  request.data[firstLine+2+ra.length..$] = hdrs.array;

                  if (request.isValid == false)
                  {
                     clientSkt.send("HTTP/1.0 400 Bad Request\r\n\r\n");
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
                        clientSkt.send("HTTP/1.0 413 Request Entity Too Large\r\n\r\n");
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
                     requestDataReceived = false; // Request completed, we can reset the timeout
                     hasMoreDataToParse = leftover.length > 0;

                     if(request == requestToProcess)
                        pushToWaitingList(this);

                     if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
                     else status = State.READY;

                  }
               }
               // Max 16k of headers
               else if (bufferRead.length >= MAX_HEADERS_SIZE)
               {
                  clientSkt.send("HTTP/1.0 431 Request Header Fields Too Large\r\n\r\n");
                  reset();
                  return;
               }
               else leftover = bufferRead.dup;

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

                  requestDataReceived = false; // Request completed, we can reset the timeout

                  leftover = request.data[request.headersLength + request.contentLength..$].dup;
                  request.data = request.data[0..request.headersLength + request.contentLength];
                  request.isValid = true;

                  if(request == requestToProcess)
                     pushToWaitingList(this);

                  hasMoreDataToParse = leftover.length > 0;

                  if (request.connection == ProtoRequest.Connection.KeepAlive) status = State.KEEP_ALIVE;
                  else status = State.READY;

               }
            }

            if (hasMoreDataToParse)
            {
               // There's a (partial) new request in the buffer, we need to create a new request
               request.next = new ProtoRequest();
               request = request.next;
               status = State.READING_HEADERS;

               bufferRead = leftover.dup;
               leftover.length = 0;

               // We try to parse the new request immediately
               tryParse = true;
            }
         }
      }
      else if (bytesRead == 0)
      {
         // Connection closed.
         status = State.READY;
         reset();
         return;
      }
      else
      {
         version(Posix)
         {
            import core.stdc.errno : errno, EINTR;
            if (errno == EINTR) goto again;
         }

         if(!wouldHaveBlocked)
         {
            status = State.READY;

            version(Posix)
            {
               import core.stdc.errno : errno, ECONNRESET;
               if (errno != ECONNRESET) log("Socket error on read. ", lastSocketError);
               else debug log("Socket error on read. ", lastSocketError);
            }
            else debug log("Socket error on read. ", lastSocketError);

            reset();
         }

         return;
      }


   }

   pragma(inline, true)
   static void pushToWaitingList(Communicator c)
   {

      // if it is already in the list, we don't add it again
      if ( execWaitingListFront == c || c.prevWaiting !is null)
      {
         return;
      }

      if (execWaitingListFront is null)
      {
         execWaitingListFront = c;
         execWaitingListBack = c;
      }
      else
      {
         execWaitingListBack.nextWaiting = c;
         c.prevWaiting = execWaitingListBack;
         execWaitingListBack = c;
      }
   }


   pragma(inline, true)
   static Communicator popFromWaitingList()
   {
      assert (execWaitingListFront !is null);

      auto c = execWaitingListFront;
      execWaitingListFront = c.nextWaiting;

      if (execWaitingListFront is null) execWaitingListBack = null;
      else execWaitingListFront.prevWaiting = null;

      c.nextWaiting = null;
      assert(c.prevWaiting is null);
      return c;
   }

   DataBuffer!char   sendBuffer;
   size_t            bufferSent;

   bool              hasBuffer = false; // Used only on EPOLL and KQUEUE

   bool              requestDataReceived;
   bool              isKeepAlive;
   bool              isSendFile        = false;
   string            fileToDelete      = null;
   File              file;

   size_t            responseSent;
   size_t            responseLength;
   size_t            id;

   Socket            clientSkt;
   socket_t          clientSktHandle = socket_t.max;  // For KQUEUE and EPOLL, we need to keep the socket handle

   ProtoRequest      requestToProcess;
   WorkerInfo        worker;
   char[]            leftover;

   CoarseTime        lastRecv    = CoarseTime.zero;
   CoarseTime        lastRequest = CoarseTime.zero;

   Communicator      next = null;
   Communicator      prev = null;

   Communicator      nextWaiting = null;
   Communicator      prevWaiting = null;

   static Communicator  alives   = null; // Communicators with a client socket assigned
   static Communicator  deads    = null;  // Communicators without a client socket assigned

   static Communicator  execWaitingListFront = null; // Communicators waiting for a worker
   static Communicator  execWaitingListBack = null; // Communicators waiting for a worker

   Communicator.State    status;
}
