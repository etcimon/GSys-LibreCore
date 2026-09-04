module probe;

/// Not `nothrow` — 1.43 `-foptimize-nothrow` deletes landing pads.
/// Called from JS (`slideshow_eh_probe` / `slideshow_phobos_probe`).

export extern (C) int svelte_engine_eh_probe() @trusted
{
    ensureHeap();
    try
    {
        throw new Exception("svelte-engine-eh");
    }
    catch (Exception e)
    {
        return e.msg.length ? 1 : 2;
    }
}

export extern (C) int svelte_engine_phobos_probe() @trusted
{
    ensureHeap();
    try
    {
        return probePhobos();
    }
    catch (Throwable)
    {
        return -2;
    }
}

private void ensureHeap()
{
    import libwasm.rt.memory : alloc_init;
    import memutils.scoped : PoolStack;

    static bool started;
    if (started)
        return;
    alloc_init(1024 * 1024);
    PoolStack.initialize();
    started = true;
}

enum BitConv = 1 << 0;
enum BitFormat = 1 << 1;
enum BitAlgo = 1 << 2;
enum BitNumeric = 1 << 3;
enum BitMath = 1 << 4;
enum BitComplex = 1 << 5;
enum BitRandom = 1 << 6;
enum BitTypecons = 1 << 7;
enum BitEh = 1 << 8;
enum Expected = BitConv | BitFormat | BitAlgo | BitNumeric | BitMath
    | BitComplex | BitRandom | BitTypecons | BitEh;

pragma(inline, false)
int probePhobos() @trusted
{
    int bits;

    try
    {
        throw new Exception("eh-smoke");
    }
    catch (Exception e)
    {
        if (e.msg == "eh-smoke")
            bits |= BitEh;
    }

    try
    {
        import std.conv : to;

        auto ok = to!int("42") == 42;
        try
        {
            cast(void) to!int("not-an-int");
        }
        catch (Exception e)
        {
            if (ok && e.msg.length)
                bits |= BitConv;
        }
    }
    catch (Exception)
    {
    }

    try
    {
        import std.format : format;

        enum s = format!"%d"(7);
        if (s == "7")
            bits |= BitFormat;
    }
    catch (Exception)
    {
    }

    try
    {
        import std.algorithm : map, sum;
        import std.range : iota;

        auto n = iota(1, 6).map!(a => a * a).sum;
        if (n == 55)
            bits |= BitAlgo;
    }
    catch (Exception)
    {
    }

    try
    {
        import std.numeric : gcd;

        if (gcd(1071, 462) == 21)
            bits |= BitNumeric;
    }
    catch (Exception)
    {
    }

    try
    {
        import std.math : abs, exp, isClose, log;
        import std.mathspecial : gamma;

        enum real g5 = gamma(5.0L);
        auto e = exp(1.0);
        if (g5 > 23 && g5 < 25 && abs(log(e) - 1.0) < 1e-6)
            bits |= BitMath;
        else if (isClose(log(e), 1.0))
            bits |= BitMath;
    }
    catch (Exception)
    {
    }

    try
    {
        import std.complex : complex;

        auto z = complex(3.0, 4.0);
        if (z.re == 3.0 && z.im == 4.0)
            bits |= BitComplex;
    }
    catch (Exception)
    {
    }

    try
    {
        import std.random : Mt19937, uniform;

        auto rng = Mt19937(42);
        auto a = uniform(0, 10, rng);
        auto b = uniform(0, 10, rng);
        if (a >= 0 && a < 10 && b >= 0 && b < 10)
            bits |= BitRandom;
    }
    catch (Exception)
    {
    }

    try
    {
        import std.typecons : Nullable, Tuple, tuple;

        Tuple!(int, string) t = tuple(1, "x");
        Nullable!int n;
        n = 9;
        if (t[0] == 1 && t[1] == "x" && !n.isNull && n.get == 9)
            bits |= BitTypecons;
    }
    catch (Exception)
    {
    }

    return bits == Expected ? 1 : bits;
}
