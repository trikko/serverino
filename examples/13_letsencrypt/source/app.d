/+
 + A https server that gets (and renews) its own Let's Encrypt certificate,
 + answering the ACME http-01 challenge by itself. No reverse proxy, no helper
 + process, no restart on renewal.
 +
 + Two listeners in the same process: the plain one answers
 + /.well-known/acme-challenge/<token> and redirects everything else, the
 + encrypted one serves the site. When the certificate is renewed,
 + Daemon.reloadCertificates() swaps it in place: connections already
 + established keep working.
 +
 + The only external tool is certbot (plus openssl). It is used in webroot mode
 + on the very same directory this server publishes. Any other ACME client does
 + just as well: --renew-command replaces the certbot call, and gets what it
 + needs from the environment (see renewWithCommand below). With dehydrated:
 +
 +    --renew-command 'dehydrated --cron --accept-terms -d "$ACME_DOMAIN" &&
 +       cp /var/lib/dehydrated/certs/"$ACME_DOMAIN"/fullchain.pem "$ACME_CERT_OUT" &&
 +       cp /var/lib/dehydrated/certs/"$ACME_DOMAIN"/privkey.pem "$ACME_KEY_OUT"'
 +
 +    sudo ./letsencrypt_example --domain www.example.com --production
 +
 + Ports 80 and 443 need privileges; to try it out without any:
 +
 +    ./letsencrypt_example --domain localhost --http 8080 --https 8443 --no-renew
 +
 + (--no-renew keeps the renewal task off, so nothing is asked to the CA: handy
 + to look at the challenge endpoint and the redirect without a real domain.
 + Without it the first renewal starts as soon as the daemon is up, because the
 + certificate in use is still the placeholder.)
 +
 + Note: the http-01 challenge requires the domain to resolve to this machine
 + and port 80 to be reachable from the internet. That's a requirement of ACME,
 + not of serverino.
 +/
module app;

import serverino;
import serverino.daemon : Daemon;

import std;
import core.thread : Thread;

mixin ServerinoMain;

enum CHALLENGE_PREFIX = "/.well-known/acme-challenge/";

// Written in the subject of the self-signed certificate we start with, so that
// the renewal task can tell a real certificate from our placeholder.
enum PLACEHOLDER_MARK = "serverino-acme-placeholder";

// Set by configure() in the daemon. Workers don't inherit the command line, so
// what they need is exported to the environment in @onDaemonStart.
__gshared
{
   string   domain = "localhost";
   string   stateDir;
   string   email;
   bool     production;
   uint     checkEveryMinutes = 12 * 60;   // a certificate lasts 90 days: twice a day is plenty
   uint     renewBeforeDays = 30;
   string   renewCommand;
   ushort   httpPort = 80;
   ushort   httpsPort = 443;
   bool     noRenew;
}

string webrootDir() { return buildPath(stateDir, "webroot"); }
string challengeDir() { return buildPath(webrootDir, ".well-known", "acme-challenge"); }
string certFile() { return buildPath(stateDir, "cert.pem"); }
string keyFile() { return buildPath(stateDir, "key.pem"); }

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

@onServerInit
ServerinoConfig configure(string[] args)
{
   string state = "acme-state";

   try
   {
      auto opts = getopt(args,
         "domain",      "Domain to get a certificate for",                  &domain,
         "http",        "Port of the plain listener (default: 80)",         &httpPort,
         "https",       "Port of the encrypted listener (default: 443)",    &httpsPort,
         "state",       "Where certificates and challenges live",           &state,
         "email",       "Email for the ACME account (optional)",            &email,
         "production",  "Use the real CA instead of the staging one",       &production,
         "check-every", "Minutes between two expiry checks (default: 720)", &checkEveryMinutes,
         "no-renew",    "Don't talk to the CA at all (to try the rest out)",  &noRenew,
         "renew-command", "Renew with this shell command instead of certbot",  &renewCommand
      );

      if (opts.helpWanted)
      {
         defaultGetoptPrinter("Serverino + Let's Encrypt (ACME http-01)\n", opts.options);
         return ServerinoConfig.create().setReturnCode(0, true);
      }
   }
   catch (Exception e)
   {
      stderr.writeln("Invalid arguments: ", e.msg);
      return ServerinoConfig.create().setReturnCode(1);
   }

   stateDir = state.absolutePath;
   mkdirRecurse(challengeDir);

   // A listener needs its certificate when it starts, so on the very first run we
   // bring up https with a self-signed placeholder: the renewal task replaces it
   // right away, and from then on the server never needs to be restarted.
   if (!certFile.exists || !keyFile.exists)
   {
      if (!createPlaceholder())
         return ServerinoConfig.create().setReturnCode(1);
   }

   return ServerinoConfig.create()
      .addListener("0.0.0.0", httpPort)                             // challenge + redirect
      .addListener("0.0.0.0", httpsPort, Https(certFile, keyFile))  // the site
      .setWorkers(2);
}

@onDaemonStart
void daemonStart()
{
   // Workers are started after this, and they inherit the environment.
   environment["ACME_DOMAIN"] = domain;
   environment["ACME_CHALLENGE_DIR"] = challengeDir;
   environment["ACME_HTTPS_PORT"] = httpsPort.to!string;
   environment["ACME_CERT"] = certFile;

   if (noRenew)
   {
      warning("Renewal disabled (--no-renew): the placeholder certificate stays in use.");
      return;
   }

   new Thread({
      Thread.getThis().isDaemon = true;

      while(true)
      {
         if (renewalNeeded) renew();
         Thread.sleep(checkEveryMinutes.minutes);
      }
   }).start();
}

// ----------------------------------------------------------------------------
// Endpoints
// ----------------------------------------------------------------------------

/+ The challenge must come first: it is the one thing that has to be served in
 + clear, before any redirect to https. +/
@endpoint @priority(100)
@route!(r => r.path.startsWith(CHALLENGE_PREFIX))
void acmeChallenge(Request request, Output output)
{
   immutable token = request.path[CHALLENGE_PREFIX.length .. $];

   // The token is a file name: refuse anything that could escape the directory.
   if (token.empty || token != token.baseName)
   {
      output.status = 400;
      return;
   }

   immutable path = buildPath(environment.get("ACME_CHALLENGE_DIR", ""), token);

   if (!path.exists || !path.isFile)
   {
      output.status = 404;
      return;
   }

   // The key authorization goes back as plain text, nothing else.
   output.addHeader("content-type", "text/plain");
   output ~= readText(path);
}

/// Everything else belongs to https. request.isSecure tells the two listeners apart.
@endpoint @priority(50)
auto forceHttps(Request request, Output output)
{
   if (request.isSecure) return Fallthrough.Yes;

   immutable port = environment.get("ACME_HTTPS_PORT", "443");
   immutable host = environment.get("ACME_DOMAIN", "localhost") ~ (port == "443" ? "" : ":" ~ port);

   output.status = 301;
   output.addHeader("location", "https://" ~ host ~ request.path);
   return Fallthrough.No;
}

@endpoint
void hello(Request request, Output output)
{
   immutable cert = environment.get("ACME_CERT", "");
   immutable subject = execute(["openssl", "x509", "-noout", "-subject", "-in", cert]).output.strip;
   immutable expires = execute(["openssl", "x509", "-noout", "-enddate", "-in", cert]).output.strip;

   output.addHeader("content-type", "text/html; charset=utf-8");
   output ~= "<!doctype html><html><head><title>Serverino + ACME</title></head>"
      ~ `<body style="font-family:sans-serif;max-width:40em;margin:4em auto">`
      ~ "<h1>Hello, HTTPS!</h1>"
      ~ "<p>The certificate below was requested, installed and reloaded by this very process.</p>"
      ~ "<pre>" ~ subject ~ "\n" ~ expires ~ "</pre>"
      ~ (subject.canFind(PLACEHOLDER_MARK)
         ? "<p><strong>This is still the self-signed placeholder.</strong> Waiting for the first renewal.</p>"
         : "")
      ~ "</body></html>";
}

// ----------------------------------------------------------------------------
// Certificate handling (daemon side)
// ----------------------------------------------------------------------------

bool createPlaceholder()
{
   info("No certificate yet: generating a self-signed placeholder for ", domain);

   auto res = execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650",
      "-keyout", keyFile, "-out", certFile,
      "-subj", "/CN=" ~ domain ~ "/OU=" ~ PLACEHOLDER_MARK]);

   if (res.status != 0)
   {
      critical("Cannot generate a placeholder certificate: ", res.output);
      return false;
   }

   return true;
}

bool isPlaceholder()
{
   auto res = execute(["openssl", "x509", "-noout", "-subject", "-in", certFile]);
   return res.status == 0 && res.output.canFind(PLACEHOLDER_MARK);
}

bool renewalNeeded()
{
   if (isPlaceholder) return true;

   // Exit code is 0 while the certificate is still valid that far in the future.
   auto res = execute(["openssl", "x509", "-checkend", (renewBeforeDays * 86_400).to!string,
      "-noout", "-in", certFile]);

   return res.status != 0;
}

/+ Renewal delegated to an external command. The contract is entirely made of
 + environment variables: the command publishes the challenge under
 + $ACME_CHALLENGE_DIR (which this server serves) and leaves the new certificate
 + in $ACME_CERT_OUT / $ACME_KEY_OUT. If those files change, they are reloaded.
+/
void renewWithCommand()
{
   auto env = environment.toAA;
   env["ACME_DOMAIN"] = domain;
   env["ACME_WEBROOT"] = webrootDir;
   env["ACME_CHALLENGE_DIR"] = challengeDir;
   env["ACME_CERT_OUT"] = certFile;
   env["ACME_KEY_OUT"] = keyFile;
   env["ACME_STATE_DIR"] = stateDir;
   env["ACME_STAGING"] = production ? "0" : "1";

   immutable before = fingerprint();

   info("Renewing the certificate: ", renewCommand);

   auto res = executeShell(renewCommand, env);

   if (res.status != 0)
   {
      warning("The renew command failed (status ", res.status, "):\n", res.output);
      return;
   }

   if (fingerprint() == before)
   {
      info("The certificate did not change: nothing to reload.\n", res.output);
      return;
   }

   Daemon.reloadCertificates();
   info("New certificate installed and loaded. No restart needed.");
}

string fingerprint()
{
   auto res = execute(["openssl", "x509", "-noout", "-fingerprint", "-sha256", "-in", certFile]);
   return res.status == 0 ? res.output.strip : "";
}

void renew()
{
   mkdirRecurse(challengeDir);

   if (renewCommand.length > 0)
   {
      renewWithCommand();
      return;
   }

   auto cmd = [
      "certbot", "certonly",
      "--webroot", "--webroot-path", webrootDir,   // the directory acmeChallenge() serves
      "-d", domain,
      "--config-dir", buildPath(stateDir, "letsencrypt"),
      "--work-dir", buildPath(stateDir, "certbot-work"),
      "--logs-dir", buildPath(stateDir, "certbot-logs"),
      "--non-interactive", "--agree-tos", "--no-eff-email", "--keep-until-expiring"
   ];

   cmd ~= email.empty ? ["--register-unsafely-without-email"] : ["-m", email];
   if (!production) cmd ~= "--staging";   // staging by default: no rate limits while trying out

   info("Renewing the certificate: ", cmd.join(" "));

   auto res = execute(cmd);

   if (res.status != 0)
   {
      warning("certbot failed (status ", res.status, "):\n", res.output);
      return;
   }

   immutable live = buildPath(stateDir, "letsencrypt", "live", domain);

   try
   {
      copy(buildPath(live, "fullchain.pem"), certFile);
      copy(buildPath(live, "privkey.pem"), keyFile);
   }
   catch (Exception e)
   {
      warning("Cannot install the new certificate: ", e.msg);
      return;
   }

   // Here's the point of the whole example: the listeners pick the new
   // certificate up without restarting, and requests in flight are not dropped.
   Daemon.reloadCertificates();
   info("New certificate installed and loaded. No restart needed.");
}
