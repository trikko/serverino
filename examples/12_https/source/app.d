import serverino;
import std.stdio;

// Use a fallback handler for all requests
void hello(Request request, Output output)
{
    output ~= `<html><body style="font-family:sans-serif; background:#fafafa; display:flex; justify-content:center; align-items:center; height:100vh; margin:0;">
        <div style="background:#fff; padding:40px; border-radius:12px; box-shadow:0 10px 15px -3px rgba(0,0,0,0.1); border-top:5px solid #10b981;">
            <h1 style="margin:0 0 10px 0;">Serverino Secure</h1>
            <p style="color:#666; margin-bottom:20px;">You are connected via HTTPS.</p>
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

    return ServerinoConfig.create()
        .enableHttps() 

        // You can add multiple certificates.
        // Create a simple self-signed cert with openssl (for "localhost"):
        // openssl req -x509 -newkey rsa:4096 -keyout server.key -out server.crt -days 365 -nodes -subj '/C=IT/ST=Italy/L=Venice/O=Example/OU=ICT/CN=localhost'
        
        // The first one added acts as the default/fallback certificate.
        .addHttpsCertificate("server.crt", "server.key")
        .addHttpsCertificate("server1.crt", "server1.key")
        // .addHttpsCertificate("another_domain.crt", "another_domain.key")
        
        .addListener("0.0.0.0", 8443);
}

mixin ServerinoMain;
