void getAdmin(HTTPServerRequest req, HTTPServerResponse res)
{
	Json payload = Json.emptyObject;
	payload["panel"] = "admin";
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
