// Host cell: vibe.0 JSON + Redis cache + PostgreSQL. Not libwasm / not PgLite.
import helpers;

void getAdmin(HTTPServerRequest req, HTTPServerResponse res)
{
	logTrace("admin getAdmin");
	Json payload = Json.emptyObject;
	payload["panel"] = "admin";
	try
	{
		auto redis = connectCache();
		redis.set("admin:ping", "1");
		payload["redis"] = redis.get!string("admin:ping");
		logInfo("admin redis ping ok");
	}
	catch (Exception e)
	{
		payload["redis"] = "skip";
		logWarn("admin redis skip: %s", e.msg);
	}
	try
	{
		auto pgconn = connectDB();
		auto sel = scoped!PGCommand(pgconn, "SELECT 1");
		sel.executeQuery();
		payload["postgres"] = "up";
		logInfo("admin postgres up");
	}
	catch (Exception e)
	{
		payload["postgres"] = "skip";
		logError("admin postgres skip: %s", e.msg);
	}
	res.writeBody(payload.serializeToJsonString(), "application/json");
}

/// Directed host soak: N Redis SETEX/GET + N Postgres SELECT 1.
/// Offline / bad creds → redis/postgres "skip:…". Do not invent a second DB stack.
void getSoak(HTTPServerRequest req, HTTPServerResponse res)
{
	int n = 16;
	try
	{
		auto q = req.query.get("n");
		if (q.length)
			n = to!int(q);
	}
	catch (Exception)
	{
	}
	if (n < 1)
		n = 1;
	if (n > 64)
		n = 64;
	Json payload = Json.emptyObject;
	payload["schema"] = "svelte-d-host-soak/v1";
	payload["rounds"] = n;
	int redisHits;
	int pgHits;
	string redisLast = "skip";
	string pgLast = "skip";
	try
	{
		auto redis = connectCache();
		foreach (i; 0 .. n)
		{
			auto k = "admin:soak:" ~ to!string(i);
			auto v = to!string(i);
			redis.set(k, v);
			if (redis.get(k) == v)
				redisHits++;
		}
		redisLast = to!string(redisHits);
		logInfo("admin soak redis %s/%s", redisHits, n);
	}
	catch (Exception e)
	{
		redisLast = "skip:" ~ e.msg;
		logWarn("admin soak redis skip: %s", e.msg);
	}
	try
	{
		auto pgconn = connectDB();
		foreach (i; 0 .. n)
		{
			auto sel = scoped!PGCommand(pgconn, "SELECT 1");
			auto dbres = sel.executeQuery!int().unique();
			if (!dbres.empty)
				pgHits++;
		}
		pgLast = to!string(pgHits);
		logInfo("admin soak postgres %s/%s", pgHits, n);
	}
	catch (Exception e)
	{
		pgLast = "skip:" ~ e.msg;
		logWarn("admin soak postgres skip: %s", e.msg);
	}
	payload["redis"] = redisLast;
	payload["postgres"] = pgLast;
	payload["redisHits"] = redisHits;
	payload["postgresHits"] = pgHits;
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
