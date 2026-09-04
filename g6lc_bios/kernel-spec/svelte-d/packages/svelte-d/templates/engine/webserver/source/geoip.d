module geoip;

// Stub: dmaxminddb 0.1.2 fails to compile on LDC 1.42 (bigEndianToNative).
// Same signature as the slideshow3dai GeoLite2 path so helpers.d still imports it.

void resolveIP(string ip_address, out string country_code, out double longitude, out double latitude)
{
	country_code = "US";
	longitude = 40.0;
	latitude = -70.0;
	cast(void) ip_address;
}
