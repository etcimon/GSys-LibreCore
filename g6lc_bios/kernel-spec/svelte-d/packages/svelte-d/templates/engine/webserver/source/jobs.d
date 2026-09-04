module jobs;
import vibe.data.json;
import std.datetime;

struct JobReport {
	Job[] jobs;

	static JobReport fromJson(Json json)
	{
		JobReport report;
		foreach (job; json["jobs"])
			report.jobs ~= Job.fromJson(job);
		return report;
	}
}

enum JobType {
	Unknown = 0,
	Update,
	Configuration
}

struct FileDetails {
	string filename;
	string download_url;
	bool is_x64;
	bool is_windows;
	string for_slideshow3dai_version_lt;
	string sha256;
}

struct UpdateInfo {
	string new_version;
	FileDetails slideshow3dai;
	FileDetails[] dependencies;
}

enum ConfigType {
	Unknown = 0,
	LogLevel,
	CheckInterval,
	DisableHTTP2,
	StayConnected,
	KeepAliveDuration,
	OneShotTimer,
	MicroTimer
}

struct ConfigurationInfo {
	bool persist;
	ConfigType type;
	union {
		Duration interval;
		bool flag;
		int number;
	}
	
	Json toJson() const {
		Json ret = Json.emptyObject;
		with(ConfigType) final switch (type) {
			case Unknown:
				break;
			case DisableHTTP2:
				ret["DisableHTTP2"] = flag;
				break;
			case StayConnected:
				ret["StayConnected"] = flag;
				break;
			case CheckInterval:
				ret["CheckInterval"] = interval.total!"seconds";
				break;
			case KeepAliveDuration:
				ret["KeepAliveDuration"] = interval.total!"seconds";
				break;
			case OneShotTimer:
				ret["OneShotTimer"] = interval.total!"seconds";
				break;
			case LogLevel:
				ret["LogLevel"] = number;
				break;
			case MicroTimer:
				ret["MicroTimer"] = interval.total!"seconds";
				break;
		}
		return ret;
	}
	
	static ConfigurationInfo fromJson(Json obj) {
		ConfigurationInfo ret;
		bool exists(string key) {
			return obj[key].type != Json.Type.undefined;
		}
		
		if (exists("DisableHTTP2")) {
			ret.type = ConfigType.CheckInterval;
			ret.flag = obj["DisableHTTP2"].get!bool;
		}
		else if (exists("StayConnected")) {
			ret.type = ConfigType.StayConnected;
			ret.flag = obj["StayConnected"].get!bool;
		}
		else if (exists("CheckInterval")) {
			ret.type = ConfigType.CheckInterval;
			ret.interval = dur!"seconds"(obj["CheckInterval"].get!long);
		}
		else if (exists("KeepAliveDuration")) {
			ret.type = ConfigType.KeepAliveDuration;
			ret.interval = dur!"seconds"(obj["KeepAliveDuration"].get!long);
		}
		else if (exists("LogLevel")) {
			ret.type = ConfigType.KeepAliveDuration;
			ret.number = obj["LogLevel"].get!int;
		}
		else if (exists("OneShotTimer")) {
			ret.type = ConfigType.OneShotTimer;
			ret.interval = dur!"seconds"(obj["OneShotTimer"].get!long);
		}
		else if (exists("MicroTimer")) {
			ret.type = ConfigType.MicroTimer;
			ret.interval = dur!"seconds"(obj["MicroTimer"].get!long);
		}
		return ret;
	}
}

struct Job {
	long id;
	JobType type;
	union {
		UpdateInfo update_info;
		ConfigurationInfo config_info;
	}
	
	Json toJson() const {
		Json ret = Json.emptyObject;
		ret["id"] = id;
		with(JobType) final switch (type)
		{
			case Unknown:
				break;
			case Configuration:
				ret["configuration"] = serializeToJson(config_info);
				break;
			case Update:
				ret["update"] = serializeToJson(update_info);
				break;
		}
		return ret;
	}
	
	static Job fromJson(Json obj) {
		Job ret;
		bool exists(string key) {
			return obj[key].type != Json.Type.undefined;
		}
		ret.id = obj["id"].get!long;
		if (exists("configuration"))
		{
			ret.type = JobType.Configuration;
			ret.config_info = deserializeJson!ConfigurationInfo(obj["configuration"]);
		}
		else if (exists("update"))
		{
			ret.type = JobType.Update;
			ret.update_info = deserializeJson!UpdateInfo(obj["update"]);
		}
		return ret;
	}
}