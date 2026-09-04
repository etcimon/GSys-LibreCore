module helpers;

// Barrel for kit +page.server.d: the same vibe.0 / botan / memutils / Phobos
// graph as connectDB / connectCache. Authors may also `import vibe.db.pgsql.pgsql`
// (etc.) directly — those packages are already in webserver/dub.sdl.

public import vibe.db.pgsql.pgsql;
public import std.conv;
public import vibe.data.json;
public import vibe.http.server;
public import vibe.core.core;
public import vibe.core.log : logDebug, logDebugV, logTrace, logDiagnostic,
	logInfo, logWarn, logError, logCritical, setLogLevel, setLogFormat, LogLevel, FileLogger;
public import std.typecons : scoped;
public import memutils.unique;
public import vibe.stream.botan;
public import vibe.stream.tls;
public import vibe.stream.operations;
public import vibe.web.web;
public import vibe.db.redis.redis;
public import vibe.core.concurrency;
public import vibe.mail.smtp;
public import botan.passhash.bcrypt;
public import botan.rng.auto_rng;
public import std.datetime;

public import std.string : indexOf;
public import jobs;
public import events;
public import geoip;

private PostgresDB g_pgdb;
private RedisClient g_redisClient;

SMTPClientSettings mailer;

/// SvelteKit-shaped console → vibe.0 log levels (host cell only).
void kitLog(string level, string msg)
{
	auto lv = level.length ? level : "info";
	if (lv == "trace")
		logTrace("%s", msg);
	else if (lv == "debug" || lv == "debugV")
		logDebug("%s", msg);
	else if (lv == "diagnostic" || lv == "verbose")
		logDiagnostic("%s", msg);
	else if (lv == "warn" || lv == "warning")
		logWarn("%s", msg);
	else if (lv == "error")
		logError("%s", msg);
	else if (lv == "critical")
		logCritical("%s", msg);
	else
		logInfo("%s", msg);
}

private string envOr(string key, string fallback)
{
	import std.process : environment;

	auto v = environment.get(key, "");
	return v.length ? v : fallback;
}

auto connectDB()
{
	if (!g_pgdb)
	{
		import std.random : uniform;

		version (Windows)
		{
			auto params = [
				"host": envOr("PGHOST", "127.0.0.1"),
				"database": envOr("PGDATABASE", "slideshow3dai"),
				"user": envOr("PGUSER", "postgres"),
				"password": envOr("PGPASSWORD", "xxxxxxxxx"),
				"statement_timeout": "90000"
			];
			auto ssl = envOr("PGSSL", "require");
			if (ssl.length && ssl != "disable" && ssl != "off")
				params["ssl"] = ssl;

		}
		else
		{
			auto params = [
				"host": envOr("PGHOST", "/tmp/.s.PGSQL.5432"),
				"database": envOr("PGDATABASE", "slideshow3dai"),
				"user": envOr("PGUSER", "root"),
				"statement_timeout": "90000"
			];
			auto pass = envOr("PGPASSWORD", "");
			if (pass.length)
				params["password"] = pass;
			auto ssl = envOr("PGSSL", "");
			if (ssl.length && ssl != "disable" && ssl != "off")
				params["ssl"] = ssl;
		}
		g_pgdb = new PostgresDB(params);
		g_pgdb.maxConcurrency = 10;
		//auto pgconn = g_pgdb.lockConnection();
		//auto upd = scoped!PGCommand(pgconn, "SET statement_timeout = 90000");
		//upd.executeNonQuery();
	}

	return g_pgdb.lockConnection();
}

RedisDatabase connectCache()
{
	if (!g_redisClient)
	{
		version (Windows)
		{
			import std.string : lastIndexOf;

			string rh = envOr("REDIS_HOST", "127.0.0.1");
			ushort rp = 6379;
			auto col = rh.lastIndexOf(':');
			if (col > 0)
			{
				try
					rp = to!ushort(rh[col + 1 .. $]);
				catch (Exception)
				{
				}
				rh = rh[0 .. col];
			}
			g_redisClient = connectRedis(rh, rp);
		}
		else
		{
			g_redisClient = connectRedis(envOr("REDIS_HOST", "/tmp/redis.sock"));
		}
	}
	return g_redisClient.getDatabase(0);
}

/// Removes the port number from an IP string, if applicable
string toIPAddress(string peer)
{
	import std.string : lastIndexOf;

	if (peer.length == 0)
		return "";
	size_t idx = peer.lastIndexOf(':');
	if (idx == -1)
		idx = peer.length;
	return peer[0 .. idx];
}

string afterColon(string msg)
{
	import std.string : lastIndexOf;

	auto idx = msg.lastIndexOf(':');
	if (idx == -1)
		return msg;
	if (idx >= msg.length - 2)
		return "";
	return msg[idx + 1 .. $];
}

enum Transaction = `try {
		auto begin = scoped!PGCommand(pgconn, "BEGIN");
		begin.executeNonQuery();
	} catch (Exception e) {
		{
			auto rb = scoped!PGCommand(pgconn, "ROLLBACK");
			rb.executeNonQuery();
		}
		{
			auto begin = scoped!PGCommand(pgconn, "BEGIN");
			begin.executeNonQuery();
		}
	}
	scope(failure) {
		auto rollback = scoped!PGCommand(pgconn, "ROLLBACK");
		rollback.executeNonQuery();
	}
	scope(success) {
		auto commit = scoped!PGCommand(pgconn, "COMMIT");
		commit.executeNonQuery();
	}
`;
