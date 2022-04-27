# serverino
Small and ready-to-go http/https server, in D.

## Ready-to-go in less than a minute
You can serve a html page in just three lines

```d
import serverino;
mixin ServerinoMain;
void hello(const Request req, Output output) { output ~= req.dump(); }
```
