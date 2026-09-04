// Host cell: form action + Redis JSON. Offline → skip.
// Third-party packages are the engine graph — same as PG/Redis via helpers.
import helpers;
import vibe.db.redis.redis;
import vibe.db.pgsql.pgsql;
import botan.passhash.bcrypt;
import std.conv : to;

void postProbe(HTTPServerRequest req, HTTPServerResponse res)
{
	Json payload = Json.emptyObject;
	payload["action"] = "probe";
	payload["n"] = to!string(1);
	try
	{
		auto redis = connectCache();
		redis.set("admin:probe", payload.serializeToJsonString());
		payload["redis"] = redis.get!string("admin:probe");
	}
	catch (Exception)
	{
		payload["redis"] = "skip";
	}
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
