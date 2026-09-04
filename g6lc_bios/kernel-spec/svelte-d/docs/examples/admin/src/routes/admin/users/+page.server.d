void getUsers(HTTPServerRequest req, HTTPServerResponse res)
{
	Json payload = Json.emptyObject;
	payload["users"] = Json.emptyArray;
	Json row = Json.emptyObject;
	row["email"] = "ada@example.com";
	payload["users"] ~= row;
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
