// Host cell: vibe.0 Redis + JSON. Offline → skip.
import helpers;

void getLogs(HTTPServerRequest req, HTTPServerResponse res)
{
	Json payload = Json.emptyObject;
	try
	{
		auto redis = connectCache();
		redis.set("admin:log", `{"msg":"boot"}`);
		payload["redis"] = redis.get!string("admin:log");
	}
	catch (Exception)
	{
		payload["redis"] = "skip";
	}
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
