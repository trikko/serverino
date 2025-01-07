module simplesession;
import serverino.interfaces;
import std;

// This is just a simple session manager
// It saves the session data in a file and uses the session_id cookie to identify the session.
// The session will expire after the maxAge.
// Probably not suitable for production, I think you want to use a database, instead.
// But it's a good example of how to use sessions in serverino.
// TODO: set cookie path, domain, secure, httpOnly, sameSite as needed
struct SimpleSession
{
   // Returns a safe session ID, it's not guessable and it's not predictable
   // This can be used to generate a session ID for a new session in a real application
   static string safeSessionID(uint length = 32)
   {
      ubyte[] value = new ubyte[length];

      // Random bytes
      version(Windows)
      {
         // On Windows, we use the Windows Cryptography API to generate random bytes
         import core.sys.windows.windows;
         import core.sys.windows.wincrypt;

         HCRYPTPROV hProvider;

         CryptAcquireContext(&hProvider, null, null, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT);
         CryptGenRandom(hProvider, cast(uint)value.length, value.ptr);
         CryptReleaseContext(hProvider, 0);
      }
      else {
         // On other platforms, we use the /dev/urandom device to generate random bytes
         value[0..$] = cast(ubyte[])read("/dev/urandom", value.length);
      }

      return value.toHexString.toLower;
   }

   // The constructor takes the request, the output and the max age of the session.
   // It also takes the store directory, which defaults to ./sessions.
   this(const Request r, ref Output o, Duration maxAge = 15.minutes, string storeDir = "./sessions")
   {
      output = &o;

      _storeDir = storeDir;
      _session_id = r.cookie.read("session_id");
      _isNew = _session_id.length == 0;
      _maxAge = maxAge;

      if (_isNew) _session_id = safeSessionID();
   }

   // Returns the session ID
   string id() { return _session_id; }

   // Saves the session data to a file
   void save(JSONValue sessionData)
   {
      auto file = buildPath(_storeDir, _session_id[0..1], _session_id);
      file.dirName.mkdirRecurse();

      JSONValue data;
      data["data"] = sessionData;
      data["expireAt"] = Clock.currTime.toUnixTime + _maxAge.total!"seconds";

      std.file.write(file, data.toString(JSONOptions.none));

      if (_isNew)
         output.setCookie(Cookie("session_id", _session_id).httpOnly(true));
   }

   // Loads the session data from a file
   JSONValue load()
   {
      auto file = buildPath(_storeDir, _session_id[0..1], _session_id);
      file.dirName.mkdirRecurse();

      try
      {
         if (!file.exists) _data = parseJSON("{}");
         else
         {
            auto tmp = parseJSON(cast(string)file.read);
            _data = tmp["data"];

            auto expireAt = tmp["expireAt"].get!long;

            if (expireAt < Clock.currTime.toUnixTime)
            {
               warning("Session expired, removing");
               remove();
            }

         }
      }
      catch(Exception e) { warning("Error loading session, removing."); remove(); }

      return _data;
   }

   // Removes the session data from the file and invalidates the session cookie
   void remove()
   {
      output.setCookie(Cookie("session_id", _session_id).httpOnly(true).invalidate());

      _session_id = safeSessionID();
      _isNew = true;
      _data = parseJSON("{}");

      auto file = buildPath(_storeDir, _session_id[0..2], _session_id);

      if (file.exists) file.remove();
   }

   // Returns true if the session is new
   bool isNew()   { return _isNew; }

   private:

   Output      *output;
   JSONValue   _data;
   Duration    _maxAge;
   string      _session_id;
   string      _storeDir;
   bool        _isNew = true;
}
