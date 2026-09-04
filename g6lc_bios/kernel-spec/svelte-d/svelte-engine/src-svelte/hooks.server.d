// Target: vibe.0 HTTPServerSettings.errorPageHandler (host cell).
import vibe.http.server;

void handleError(HTTPServerRequest req, HTTPServerResponse res, HTTPServerErrorInfo error)
{
	res.writeBody("hook-error");
}
