module api;

import helpers;
import std.string : toLower;
import std.random : uniform;
import std.exception : enforce;
import std.array : Appender;

class InstallationAPI
{

	@path("/download/:guid/:filename")
	void getFile(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		string filename = req.params.get("filename", null);
		enforceBadRequest(filename !is null);
		// todo: Store these in the database
		FileStream file = openFile("downloads/" ~ filename);
		scope (exit)
			file.close();
		res.headers["Content-Length"] = file.size.to!string;
		res.contentType = "application/octet-stream";
		res.bodyWriter.write(file);
	}

	bool updating_success;
	SysTime last_success_update;
	// Through here, the client downloads any pending jobs, or does an automatic update if it is enabled
	@path("/updater/check/")
	void getUpdates(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		JobReport ret;
		/*{Job job = Job(0, JobType.Configuration);
		job.config_info = ConfigurationInfo(false, ConfigType.MicroTimer);
		job.config_info.interval = 60.minutes;
		ret.jobs ~= job;
		}*/
		long installation_id;
		scope (success)
		{
			auto str = ret.serializeToJsonString();
			res.writeBody(str);
		}
		res.headers["Content-Type"] = "application/json";
		try
		{
			static bool enable_autoupdate;
			static string update_mode;
			static long max_minutely_updates;
			static string latest_version;
			static long test_installation_id;

			static short seconds_elapsed;

			static SysTime last_check;
			mixin(Trace);
			enforceBadRequest("User-Agent" in req.headers);

			if (Clock.currTime(UTC()) - last_check > 1.seconds)
			{
				last_check = Clock.currTime(UTC());
				if (++seconds_elapsed == 5)
				{
					seconds_elapsed = 0;
				}
				RedisDatabase redis = connectCache();
				static string[] mget_keys = [
					"enable_autoupdate", "update_mode", "max_minutely_updates",
					"latest_version", "test_installation_id"
				];
				RedisReply!string redis_reply = redis.mget(mget_keys);
				enable_autoupdate = redis_reply.front == "1";
				redis_reply.popFront();
				update_mode = redis_reply.front;
				redis_reply.popFront();
				max_minutely_updates = redis_reply.front.to!long;
				redis_reply.popFront();
				latest_version = redis_reply.front;
				redis_reply.popFront();
				test_installation_id = redis_reply.front.to!long;
				redis_reply.popFront();
			}
			string guid = getGUID(req, true);
			{
				auto pgconn = connectDB();
				installation_id = getInstallationID(pgconn, guid);
			}
			string slideshow3dai_version;
			int speed;
			int ram;
			string os;
			bool client_x64;
			bool is_x64;
			extractUserAgent(req.headers["user-agent"], slideshow3dai_version, client_x64, os, is_x64, ram, speed);
			// gte
			bool isVersionGreaterThan(string ver)
			{
				import semver;

				return semver.compareVersions(ver, slideshow3dai_version) <= 0;
			}

			// update installation info with user agent and IP Address
			string ip_address = req.peer.toIPAddress();
			{

				if (enable_autoupdate && req.processAutoUpdate(ret, installation_id, update_mode, max_minutely_updates, latest_version, test_installation_id))
					return;

				{
					auto pgconn = connectDB();
					req.processJobRequests(pgconn, ret, installation_id);
				}
			}

		}
		catch (Exception e)
		{
			logError("Updater Failure: %s", e.msg);
		}
	}

	// acquire confirmation
	@path("/updater/complete") @method(HTTPMethod.POST)
	void addJobCompletion(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);

		enforceBadRequest("User-Agent" in req.headers);
		try
		{
			//auto pgconn = connectDB();
			//string guid = getGUID(req, true);
			//long installation_id = getInstallationID(pgconn, guid);
			//int action_type = req.json["action"].get!int;

		}
		catch (Exception e)
		{
			logError("Failed updater/complete: %s", e.msg);
		}

		res.statusCode = HTTPStatus.OK;
		res.writeVoidBody();
	}

	// this currently only deletes the job and sets an event log
	@path("/updater/:job_id/failure")
	void addJobFailure(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		enforceBadRequest("User-Agent" in req.headers);

		auto pgconn = connectDB();
		string guid = getGUID(req, true);
		long installation_id = getInstallationID(pgconn, guid);

		Json failure = req.json;
		logEvent(pgconn, "error", installation_id, failure);

		res.statusCode = HTTPStatus.OK;
		res.writeVoidBody();
	}

	// Called when all jobs are finished
	@path("/updater/bye/")
	void postBye(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		res.writeVoidBody();

		/*
		mixin(Trace);
		enforceBadRequest("User-Agent" in req.headers);
		auto pgconn = connectDB();
		string guid = getGUID(req, true);
		long installation_id = getInstallationID(pgconn, guid, true);

		string query = `UPDATE installations SET is_busy=false WHERE id=$1`;
		auto upd = scoped!PGCommand(pgconn, query);
		upd.parameters.bind(1, PGType.INT8, installation_id);
		upd.executeNonQuery();

		res.statusCode = HTTPStatus.OK;
		res.writeVoidBody();
*/
	}

	// called once after the slideshow3dai-client is installed (-or if the sqlite db is removed)
	@path("/installations/add/")
	void addInstallation(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		string ip_address = req.peer.toIPAddress();
		import std.uuid : randomUUID;

		string guid = getGUID(req, false);
		string computer_name = "";
		if (req.json.type == Json.Type.object && req.json["computer_name"].type == Json.Type.string)
			computer_name = req.json["computer_name"].get!string;
		auto pgconn = connectDB();
		{
			auto sel = scoped!PGCommand(pgconn, "SELECT coalesce(guid, '0') FROM installations WHERE ip_address=$1 AND (extras->>'computer_name')::text=$2");
			sel.parameters.bind(1, PGType.INET, ip_address).bind(2, PGType.TEXT, computer_name);
			auto dbres = sel.executeQuery!string().unique();
			guid = dbres.front;
		}
		long installation_id;
		if (!guid || guid == "" || guid == "0")
			installation_id = createInstallation(pgconn, ip_address, req.headers["User-Agent"], guid, req
				.json);

		// Add the GUID in slideshow3dai-client through headers
		res.headers.insert("Set-Installation-GUID", guid);

		// return the installation ID to prove success
		res.statusCode = HTTPStatus.ok;
		res.writeBody(installation_id.to!string);
	}

	// Called once at every slideshow3dai-client startup
	@method(HTTPMethod.GET) @path("/installations/check/")
	void checkInstallation(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		enforceBadRequest("User-Agent" in req.headers);
		string guid = getGUID(req, false);
		auto pgconn = connectDB();
		long installation_id = getInstallationID(pgconn, guid, false);
		string ip_address = req.peer.toIPAddress();
		if (installation_id == 0 || installation_id == 2514)
		{
			// We allow the client a chance to redefine itself... because we would lose it otherwise!
			installation_id = createInstallation(pgconn, ip_address, req.headers["user-agent"], guid, Json
				.emptyObject);
			res.headers.insert("Set-Installation-GUID", guid);

		}
		else
		{
			// update installation info with user agent and IP Address, which may have changed
			// since the last startup occured
			updateInstallationData(pgconn, ip_address, req.headers["user-agent"], installation_id);

		}
		// confirmation
		res.statusCode = HTTPStatus.ok;
		res.writeBody("Valid");
	}

	// slideshow3dai-client debug information
	@path("/events/add/:severity/")
	void addEvent(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		long event_id;
		{
			string severity = req.params.get("severity", null);
			enforceBadRequest(severity !is null);
			string guid = getGUID(req);
			auto pgconn = connectDB();
			long installation_id = getInstallationID(pgconn, guid);

			Json failure = req.json;

			event_id = logEvent(pgconn, severity, installation_id, failure);
		}
		// return the event ID to prove success
		res.writeBody(event_id.to!string, HTTPStatus.OK, "text/plain");
	}

	@path("/add_report") @method(HTTPMethod.POST)
	void addErrorReport(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		string data = cast(string) req.bodyReader.readAllUTF8(true, 4192);
		logError("Application Error Report: %s", data);
		res.writeVoidBody();
	}
}

class UserAPI
{
	SessionVar!(long, "user_id") m_userid;
	private enum auth = before!authenticate("_userid");

	this()
	{
	}

	@auth @path("/get_user_id")
	void getUserID(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		res.writeBody(`{"user_id": ` ~ _userid.to!string ~ `}`);
	}

	@path("/forgot_password")
	void postForgotPassword(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		import mail : sendEmail;
		import std.uuid : randomUUID;

		try
		{
			res.setDefaultHeaders();
			import std.array : replace;

			string password_reset_token = randomUUID().toString()[0 .. 10].replace("-", "");
			auto pgconn = connectDB();
			long installation_id;
			string guid = getGUID(req, true);
			installation_id = getInstallationID(pgconn, guid);
			enforce(installation_id > 0, "Invalid installation");

			import std.string : toLower;

			string email = req.json["email"].get!string().toLower();
			enforce(email !is null && email != "", "Email required");
			string query = "UPDATE users SET password_reset_token=$1 WHERE lower(email)=$2 RETURNING id";
			auto upd = scoped!PGCommand(pgconn, query);
			upd.parameters.bind(1, PGType.VARCHAR, password_reset_token)
				.bind(2, PGType.VARCHAR, email);
			auto dbres = upd.executeQuery!long().unique();
			enforce(!dbres.empty, "This e-mail is not registered");
			mailer.sendEmail(email, "Your secret token is: " ~ password_reset_token);
			res.writeVoidBody();
		}
		catch (Exception e)
		{
			Json error_json = Json.emptyObject;
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
			logError("PostForgotPassword error: %s", e.msg);
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}
	}

	@path("/change_password")
	void postNewPassword(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		try
		{
			res.setDefaultHeaders();
			import std.string : toLower;

			string email = req.json["email"].get!string().toLower();
			enforce(email != "", "No e-mail entered. Try re-entering it");
			string password_reset_token = req.json["secret_token"].get!string;
			string new_password = req.json["password"].get!string;
			string confirm_password = req.json["confirm_password"].get!string;
			enforce(new_password == confirm_password, "Passwords don't match");
			auto pgconn = connectDB();
			mixin(Transaction);

			long installation_id;
			string guid = getGUID(req, true);
			installation_id = getInstallationID(pgconn, guid);
			enforce(installation_id > 0, "Invalid installation");

			string passhash = new_password;

			string reset_token;
			{
				string query = "SELECT password_reset_token FROM users WHERE lower(email)=$1";
				auto sel = scoped!PGCommand(pgconn, query);
				sel.parameters.bind(1, PGType.VARCHAR, email);
				auto dbres = sel.executeQuery!string().unique();
				reset_token = dbres.front;
			}

			enforce(reset_token == password_reset_token, "Invalid reset token. Please contact us for help at http://psxai.com/#contact");

			{
				string query = "UPDATE users SET password=crypt($1,gen_salt('bf',4)), last_installation_id=$2 WHERE lower(email)=$3";
				auto upd = scoped!PGCommand(pgconn, query);
				upd.parameters.bind(1, PGType.VARCHAR, passhash)
					.bind(2, PGType.INT8, installation_id)
					.bind(3, PGType.VARCHAR, email);
				upd.executeNonQuery();
			}

			res.writeVoidBody();
		}
		catch (Exception e)
		{
			Json error_json = Json.emptyObject;
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
			logError("PostNewPassword error: %s", e.msg);
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}
	}

	@path("/:email/availability")
	void getUserEmailAvailability(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		res.setDefaultHeaders();
		enforceBadRequest(req.params.get("email", "") != "");
		Json ret = Json.emptyObject;
		ret["count"] = 0;
		scope (exit)
			res.writeJsonBody(ret);
		auto pgconn = connectDB();
		long installation_id;
		string guid = getGUID(req, true);
		installation_id = getInstallationID(pgconn, guid);
		enforce(installation_id > 0, "Invalid installation");

		auto sel = scoped!PGCommand(pgconn, "SELECT count(*) as count FROM users WHERE email=$1");
		sel.parameters.bind(1, PGType.TEXT, req.params["email"]);
		auto dbres = sel.executeQuery!long().unique();
		ret["count"] = dbres.front;
	}

	@auth @path("/users/current_identity")
	void getUserIdentity(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		mixin(Trace);
		long installation_id;
		res.setDefaultHeaders();
		if (!req.session)
			req.session = res.startSession("/", SessionOption.httpOnly, 365.days);
		try
		{
			auto pgconn = connectDB();
			string guid = getGUID(req, true);
			installation_id = getInstallationID(pgconn, guid);
			enforce(installation_id > 0, "Invalid installation");

			string query = "SELECT (select row_to_json(_) from (select u.username as username, u.id as user_id," ~
				"'' as thumbnail, json_agg(r.name) as roles) as _)::text " ~
				"FROM users u " ~
				"JOIN users_roles ur ON ur.user_id=u.id " ~
				"JOIN roles r ON ur.role_id=r.id " ~
				"WHERE u.id=$1";
			auto sel = scoped!PGCommand(pgconn, query);
			sel.parameters.bind(1, PGType.INT8, _userid);
			auto dbres = sel.executeQuery!(string)().unique();
			string identity;
			if (!dbres.empty)
				identity = dbres.front;

			if (identity)
			{

				res.writeBody(identity, "application/json");
			}
		}
		catch (Exception e)
		{
			Json error_json = Json.emptyObject;
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
			logError("getUserIdentity error installation %d: %s", installation_id, e.msg);
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}
	}

	@auth
	void getNotifications(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		mixin(Trace);
		res.setDefaultHeaders();
		res.writeBody(`[ { "message": "Coming Soon!" } ]`, "application/json");
	}

	@auth
	void getMessages(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		res.setDefaultHeaders();
		res.writeBody(`[ { "message": "Coming Soon!" } ]`, "application/json");
	}

	/// Login: Returns identity
	@path("/login")
	void postLogin(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		res.setDefaultHeaders();
		Json error_json = Json.emptyObject;
		long installation_id;
		{
			RedisDatabase redis = connectCache();
		}
		try
		{
			// Set-cookie
			if (!req.session)
				req.session = res.startSession("/", SessionOption.httpOnly, 365.days);
			auto pgconn = connectDB();
			{
				string guid = getGUID(req, true);
				installation_id = getInstallationID(pgconn, guid);
			}

			Json user = req.json;
			import std.string : toLower;

			string email = req.json["email"].get!string.toLower();
			string password = req.json["pass"].get!string;
			string query;

			//login
			long userid;
			string identity;
			{
				long cache_userid;
				string passhash;
				bool password_is_good;
				{
					query = "SELECT id, password=crypt($2,password) FROM users WHERE lower(email)=$1 ORDER BY id DESC LIMIT 1";
					auto sel = scoped!PGCommand(pgconn, query);
					sel.parameters.bind(1, PGType.VARCHAR, email).bind(2, PGType.VARCHAR, password);
					auto dbres = sel.executeQuery!(long, bool)().unique();
					cache_userid = dbres.front[0];
					password_is_good = dbres.front[1];
				}

				enforce(cache_userid != 0, "E-mail not found. Did you sign up yet?");

				//enforce(m_userid.value != dbres.front[0], "Already logged in. Try refreshing the page.");				

				enforce(password_is_good, "Invalid login email or password");
				userid = cache_userid;
				m_userid.value = userid;
			}

			// if successful, update last_installation_id record
			{
				query = "UPDATE users SET last_installation_id=$1, updated=timezone('utc'::text, now()) WHERE id=$2";
				auto upd = scoped!PGCommand(pgconn, query);
				upd.parameters.bind(1, PGType.INT8, installation_id)
					.bind(2, PGType.INT8, userid);
				upd.executeNonQuery();
			}

			// todo: add this device to a list of available devices

			{
				struct LoginActivity
				{
					string message;
					string email;
				}

				LoginActivity login_activity;
				login_activity.message = "Successful login";
				login_activity.email = email;
				logActivity(pgconn, "info", installation_id, userid, login_activity.serializeToJson());
			}
			res.writeBody(identity, "application/json");
		}
		catch (Exception e)
		{
			import std.string : lastIndexOf;

			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
		}

		if (error_json != Json.emptyObject)
		{
			auto pgconn = connectDB();

			Json login_failed = Json.emptyObject;
			login_failed["message"] = "Login failed";
			login_failed["details"] = error_json["message"].get!string;
			login_failed["email"] = req.json["email"].get!string;
			if (installation_id != 0)
				logEvent(pgconn, "error", installation_id, login_failed);
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}

	}

	@auth @path("/logout") @method(HTTPMethod.POST)
	void postLogout(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		res.setDefaultHeaders();
		res.terminateSession();
		res.writeVoidBody();
	}

	/// Registration
	@path("/users/add/")
	void addUser(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		res.setDefaultHeaders();
		Json error_json = Json.emptyObject;
		try
		{
			// Set-cookie
			if (!req.session)
				req.session = res.startSession("/", SessionOption.httpOnly, 365.days);
			auto pgconn = connectDB();
			long installation_id;
			{
				string guid = getGUID(req, true);
				installation_id = getInstallationID(pgconn, guid);
			}
			Json user = req.json;

			string country_code;
			double longitude;
			double latitude;
			string ip_address = req.peer.toIPAddress();
			resolveIP(ip_address, country_code, longitude, latitude);

			int timezone = user["timezone"].get!int;
			string device_uuid = user["device_uuid"].get!string;
			string locale = user["locale"].get!string;
			string first_name = user["first_name"].get!string;
			string last_name = user["last_name"].get!string;
			import std.string : toLower;

			string email = user["email"].get!string.toLower();
			{
				string query = "SELECT id FROM users WHERE email=$1";
				auto sel = scoped!PGCommand(pgconn, query);
				sel.parameters.bind(1, PGType.TEXT, email);
				auto dbres = sel.executeQuery!long().unique();
				enforce(dbres.empty, "This e-mail belongs to an account");
			}

			// slideshow3dai password

			string passhash = user["password"].get!string;
			enforce(passhash.length > 0, "Password cannot be empty");

			mixin(Transaction);

			long userid;
			{
				string query = "INSERT INTO users (installation_id, last_installation_id, first_name, last_name, email, password, timezone, locale, first_ip_address) VALUES ($1,$1,$2,$3,$4,crypt($5, gen_salt('bf',4)),$6,$7,$8) RETURNING id";
				auto ins = scoped!PGCommand(pgconn, query);
				ins.parameters.bind(1, PGType.INT8, installation_id)
					.bind(2, PGType.VARCHAR, first_name)
					.bind(3, PGType.VARCHAR, last_name)
					.bind(4, PGType.VARCHAR, email)
					.bind(5, PGType.VARCHAR, passhash)
					.bind(6, PGType.INT4, timezone)
					.bind(7, PGType.VARCHAR, locale)
					.bind(8, PGType.INET, ip_address);
				auto dbres = ins.executeQuery!long().unique();
				userid = dbres.front;
			}
			enforce(userid > 0, "Failed to add user");
			m_userid.value = userid;
			// Create the user role
			{
				string query = "INSERT INTO users_roles (user_id, role_id) VALUES ($1, $2)";
				auto ins = scoped!PGCommand(pgconn, query);
				ins.parameters.bind(1, PGType.INT8, userid)
					.bind(2, PGType.INT2, cast(short) 2);
				ins.executeNonQuery();
			}

			res.writeVoidBody();

			/* Add a welcome message

			{
				string query = "INSERT INTO users_messages ()";
			}*/

		}
		catch (Exception e)
		{
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg; //.afterColon();
			//logError("Registration failed: %s", e.msg);
		}
		finally
		{
			if (error_json != Json.emptyObject)
			{
				res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
				logError("Registration Error: %s", error_json["message"].get!string);
			}
		}

	}

	@path("/error/")
	void postError(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		res.setDefaultHeaders();

		try
		{
			Json activity = req.json;
			auto pgconn = connectDB();
			long installation_id;
			{
				string guid = getGUID(req, true);
				installation_id = getInstallationID(pgconn, guid);
			}
			logEvent(pgconn, "error", installation_id, req.json);
			res.writeVoidBody();
		}
		catch (Exception e)
		{
			Json error_json = Json.emptyObject;
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}
	}

	@auth @path("/activity/:severity")
	void postActivity(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		mixin(Trace);
		res.setDefaultHeaders();

		try
		{
			Json activity = req.json;
			string severity = req.params["severity"];
			auto pgconn = connectDB();
			long installation_id;
			{
				string guid = getGUID(req, true);
				installation_id = getInstallationID(pgconn, guid);
			}
			logActivity(pgconn, severity, installation_id, _userid, req.json);
			res.writeVoidBody();
		}
		catch (Exception e)
		{
			Json error_json = Json.emptyObject;
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}
	}

	@auth @path("/activity")
	void postActivityJson(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		mixin(Trace);
		res.setDefaultHeaders();

		try
		{
			Json activity = req.json;
			string severity = req.json["severity"].get!string;
			auto pgconn = connectDB();
			long installation_id;
			{
				string guid = getGUID(req, true);
				installation_id = getInstallationID(pgconn, guid);
			}
			logActivity(pgconn, severity, installation_id, _userid, req.json);
			res.writeVoidBody();
		}
		catch (Exception e)
		{
			Json error_json = Json.emptyObject;
			error_json["status"] = HTTPStatus.internalServerError;
			error_json["message"] = e.msg.afterColon();
			res.writeBody(error_json.toString(), HTTPStatus.internalServerError, "application/json");
		}
	}

private:
	public mixin PrivateAccessProxy;

	long authenticate(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		res.setDefaultHeaders();
		struct ErrorMessage
		{
			string message;
			int status;
		}

		if (!req.session)
			req.session = res.startSession("/", SessionOption.httpOnly, 365.days);
		long userid = m_userid;
		if (userid == 0)
		{
			res.writeJsonBody(ErrorMessage("Invalid user session", 403), HTTPStatus.forbidden);
		}
		return userid;
	}

}

private:

void setDefaultHeaders(scope HTTPServerResponse res)
{
	// IE workarounds for cache
	res.headers["Cache-Control"] = "no-cache, no-store, must-revalidate";
	res.headers["Pragma"] = "no-cache";
	res.headers["Expires"] = "0";
}

bool requiresUpdate(string client_version, string available_version)
{
	import semver;

	enforce(semver.isValidVersion(client_version));
	enforce(semver.isValidVersion(available_version));
	return semver.compareVersions(client_version, available_version) < 0;
}

void extractUserAgent(string user_agent, out string client_version, out bool client_x64, out string os, out bool is_x64, out int ram, out int speed) {

}

bool processAutoUpdate(scope HTTPServerRequest req, ref JobReport ret, long installation_id, string update_mode,
	long max_minutely_updates, string latest_version, long test_installation_id)
{

	auto cache = connectCache();
	// Automatic updates can avoid scheduling a job for every installation
	// but they are more likely to happen in the same timespan, which could cause involuntary DDOS
	if (update_mode && update_mode == "Automatic")
	{
		//ok
		import std.string : indexOf;

		string client_version;
		string os;
		bool client_x64;
		bool is_x64;
		int ram;
		int speed;
		extractUserAgent(req.headers["user-agent"], client_version, client_x64, os, is_x64, ram, speed);

		if (requiresUpdate(client_version, latest_version))
		{
			// check user cooldown
			import std.range : iota;
			import std.array : array;

			// get 8 previous hours
			ubyte hour = Clock.currTime(UTC()).hour;
			ubyte[7] hours_;
			if (hour >= 7)
				hours_[] = iota(hour - 6, hour + 1, 1).array.to!(ubyte[]);
			else
			{
				hours_[0 .. cast(size_t) 7 - hour - 1] = iota(24 - (7 - hour - 1), 24, 1).array.to!(
					ubyte[]);
				hours_[cast(size_t) 7 - hour - 1 .. $] = iota(0, hour + 1, 1).array.to!(ubyte[]);
			}
			// check if it was updated less than 8 hours ago
			foreach (i, hour_; hours_)
			{
				if (i == 6)
				{ //current hour
					// hourly entries in set
					string skey = "update_cooldown_" ~ hour_.to!string;
					if (!cache.exists(skey))
					{
						cache.sadd(skey, installation_id);
						cache.expire(skey, cast(long) 8 * 60 * 60);
					}
					else if (cache.sisMember(skey, installation_id))
					{

						if (installation_id != test_installation_id)
							return false;
					}
					else
					{
						cache.sadd(skey, installation_id);
					}
				}
				else if (cache.sisMember("update_cooldown_" ~ hour_.to!string, installation_id))
				{
					if (installation_id != test_installation_id)
						return false;

				}
			}

			// Sometimes the computer has an antivirus blocking updates. We abort to save bandwidth.
			/*if (!cache.sisMember("update_updatable", installation_id)) {
				if (!cache.sisMember("update_not_updatable", installation_id)) {
					bool is_updatable;
					{
						auto pgconn = connectDB();
						auto sel = scoped!PGCommand(pgconn, "SELECT is_updatable FROM installations WHERE id=$1");
						sel.parameters.bind(1, PGType.INT8, installation_id);
						auto dbres = sel.executeQuery!bool().unique();
						is_updatable = dbres.front;
					}
					if (is_updatable) 
						cache.sadd("update_updatable", installation_id);
					else {
						cache.sadd("update_not_updatable", installation_id);

						if (installation_id != test_installation_id)
							return false;
					}
				}
				else {
					if (installation_id != test_installation_id)
						return false;
				}
			}*/

			// congestion control
			if (cache.incr("minutely_updates") > max_minutely_updates)
			{
				if (installation_id != test_installation_id)
					return false;
			}

			Job job;
			bool is_windows = os[0 .. os.indexOf(' ')] == "Windows";
			if (!is_windows && cache.get("ignore_mac_update") == "1")
			{
				return false;
			}
			// ignore broken 2.4.5 version for Mac
			if (!is_windows && requiresUpdate(client_version, "2.4.6"))
				return false;

			job.update_info.slideshow3dai.is_windows = is_windows;
			job.update_info.slideshow3dai.is_x64 = is_x64;
			job.update_info.slideshow3dai.download_url = cache.hget("download_url_map", (is_windows ? "win_"
					: "mac_") ~ (is_x64 ? "x64" : "x86"));
			if (job.update_info.slideshow3dai.download_url != "")
			{
				job.id = 0;
				job.type = JobType.Update;
				job.update_info.new_version = latest_version;
				if (is_windows)
					job.update_info.slideshow3dai.filename = "slideshow3dai.exe.gz_";
				else
					job.update_info.slideshow3dai.filename = "slideshow3dai.gz_";

				URL dl_link = URL.parse(job.update_info.slideshow3dai.download_url);
				import std.string : indexOf;

				static string[string] sha_256_cache;
				string _fname = dl_link.pathString[dl_link.pathString.indexOf(
						"files/") .. $] ~ ".sha256";
				if (_fname !in sha_256_cache)
				{
					sha_256_cache[_fname] = cast(string) readFile(
						dl_link.pathString[dl_link.pathString.indexOf("files/") .. $] ~ ".sha256");
				}
				job.update_info.slideshow3dai.sha256 = sha_256_cache[_fname];

				ret.jobs ~= job;

				// The update takes priority
				return true;
			}
			else
			{
				Json event = Json.emptyObject;
				event["os"] = os;
				event["message"] = "Cannot find download URL";
				auto pgconn = connectDB();
				auto evt = logEvent(pgconn, "error", installation_id, event);
			}
		}
	}
	return false;
}

void processJobRequests(PGConn)(scope HTTPServerRequest req, ref PGConn pgconn, ref JobReport ret, long installation_id)
{

	string query = "SELECT id, payload::text, (trigger_on+expires_after <= (now() at time zone 'utc')) as expired " ~
		"FROM installations_jobs WHERE installation_id=$1 AND trigger_on - '30 seconds'::interval <= (now() at time zone 'utc')";
	auto sel = scoped!PGCommand(pgconn, query);
	sel.parameters.bind(1, PGType.INT8, installation_id);
	auto dbres = sel.executeQuery!(long, string, bool)().unique();
	int expired_cnt;
	foreach (row; *dbres)
	{
		void failMessage(string msg, string details)
		{
			auto pgconn2 = connectDB();
			try
			{
				Json event = Json.emptyObject;
				event["message"] = msg;
				event["details"] = details;
				event["jobId"] = row[0];
				event["jobInfo"] = row[1];
				auto evt = logEvent(pgconn2, "error", installation_id, event);
			}
			catch (Exception e)
			{
			}
		}
		// if expired, remove the job
		if (bool expired = row[2])
		{
			failMessage("Job expired", null);
			if (++expired_cnt > 1)
			{
				auto pgconn2 = connectDB();
				deleteJob(pgconn2, row[0]);
				continue;
			}
		}
		string error_details;
		string preemptive_msg;
		try
		{
			preemptive_msg = "Could not deserialize job information";
			Job job = deserializeJson!Job(row[1]);
			job.id = row[0];
			// delete the job to avoid reposts
			{
				auto pgconn2 = connectDB();
				deleteJob(pgconn2, job.id);
			}
			// if it's a configuration change, it will be peristent and we update our records
			if (job.type == JobType.Configuration)
			{
				preemptive_msg = "Could not update configuration data";
				auto pgconn2 = connectDB();

				updateConfigurationData(pgconn2, installation_id, job);

			}
			// if it's an update, we process only the update.
			if (job.type == JobType.Update)
			{
				ret.jobs = [job];
				break;
			}
			// for anything except updates, we push it to the client
			ret.jobs ~= job;
		}
		catch (Exception e)
		{
			error_details = e.msg;
		}

		// if updateConfigurationData or deserialization failed, remove job and fail
		if (error_details)
			failMessage(preemptive_msg, error_details);
	}
}

string getGUID(scope HTTPServerRequest req, bool enforce_valid = true)
{
	string guid = req.headers.get("Installation-GUID", "");
	enforceBadRequest(!enforce_valid || guid != "");
	return guid;
}

void deleteJob(PGConn)(ref PGConn pgconn, long id)
{

	auto del = scoped!PGCommand(pgconn, "DELETE FROM installations_jobs WHERE id=$1");
	del.parameters.bind(1, PGType.INT8, id);
	del.executeNonQuery();
}

long getInstallationID(PGConn)(ref PGConn pgconn, string guid, bool enforce_valid = true)
{
	enforce(!enforce_valid || guid, "The installation process cannot complete due to unknown conflicts. Try restarting the computer or disabling the antivirus.");
	if (!guid)
		return 0;
	auto sel = scoped!PGCommand(pgconn, "SELECT id, is_banned FROM installations WHERE guid=$1 LIMIT 1");
	sel.parameters.bind(1, PGType.TEXT, guid);
	auto dbres = sel.executeQuery!(long, bool)().unique();
	enforceHTTP(!enforce_valid || !dbres.empty, HTTPStatus.forbidden);
	if (dbres.empty)
		return 0;
	enforce(!dbres.front[1]);
	return dbres.front[0];
}

struct InstallationData
{
	string ip_address;
	long installation_id;
	string country_code;
	double longitude;
	double latitude;
	string software_version;
	string operating_system;
	bool is_x64;
	bool client_x64;
	int available_ram;
	int connection_speed;
}

InstallationData getInstallationData(string ip_address, string user_agent, long installation_id)
{
	InstallationData data;
	data.ip_address = ip_address;
	data.installation_id = installation_id;
	resolveIP(ip_address, data.country_code, data.longitude, data.latitude);
	if (!data.country_code || data.country_code == "")
		data.country_code = "US";
	extractUserAgent(user_agent, data.software_version, data.client_x64, data.operating_system, data.is_x64, data
			.available_ram, data.connection_speed);
	return data;
}

Json getTransactionDetails(scope HTTPServerRequest req, long installation_id)
{
	import vibe.data.json : serializeToJson;

	Json details = req.json;
	details["installation_data"] = getInstallationData(req.peer.toIPAddress(), req.headers["User-Agent"], installation_id)
		.serializeToJson();
	return details;
}

void updateInstallationData(PGConn)(ref PGConn pgconn, string ip_address, string user_agent, long installation_id)
{
	{ // update at most once an hour
		RedisDatabase redis = connectCache();
		if (redis.get("enable_updated_installation_cooldown") == "1"
			&& redis.exists("updated_installation_" ~ installation_id.to!string))
			return;
		redis.setEX("updated_installation_" ~ installation_id.to!string, 3600, "1");
	}

	InstallationData data = getInstallationData(ip_address, user_agent, installation_id);
	bool version_is_same;
	{
		auto sel = scoped!PGCommand(pgconn, "SELECT slideshow3dai_version FROM installations WHERE id=$1");
		sel.parameters.bind(1, PGType.INT8, installation_id);
		auto dbres = sel.executeQuery!string().unique();
		version_is_same = (dbres.front == data.software_version);
	}
	if (!version_is_same)
	{
		string query = "UPDATE installations SET updated=(now() at time zone 'utc'), ip_address=$1, country_code=$2, latitude=$3, longitude=$4,
						slideshow3dai_version=$5, slideshow3dai_x64=$6, operating_system=$7, architecture_x64=$8, available_ram_mb=$9, connection_speed=$10 WHERE id=$11";
		auto upd = scoped!PGCommand(pgconn, query);
		upd.parameters.bind(1, PGType.INET, data.ip_address)
			.bind(2, PGType.VARCHAR, data.country_code)
			.bind(3, PGType.NUMERIC, data.latitude.to!string)
			.bind(4, PGType.NUMERIC, data.longitude.to!string)
			.bind(5, PGType.VARCHAR, data.software_version)
			.bind(6, PGType.BOOLEAN, data.client_x64)
			.bind(7, PGType.VARCHAR, data.operating_system)
			.bind(8, PGType.BOOLEAN, data.is_x64)
			.bind(9, PGType.INT4, data.available_ram)
			.bind(10, PGType.INT4, data.connection_speed)
			.bind(11, PGType.INT8, data.installation_id);
		upd.executeNonQuery();
	}

}

long createInstallation(PGConn)(ref PGConn pgconn, string ip_address, string user_agent, ref string guid, Json extras)
{
	import std.uuid : randomUUID;

	bool client_guid;
	if (!guid || guid == "" || guid.length < 16)
		guid = randomUUID().toString();
	else
		client_guid = true;
	string country_code;
	double longitude;
	double latitude;
	resolveIP(ip_address, country_code, longitude, latitude);
	if (!country_code || country_code == "")
		country_code = "NA";
	string software_version;
	string operating_system;
	bool is_x64;
	bool client_x64;
	int available_ram;
	int connection_speed;
	mixin(Transaction);

	extractUserAgent(user_agent, software_version, client_x64, operating_system, is_x64, available_ram, connection_speed);
	string query = `INSERT INTO installations (guid, ip_address, first_country_code, country_code, 
												longitude, latitude, operating_system, available_ram_mb, 
												connection_speed, slideshow3dai_x64, slideshow3dai_version, client_guid, architecture_x64, extras) 
							VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) RETURNING id`;
	auto ins1 = scoped!PGCommand(pgconn, query);
	ins1.parameters.bind(1, PGType.VARCHAR, guid)
		.bind(2, PGType.INET, ip_address)
		.bind(3, PGType.VARCHAR, country_code)
		.bind(4, PGType.VARCHAR, country_code)
		.bind(5, PGType.NUMERIC, longitude.to!string)
		.bind(6, PGType.NUMERIC, latitude.to!string)
		.bind(7, PGType.VARCHAR, operating_system)
		.bind(8, PGType.INT4, available_ram)
		.bind(9, PGType.INT4, connection_speed)
		.bind(10, PGType.BOOLEAN, client_x64)
		.bind(11, PGType.VARCHAR, software_version)
		.bind(12, PGType.BOOLEAN, client_guid)
		.bind(13, PGType.BOOLEAN, is_x64)
		.bind(14, PGType.JSONB, extras.type == Json.Type.undefined ? "{}" : extras.toString());
	long installation_id;
	{
		auto dbres = ins1.executeQuery!long().unique();
		installation_id = dbres.front;
	}

	// create configuration
	{
		query = "INSERT INTO installations_config (installation_id) VALUES ($1)";
		auto ins = scoped!PGCommand(pgconn, query);
		ins.parameters.bind(1, PGType.INT8, installation_id);
		ins.executeNonQuery();
	}
	return installation_id;
}

// Update database configuration data for this installation
void updateConfigurationData(PGConn)(ref PGConn pgconn, long installation_id, Job job)
{
	string col;
	with (job.config_info)
	{
		switch (type)
		{
		case ConfigType.Unknown:
			return;
		case ConfigType.DisableHTTP2:
			col = "disable_http2";
			break;
		case ConfigType.StayConnected:
			col = "stay_connected";
			break;
		case ConfigType.CheckInterval:
			col = "check_interval";
			break;
		case ConfigType.MicroTimer:
			col = "micro_timer";
			break;
		case ConfigType.OneShotTimer:
			col = "oneshot_timer";
			break;
		case ConfigType.KeepAliveDuration:
			col = "keep_alive";
			break;
		case ConfigType.LogLevel:
			col = "log_level";
			break;
		default:
			return;
		}
	}

	mixin(Transaction);
	// check if the user has an installation
	string query;
	{
		long count;
		{
			query = "SELECT id FROM installations_config WHERE installation_id=$1";
			auto sel = scoped!PGCommand(pgconn, query);
			sel.parameters.bind(1, PGType.INT8, installation_id);
			auto dbres = sel.executeQuery!long().unique();
			count = dbres.front;
		}
		if (count == 0) // create configuration
		{
			query = "INSERT INTO installations_config (installation_id) VALUES ($1)";
			auto ins = scoped!PGCommand(pgconn, query);
			ins.parameters.bind(1, PGType.INT8, installation_id);
			ins.executeNonQuery();
		}
	}
	{
		query = "UPDATE installations_config SET " ~ col ~ "=$1 WHERE installation_id=$2";
		auto upd = scoped!PGCommand(pgconn, query);

		with (job.config_info)
		{
			switch (type)
			{
			case ConfigType.Unknown:
				assert(0, "Invalid ConfigType");
			case ConfigType.DisableHTTP2:
				upd.parameters.bind(1, PGType.BOOLEAN, job.config_info.flag);
				break;
			case ConfigType.StayConnected:
				upd.parameters.bind(1, PGType.BOOLEAN, job.config_info.flag);
				break;
			case ConfigType.CheckInterval:
				upd.parameters.bind(1, PGType.INTERVAL, job.config_info.interval.total!"seconds");
				break;
			case ConfigType.MicroTimer:
				upd.parameters.bind(1, PGType.INTERVAL, job.config_info.interval.total!"seconds");
				break;
			case ConfigType.OneShotTimer:
				upd.parameters.bind(1, PGType.INTERVAL, job.config_info.interval.total!"seconds");
				break;
			case ConfigType.KeepAliveDuration:
				upd.parameters.bind(1, PGType.INTERVAL, job.config_info.interval.total!"seconds");
				break;
			case ConfigType.LogLevel:
				upd.parameters.bind(1, PGType.INT2, job.config_info.number.to!short);
				break;
			default:
				assert(0, "Invalid ConfigType");
			}
		}
		upd.parameters.bind(2, PGType.INT8, installation_id);
		upd.executeNonQuery();
	}

}

long logEvent(PGConn)(ref PGConn pgconn, string severity, long installation_id, Json event_data)
{
	short severity_id = getSeverity(severity);
	if (event_data["args"].toString().indexOf("JSON of type undefined") > -1)
	{
		auto cache = connectCache();
		cache.sadd("installation_is_errored", installation_id.to!string);
	}
	string query = `INSERT INTO installations_events (severity_id, typecode, payload, installation_id) VALUES ($1, $2, $3, $4) RETURNING id`;
	auto cmd = scoped!PGCommand(pgconn, query);
	cmd.parameters.bind(1, PGType.INT2, severity_id)
		.bind(2, PGType.INT2, cast(short) 0) // this type is unsupported
		.bind(3, PGType.JSONB, event_data.toString()) // will be re-serialized
		.bind(4, PGType.INT8, installation_id);
	auto dbres = cmd.executeQuery!long().unique();
	return dbres.front;
}

/// Insert user activity in the database
long logActivity(PGConn)(ref PGConn pgconn, string severity, long installation_id, long user_id, Json event_data)
{
	short severity_id = getSeverity(severity);
	string query = `INSERT INTO users_activities (user_id, severity_id, typecode, payload, installation_id) VALUES ($1, $2, $3, $4, $5) RETURNING id`;
	auto cmd = scoped!PGCommand(pgconn, query);
	cmd.parameters.bind(1, PGType.INT8, user_id)
		.bind(2, PGType.INT2, severity_id)
		.bind(3, PGType.INT2, cast(short) 0) // this type is unsupported
		.bind(4, PGType.JSONB, event_data.toString()) // will be re-serialized
		.bind(5, PGType.INT8, installation_id);
	auto dbres = cmd.executeQuery!long().unique();
	return dbres.front;
}
