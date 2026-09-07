module libwasm.moment;

import libwasm.types;

nothrow:
@safe:

Moment moment() {
    return Moment(libwasm_moment_now());
}

Moment moment(long ms) {
    return Moment(libwasm_moment_from_millis(ms));
}

Moment momentHandle(Handle handle) {
    return Moment(handle);
}

struct Moment {
    nothrow:
    @safe:
    private Handle m_handle;
    alias m_handle this;

    private this(Handle h) {
        m_handle = h;
    }

    long valueOf()() {
        return cast(long) Object_Call_string__double(m_handle, "getTime", "");
    }

    long unix()() {
        return valueOf() / 1000;
    }

    string format()(string fmt = null) {
        if (fmt.length == 0)
            fmt = "";
        return Object_Call_string__string(m_handle, "toISOString", fmt);
    }

    uint year()() { return Object_Call_string__uint(m_handle, "getFullYear", ""); }
    uint month()() { return Object_Call_string__uint(m_handle, "getMonth", ""); }
    uint date()() { return Object_Call_string__uint(m_handle, "getDate", ""); }
    uint day()() { return Object_Call_string__uint(m_handle, "getDay", ""); }
    uint hours()() { return Object_Call_string__uint(m_handle, "getHours", ""); }
    uint minutes()() { return Object_Call_string__uint(m_handle, "getMinutes", ""); }
    uint seconds()() { return Object_Call_string__uint(m_handle, "getSeconds", ""); }
    uint milliseconds()() { return Object_Call_string__uint(m_handle, "getMilliseconds", ""); }

    Moment add()(long n, string unit) {
        long ms = valueOf() + n * unitToMs(unit);
        return Moment(libwasm_moment_from_millis(ms));
    }

    Moment subtract()(long n, string unit) {
        return add(-n, unit);
    }

    long diff()(Moment other, string unit) {
        return (valueOf() - other.valueOf()) / unitToMs(unit);
    }

    Moment clone()() {
        return Moment(libwasm_moment_from_millis(valueOf()));
    }

    private static long unitToMs(string unit) {
        switch (unit) {
            case "milliseconds", "millisecond", "ms": return 1;
            case "seconds", "second", "s": return 1_000;
            case "minutes", "minute", "m": return 60_000;
            case "hours", "hour", "h": return 3_600_000;
            case "days", "day", "d": return 86_400_000;
            case "weeks", "week", "w": return 604_800_000;
            case "months", "month", "M": return 2_629_800_000;
            case "quarters", "quarter", "Q": return 7_889_400_000;
            case "years", "year", "y": return 31_557_600_000;
            default: return 1;
        }
    }
}
