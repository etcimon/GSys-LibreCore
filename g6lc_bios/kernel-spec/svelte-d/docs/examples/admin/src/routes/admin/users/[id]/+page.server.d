void getUser(HTTPServerRequest req, HTTPServerResponse res)
{
	Json payload = Json.emptyObject;
	auto id = req.params.get("id");
	payload["id"] = id.length ? id : "";
	res.writeBody(payload.serializeToJsonString(), "application/json");
}
