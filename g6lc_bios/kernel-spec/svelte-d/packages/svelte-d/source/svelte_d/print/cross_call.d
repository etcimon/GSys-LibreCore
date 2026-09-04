// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// lang=ts exports ↔ lang=d via libwasm Lodash (`callTs`) and
// exportDelegate / callNative. Registry keys are module-mangled
// (`ident.fn`) so cross-svelte calls stay unique; local D thunks
// keep the simple name. Extra args are never required — omitted
// ones keep the callee default.
module svelte_d.print.cross_call;

import std.algorithm : canFind, startsWith;
import std.array : appender, join;
import std.conv : to;
import std.string : indexOf, replace, strip, toLower;
import std.uni : isAlphaNum;
import svelte_d.parse.svelte;
import svelte_d.fallthrough : identFromRel;

struct TsExport
{
	string name;
	bool async_;
	string retType; /// raw TS annotation, may be empty
	string[] paramNames;
	string[] paramDefaults; /// empty string = no default
}

struct DExport
{
	string name;
	string retType;
	string[] paramNames;
	string[] paramDefaults;
	string body; /// full `extern(C) export … { … }`
}

struct TsImport
{
	string spec;
	string[] names; /// empty = side-effect import
}

struct CrossCall
{
	string ident; /// identFromRel (instance)
	string identMod; /// ident + "_mod" when a context=module script exists
	TsExport[] tsInst;
	TsExport[] tsMod;
	DExport[] dExports;
	TsImport[] tsImports;
}

CrossCall analyzeCrossCall(string srcSvelteRel, SvelteScan scan)
{
	CrossCall c;
	c.ident = identFromRel(srcSvelteRel);
	c.identMod = c.ident ~ "_mod";
	foreach (s; scan.scripts)
	{
		if (s.lang == "ts")
		{
			auto ex = parseTsExports(s.body);
			if (s.moduleContext)
				c.tsMod ~= ex;
			else
				c.tsInst ~= ex;
			c.tsImports ~= parseTsImports(s.body);
		}
		else if (s.lang == "d")
			c.dExports ~= parseDExports(s.body);
	}
	return c;
}

string registryIdent(const ref CrossCall c, bool moduleContext)
{
	return moduleContext && c.tsMod.length ? c.identMod : c.ident;
}

/// Variadic D thunks — caller may omit trailing args (JS/D defaults apply).
string emitTsThunks(const ref CrossCall c)
{
	auto acc = appender!string();
	void one(const TsExport[] list, string ident)
	{
		foreach (e; list)
		{
			if (!e.name.length || dDefines(c, e.name))
				continue;
			auto path = ident ~ "." ~ e.name;
			if (e.async_ || isPromiseType(e.retType))
			{
				auto t = promiseInner(e.retType);
				acc ~= "JsPromise!(" ~ t ~ ") " ~ e.name
					~ "(ARGS...)(auto ref ARGS args)\n{\n  return callTsPromise!("
					~ t ~ ")(\"" ~ path ~ "\", args);\n}\n\n";
			}
			else
			{
				auto t = dRetType(e.retType);
				if (t == "void")
					acc ~= "void " ~ e.name
						~ "(ARGS...)(auto ref ARGS args)\n{\n  cast(void) callTs!Any(\""
						~ path ~ "\", args);\n}\n\n";
				else
					acc ~= t ~ " " ~ e.name
						~ "(ARGS...)(auto ref ARGS args)\n{\n  return callTs!("
						~ t ~ ")(\"" ~ path ~ "\", args);\n}\n\n";
			}
		}
	}
	one(c.tsInst, c.ident);
	one(c.tsMod, c.tsMod.length ? c.identMod : c.ident);
	return acc.data;
}

string emitDExportWrappers(const ref CrossCall c)
{
	if (!c.dExports.length)
		return "";
	auto acc = appender!string();
	foreach (e; c.dExports)
	{
		acc ~= e.body;
		if (e.body.length && e.body[$ - 1] != '\n')
			acc ~= "\n";
		auto wrap = "svelte_d_wrap_" ~ c.ident ~ "_" ~ e.name;
		acc ~= "\nvoid " ~ wrap ~ "(Handle h) @trusted\n{\n";
		foreach (i, pn; e.paramNames)
		{
			auto defv = (i < e.paramDefaults.length) ? e.paramDefaults[i] : "";
			if (looksStringParam(e.body, pn))
			{
				acc ~= "  string " ~ pn ~ " = "
					~ (defv.length ? defv : "\"\"") ~ ";\n";
				acc ~= "  if (h > 2)\n  {\n    auto _j" ~ pn ~ " = JSON(h)["
					~ to!string(cast(uint) i) ~ "];\n"
					~ "    if (_j" ~ pn ~ ".handle.handle > 2) " ~ pn
					~ " = _j" ~ pn ~ ".as!string;\n  }\n";
			}
			else
			{
				acc ~= "  int " ~ pn ~ " = " ~ (defv.length ? defv : "0") ~ ";\n";
				acc ~= "  if (h > 2)\n  {\n    auto _j" ~ pn ~ " = JSON(h)["
					~ to!string(cast(uint) i) ~ "];\n"
					~ "    if (_j" ~ pn ~ ".handle.handle > 2) " ~ pn
					~ " = cast(int) _j" ~ pn ~ ".as!long;\n  }\n";
			}
		}
		if (e.retType == "void" || !e.retType.length)
		{
			acc ~= "  " ~ e.name ~ "(";
			foreach (i, pn; e.paramNames)
			{
				if (i)
					acc ~= ", ";
				acc ~= pn;
			}
			acc ~= ");\n";
		}
		else
		{
			acc ~= "  auto _r = " ~ e.name ~ "(";
			foreach (i, pn; e.paramNames)
			{
				if (i)
					acc ~= ", ";
				acc ~= pn;
			}
			acc ~= ");\n  setDRet(_r);\n";
		}
		acc ~= "}\n\n";
	}
	acc ~= "void registerDExports_" ~ c.ident ~ "() @trusted\n{\n";
	foreach (e; c.dExports)
		acc ~= "  exportDelegate(\"" ~ c.ident ~ "." ~ e.name
			~ "\", &svelte_d_wrap_" ~ c.ident ~ "_" ~ e.name ~ ");\n";
	acc ~= "}\n\n";
	return acc.data;
}

/// Lift `extern(C) export` functions out of the struct body.
string peelExternCExports(string dbody, out DExport[] found)
{
	found = parseDExports(dbody);
	if (!found.length)
		return dbody;
	string outp = dbody;
	foreach (e; found)
		outp = outp.replace(e.body, "\n");
	return outp;
}

string emitTsTrailer(string ident, TsExport[] exps, string body)
{
	auto acc = appender!string();
	acc ~= "\nimport { ensureSvelteD } from '../libwasm.ts';\n";
	acc ~= "{\n  const __sd = ensureSvelteD();\n";
	foreach (e; exps)
	{
		acc ~= "  __sd.registerTs(\"" ~ ident ~ "\", \"" ~ e.name
			~ "\", (...args: any[]) => " ~ e.name ~ "(...args));\n";
	}
	acc ~= "}\n";
	if (indexOf(body, "jsExports") >= 0)
		return acc.data;
	acc ~= "export const jsExports = { env: {\n";
	foreach (e; exps)
		acc ~= "  " ~ e.name ~ ": (...args: any[]) => " ~ e.name ~ "(...args),\n";
	acc ~= "} as Record<string, unknown> };\n";
	return acc.data;
}

string rewriteTsImports(string body, string srcSvelteRel, ref string[] npmOut)
{
	auto acc = appender!string();
	size_t i;
	while (i < body.length)
	{
		auto j = findFrom(body, i);
		if (j < 0)
		{
			acc ~= body[i .. $];
			break;
		}
		acc ~= body[i .. j];
		char q = body[j];
		auto k = indexOf(body, q, j + 1);
		if (k < 0)
		{
			acc ~= body[j .. $];
			break;
		}
		auto spec = body[j + 1 .. k];
		acc ~= q ~ rewriteSpec(spec, srcSvelteRel, npmOut) ~ q;
		i = k + 1;
	}
	return acc.data;
}

TsExport[] parseTsExports(string src)
{
	TsExport[] o;
	size_t i;
	while (i < src.length)
	{
		auto p = indexOf(src, "export ", i);
		if (p < 0)
			break;
		auto rest = src[p + 7 .. $].strip;
		TsExport e;
		if (rest.startsWith("async function"))
		{
			e.async_ = true;
			rest = rest[14 .. $].strip;
			e = parseTsFun(rest, e);
		}
		else if (rest.startsWith("function"))
		{
			rest = rest[8 .. $].strip;
			e = parseTsFun(rest, e);
		}
		else if (rest.startsWith("const ") || rest.startsWith("let ") || rest.startsWith("var "))
		{
			auto sp = rest.indexOf(' ');
			rest = rest[sp + 1 .. $].strip;
			e.name = takeIdent(rest);
			auto eq = rest.indexOf('=');
			if (eq >= 0)
			{
				auto rhs = rest[eq + 1 .. $].strip;
				if (rhs.startsWith("async"))
					e.async_ = true;
			}
		}
		if (e.name.length && e.name != "jsExports" && !canFindName(o, e.name))
			o ~= e;
		i = p + 8;
	}
	return o;
}

TsImport[] parseTsImports(string src)
{
	TsImport[] o;
	size_t i;
	while (i < src.length)
	{
		auto p = indexOf(src, "from ", i);
		auto q = indexOf(src, "import ", i);
		size_t at = size_t.max;
		if (p >= 0)
			at = p;
		if (q >= 0 && q < at)
			at = q;
		if (at == size_t.max)
			break;
		auto cut = src[at .. $];
		auto a = indexOf(cut, '\'');
		auto b = indexOf(cut, '"');
		size_t qpos = size_t.max;
		char qc;
		if (a >= 0)
		{
			qpos = a;
			qc = '\'';
		}
		if (b >= 0 && b < qpos)
		{
			qpos = b;
			qc = '"';
		}
		if (qpos == size_t.max)
		{
			i = at + 5;
			continue;
		}
		auto abs = at + qpos;
		auto end = indexOf(src, qc, abs + 1);
		if (end < 0)
			break;
		TsImport im;
		im.spec = src[abs + 1 .. end];
		if (im.spec.length && !canFindSpec(o, im.spec))
			o ~= im;
		i = end + 1;
	}
	return o;
}

DExport[] parseDExports(string src)
{
	DExport[] o;
	size_t i;
	while (i < src.length)
	{
		auto p = indexOf(src, "extern", i);
		if (p < 0)
			break;
		auto rest = src[p .. $];
		if (!startsWithIgnoreSpace(rest, "extern(C)") && !startsWithIgnoreSpace(rest, "extern (C)"))
		{
			i = p + 6;
			continue;
		}
		auto exp = indexOf(rest, "export");
		if (exp < 0 || exp > 24)
		{
			i = p + 6;
			continue;
		}
		auto after = rest[exp + 6 .. $].strip;
		DExport e;
		e.retType = takeIdent(after);
		after = after[e.retType.length .. $].strip;
		e.name = takeIdent(after);
		auto par = after.indexOf('(');
		auto parE = after.indexOf(')');
		if (par >= 0 && parE > par)
			parseDParams(after[par + 1 .. parE], e);
		auto brace = indexOf(src, '{', p);
		if (brace < 0)
		{
			i = p + 6;
			continue;
		}
		auto end = matchBrace(src, brace);
		if (end < 0)
		{
			i = p + 6;
			continue;
		}
		e.body = src[p .. end + 1].strip;
		if (e.name.length)
			o ~= e;
		i = end + 1;
	}
	return o;
}

private bool dDefines(const ref CrossCall c, string name)
{
	foreach (e; c.dExports)
		if (e.name == name)
			return true;
	return false;
}

private bool canFindName(TsExport[] a, string n)
{
	foreach (e; a)
		if (e.name == n)
			return true;
	return false;
}

private bool canFindSpec(TsImport[] a, string s)
{
	foreach (e; a)
		if (e.spec == s)
			return true;
	return false;
}

private TsExport parseTsFun(string rest, TsExport e)
{
	e.name = takeIdent(rest);
	auto par = rest.indexOf('(');
	auto parE = rest.indexOf(')');
	if (par >= 0 && parE > par)
	{
		auto params = rest[par + 1 .. parE];
		parseTsParams(params, e);
		auto after = rest[parE + 1 .. $].strip;
		if (after.length && after[0] == ':')
		{
			after = after[1 .. $].strip;
			size_t n;
			int depth;
			foreach (ch; after)
			{
				if (ch == '<')
					depth++;
				else if (ch == '>')
					depth--;
				else if ((ch == '{' || ch == '\n') && depth == 0)
					break;
				n++;
			}
			e.retType = after[0 .. n].strip;
		}
	}
	return e;
}

private void parseTsParams(string params, ref TsExport e)
{
	foreach (part; splitComma(params))
	{
		auto t = part.strip;
		if (!t.length || t == "...")
			continue;
		auto col = t.indexOf(':');
		auto eq = t.indexOf('=');
		string name = t;
		if (col >= 0)
			name = t[0 .. col].strip;
		else if (eq >= 0)
			name = t[0 .. eq].strip;
		if (name.length && name[$ - 1] == '?')
			name = name[0 .. $ - 1];
		e.paramNames ~= takeIdent(name);
		if (eq >= 0)
			e.paramDefaults ~= t[eq + 1 .. $].strip;
		else
			e.paramDefaults ~= "";
	}
}

private void parseDParams(string params, ref DExport e)
{
	foreach (part; splitComma(params))
	{
		auto t = part.strip;
		if (!t.length)
			continue;
		auto eq = t.indexOf('=');
		string left = eq >= 0 ? t[0 .. eq].strip : t;
		auto sp = lastSpace(left);
		e.paramNames ~= takeIdent(sp >= 0 ? left[sp + 1 .. $] : left);
		e.paramDefaults ~= eq >= 0 ? t[eq + 1 .. $].strip : "";
	}
}

private string[] splitComma(string s)
{
	string[] o;
	size_t i;
	int depth;
	foreach (j, c; s)
	{
		if (c == '(' || c == '<' || c == '[')
			depth++;
		else if (c == ')' || c == '>' || c == ']')
			depth--;
		else if (c == ',' && depth == 0)
		{
			o ~= s[i .. j];
			i = j + 1;
		}
	}
	o ~= s[i .. $];
	return o;
}

private ptrdiff_t lastSpace(string s)
{
	ptrdiff_t p = -1;
	foreach (i, c; s)
		if (c == ' ' || c == '\t')
			p = i;
	return p;
}

private string takeIdent(string s)
{
	string o;
	foreach (c; s.strip)
	{
		if (isAlphaNum(c) || c == '_')
			o ~= c;
		else
			break;
	}
	return o;
}

private bool isPromiseType(string t)
{
	auto s = t.strip.toLower;
	return s.startsWith("promise");
}

private string promiseInner(string t)
{
	auto a = t.indexOf('<');
	auto b = t.indexOf('>');
	if (a >= 0 && b > a)
		return dRetType(t[a + 1 .. b]);
	return "Any";
}

private string dRetType(string t)
{
	auto s = t.strip;
	if (!s.length || s == "void")
		return "void";
	if (s == "string" || s == "String")
		return "string";
	if (s == "number" || s == "int" || s == "bigint")
		return "long";
	if (s == "boolean" || s == "bool")
		return "long";
	if (s == "any" || s == "unknown" || s == "object")
		return "Any";
	return "Any";
}

private string defaultLit(string t)
{
	if (t == "string")
		return "\"\"";
	return "0";
}

private bool looksStringParam(string body, string name)
{
	return canFind(body, "string " ~ name);
}

private bool startsWithIgnoreSpace(string s, string p)
{
	return s.strip.startsWith(p) || s.replace(" ", "").startsWith(p.replace(" ", ""));
}

private ptrdiff_t matchBrace(string s, size_t open)
{
	int depth;
	foreach (i; open .. s.length)
	{
		if (s[i] == '{')
			depth++;
		else if (s[i] == '}')
		{
			depth--;
			if (depth == 0)
				return i;
		}
	}
	return -1;
}

private ptrdiff_t findFrom(string body, size_t i)
{
	auto a = indexOf(body, "from '", i);
	auto b = indexOf(body, "from \"", i);
	auto c = indexOf(body, "import '", i);
	auto d = indexOf(body, "import \"", i);
	ptrdiff_t best = -1;
	void consider(ptrdiff_t p, size_t qlen)
	{
		if (p < 0)
			return;
		auto q = p + qlen;
		if (q >= body.length)
			return;
		if (best < 0 || p < best)
			best = q - 1; // position of quote
	}
	if (a >= 0)
		consider(a, 6);
	if (b >= 0)
		consider(b, 6);
	if (c >= 0)
		consider(c, 8);
	if (d >= 0)
		consider(d, 8);
	return best;
}

private string rewriteSpec(string spec, string srcSvelteRel, string[] npmOut)
{
	auto s = spec.strip;
	if (!s.length)
		return spec;
	if (s[0] == '.' || s[0] == '/')
	{
		if (s.length > 7 && s[$ - 7 .. $] == ".svelte")
		{
			auto target = resolveRel(srcSvelteRel, s);
			return "./" ~ identFromRel(target) ~ ".ts";
		}
		auto target = resolveRel(srcSvelteRel, s);
		if (target.length > 3 && target[$ - 3 .. $] == ".ts")
			target = target[0 .. $ - 3];
		if (target.length > 3 && target[$ - 3 .. $] == ".js")
			target = target[0 .. $ - 3];
		return "../../helpers/" ~ target;
	}
	if (s == "$lib" || s.startsWith("$lib/"))
	{
		auto rest = s == "$lib" ? "lib" : "lib/" ~ s[5 .. $];
		if (rest.length > 3 && rest[$ - 3 .. $] == ".ts")
			rest = rest[0 .. $ - 3];
		if (rest.length > 3 && rest[$ - 3 .. $] == ".js")
			rest = rest[0 .. $ - 3];
		return "../../helpers/" ~ rest;
	}
	if (s.startsWith("$app") || s.startsWith("$env") || s == "svelte" || s.startsWith("svelte/"))
		return spec;
	if (!canFind(npmOut, s))
		npmOut ~= s;
	return spec;
}

private string resolveRel(string fromRel, string spec)
{
	auto dir = fromRel;
	auto sl = lastSlash(dir);
	if (sl >= 0)
		dir = dir[0 .. sl];
	else
		dir = "";
	auto cur = dir;
	auto rest = spec;
	if (rest.startsWith("./"))
		rest = rest[2 .. $];
	while (rest.startsWith("../"))
	{
		rest = rest[3 .. $];
		auto p = lastSlash(cur);
		cur = p >= 0 ? cur[0 .. p] : "";
	}
	if (cur.length)
		return cur ~ "/" ~ rest;
	return rest;
}

private ptrdiff_t lastSlash(string s)
{
	ptrdiff_t p = -1;
	foreach (i, c; s)
		if (c == '/')
			p = i;
	return p;
}
