module events;

enum TypeCode {
	none
}

// must mimic the severity table in Postgresql
enum Severity : short {
	undefined,
	trace = 1,
	info,
	debug_,
	error
}

Severity getSeverity(string severity) {
	switch (severity) {
		case "trace":
			return Severity.trace;
		case "info":
			return Severity.info;
		case "debug":
			return Severity.debug_;
		case "error":
			return Severity.error;
		default:
			return Severity.error;
	}
}