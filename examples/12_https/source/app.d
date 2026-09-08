import serverino;
import std.stdio;

// Plain http and https live in the same process, on two different listeners.
// Requests to the plain one are redirected, but for the sake of the example
// /insecure is served in clear too.
@endpoint @priority(100)
auto forceHttps(Request request, Output output)
{
    if (request.isSecure) return Fallthrough.Yes;
    if (request.path == "/insecure") return Fallthrough.Yes;

    output.status = 301;
    output.addHeader("location", "https://localhost:8443" ~ request.path);
    return Fallthrough.No;
}

// Use a fallback handler for all requests
@endpoint
void hello(Request request, Output output)
{
    output ~= `<html><body style="font-family:sans-serif; background:#fafafa; display:flex; justify-content:center; align-items:center; height:100vh; margin:0;">
        <div style="background:#fff; padding:40px; border-radius:12px; box-shadow:0 10px 15px -3px rgba(0,0,0,0.1); border-top:5px solid ` ~ (request.isSecure ? "#10b981" : "#f59e0b") ~ `;">
            <h1 style="margin:0 0 10px 0;">Serverino ` ~ (request.isSecure ? "Secure" : "Insecure") ~ `</h1>
            <p style="color:#666; margin-bottom:20px;">` ~ (request.isSecure ? "You are connected via HTTPS." : "You are connected via plain HTTP.") ~ `</p>
            <div style="display:flex; flex-direction:column; gap:10px;">
                <code style="background:#eee; padding:5px 10px; border-radius:4px;">Host: ` ~ request.host ~ `</code>
                <code style="background:#eee; padding:5px 10px; border-radius:4px;">Path: ` ~ request.path ~ `</code>
            </div>
        </div></body></html>`;
}

@onServerInit
ServerinoConfig configure()
{
    // Note: This example works only on posix systems (linux, macOS, ...)

    // Note: To test SNI with different domains locally,
    // you might need to add them to your /etc/hosts file.
    // e.g., 127.0.0.1 localhost domain1.test domain2.test

    // Certificates are attached to a listener, so plain and encrypted
    // listeners can be mixed in the same process.
    // Create a simple self-signed cert with openssl (for "localhost"):
    // openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj '/C=IT/ST=Italy/L=Venice/O=Example/OU=ICT/CN=localhost'

    // The first certificate of the set is the default one, the others are picked using SNI.
    auto certificates = Https("server.crt", "server.key");

    // The set can also be built at runtime, for example reading a directory:
    // foreach(f; dirEntries("certs", "*.crt", SpanMode.shallow))
    //    certificates.add(f.name, f.name.setExtension(".key"));

    return ServerinoConfig.create()
        .addListener("0.0.0.0", 8080)                   // plain http
        .addListener("0.0.0.0", 8443, certificates);    // https
}

// Certificates are read when the daemon starts. After renewing them (certbot, acme, ...)
// call Daemon.reloadCertificates() — or just send a SIGHUP to the daemon — and the
// listeners pick the new ones up without restarting the server. Connections already
// established keep working with the certificate they were built with.
//
//    import serverino.daemon : Daemon;
//    Daemon.reloadCertificates();

mixin ServerinoMain;
