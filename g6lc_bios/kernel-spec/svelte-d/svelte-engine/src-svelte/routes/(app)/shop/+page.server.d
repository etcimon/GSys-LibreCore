// Target: vibe.0 registerWebInterface (host cell).
import vibe.http.server;

void get(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("shop");
}
