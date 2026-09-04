// Target: vibe.0 registerWebInterface method (host cell, not wasm).
// Copied as-is by the later printer into webserver/source/generated/.
module svelte_engine.routes.page_server;

import vibe.http.server;

void get(HTTPServerRequest req, HTTPServerResponse res)
{
	res.writeBody("svelte-engine");
}
