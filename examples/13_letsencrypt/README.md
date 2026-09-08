# Let's Encrypt from inside serverino

A https server that gets and renews its own certificate, answering the ACME
`http-01` challenge by itself: no reverse proxy in front, no helper process, no
restart when the certificate is renewed.

Two listeners in the same process:

* the plain one serves `/.well-known/acme-challenge/<token>` out of the
  directory the ACME client fills, and redirects everything else to https;
* the encrypted one serves the site.

After a renewal `Daemon.reloadCertificates()` swaps the certificate in place, so
connections already established keep working and the process is never restarted.

## Requirements

* POSIX only (so is serverino's TLS support), and the `https` subconfiguration —
  already set in `dub.json`;
* `certbot` and `openssl` at run time. Any other ACME client does as well, see
  [Another ACME client](#another-acme-client);
* the domain must resolve **to this machine**, and port 80 must be reachable
  from the internet. That is what `http-01` requires, not serverino;
* nothing else may be listening on the ports you pick: on a server that usually
  means stopping nginx/apache first.

## Build

```bash
dub build --build=release
```

## Try it out locally, without touching a CA

`--no-renew` keeps the renewal task off, so nothing is ever asked to Let's
Encrypt. Handy to look at the challenge endpoint and the redirect:

```bash
./letsencrypt_example --domain localhost --http 8080 --https 8443 --no-renew

echo hello > acme-state/webroot/.well-known/acme-challenge/token
curl http://localhost:8080/.well-known/acme-challenge/token   # hello
curl -sI http://localhost:8080/                               # 301 to https
curl -k https://localhost:8443/                               # the page
```

The certificate served here is the self-signed placeholder described below,
hence `curl -k`.

## Run it on a server

Ports 80 and 443 need privileges, and they must be free:

```bash
sudo systemctl stop nginx           # or apache2, or whatever owns 80/443

# staging first: no rate limits while you get it right
sudo ./letsencrypt_example --domain www.example.com --email you@example.com

# happy? ask the real CA
sudo ./letsencrypt_example --domain www.example.com --email you@example.com --production
```

Staging is the default on purpose: its certificates are not trusted by browsers,
but hitting Let's Encrypt's rate limits while experimenting is unpleasant.
`--email` is optional; without it the account is registered with
`--register-unsafely-without-email`.

What happens on the first run:

1. there is no certificate yet, and a listener needs one to start, so a
   self-signed **placeholder** is generated (its subject carries
   `serverino-acme-placeholder`);
2. both listeners come up, https included;
3. the renewal task sees the placeholder and asks for a real certificate right
   away: `certbot certonly --webroot` publishes the token in the directory this
   server is already serving;
4. the new certificate is installed and loaded. From here on the process never
   needs to be restarted.

The log tells the story:

```
No certificate yet: generating a self-signed placeholder for www.example.com
Listening on http://0.0.0.0:80/
Listening on https://0.0.0.0:443/
Renewing the certificate: certbot certonly --webroot ...
New certificate installed and loaded. No restart needed.
```

Everything lives under `--state` (`./acme-state` by default):

```
acme-state/cert.pem                     # what the listener uses
acme-state/key.pem
acme-state/webroot/.well-known/acme-challenge/     # tokens, served by the app
acme-state/letsencrypt/                 # certbot's own --config-dir
```

certbot is given a private `--config-dir`, `--work-dir` and `--logs-dir` in
there, so it never touches `/etc/letsencrypt` nor the certificates another
client may already manage on the machine.

## Renewal

The expiry is checked twice a day (`--check-every`, in minutes) and a renewal
starts 30 days before the certificate expires. A failed renewal is logged and
retried at the next check, keeping the certificate currently in use: a broken
renewal never brings the server down.

You can also trigger a reload from outside, without a renewal — useful if some
other tool updated the files:

```bash
sudo kill -HUP $(pgrep -f letsencrypt_example)
```

## Another ACME client

`--renew-command` replaces the certbot call with a shell command. It gets what
it needs from the environment:

| variable | meaning |
|---|---|
| `ACME_DOMAIN` | the domain |
| `ACME_CHALLENGE_DIR` | where to publish the token (this server serves it) |
| `ACME_WEBROOT` | the root of that directory |
| `ACME_CERT_OUT` / `ACME_KEY_OUT` | where to leave the new certificate |
| `ACME_STATE_DIR` | the state directory |
| `ACME_STAGING` | `1` unless `--production` |

With [dehydrated](https://github.com/dehydrated-io/dehydrated):

```bash
sudo ./letsencrypt_example --domain www.example.com --production \
   --renew-command 'dehydrated --cron --accept-terms -d "$ACME_DOMAIN" &&
      cp /var/lib/dehydrated/certs/"$ACME_DOMAIN"/fullchain.pem "$ACME_CERT_OUT" &&
      cp /var/lib/dehydrated/certs/"$ACME_DOMAIN"/privkey.pem "$ACME_KEY_OUT"'
```

The certificate is reloaded only if the files actually changed, so a command
that decides there is nothing to renew costs nothing.

## As a service

```ini
[Unit]
Description=serverino + Let's Encrypt
After=network-online.target

[Service]
ExecStart=/opt/mysite/letsencrypt_example --domain www.example.com --production --state /var/lib/mysite
Restart=always
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
```

`AmbientCapabilities=CAP_NET_BIND_SERVICE` lets it bind 80 and 443 without
running as root; the `--state` directory must then be writable by the service
user, since that is where the ACME client works.

## If it does not work

* `certbot failed (status 1)` in the log: the reason is in certbot's output,
  right below. Nine times out of ten it is the domain not pointing here, or
  port 80 not reachable from outside (firewall, security group);
* the page says *"This is still the self-signed placeholder"*: no renewal has
  succeeded yet - check the log, or whether you are running with `--no-renew`;
* browsers complain about the certificate: you are on the staging CA, add
  `--production`.
