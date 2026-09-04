// Target: vibe.0 registerWebInterface (layout server, host cell).
import vibe.http.server;

void get(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("app-layout");
}
