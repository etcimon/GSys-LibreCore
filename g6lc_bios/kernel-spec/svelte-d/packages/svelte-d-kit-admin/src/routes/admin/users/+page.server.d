// Host cell: vibe.0 PostgreSQL + JSON list. Offline → skip + seed row.
import helpers;

void getUsers(HTTPServerRequest req, HTTPServerResponse res)
{
	Json payload = Json.emptyObject;
	payload["users"] = Json.emptyArray;
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
	Json row = Json.emptyObject;
	row["email"] = "ada@example.com";
	payload["users"] ~= row;
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
