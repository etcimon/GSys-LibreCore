// Target: vibe.0 registerWebInterface endpoint (host cell).
import vibe.http.server;

void post(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("board-post");
}
