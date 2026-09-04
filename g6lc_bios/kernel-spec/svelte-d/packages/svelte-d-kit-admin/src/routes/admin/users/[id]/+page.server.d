// Host cell: cookies + redirect + JSON + optional PG. $app env is host-only here.
import helpers;
import generated.kit.app_environment;
import generated.kit.env_static_public;

void getUser(HTTPServerRequest req, HTTPServerResponse res)
{
	auto id = req.cookies.get("who");
	if (!id.length)
	{
		res.redirect("/__svelte-d/host/users");
		return;
	}
	Json payload = Json.emptyObject;
	payload["id"] = id;
	payload["server"] = server;
	payload["app"] = PUBLIC_APP_NAME;
	try
	{
		auto pgconn = connectDB();
		auto sel = scoped!PGCommand(pgconn, "SELECT 1");
		sel.executeQuery();
		payload["postgres"] = "up";
	}
	catch (Exception)
	{
		payload["postgres"] = "skip";
	}
	res.setCookie("seen", id);
	res.headers["X-Svelte-D"] = "admin-user";
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
