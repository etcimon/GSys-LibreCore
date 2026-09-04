// Target: vibe.0 load — cookies, redirect, setHeaders; $env/static/private host-only.
import vibe.http.server;
import generated.kit.env_static_private;
import generated.kit.app_environment;

void get(HTTPServerRequest req, HTTPServerResponse res)
{
	auto who = req.cookies.get("who");
	if (!who.length)
	{
		res.redirect("/inbox");
		return;
	}
	res.headers["X-Svelte-D"] = "account";
	res.setCookie("cell", server ? "host" : "wasm");
	res.writeBody(SECRET_TOKEN);
}
