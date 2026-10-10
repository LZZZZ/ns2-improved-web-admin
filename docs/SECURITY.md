# Securing the web admin

The engine's web admin speaks **plain HTTP**, with or without this mod. Its
HTTP Digest login keeps the password itself off the wire, but everything
after it crosses in the clear: names, Steam ids and IPs, chat, the server
log, and every command. A captured Digest exchange can be attacked offline
to guess the password. **Do not expose the web admin port to the internet
as it is.** The mod cannot add HTTPS: the web server is the engine's.

1. **Bind it to loopback** with `-webdomain 127.0.0.1`, and reach it
   through one of the next two.
2. **An SSH tunnel**, with nothing to set up on the server:

   ```
   ssh -N -L 8080:127.0.0.1:8080 you@your-server
   ```

   then open `http://127.0.0.1:8080/index.html` locally. The browser's
   `Host` and `Origin` are `127.0.0.1:8080`, which the engine accepts.
3. **An HTTPS reverse proxy** (nginx, Caddy, Apache, ...) for several
   admins and a bookmark. No proxy configuration is tested here, but the
   engine's rules it must satisfy were measured
   ([CONSTRAINTS.md](CONSTRAINTS.md#the-origin-rule)):
   - **`Origin` is compared with `Host`.** The browser sends your public
     site as the `Origin` of every `POST`, so either pass the public `Host`
     through unchanged, or send a loopback `Host` and rewrite a matching
     `Origin` to `http://127.0.0.1:<port>`. Rewrite only your own site's
     `Origin` and refuse others at the proxy, or the engine's cross-site
     protection is switched off.
   - **With no login configured, `Host` must be `localhost` or an IP**
     (09-25 and later), so the proxy must send a loopback `Host`.
   - **Who checks passwords:** either the engine (Digest through the
     proxy; not tested here), or the proxy, with the engine on loopback and
     no login. Then the proxy is the only lock, so nothing else may reach
     the engine's port.
   - **The failed-login lockout is per address**: 10 failures in a minute
     lock it out for a minute, and behind a proxy every admin shares one
     address.
   - Nothing else is needed: the panel makes only same-origin `GET` and
     `POST` requests, with no WebSockets.

   The mock applies the same `Origin` and `Host` rules (`node
   mock/server.js --web web`, without `--auth`), so a proxy configuration
   can be tried against it first.
4. **Prefer `-webusers` to `-webpassword`.** `-webusers` reads a Digest
   `.htpasswd` file; a password on the command line is visible to local
   users in the process list and ends up in crash dumps.
5. If it must listen on a public address, firewall the port to the
   addresses that need it, and feed `WebAdmin - rejected request from
   <address>` log lines to fail2ban.

The engine's changelog says the same web server serves the server's mod
backup downloads; if you rely on those, check what binding it to loopback
does to them.

What the panel itself shows and stores (masking, the recent-players file,
the log shown verbatim) is in [API.md](API.md#privacy).
