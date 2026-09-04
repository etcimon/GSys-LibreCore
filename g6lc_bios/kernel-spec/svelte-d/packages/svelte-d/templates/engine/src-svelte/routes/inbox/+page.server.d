// Target: vibe.0 registerWebInterface actions (POST / and POST /save).
import vibe.http.server;

void post(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("inbox");
}

void postSave(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("inbox-save");
}
