// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Svelte markup → libwasm struct IR (NodeDef / NamedNode / @prop / @callback /
// @connect / @inject / UnorderedList / HTMLArray assignEventListeners).
module svelte_d.print.dom_print;

import std.algorithm : canFind;
import std.array : Appender, appender, join;
import std.conv : to;
import std.string : replace, strip, toLower, indexOf;
import std.uni : isAlphaNum;
import svelte_d.parse.svelte;
import svelte_d.parse.markup;
import svelte_d.print.d_imports;
import svelte_d.print.cross_call;
import svelte_d.fallthrough : identFromRel;

struct DomPrint
{
	string dest;
	string generated;
	string[] udas;
	string[] authorImports;
	string[] rejectedImports;
	bool hasList;
	bool hasInject;
	bool ok = true;
	string detail;
	string parseKind;
}

private int gSeq;

/// One `{#await}` job to settle in `wireAwait`. First keeps
/// `await_then` / `await_catch` so Combo Go/Fail still rewrite.
private struct AwaitWire
{
	string job;
	string pend;
	string then;
	string catchChild;
	string catchName;
	string thenName;
	string recv;
	string catchPath;
	string thenPath;
	string pendFlag;
	string thenFlag;
	string catchFlag;
}

private int originLine(string src, string needle)
{
	if (!src.length || !needle.length)
		return 1;
	auto i = src.indexOf(needle);
	if (i < 0)
		return 1;
	int line = 1;
	foreach (c; src[0 .. i])
		if (c == '\n')
			line++;
	return line;
}

private string ident(string s)
{
	string o;
	foreach (c; s)
	{
		if (isAlphaNum(c) || c == '_')
			o ~= c;
		else
			o ~= '_';
	}
	if (!o.length)
		o = "x";
	if (o[0] >= '0' && o[0] <= '9')
		o = "n_" ~ o;
	return o;
}

private string pascal(string s)
{
	string o;
	bool up = true;
	foreach (c; s)
	{
		if (!isAlphaNum(c))
		{
			up = true;
			continue;
		}
		if (up)
		{
			if (c >= 'a' && c <= 'z')
				o ~= cast(char)(c - 32);
			else
				o ~= c;
			up = false;
		}
		else
			o ~= c;
	}
	if (!o.length)
		o = "N";
	if (o[0] >= '0' && o[0] <= '9')
		o = "N" ~ o;
	return o;
}

private string eventName(string onAttr)
{
	// on:click|preventDefault → click
	string s = onAttr;
	if (s.length > 3 && s[0 .. 3] == "on:")
		s = s[3 .. $];
	auto p = indexOf(s, "|");
	return p < 0 ? s : s[0 .. p];
}

private string[] eventMods(string onAttr)
{
	string s = onAttr;
	if (s.length > 3 && s[0 .. 3] == "on:")
		s = s[3 .. $];
	string[] o;
	auto p = indexOf(s, "|");
	if (p < 0)
		return o;
	auto rest = s[p + 1 .. $];
	size_t i;
	foreach (j, c; rest)
	{
		if (c == '|')
		{
			if (j > i)
				o ~= rest[i .. j];
			i = j + 1;
		}
	}
	if (i < rest.length)
		o ~= rest[i .. $];
	return o;
}

private bool isBoolAttr(string name)
{
	auto n = name.toLower;
	return n == "disabled" || n == "checked" || n == "hidden" || n == "readonly"
		|| n == "required" || n == "autofocus" || n == "multiple" || n == "selected"
		|| n == "open" || n == "defer" || n == "async" || n == "novalidate"
		|| n == "reversed" || n == "ismap" || n == "allowfullscreen" || n == "muted"
		|| n == "loop" || n == "controls" || n == "inert" || n == "default";
}

private string eventType(string ev)
{
	if (ev == "click" || ev == "dblclick" || ev == "mousedown" || ev == "mouseup")
		return "MouseEvent";
	if (ev == "keydown" || ev == "keyup" || ev == "keypress")
		return "KeyboardEvent";
	if (ev == "input")
		return "InputEvent";
	if (ev == "focus" || ev == "focusin" || ev == "focusout")
		return "FocusEvent";
	if (ev == "blur")
		return "Event";
	if (ev.length >= 7 && ev[0 .. 7] == "pointer")
		return "PointerEvent";
	if (ev.length >= 5 && ev[0 .. 5] == "touch")
		return "TouchEvent";
	if (ev == "wheel")
		return "WheelEvent";
	if (ev == "change")
		return "Event";
	if (ev == "copy" || ev == "cut" || ev == "paste")
		return "ClipboardEvent";
	if (ev == "scroll")
		return "CustomEvent";
	if (ev == "contextmenu")
		return "MouseEvent";
	if (ev == "drag" || ev == "dragstart" || ev == "dragend" || ev == "drop"
			|| ev == "dragover" || ev == "dragenter" || ev == "dragleave")
		return "DragEvent";
	return "CustomEvent";
}

/// `{#if n > 0}` / `n == 1` → left ident; empty if not a comparison
private string cmpIfLeft(string s)
{
	s = s.strip;
	if (splitAndParts(s).length >= 2 || splitOrParts(s).length >= 2)
		return "";
	string[] ops = [">=", "<=", "==", "!=", ">", "<"];
	foreach (op; ops)
	{
		auto p = indexOf(s, op);
		if (p <= 0)
			continue;
		auto left = s[0 .. p].strip;
		if (left.length && isMustacheIdent(left))
			return left;
	}
	return "";
}

/// `[id]` / `[[lang]]` in a kit source path → D field names. Skip `[...rest]`.
private string[] kitParamNames(string srcRel)
{
	auto s = srcRel.replace(`\`, `/`);
	string[] o;
	size_t i;
	while (i < s.length)
	{
		if (s[i] != '[')
		{
			i++;
			continue;
		}
		auto j = i + 1;
		if (j < s.length && s[j] == '[')
			j++;
		if (j < s.length && s[j] == '.')
		{
			i++;
			continue;
		}
		string n;
		while (j < s.length && s[j] != ']' && s[j] != '.')
		{
			n ~= s[j];
			j++;
		}
		auto id = ident(n);
		if (id.length)
		{
			bool seen;
			foreach (x; o)
				if (x == id)
					seen = true;
			if (!seen)
				o ~= id;
		}
		i = j;
	}
	return o;
}

/// D field name for a Slot mixin. `default` is a keyword.
private string slotField(string n)
{
	auto s = ident(n);
	if (s == "default" || s == "module" || s == "version" || s == "function"
		|| s == "in" || s == "out" || s == "body" || s == "align"
		|| s == "init" || s == "scope" || s == "shared")
		return s ~ "_";
	return s;
}

/// `this.emit(done)` / `emit(done)` → slot name `done`
private string[] emitSlotNames(string dbody)
{
	string[] o;
	size_t i;
	while (i < dbody.length)
	{
		auto at = indexOfFrom(dbody, "emit(", i);
		if (at < 0)
			break;
		auto p = at + 5;
		while (p < dbody.length && (dbody[p] == ' ' || dbody[p] == '\t'))
			p++;
		string name;
		while (p < dbody.length && (isAlphaNum(dbody[p]) || dbody[p] == '_'))
		{
			name ~= dbody[p];
			p++;
		}
		i = p;
		if (!name.length)
			continue;
		name = slotField(name);
		bool seen;
		foreach (x; o)
			if (x == name)
				seen = true;
		if (!seen)
			o ~= name;
	}
	return o;
}

/// Author already wrote `mixin Slot!"n"` / `mixin Slot!("n", …)`.
private bool hasMixinSlot(string hay, string name)
{
	if (!name.length)
		return false;
	return canFind(hay, `mixin Slot!"` ~ name ~ `"`)
		|| canFind(hay, `mixin Slot!("` ~ name ~ `"`);
}

private bool findItemElement(MkNode[] ks, ref MkNode found)
{
	foreach (k; ks)
	{
		if (k.kind == MkNode.Kind.element)
		{
			found = k;
			return true;
		}
		if (k.kind == MkNode.Kind.if_ || k.kind == MkNode.Kind.await_
				|| k.kind == MkNode.Kind.key_ || k.kind == MkNode.Kind.snippet)
		{
			if (findItemElement(k.kids, found))
				return true;
			if (findItemElement(k.elseKids, found))
				return true;
			if (findItemElement(k.catchKids, found))
				return true;
		}
	}
	return false;
}

/// `{#each}{#if cond}<li>` — host bool, same cond on every item (G94).
/// Dotted `alias.field` is item-local (see `eachIfItemField`).
private string eachIfCond(MkNode n)
{
	string cond;
	bool any;
	foreach (k; n.kids)
	{
		if (k.kind != MkNode.Kind.if_ && k.kind != MkNode.Kind.element
				&& k.kind != MkNode.Kind.text)
			continue;
		if (k.kind == MkNode.Kind.text)
			continue;
		if (k.kind != MkNode.Kind.if_)
			return "";
		auto raw = k.text.strip;
		if (raw.length && raw[0] == '!')
			return "";
		if (canFind(raw, '.') || canFind(raw, '['))
			return "";
		auto c = ident(raw);
		if (!c.length)
			return "";
		if (any && c != cond)
			return "";
		cond = c;
		any = true;
	}
	return any ? cond : "";
}

/// `{#each rows as row}{#if row.ok}` — cond is the item field after the alias.
private string eachIfItemField(MkNode n)
{
	auto aliasParts = splitCommaIdents(n.aliasName);
	auto alias0 = ident(aliasParts.length ? aliasParts[0]
			: (n.aliasName.length ? n.aliasName : "item"));
	string field;
	bool any;
	foreach (k; n.kids)
	{
		if (k.kind != MkNode.Kind.if_ && k.kind != MkNode.Kind.element
				&& k.kind != MkNode.Kind.text)
			continue;
		if (k.kind == MkNode.Kind.text)
			continue;
		if (k.kind != MkNode.Kind.if_)
			return "";
		auto raw = k.text.strip;
		if (!raw.length || raw[0] == '!')
			return "";
		auto dot = raw.indexOf('.');
		if (dot <= 0)
			return "";
		auto left = raw[0 .. dot].strip;
		auto right = raw[dot + 1 .. $].strip;
		if (!isMustacheIdent(left) || !isMustacheIdent(right))
			return "";
		if (ident(left) != alias0)
			return "";
		if (any && right != field)
			return "";
		field = right;
		any = true;
	}
	return any ? field : "";
}

/// `{#each skips as skip}{#if !skip.ok}` — negated item field (G99).
private string eachIfItemNeg(MkNode n)
{
	auto aliasParts = splitCommaIdents(n.aliasName);
	auto alias0 = ident(aliasParts.length ? aliasParts[0]
			: (n.aliasName.length ? n.aliasName : "item"));
	string field;
	bool any;
	foreach (k; n.kids)
	{
		if (k.kind != MkNode.Kind.if_ && k.kind != MkNode.Kind.element
				&& k.kind != MkNode.Kind.text)
			continue;
		if (k.kind == MkNode.Kind.text)
			continue;
		if (k.kind != MkNode.Kind.if_)
			return "";
		auto raw = k.text.strip;
		if (raw.length < 2 || raw[0] != '!')
			return "";
		raw = raw[1 .. $].strip;
		auto dot = raw.indexOf('.');
		if (dot <= 0)
			return "";
		auto left = raw[0 .. dot].strip;
		auto right = raw[dot + 1 .. $].strip;
		if (!isMustacheIdent(left) || !isMustacheIdent(right))
			return "";
		if (ident(left) != alias0)
			return "";
		if (any && right != field)
			return "";
		field = right;
		any = true;
	}
	return any ? field : "";
}

private struct EachIfCmp
{
	string field;
	string op;
	string rhs;
	string host;
	string hostOp;
	bool hostNeg;
	bool neg;
}

private bool cmpRhsOk(string right)
{
	if (!right.length)
		return false;
	if (isMustacheIdent(right))
		return true;
	foreach (c; right)
		if (c < '0' || c > '9')
			return false;
	return true;
}

private EachIfCmp parseItemCmpPart(string raw, string alias0)
{
	EachIfCmp none;
	raw = raw.strip;
	bool wrapNeg;
	if (raw.length >= 4 && raw[0] == '!' && raw[1] == '(' && raw[$ - 1] == ')')
	{
		wrapNeg = true;
		raw = raw[2 .. $ - 1].strip;
	}
	else if (raw.length && raw[0] == '!')
		return none;
	if (!raw.length)
		return none;
	string[] ops = [">=", "<=", "==", "!=", ">", "<"];
	string op;
	ptrdiff_t at = -1;
	foreach (cand; ops)
	{
		auto p = raw.indexOf(cand);
		if (p > 0)
		{
			op = cand;
			at = p;
			break;
		}
	}
	if (at <= 0)
		return none;
	auto left = raw[0 .. at].strip;
	auto right = raw[at + op.length .. $].strip;
	auto dot = left.indexOf('.');
	if (dot <= 0)
		return none;
	auto rec = left[0 .. dot].strip;
	auto field = left[dot + 1 .. $].strip;
	if (!isMustacheIdent(rec) || !isMustacheIdent(field) || ident(rec) != alias0)
		return none;
	if (!cmpRhsOk(right))
		return none;
	EachIfCmp o;
	o.field = field;
	o.op = op;
	o.rhs = right;
	o.neg = wrapNeg;
	return o;
}

private string parseHostPart(string raw, ref bool hostNeg)
{
	raw = raw.strip;
	if (raw.length && raw[0] == '!')
	{
		hostNeg = true;
		raw = raw[1 .. $].strip;
	}
	if (!raw.length || canFind(raw, '.') || canFind(raw, '['))
		return "";
	if (isMustacheIdent(raw))
		return ident(raw);
	return "";
}

/// `{#if hit.n > 0}` (G109) / `{#if more.n > 0 && on}` (G110) /
/// `{#if lot.n > 0 || on}` (G111) / `{#if few.n > 0 && !on}` (G112).
private EachIfCmp eachIfItemCmp(MkNode n)
{
	EachIfCmp none;
	auto aliasParts = splitCommaIdents(n.aliasName);
	auto alias0 = ident(aliasParts.length ? aliasParts[0]
			: (n.aliasName.length ? n.aliasName : "item"));
	EachIfCmp found;
	bool any;
	foreach (k; n.kids)
	{
		if (k.kind != MkNode.Kind.if_ && k.kind != MkNode.Kind.element
				&& k.kind != MkNode.Kind.text)
			continue;
		if (k.kind == MkNode.Kind.text)
			continue;
		if (k.kind != MkNode.Kind.if_)
			return none;
		auto raw = k.text.strip;
		if (!raw.length)
			return none;
		EachIfCmp cur;
		auto andAt = raw.indexOf("&&");
		auto orAt = raw.indexOf("||");
		if (andAt > 0 && orAt > 0)
			return none;
		if (andAt > 0 || orAt > 0)
		{
			auto hop = andAt > 0 ? "&&" : "||";
			auto at = andAt > 0 ? andAt : orAt;
			auto a = raw[0 .. at].strip;
			auto b = raw[at + 2 .. $].strip;
			if (!a.length || !b.length || canFind(b, "&&") || canFind(b, "||"))
				return none;
			bool hnegA, hnegB;
			auto ca = parseItemCmpPart(a, alias0);
			auto cb = parseItemCmpPart(b, alias0);
			auto ha = parseHostPart(a, hnegA);
			auto hb = parseHostPart(b, hnegB);
			if (ca.field.length && hb.length && !cb.field.length && !ha.length)
			{
				cur = ca;
				cur.host = hb;
				cur.hostOp = hop;
				cur.hostNeg = hnegB;
			}
			else if (cb.field.length && ha.length && !ca.field.length && !hb.length)
			{
				cur = cb;
				cur.host = ha;
				cur.hostOp = hop;
				cur.hostNeg = hnegA;
			}
			else
				return none;
		}
		else
		{
			cur = parseItemCmpPart(raw, alias0);
			if (!cur.field.length)
				return none;
		}
		if (any && (cur.field != found.field || cur.op != found.op || cur.rhs != found.rhs
				|| cur.host != found.host || cur.hostOp != found.hostOp
				|| cur.hostNeg != found.hostNeg || cur.neg != found.neg))
			return none;
		found = cur;
		any = true;
	}
	return any ? found : none;
}

private struct EachIfMix
{
	string field;
	string host;
	string op;
	bool neg;
	bool hostNeg;
}

/// `{#if pick.ok && on}` (G97) / `{#if hold.ok || on}` (G98) /
/// `{#if !cut.ok && on}` (G100) / `{#if drop.ok && !on}` (G102).
private EachIfMix eachIfMix(MkNode n)
{
	EachIfMix none;
	auto aliasParts = splitCommaIdents(n.aliasName);
	auto alias0 = ident(aliasParts.length ? aliasParts[0]
			: (n.aliasName.length ? n.aliasName : "item"));
	EachIfMix found;
	bool any;
	string partField(string part, ref bool neg)
	{
		if (part.length && part[0] == '!')
		{
			neg = true;
			part = part[1 .. $].strip;
		}
		auto dot = part.indexOf('.');
		if (dot <= 0)
			return "";
		auto left = part[0 .. dot].strip;
		auto right = part[dot + 1 .. $].strip;
		if (isMustacheIdent(left) && isMustacheIdent(right) && ident(left) == alias0)
			return right;
		return "";
	}
	string partHost(string part, ref bool hneg)
	{
		if (part.length && part[0] == '!')
		{
			hneg = true;
			part = part[1 .. $].strip;
		}
		if (canFind(part, '.') || canFind(part, '['))
			return "";
		if (isMustacheIdent(part))
			return ident(part);
		return "";
	}
	foreach (k; n.kids)
	{
		if (k.kind != MkNode.Kind.if_ && k.kind != MkNode.Kind.element
				&& k.kind != MkNode.Kind.text)
			continue;
		if (k.kind == MkNode.Kind.text)
			continue;
		if (k.kind != MkNode.Kind.if_)
			return none;
		auto raw = k.text.strip;
		if (!raw.length)
			return none;
		auto andAt = raw.indexOf("&&");
		auto orAt = raw.indexOf("||");
		string op;
		ptrdiff_t at = -1;
		if (andAt > 0 && orAt > 0)
			return none;
		if (andAt > 0)
		{
			op = "&&";
			at = andAt;
		}
		else if (orAt > 0)
		{
			op = "||";
			at = orAt;
		}
		else
			return none;
		auto a = raw[0 .. at].strip;
		auto b = raw[at + 2 .. $].strip;
		if (!a.length || !b.length || canFind(b, "&&") || canFind(b, "||"))
			return none;
		bool negA, negB, hnegA, hnegB;
		auto field = partField(a, negA);
		auto host = partHost(a, hnegA);
		auto fb = partField(b, negB);
		auto hb = partHost(b, hnegB);
		bool neg = field.length ? negA : negB;
		bool hostNeg = host.length ? hnegA : hnegB;
		if (fb.length)
		{
			field = fb;
			neg = negB;
		}
		if (hb.length)
		{
			host = hb;
			hostNeg = hnegB;
		}
		if (!field.length || !host.length)
			return none;
		if (any && (field != found.field || host != found.host || op != found.op
				|| neg != found.neg || hostNeg != found.hostNeg))
			return none;
		found.field = field;
		found.host = host;
		found.op = op;
		found.neg = neg;
		found.hostNeg = hostNeg;
		any = true;
	}
	return any ? found : none;
}

private string textOf(MkNode n)
{
	string t;
	foreach (k; n.kids)
		if (k.kind == MkNode.Kind.text)
			t ~= k.text;
	return t.strip;
}

private bool isMustacheIdent(string s)
{
	if (!s.length)
		return false;
	foreach (c; s)
		if (!isAlphaNum(c) && c != '_')
			return false;
	return true;
}

/// Print one interactive .svelte file to libwasm NodeDef IR.
DomPrint printDomComponent(string destRel, string srcRel, string hostName, SvelteScan scan,
	bool force = false)
{
	DomPrint r;
	r.dest = destRel.replace(`\`, `/`);
	string cssText;
	auto markup = stripStyleBlocks(scan.markup, cssText);
	auto parsed = parseMarkupEx(markup);
	auto forest = parsed.nodes;
	r.parseKind = parsed.kind.length ? parsed.kind : "scan-fail";
	if (!force && !markupIsInteractive(scan.markup) && !cssText.length)
		return r;

	string dbody;
	foreach (s; scan.scripts)
		if (s.lang == "d")
			dbody ~= s.body.strip ~ "\n";
	auto peeled = peelAuthorImports(dbody, ImportCell.wasm);
	dbody = peeled.body;
	DExport[] liftedEx;
	dbody = peelExternCExports(dbody, liftedEx);
	auto xc = analyzeCrossCall(srcRel, scan);
	if (liftedEx.length)
		xc.dExports = liftedEx;
	r.authorImports = keptMods(peeled);
	r.rejectedImports = rejectedMods(peeled);
	string[] runeMount;
	dbody = rewriteRunes(dbody, runeMount);
	dbody = wrapHeavyMethods(dbody);
	string[] ifConds;
	collectIfConds(forest, ifConds);
	string[string] boolInits;
	foreach (c; ifConds)
		dbody = takeBoolDecl(dbody, ident(c), boolInits);
	string[] eachNames;
	collectEachNames(forest, eachNames);
	string[][string] arraySeeds;
	foreach (en; eachNames)
		dbody = takeArrayDecl(dbody, en, arraySeeds);
	auto hasConstruct = canFind(dbody, "void construct");
	auto hasOnMount = canFind(dbody, "void onMount");
	auto hasOnUnmount = canFind(dbody, "void onUnmount");
	auto hasOnDestroy = canFind(dbody, "void onDestroy");

	gSeq = 0;
	auto acc = appender!string();
	acc ~= "/// compile!() fills @inject on static @child; list items use ctor + assignEventListeners.\n";
	acc ~= "/// construct / onMount / onUnmount are Spa hooks; ScopedPool wraps heavy methods.\n";
	acc ~= "struct " ~ hostName ~ "\n{\nnothrow:\n  @trusted:\n";
	acc ~= "  @inject!\"m_pool\" ManagedPool m_pool;\n";
	if (canFind(dbody, "formatNow") && !canFind(dbody, "import jshost"))
		acc ~= "  import jshost : formatNow;\n";
	foreach (pn; kitParamNames(srcRel))
		if (pn.length && !canFind(dbody, "string " ~ pn) && !canFind(acc.data, "string " ~ pn))
			acc ~= "  string " ~ pn ~ "; // kit param\n";
	foreach (cn; cssClassNames(cssText))
		r.udas ~= "style";

	string[] connects;
	string[][string] fieldsOf; // parent struct → @child names declared on it
	string[string] mustacheChild; // ident → @child field (this.update.msg → msgSpan.update.msg)
	string[string] visibleChild; // first @visible child (rewrite)
	string[string] visibleOwner; // cond → parent path (empty = host `this`)
	string[string] visSyncField; // author ident → @visible field on recv
	string[string] visSyncExpr; // author ident → rhs for that field
	string[string] visSyncElse; // author ident → not_* field
	string[][string] visDirect; // author ident → extra @visible kids (each-inner-if)
	string[string] elseVisible;
	string[][string] visibleMany; // cond → all consequent children
	string[][string] elseMany;
	string[][string] invertMany; // `{#if !cond}` → setVisible(child, !cond)
	string[][string] andVis; // `{#if a && b}` part → children
	string[string] andExpr; // part → `a && b` (last write; prefer andExprChild)
	string[string] andExprChild; // @visible child → its full pred
	string[][string] derivedAssigns; // ident → `field = expr` (all ifs sharing ident)
	bool[string] emittedHostBool; // one `bool on` even if several {#if} mention it
	string[][string] classSync; // bool ident → child fields with @style
	string[string] tagChild; // this={tag} ident → child fname (applyTag)
	string[] constructLines;
	string[] itemFieldSyncs;
	dbody = peelRuntimeInits(dbody, constructLines);
	if (xc.dExports.length)
		constructLines ~= "    registerDExports_" ~ xc.ident ~ "();";
	if (cssText.length)
		constructLines ~= "    addCss(\"" ~ escapeDString(cssText) ~ "\");";
	string[] onMountLines;
	string[] onMountTail;
	AwaitWire[] awaitWires;
	foreach (ln; runeMount)
		onMountLines ~= ln;
	string[string] bindThis; // host Handle field ← child fname
	MkNode[string] snippetStore; // {#snippet name} body, instantiated at {@render}
	string boundaryResetHandler; // failed(error, reset) → resetBoundary
	string[] listNames;
	string[string] listEmptyChild; // extras → empty_extrasP
	string[string] listEmptyRecv; // extras → extras (else lives on the list)
	bool absorbEachOwnsUl;
	auto nested = appender!string();
	string[][string] pendingKids;
	bool sawList;
	bool sawInject;

	void addDerived(string ident, string assign)
	{
		if (auto a = ident in derivedAssigns)
			foreach (x; *a)
				if (x == assign)
					return;
		derivedAssigns[ident] ~= assign;
	}
	void emitHostBool(string name, string init)
	{
		if (name in emittedHostBool)
			return;
		if (canFind(acc.data, "bool " ~ name ~ " ="))
		{
			emittedHostBool[name] = true;
			return;
		}
		emittedHostBool[name] = true;
		acc ~= "  bool " ~ name ~ " = " ~ init ~ ";\n";
	}

	bool onHost(string parent)
	{
		return parent == hostName || !parent.length;
	}

	bool hostHasName(string name)
	{
		if (!name.length)
			return false;
		if (name in boolInits)
			return true;
		bool declAt(string src, string ty)
		{
			auto needle = ty ~ name;
			ptrdiff_t i = src.indexOf(needle);
			while (i >= 0)
			{
				auto after = i + needle.length;
				if (after >= src.length || (!isAlphaNum(src[after]) && src[after] != '_'))
					return true;
				i = src.indexOf(needle, after);
			}
			return false;
		}
		foreach (ty; ["bool ", "string ", "int ", "double ", "Handle "])
		{
			if (declAt(dbody, ty) || declAt(acc.data, ty))
				return true;
		}
		return false;
	}

	bool hostHasPromise(string name)
	{
		if (!name.length)
			return false;
		ptrdiff_t i = dbody.indexOf("JsPromise");
		while (i >= 0)
		{
			auto j = i + 9;
			while (j < dbody.length && dbody[j] != ' ' && dbody[j] != '\t'
					&& dbody[j] != ';' && dbody[j] != '=')
				j++;
			while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
				j++;
			auto n0 = j;
			while (j < dbody.length && (isAlphaNum(dbody[j]) || dbody[j] == '_'))
				j++;
			if (dbody[n0 .. j] == name)
				return true;
			i = dbody.indexOf("JsPromise", i + 9);
		}
		return false;
	}

	void emitChildDecl(string parent, string line)
	{
		if (onHost(parent))
			acc ~= line;
		else
			pendingKids[parent] ~= line;
	}

	string joinPath(string prefix, string fname)
	{
		return prefix.length ? prefix ~ "." ~ fname : fname;
	}

	string ownerKey(string parent)
	{
		return onHost(parent) ? hostName : parent;
	}

	void addField(string parent, string fname)
	{
		fieldsOf[ownerKey(parent)] ~= fname;
	}

	string[] ownerFields(string parent)
	{
		auto k = ownerKey(parent);
		if (auto p = k in fieldsOf)
			return *p;
		return null;
	}

	bool fieldTaken(string parent, string fname)
	{
		foreach (f; ownerFields(parent))
			if (f == fname)
				return true;
		return false;
	}

	bool[string] usedStructs;

	void takeStruct(string sname)
	{
		usedStructs[sname] = true;
	}

	/// Two `{:catch e}{e}` must not both emit `@child EP eP` / `struct EP`.
	void uniquifyName(string parent, ref string fname, ref string sname)
	{
		auto baseF = fname;
		auto baseS = sname;
		int n = 2;
		while (fieldTaken(parent, fname) || (sname in usedStructs))
		{
			fname = baseF ~ to!string(n);
			sname = baseS ~ to!string(n);
			n++;
		}
	}

	auto origRel = srcRel.replace(`\`, `/`);
	auto origSrc = scan.source;

	void emitOrigin(string needle, string kind, string name)
	{
		acc ~= "  //# svelte-d-ir orig=" ~ origRel ~ ":" ~ to!string(originLine(origSrc, needle))
			~ " kind=" ~ kind;
		if (name.length)
			acc ~= " name=" ~ name;
		acc ~= "\n";
	}

	bool walkable(MkNode k)
	{
		return k.kind == MkNode.Kind.element || k.kind == MkNode.Kind.each
			|| k.kind == MkNode.Kind.if_ || k.kind == MkNode.Kind.await_
			|| k.kind == MkNode.Kind.snippet || k.kind == MkNode.Kind.render
			|| k.kind == MkNode.Kind.key_ || k.kind == MkNode.Kind.const_
			|| k.kind == MkNode.Kind.debug_ || k.kind == MkNode.Kind.attach_
			|| (k.kind == MkNode.Kind.text && k.isHtml);
	}

	void walk(MkNode n, string parentStruct, string nameHint = null, string parentPath = "")
	{
		if (n.kind == MkNode.Kind.text && n.isHtml)
		{
			auto id = ident(n.text.length ? n.text : "html");
			auto fname = id ~ "Html";
			auto sname = pascal(id) ~ "Html";
			addField(parentStruct, fname);
			auto htmlPath = joinPath(parentPath, fname);
			emitChildDecl(parentStruct, "  @child " ~ sname ~ " " ~ fname ~ ";\n");
			mustacheChild[id] = htmlPath;
			constructLines ~= "    " ~ htmlPath ~ "." ~ id ~ " = " ~ id ~ ";";
			takeStruct(sname);
			nested ~= "struct " ~ sname ~ "\n{\nnothrow:\n  @trusted:\n";
			nested ~= "  @prop!\"innerHTML\" string " ~ id ~ ";\n";
			nested ~= "  mixin NodeDef!\"div\";\n}\n";
			r.udas ~= ["NodeDef", "child", "prop"];
			return;
		}
		if (n.kind == MkNode.Kind.if_)
		{
			emitOrigin("{#if " ~ n.text, "if", ident(n.text));
			auto raw = stripOuterParens(n.text.strip);
			bool inv;
			if (raw.length && raw[0] == '!')
			{
				inv = true;
				raw = raw[1 .. $].strip;
			}
			auto andParts = splitAndParts(raw);
			auto orParts = splitOrParts(raw);
			auto mixed = andParts.length >= 2 && orParts.length >= 2;
			string[] boolParts;
			string boolOp;
			string boolJoin;
			string[] boolBares;
			string[] boolDps;
			if (!inv && !mixed && andParts.length >= 2)
			{
				boolParts = andParts;
				boolOp = " && ";
				boolJoin = "_and_";
			}
			else if (!inv && !mixed && orParts.length >= 2)
			{
				boolParts = orParts;
				boolOp = " || ";
				boolJoin = "_or_";
			}
			if (boolParts.length >= 2)
			{
				foreach (p; boolParts)
				{
					auto t = p.strip;
					bool pinv = t.length && t[0] == '!';
					if (pinv)
						t = t[1 .. $].strip;
					auto pn = ident(t);
					boolBares ~= pn;
					boolDps ~= pinv ? ("!" ~ pn) : pn;
				}
			}
			auto cond = ident(raw.length ? raw : "shown");
			if (boolBares.length >= 2)
				cond = ident(join(boolBares, boolJoin));
			auto cmpLeft = cmpIfLeft(raw);
			auto isCmp = !inv && boolParts.length < 2 && cmpLeft.length;
			auto init = cond in boolInits ? boolInits[cond] : "false";
			auto before = ownerFields(parentStruct).length;
			auto kidHint = inv ? ("not_" ~ cond) : cond;
			foreach (k; n.kids)
				if (walkable(k))
					walk(k, parentStruct, kidHint, parentPath);
			auto grown = ownerFields(parentStruct);
			if (grown.length > before)
			{
				string uda;
				foreach (i; before .. grown.length)
				{
					auto fname = grown[i];
					uda ~= "@visible!\"" ~ fname ~ "\" ";
					if (inv)
					{
						invertMany[cond] ~= fname;
					}
					else if (boolBares.length >= 2)
					{
						auto dexpr = join(boolDps, boolOp);
						andExprChild[fname] = dexpr;
						foreach (pn; boolBares)
						{
							andVis[pn] ~= fname;
							andExpr[pn] = dexpr;
							addDerived(pn, cond ~ " = " ~ dexpr);
							if (parentPath.length)
								visibleOwner[pn] = parentPath;
						}
					}
					else if (isCmp)
					{
						andVis[cmpLeft] ~= fname;
						andExpr[cmpLeft] = raw;
						andExprChild[fname] = raw;
						addDerived(cmpLeft, cond ~ " = " ~ raw);
						if (parentPath.length)
							visibleOwner[cmpLeft] = parentPath;
					}
					else
					{
						visibleMany[cond] ~= fname;
						if (cond !in visibleChild)
							visibleChild[cond] = fname;
					}
				}
				if (parentPath.length)
					visibleOwner[cond] = parentPath;
				void emitOwnedVis(string visLine, string hostPlain)
				{
					if (onHost(parentStruct))
						acc ~= visLine;
					else
					{
						acc ~= hostPlain;
						emitChildDecl(parentStruct, visLine);
					}
				}
				if (inv)
				{
					auto einst = (init == "true") ? "false" : "true";
					emitHostBool(cond, init);
					visSyncField[cond] = "not_" ~ cond;
					visSyncExpr[cond] = "!" ~ cond;
					addDerived(cond, "not_" ~ cond ~ " = !" ~ cond);
					emitOwnedVis("  " ~ uda ~ "bool not_" ~ cond ~ " = " ~ einst ~ ";\n",
						"  bool not_" ~ cond ~ " = " ~ einst ~ ";\n");
					if (parentPath.length)
					{
						constructLines ~= "    " ~ parentPath ~ ".not_" ~ cond ~ " = !" ~ cond ~ ";";
						if (auto iv = cond in invertMany)
							foreach (fn; *iv)
								onMountLines ~= "    setVisible!\"" ~ fn ~ "\"(" ~ parentPath
									~ ", !" ~ cond ~ ");";
					}
				}
				else if (boolBares.length >= 2)
				{
					foreach (pn; boolBares)
					{
						auto pin = pn in boolInits ? boolInits[pn] : "false";
						emitHostBool(pn, pin);
						visSyncField[pn] = cond;
						visSyncExpr[pn] = join(boolDps, boolOp);
					}
					auto dexpr = join(boolDps, boolOp);
					emitOwnedVis("  " ~ uda ~ "bool " ~ cond ~ " = false;\n",
						"  bool " ~ cond ~ " = false;\n");
					constructLines ~= "    " ~ cond ~ " = " ~ dexpr ~ ";";
					if (parentPath.length)
						constructLines ~= "    " ~ parentPath ~ "." ~ cond ~ " = " ~ cond ~ ";";
				}
				else if (isCmp)
				{
					visSyncField[cmpLeft] = cond;
					visSyncExpr[cmpLeft] = raw;
					emitOwnedVis("  " ~ uda ~ "bool " ~ cond ~ " = false;\n",
						"  bool " ~ cond ~ " = false;\n");
					constructLines ~= "    " ~ cond ~ " = " ~ raw ~ ";";
					if (parentPath.length)
						constructLines ~= "    " ~ parentPath ~ "." ~ cond ~ " = " ~ cond ~ ";";
				}
				else
				{
					visSyncField[cond] = cond;
					visSyncExpr[cond] = cond;
					if (cond in emittedHostBool || canFind(acc.data, "bool " ~ cond ~ " ="))
					{
						emittedHostBool[cond] = true;
						foreach (i; before .. grown.length)
							onMountLines ~= "    setVisible!\"" ~ grown[i] ~ "\"(this, " ~ cond ~ ");";
					}
					else
					{
						emittedHostBool[cond] = true;
						emitOwnedVis("  " ~ uda ~ "bool " ~ cond ~ " = " ~ init ~ ";\n",
							"  bool " ~ cond ~ " = " ~ init ~ ";\n");
					}
					if (parentPath.length)
						constructLines ~= "    " ~ parentPath ~ "." ~ cond ~ " = " ~ cond ~ ";";
				}
				r.udas ~= ["visible", "child"];
			}
			if (n.elseKids.length)
			{
				auto elseif = n.elseKids[0].kind == MkNode.Kind.if_;
				auto ebefore = ownerFields(parentStruct).length;
				foreach (ek; n.elseKids)
					if (walkable(ek))
						walk(ek, parentStruct, elseif ? null : "else_" ~ cond, parentPath);
				auto egrown = ownerFields(parentStruct);
				if (!elseif && egrown.length > ebefore)
				{
					string euda;
					auto einst = (init == "true") ? "false" : "true";
					foreach (i; ebefore .. egrown.length)
					{
						auto efname = egrown[i];
						euda ~= "@visible!\"" ~ efname ~ "\" ";
						elseMany[cond] ~= efname;
						if (cond !in elseVisible)
							elseVisible[cond] = efname;
					}
					visSyncElse[cond] = "not_" ~ cond;
					foreach (pn; boolBares)
						visSyncElse[pn] = "not_" ~ cond;
					if (isCmp)
						visSyncElse[cmpLeft] = "not_" ~ cond;
					if (onHost(parentStruct))
						acc ~= "  " ~ euda ~ "bool not_" ~ cond ~ " = " ~ einst ~ ";\n";
					else
					{
						emitChildDecl(parentStruct, "  " ~ euda ~ "bool not_" ~ cond ~ " = " ~ einst ~ ";\n");
						if (parentPath.length)
							constructLines ~= "    " ~ parentPath ~ ".not_" ~ cond ~ " = !" ~ cond ~ ";";
					}
					r.udas ~= ["visible", "child"];
				}
			}
			return;
		}
		if (n.kind == MkNode.Kind.await_)
		{
			// Host JsPromise: pending first. wireAwait uses .await when the
			// ship module is asyncified (fork), else JsPromise.then (G92).
			// No job: already-resolved — show {:then} (G87). Never wrap
			// .await in try/catch — landing pad stays off the import.
			auto jobName = ident(n.text);
			auto settleThen = !hostHasName(jobName) && !hostHasPromise(jobName);
			string pendFlag = "await_pending";
			string thenFlag = "await_then";
			string catchFlag = "await_catch";
			if (!settleThen && awaitWires.length)
			{
				pendFlag ~= "_" ~ jobName;
				thenFlag ~= "_" ~ jobName;
				catchFlag ~= "_" ~ jobName;
			}
			string pendChild, thenChild, catchChild;
			auto before = ownerFields(parentStruct).length;
			foreach (k; n.kids)
				if (walkable(k))
					walk(k, parentStruct, "pend_" ~ ident(n.text), parentPath);
			auto grown = ownerFields(parentStruct);
			if (grown.length > before)
			{
				pendChild = grown[before];
				auto pendOn = n.kids.length && !settleThen;
				auto line = "  @visible!\"" ~ pendChild ~ "\" bool " ~ pendFlag ~ " = "
					~ (pendOn ? "true" : "false") ~ ";\n";
				if (onHost(parentStruct))
					acc ~= line;
				else
					emitChildDecl(parentStruct, line);
				r.udas ~= ["visible", "child"];
			}
			auto t0 = ownerFields(parentStruct).length;
			foreach (k; n.elseKids)
				if (walkable(k))
					walk(k, parentStruct, "then_" ~ ident(n.text), parentPath);
			grown = ownerFields(parentStruct);
			if (grown.length > t0)
			{
				thenChild = grown[t0];
				auto thenOn = settleThen || !n.kids.length;
				auto line = "  @visible!\"" ~ thenChild ~ "\" bool " ~ thenFlag ~ " = "
					~ (thenOn ? "true" : "false") ~ ";\n";
				if (onHost(parentStruct))
					acc ~= line;
				else
					emitChildDecl(parentStruct, line);
				r.udas ~= ["visible", "child"];
			}
			auto c0 = ownerFields(parentStruct).length;
			foreach (k; n.catchKids)
				if (walkable(k))
					walk(k, parentStruct, "catch_" ~ ident(n.text), parentPath);
			grown = ownerFields(parentStruct);
			if (grown.length > c0)
			{
				catchChild = grown[c0];
				auto line = "  @visible!\"" ~ catchChild ~ "\" bool " ~ catchFlag ~ " = false;\n";
				if (onHost(parentStruct))
					acc ~= line;
				else
					emitChildDecl(parentStruct, line);
				r.udas ~= ["visible", "child"];
			}
			if (!settleThen)
			{
				// Do not job.then in onMount: _start unmounts before the
				// child handle is in the JS table. Author settles with
				// this.update.await_then after first paint (G92). App.ready
				// calls wireAwait after render (G93).
				AwaitWire w;
				w.job = jobName;
				w.pend = pendChild;
				w.then = thenChild;
				w.catchChild = catchChild;
				w.catchName = ident(n.catchName);
				w.thenName = ident(n.aliasName);
				w.recv = parentPath.length ? parentPath : "this";
				w.pendFlag = pendFlag;
				w.thenFlag = thenFlag;
				w.catchFlag = catchFlag;
				if (w.thenName.length)
					if (auto ch = w.thenName in mustacheChild)
						w.thenPath = *ch;
				if (w.catchName.length)
					if (auto ch = w.catchName in mustacheChild)
						w.catchPath = *ch;
				awaitWires ~= w;
				if (thenChild.length)
				{
					visibleChild[thenFlag] = thenChild;
					visSyncField[thenFlag] = thenFlag;
					visSyncExpr[thenFlag] = thenFlag;
					if (pendChild.length)
						elseMany[thenFlag] ~= pendChild;
					if (catchChild.length)
						elseMany[thenFlag] ~= catchChild;
					if (parentPath.length)
						visibleOwner[thenFlag] = parentPath;
				}
				if (pendChild.length)
				{
					visibleChild[pendFlag] = pendChild;
					visSyncField[pendFlag] = pendFlag;
					visSyncExpr[pendFlag] = pendFlag;
				}
				if (catchChild.length)
				{
					visibleChild[catchFlag] = catchChild;
					visSyncField[catchFlag] = catchFlag;
					visSyncExpr[catchFlag] = catchFlag;
					if (thenChild.length)
						elseMany[catchFlag] ~= thenChild;
					if (pendChild.length)
						elseMany[catchFlag] ~= pendChild;
				}
			}
			return;
		}
		if (n.kind == MkNode.Kind.each)
		{
			sawList = true;
			sawInject = true;
			emitOrigin("{#each " ~ n.text, "each", ident(n.text.length ? n.text : "items"));
			auto aliasParts = splitCommaIdents(n.aliasName);
			auto coll = ident(n.text.length ? n.text : "items");
			auto item = pascal(aliasParts.length ? aliasParts[0]
					: (n.aliasName.length ? n.aliasName : "item"));
			auto listPath = joinPath(parentPath, coll);
			auto listType = (absorbEachOwnsUl && n.elseKids.length) ? (pascal(coll) ~ "List") : "";
			acc ~= "  import libwasm.array;\n";
			if (listType.length)
				emitChildDecl(parentStruct, "  import libwasm.array;\n  @child " ~ listType ~ " " ~ coll ~ ";\n");
			else
				emitChildDecl(parentStruct, "  import libwasm.array;\n  @child UnorderedList!" ~ item ~ " " ~ coll ~ ";\n");
			// So a wrapping `{#if}` can `@visible` the list (host or parent element).
			addField(parentStruct, coll);
			auto innerIf = eachIfCond(n);
			auto itemField = eachIfItemField(n);
			auto itemNeg = eachIfItemNeg(n);
			auto mix = eachIfMix(n);
			auto icmp = eachIfItemCmp(n);
			if (mix.field.length && mix.host.length)
				itemField = mix.field;
			else if (itemNeg.length)
				itemField = itemNeg;
			else if (icmp.field.length)
				itemField = icmp.field;
			string itemSync;
			if (itemField.length)
			{
				// Per-item `{#if alias.field}` (G95), `{#if !alias.field}` (G99),
				// `{#if [!]alias.field &&/|| host}` (G97–G104),
				// `{#if alias.n > 0}` (G109) / `{#if alias.n > 0 && on}` (G110).
				string rhsHost;
				if (icmp.field.length && icmp.rhs.length && isMustacheIdent(icmp.rhs))
				{
					bool digits = true;
					foreach (c; icmp.rhs)
						if (c < '0' || c > '9')
							digits = false;
					if (!digits)
						rhsHost = icmp.rhs;
				}
				auto syncKey = mix.host.length ? mix.host
					: (icmp.host.length ? icmp.host
					: (rhsHost.length ? rhsHost : itemField));
				itemSync = "sync_" ~ coll ~ "_" ~ syncKey;
				string pred;
				if (mix.host.length)
				{
					auto lhs = mix.neg ? ("!it." ~ itemField) : ("it." ~ itemField);
					auto rhs = mix.hostNeg ? ("!" ~ mix.host) : mix.host;
					pred = lhs ~ " " ~ (mix.op.length ? mix.op : "&&") ~ " " ~ rhs;
				}
				else if (itemNeg.length)
					pred = "!it." ~ itemField;
				else if (icmp.field.length)
				{
					pred = "it." ~ itemField ~ " " ~ icmp.op ~ " " ~ icmp.rhs;
					if (icmp.neg)
						pred = "!(" ~ pred ~ ")";
					if (icmp.host.length)
					{
						auto hr = icmp.hostNeg ? ("!" ~ icmp.host) : icmp.host;
						pred ~= " " ~ (icmp.hostOp.length ? icmp.hostOp : "&&") ~ " " ~ hr;
					}
				}
				else
					pred = "it." ~ itemField;
				auto slist = listPath;
				auto sline = "  void " ~ itemSync ~ "() @trusted\n  {\n";
				sline ~= "    foreach (it; " ~ slist ~ ".items)\n    {\n";
				sline ~= "      if (" ~ pred ~ ")\n      {\n";
				sline ~= "        if (!it.node.mounted)\n";
				sline ~= "          libwasm.dom.render(" ~ slist ~ ".node, *it);\n";
				sline ~= "      }\n";
				sline ~= "      else if (it.node.mounted)\n      {\n";
				sline ~= "        unmount(*it);\n";
				sline ~= "        it.node.mounted = false;\n";
				sline ~= "      }\n    }\n  }\n";
				auto fill = "fill_" ~ coll;
				if (!canFind(dbody, "void " ~ fill))
				{
					sline ~= "  void " ~ fill ~ "() @trusted\n  {\n";
					sline ~= "    foreach (it; " ~ slist ~ ".items)\n";
					if (icmp.field.length)
						sline ~= "      it." ~ itemField ~ " = " ~ icmp.rhs ~ " + 1;\n";
					else
						sline ~= "      it." ~ itemField ~ " = true;\n";
					sline ~= "    " ~ itemSync ~ "();\n  }\n";
				}
				if (onHost(parentStruct))
					acc ~= sline;
				else
					emitChildDecl(parentStruct, sline);
				itemFieldSyncs ~= itemSync;
				if (mix.host.length)
				{
					visDirect[mix.host] ~= coll;
					if (parentPath.length)
						visibleOwner[mix.host] = parentPath;
				}
				else if (icmp.host.length)
				{
					visDirect[icmp.host] ~= coll;
					if (parentPath.length)
						visibleOwner[icmp.host] = parentPath;
					auto hn = icmp.host;
					if (!canFind(acc.data, "bool " ~ hn) && !canFind(dbody, "bool " ~ hn))
					{
						auto init = "true";
						if (auto p = hn in boolInits)
							init = *p;
						acc ~= "  bool " ~ hn ~ " = " ~ init ~ ";\n";
					}
				}
				if (icmp.field.length && icmp.rhs.length && isMustacheIdent(icmp.rhs))
				{
					bool digits = true;
					foreach (c; icmp.rhs)
						if (c < '0' || c > '9')
							digits = false;
					if (!digits)
					{
						visDirect[icmp.rhs] ~= coll;
						if (!hostHasName(icmp.rhs) && !canFind(acc.data, "int " ~ icmp.rhs ~ " "))
							acc ~= "  int " ~ icmp.rhs ~ " = 0;\n";
					}
				}
				r.udas ~= ["visible", "child"];
			}
			else if (innerIf.length)
			{
				// Host `{#if cond}`: keep the ul, hide each li (G94).
				auto sync = "sync_" ~ coll ~ "_" ~ innerIf;
				auto slist = listPath;
				auto sline = "  void " ~ sync ~ "() @trusted\n  {\n";
				sline ~= "    foreach (it; " ~ slist ~ ".items)\n    {\n";
				sline ~= "      if (" ~ innerIf ~ ")\n      {\n";
				sline ~= "        if (!it.node.mounted)\n";
				sline ~= "          libwasm.dom.render(" ~ slist ~ ".node, *it);\n";
				sline ~= "      }\n";
				sline ~= "      else if (it.node.mounted)\n      {\n";
				sline ~= "        unmount(*it);\n";
				sline ~= "        it.node.mounted = false;\n";
				sline ~= "      }\n    }\n  }\n";
				if (onHost(parentStruct))
					acc ~= sline;
				else
					emitChildDecl(parentStruct, sline);
				visDirect[innerIf] ~= coll;
				if (parentPath.length)
					visibleOwner[innerIf] = parentPath;
				r.udas ~= ["visible", "child"];
			}
			acc ~= "  @connect!(\"" ~ listPath ~ ".items\",\"picked\") void on_" ~ coll ~ "_picked(size_t idx, string name)\n";
			acc ~= "  {\n    auto scoped = ScopedPool(m_pool);\n";
			if (canFind(dbody, "pick(") || canFind(dbody, "void pick"))
				acc ~= "    pick(name);\n";
			acc ~= "  }\n";
			listNames ~= coll;
			string[] seeds;
			bool haveArr;
			if (auto a = coll in arraySeeds)
			{
				haveArr = true;
				seeds = *a;
			}
			if (haveArr)
			{
				foreach (si, lab; seeds)
				{
					if (n.indexName.length)
						constructLines ~= "    " ~ listPath ~ ".put(new " ~ item ~ "(\""
							~ lab.replace(`"`, `'`) ~ "\", " ~ to!string(cast(int) si)
							~ ", &this));";
					else
						constructLines ~= "    " ~ listPath ~ ".put(new " ~ item ~ "(\""
							~ lab.replace(`"`, `'`) ~ "\", &this));";
				}
			}
			else if (n.indexName.length)
			{
				constructLines ~= "    " ~ listPath ~ ".put(new " ~ item ~ "(\"one\", 0, &this));";
				constructLines ~= "    " ~ listPath ~ ".put(new " ~ item ~ "(\"two\", 1, &this));";
			}
			else
			{
				constructLines ~= "    " ~ listPath ~ ".put(new " ~ item ~ "(\"one\", &this));";
				constructLines ~= "    " ~ listPath ~ ".put(new " ~ item ~ "(\"two\", &this));";
			}
			if (itemField.length)
			{
				auto listEmptySeed = haveArr && !seeds.length;
				if (!listEmptySeed)
				{
					constructLines ~= "    if (" ~ listPath ~ ".items.length)";
					if (icmp.field.length)
						constructLines ~= "      " ~ listPath ~ ".items[0]." ~ itemField
							~ " = " ~ icmp.rhs ~ " + 1;";
					else
						constructLines ~= "      " ~ listPath ~ ".items[0]." ~ itemField ~ " = true;";
				}
				if (itemSync.length)
					constructLines ~= "    " ~ itemSync ~ "();";
			}
			auto listEmpty = haveArr && !seeds.length;
			MkNode itemEl;
			bool haveEl;
			if (findItemElement(n.kids, itemEl))
				haveEl = true;
			auto itemTag = haveEl && itemEl.tag.length ? itemEl.tag.toLower : "li";
			auto itemMust = "";
			if (haveEl)
				foreach (k; itemEl.kids)
					if (k.kind == MkNode.Kind.text && k.isMustache && isMustacheIdent(k.text))
						itemMust = ident(k.text);
			if (!itemMust.length)
				itemMust = aliasParts.length ? ident(aliasParts[0]) : "label";
			string itemClass;
			string itemOn;
			string itemEv = "click";
			string[] itemClassDirs;
			string[] itemClassFlags;
			string[] itemStatic;
			if (haveEl)
				foreach (a; itemEl.attrs)
				{
					if (a.isOn)
					{
						itemEv = eventName(a.name);
						itemOn = a.value;
					}
					else if (a.name == "class")
						itemClass = a.value;
					else if (a.isClassDir)
					{
						itemClassDirs ~= a.name.length > 6 ? a.name[6 .. $] : a.name;
						itemClassFlags ~= a.value.length ? ident(a.value) : ident(a.name[6 .. $]);
					}
					else if (!a.isBind && !a.isStyleDir && !a.isMustache && a.name.length
							&& a.value.length)
						itemStatic ~= a.name ~ "=" ~ a.value;
				}
			takeStruct(item);
			nested ~= "struct " ~ item ~ "\n{\nnothrow:\n  @trusted:\n";
			foreach (i, cn; itemClassDirs)
			{
				nested ~= "  @style!\"" ~ cn ~ "\" bool " ~ itemClassFlags[i] ~ ";\n";
				classSync[itemClassFlags[i]] ~= listPath;
			}
			foreach (st; itemStatic)
			{
				auto eq = st.indexOf('=');
				if (eq <= 0)
					continue;
				nested ~= "  @attr!\"" ~ st[0 .. eq] ~ "\" string " ~ ident(st[0 .. eq])
					~ "_ = \"" ~ st[eq + 1 .. $].replace(`"`, `'`) ~ "\";\n";
			}
			if (aliasParts.length > 1)
				foreach (ap; aliasParts[1 .. $])
					if (ident(ap).length && ident(ap) != itemMust)
						nested ~= "  string " ~ ident(ap) ~ ";\n";
			if (itemField.length)
			{
				if (icmp.field.length)
					nested ~= "  int " ~ itemField ~ ";\n";
				else
					nested ~= "  bool " ~ itemField ~ ";\n";
			}
			if (n.indexName.length)
				nested ~= "  int " ~ ident(n.indexName) ~ "; // each index\n";
			if (n.keyName.length)
				nested ~= "  @attr!\"data-key\" string data_key_ = \""
					~ n.keyName.replace(`"`, `'`) ~ "\";\n";
			if (itemClass.length)
				foreach (c; itemClass.splitClasses())
					if (c.length)
						nested ~= "  @style!\"" ~ c ~ "\"\n";
			nested ~= "  mixin NodeDef!\"" ~ itemTag ~ "\";\n";
			nested ~= "  @prop!\"textContent\" string " ~ itemMust ~ ";\n";
			nested ~= "  mixin Slot!(\"picked\", string);\n";
			nested ~= "  @inject!\"host\" " ~ hostName ~ "* host;\n";
			if (itemOn.length || canFind(dbody, "pick("))
			{
				nested ~= "  @callback!\"click\" void onClick(MouseEvent ev) @trusted\n  {\n";
				nested ~= "    this.emit(picked, this." ~ itemMust ~ ");\n";
				if (canFind(dbody, "pick(") || canFind(dbody, "void pick"))
					nested ~= "    if (host !is null) host.pick(this." ~ itemMust ~ ");\n";
				nested ~= "  }\n";
			}
			if (n.indexName.length)
			{
				nested ~= "  this(string label_, int i_, " ~ hostName ~ "* host_)\n  {\n";
				nested ~= "    " ~ itemMust ~ " = label_;\n    " ~ ident(n.indexName)
					~ " = i_;\n    host = host_;\n  }\n}\n";
			}
			else
			{
				nested ~= "  this(string label_, " ~ hostName ~ "* host_)\n  {\n";
				nested ~= "    " ~ itemMust ~ " = label_;\n    host = host_;\n  }\n}\n";
			}
			r.udas ~= ["NodeDef", "UnorderedList", "HTMLArray", "ArrayItemEvents",
				"assignEventListeners", "Slot", "callback", "connect", "inject", "prop", "ScopedPool"];
			if (listType.length)
			{
				takeStruct(listType);
				nested ~= "struct " ~ listType ~ "\n{\nnothrow:\n  @trusted:\n";
				nested ~= "  import libwasm.array;\n";
				nested ~= "  @child HTMLArray!" ~ item ~ " items;\n";
				nested ~= "  // svelte-d:kids " ~ listType ~ "\n";
				nested ~= "  void put(" ~ item ~ "* t) @trusted\n  {\n";
				nested ~= "    items.put(t);\n";
				nested ~= "    libwasm.dom.render(node, *items[$ - 1]);\n";
				nested ~= "  }\n";
				nested ~= "  void shrinkTo(size_t size) @trusted\n  {\n";
				nested ~= "    if (size < items.length)\n";
				nested ~= "      foreach (i; items[size .. $])\n";
				nested ~= "        unmount(*i);\n";
				nested ~= "    items.shrinkTo(size);\n";
				nested ~= "  }\n";
				nested ~= "  mixin NodeDef!\"ul\";\n}\n";
			}
			if (n.elseKids.length)
			{
				MkNode einner;
				bool ehave;
				foreach (ek; n.elseKids)
					if (ek.kind == MkNode.Kind.element || ek.kind == MkNode.Kind.if_)
					{
						einner = ek;
						ehave = true;
						break;
					}
				if (ehave)
				{
					auto elseParent = listType.length ? listType : parentStruct;
					auto elsePath = listType.length ? listPath : parentPath;
					auto ebefore = ownerFields(elseParent).length;
					walk(einner, elseParent, "empty_" ~ coll, elsePath);
					auto egrown = ownerFields(elseParent);
					if (egrown.length > ebefore)
					{
						auto efname = egrown[$ - 1];
						auto eflag = coll ~ "_empty";
						auto eline = "  @visible!\"" ~ efname ~ "\" bool " ~ eflag ~ " = "
							~ (listEmpty ? "true" : "false") ~ ";\n";
						if (onHost(elseParent))
							acc ~= eline;
						else
							emitChildDecl(elseParent, eline);
						listEmptyChild[coll] = efname;
						if (listType.length)
							listEmptyRecv[coll] = listPath;
						visibleChild[eflag] = efname;
						visSyncField[eflag] = eflag;
						visSyncExpr[eflag] = eflag;
						if (elsePath.length)
							visibleOwner[eflag] = elsePath;
						r.udas ~= ["visible", "child"];
					}
				}
			}
			return;
		}
		if (n.kind == MkNode.Kind.snippet)
		{
			auto sn = ident(n.text.length ? n.text : "snippet");
			snippetStore[sn] = n;
			return;
		}
		if (n.kind == MkNode.Kind.render)
		{
			auto rn = renderName(n.text);
			if (auto sn = rn in snippetStore)
			{
				foreach (k; (*sn).kids)
					if (walkable(k))
						walk(k, parentStruct, rn);
				auto params = splitCommaIdents((*sn).aliasName);
				auto args = splitCommaIdents(renderInner(n.text));
				foreach (pi, param; params)
				{
					if (pi >= args.length)
						break;
					auto pn = ident(param);
					if (auto ch = pn in mustacheChild)
						constructLines ~= "    " ~ *ch ~ "." ~ pn ~ " = " ~ ident(args[pi]) ~ ";";
				}
			}
			return;
		}
		if (n.kind == MkNode.Kind.key_)
		{
			auto before = ownerFields(parentStruct).length;
			auto kn = ident(n.text.length ? n.text : "key");
			foreach (k; n.kids)
				if (walkable(k))
					walk(k, parentStruct, "key_" ~ kn);
			auto grown = ownerFields(parentStruct);
			if (grown.length > before)
			{
				auto fname = grown[before];
				acc ~= "  void remount_" ~ kn ~ "() @trusted { remount!\"" ~ fname ~ "\"(this); }\n";
				r.udas ~= "visible";
			}
			return;
		}
		if (n.kind == MkNode.Kind.const_)
		{
			string cname, cexpr, ctype;
			splitConst(n.text, cname, cexpr, ctype);
			if (cname.length)
			{
				if (!cexpr.length)
					acc ~= "  " ~ ctype ~ " " ~ cname ~ ";\n";
				else
					acc ~= "  " ~ ctype ~ " " ~ cname ~ " = " ~ cexpr ~ ";\n";
			}
			return;
		}
		if (n.kind == MkNode.Kind.debug_)
		{
			auto msg = n.text.length ? n.text.replace(`"`, `'`) : "debug";
			onMountLines ~= "    console.log(\"" ~ msg ~ "\");";
			return;
		}
		if (n.kind == MkNode.Kind.attach_)
		{
			auto fn = renderName(n.text);
			if (fn.length)
				onMountLines ~= "    " ~ fn ~ "(this.node.handle.handle);";
			return;
		}
		if (n.kind != MkNode.Kind.element)
			return;
		if (n.tag == "style")
			return;
		if (n.tag.length > 7 && n.tag[0 .. 7] == "svelte:")
		{
			auto sk = n.tag[7 .. $];
			if (sk == "fragment")
			{
				foreach (k; n.kids)
					if (walkable(k))
						walk(k, parentStruct, nameHint, parentPath);
				return;
			}
			if (sk == "boundary")
			{
				// Body kids stay mounted; {#snippet failed} is hidden until
				// failBoundary / this.update.boundary_failed (G91+G96).
				// failed(error, reset) + onerror; no D throw (module nothrow).
				string[] bodyKids;
				string onerrorFn;
				foreach (a; n.attrs)
				{
					auto an = a.name;
					if (an == "onerror" || (a.isOn && eventName(an) == "error"))
						onerrorFn = ident(a.value);
				}
				auto before = ownerFields(parentStruct).length;
				foreach (k; n.kids)
				{
					if (k.kind == MkNode.Kind.snippet)
					{
						auto sn = ident(k.text.length ? k.text : "snippet");
						snippetStore[sn] = k;
					}
					else if (walkable(k))
						walk(k, parentStruct, "bound", parentPath);
				}
				auto grown = ownerFields(parentStruct);
				if (grown.length > before)
				{
					string uda;
					foreach (i; before .. grown.length)
					{
						auto fname = grown[i];
						bodyKids ~= fname;
						uda ~= "@visible!\"" ~ fname ~ "\" ";
						visibleMany["boundary_ok"] ~= fname;
						elseMany["boundary_failed"] ~= fname;
					}
					auto line = "  " ~ uda ~ "bool boundary_ok = true;\n";
					if (onHost(parentStruct))
						acc ~= line;
					else
						emitChildDecl(parentStruct, line);
					visibleChild["boundary_ok"] = bodyKids[0];
					visSyncField["boundary_ok"] = "boundary_ok";
					visSyncExpr["boundary_ok"] = "boundary_ok";
					if (parentPath.length)
						visibleOwner["boundary_ok"] = parentPath;
					r.udas ~= ["visible", "child"];
				}
				string failErrParam;
				string failResetParam;
				if (auto sn = "failed" in snippetStore)
				{
					auto ps = splitCommaIdents((*sn).aliasName);
					if (ps.length)
						failErrParam = ident(ps[0]);
					if (ps.length > 1)
						failResetParam = ident(ps[1]);
				}
				auto prevReset = boundaryResetHandler;
				if (failResetParam.length)
					boundaryResetHandler = failResetParam;
				auto t0 = ownerFields(parentStruct).length;
				if (auto sn = "failed" in snippetStore)
					foreach (skid; (*sn).kids)
						if (walkable(skid))
							walk(skid, parentStruct, "failed", parentPath);
				boundaryResetHandler = prevReset;
				grown = ownerFields(parentStruct);
				string[] failKids;
				if (grown.length > t0)
				{
					string uda;
					foreach (i; t0 .. grown.length)
					{
						auto fname = grown[i];
						failKids ~= fname;
						uda ~= "@visible!\"" ~ fname ~ "\" ";
						visibleMany["boundary_failed"] ~= fname;
						elseMany["boundary_ok"] ~= fname;
					}
					auto line = "  " ~ uda ~ "bool boundary_failed = false;\n";
					if (onHost(parentStruct))
						acc ~= line;
					else
						emitChildDecl(parentStruct, line);
					visibleChild["boundary_failed"] = failKids[0];
					visSyncField["boundary_failed"] = "boundary_failed";
					visSyncExpr["boundary_failed"] = "boundary_failed";
					if (parentPath.length)
						visibleOwner["boundary_failed"] = parentPath;
					if (bodyKids.length)
					{
						visSyncElse["boundary_ok"] = "boundary_failed";
						visSyncElse["boundary_failed"] = "boundary_ok";
					}
					r.udas ~= ["visible", "child"];
				}
				if (failKids.length || failErrParam.length || onerrorFn.length)
				{
					string helpers;
					if (!hostHasName("boundary_error")
							&& !canFind(acc.data, "string boundary_error"))
						helpers ~= "  string boundary_error;\n";
					helpers ~= "  void failBoundary(string msg) @trusted\n  {\n";
					helpers ~= "    boundary_error = msg;\n";
					if (failErrParam.length)
					{
						if (auto ch = failErrParam in mustacheChild)
						{
							helpers ~= "    " ~ *ch ~ "." ~ failErrParam ~ " = msg;\n";
							helpers ~= "    " ~ *ch ~ ".update." ~ failErrParam ~ " = msg;\n";
						}
					}
					helpers ~= "    boundary_failed = true;\n    boundary_ok = false;\n";
					foreach (fn; failKids)
						helpers ~= "    setVisible!\"" ~ fn ~ "\"(this, true);\n";
					foreach (fn; bodyKids)
						helpers ~= "    setVisible!\"" ~ fn ~ "\"(this, false);\n";
					if (onerrorFn.length)
						helpers ~= "    " ~ onerrorFn ~ "(msg);\n";
					helpers ~= "  }\n";
					// Same-function throw/catch as navbar EH: exception does
					// not escape, so the printed struct stays nothrow.
					helpers ~= "  void throwBoundary(string msg) @trusted\n  {\n";
					helpers ~= "    try { throw new Exception(msg); }\n";
					helpers ~= "    catch (Exception e) { failBoundary(e.msg); }\n";
					helpers ~= "  }\n";
					helpers ~= "  void resetBoundary() @trusted\n  {\n";
					helpers ~= "    boundary_error = \"\";\n";
					if (failErrParam.length)
					{
						if (auto ch = failErrParam in mustacheChild)
						{
							helpers ~= "    " ~ *ch ~ "." ~ failErrParam ~ " = \"\";\n";
							helpers ~= "    " ~ *ch ~ ".update." ~ failErrParam ~ " = \"\";\n";
						}
					}
					helpers ~= "    boundary_ok = true;\n    boundary_failed = false;\n";
					foreach (fn; bodyKids)
						helpers ~= "    setVisible!\"" ~ fn ~ "\"(this, true);\n";
					foreach (fn; failKids)
						helpers ~= "    setVisible!\"" ~ fn ~ "\"(this, false);\n";
					helpers ~= "  }\n";
					if (onHost(parentStruct))
						acc ~= helpers;
					else
						emitChildDecl(parentStruct, helpers);
				}
				return;
			}
			if (sk == "element")
				n.tag = svelteThisTag(n, "div");
			else if (sk == "component")
			{
				auto ctor = svelteThisIdent(n);
				if (isComponentTag(ctor))
					n.tag = ctor;
				else
					return;
			}
			else if (sk == "self")
			{
				// Recursive instance: @child Host*. compile! skips null and
				// same-type Ts growth (libwasm compile! / registerRoutes).
				acc ~= "  // svelte:self\n";
				acc ~= "  @child " ~ hostName ~ "* selfKid;\n";
				addField(hostName, "selfKid");
				n.tag = "div";
				if (!nameHint.length)
					nameHint = "self";
			}
			else if (sk == "options")
			{
				foreach (a; n.attrs)
				{
					if (!a.name.length)
						continue;
					acc ~= "  // svelte:options " ~ a.name;
					if (a.value.length)
						acc ~= "=" ~ a.value.replace(`"`, `'`);
					acc ~= "\n";
				}
				return;
			}
			else if (sk == "head")
			{
				onMountLines ~= "    auto _svelte_doc = document(); // svelte:head handle 1";
				foreach (k; n.kids)
				{
					if (k.kind == MkNode.Kind.element && k.tag == "title")
					{
						auto t = textOf(k);
						if (t.length)
							onMountLines ~= "    document().title(\"" ~ t.replace(`"`, `'`) ~ "\");";
					}
					else if (walkable(k))
						walk(k, parentStruct);
				}
				return;
			}
			else
			{
				walkSvelteSpecial(n, acc, onMountLines, r, dbody);
				return;
			}
		}
		if (n.tag == "title")
		{
			auto t = textOf(n);
			if (t.length)
				onMountLines ~= "    document().title(\"" ~ t.replace(`"`, `'`) ~ "\");";
			else
				onMountLines ~= "    auto _svelte_doc = document(); // <title> handle 1";
			return;
		}
		if (n.tag == "slot" || n.tag == "Slot")
		{
			auto slotN = "default";
			string[] letNames;
			foreach (a; n.attrs)
			{
				if (a.name == "name" && a.value.length)
					slotN = ident(a.value);
				else if (a.isLet)
					letNames ~= a.name.length > 4 ? a.name[4 .. $] : a.value;
			}
			auto fname = "slot_" ~ ident(slotN);
			auto sname = "Slot" ~ pascal(slotN);
			uniquifyName(parentStruct, fname, sname);
			addField(parentStruct, fname);
			emitChildDecl(parentStruct, "  @child " ~ sname ~ " " ~ fname ~ ";\n");
			acc ~= "  mixin Slot!\"" ~ slotField(slotN) ~ "\";\n";
			takeStruct(sname);
			nested ~= "struct " ~ sname ~ "\n{\nnothrow:\n  @trusted:\n";
			foreach (ln; letNames)
				if (ident(ln).length)
					nested ~= "  string " ~ ident(ln) ~ "; // let:" ~ ident(ln) ~ "\n";
			auto cap = textOf(n);
			if (cap.length)
				nested ~= "  @prop!\"textContent\" string text = \"" ~ cap.replace(`"`, `'`) ~ "\";\n";
			nested ~= "  mixin NodeDef!\"div\";\n}\n";
			r.udas ~= ["Slot", "child", "NodeDef"];
			return;
		}
		if (isComponentTag(n.tag))
		{
			auto sname = n.tag;
			emitOrigin("<" ~ sname, "component", ident(sname));
			auto fname = ident(n.tag);
			if (fname.length && fname[0] >= 'A' && fname[0] <= 'Z')
				fname = cast(string)([cast(char)(fname[0] + 32)] ~ fname[1 .. $]);
			addField(parentStruct, fname);
			emitChildDecl(parentStruct, "  import lib." ~ sname ~ ";\n  @child " ~ sname ~ " " ~ fname ~ ";\n");
			foreach (a; n.attrs)
			{
				if (a.isBind)
				{
					auto bk = a.name.length > 5 ? a.name[5 .. $] : "this";
					auto bv = a.value.length ? a.value : bk;
					if (bk == "this")
						bindThis[ident(bv)] = fname;
					continue;
				}
				if (a.isOn)
				{
					auto ev = eventName(a.name);
					auto h = a.value;
					if (ev.length && h.length)
					{
						acc ~= "  @connect!\"" ~ fname ~ "." ~ ev ~ "\" void on_" ~ fname
							~ "_" ~ ident(ev) ~ "()\n";
						acc ~= "  {\n    auto scoped = ScopedPool(m_pool);\n    " ~ h ~ "();\n  }\n";
						r.udas ~= ["connect", "Slot", "ScopedPool"];
					}
					continue;
				}
				if (a.isClassDir || a.isStyleDir || a.isUse
						|| a.isTransition || a.isAnimate || a.isSpread || a.isLet)
					continue;
				if (a.name == "this" || !a.name.length)
					continue;
				auto pn = ident(a.name);
				if (!pn.length)
					continue;
				if (a.isMustache)
					constructLines ~= "    " ~ fname ~ "." ~ pn ~ " = " ~ ident(a.value) ~ ";";
				else if (a.value.length)
					constructLines ~= "    " ~ fname ~ "." ~ pn ~ " = \"" ~ a.value.replace(`"`, `'`) ~ "\";";
			}
			r.udas ~= ["child", "NodeDef"];
			foreach (k; n.kids)
			{
				if (k.kind == MkNode.Kind.snippet)
				{
					auto sn = ident(k.text.length ? k.text : "children");
					snippetStore[sn] = k;
					foreach (sk; k.kids)
						if (walkable(sk))
							walk(sk, parentStruct, sn);
				}
				else if (walkable(k))
					walk(k, parentStruct, fname);
			}
			return;
		}
		if (n.tag == "ul")
		{
			foreach (k; n.kids)
				if (k.kind == MkNode.Kind.each)
				{
					// UnorderedList is already NodeDef!"ul" — absorb, do not wrap.
					// With {:else}, print a list struct so Empty hangs inside the ul.
					auto prev = absorbEachOwnsUl;
					absorbEachOwnsUl = k.elseKids.length > 0;
					walk(k, parentStruct, nameHint, parentPath);
					absorbEachOwnsUl = prev;
					return;
				}
		}
		string onHandler;
		string ev = "click";
		string[] onMods;
		string[] onEvs;
		string[] onHandlers;
		string[][] onModss;
		string cls;
		string typ;
		string placeholder;
		string bind;
		string bindKind = "value";
		string[] bindKinds;
		string[] bindVals;
		string[] classDirs;
		string[] classDirFlags;
		string[] styleDirs;
		string[] styleDirVals;
		bool[] styleDirImps;
		string dynTag;
		string[] attrMustNames;
		string[] attrMustIdents;
		string[] useNames;
		string[] useArgs;
		string[] motionStyles;
		string[] spreads;
		string[] letNames;
		foreach (a; n.attrs)
		{
			if (a.isOn)
			{
				auto e = eventName(a.name);
				auto h = a.value;
				if (boundaryResetHandler.length && h == boundaryResetHandler)
					h = "resetBoundary";
				auto m = eventMods(a.name);
				if (!onHandler.length)
				{
					ev = e;
					onHandler = h;
					onMods = m;
				}
				onEvs ~= e;
				onHandlers ~= h;
				onModss ~= m;
			}
			else if (a.isUse)
			{
				useNames ~= a.name.length > 4 ? a.name[4 .. $] : a.name;
				useArgs ~= a.value;
			}
			else if (a.isTransition || a.isAnimate)
			{
				auto mn = motionName(a.name);
				if (mn.length)
					motionStyles ~= mn;
			}
			else if (a.isSpread)
			{
				auto sn = ident(a.value.length ? a.value : "props");
				spreads ~= sn;
			}
			else if (a.isLet)
				letNames ~= a.name.length > 4 ? a.name[4 .. $] : a.value;
			else if (a.isClassDir)
			{
				auto cn = a.name.length > 6 ? a.name[6 .. $] : a.name;
				auto fl = a.value.length ? ident(a.value) : ident(cn);
				classDirs ~= cn;
				classDirFlags ~= fl;
			}
			else if (a.isStyleDir)
			{
				auto sn = a.name.length > 6 ? a.name[6 .. $] : a.name;
				bool imp;
				auto bar = indexOf(sn, "|");
				if (bar >= 0)
				{
					imp = canFind(sn[bar + 1 .. $], "important");
					sn = sn[0 .. bar];
				}
				auto sv = a.value.length ? ident(a.value) : ident(sn);
				styleDirs ~= sn;
				styleDirVals ~= sv;
				styleDirImps ~= imp;
			}
			else if (a.name == "this" && a.isMustache && isMustacheIdent(a.value))
				dynTag = ident(a.value);
			else if (a.isBind)
			{
				auto bk = a.name.length > 5 ? a.name[5 .. $] : "value";
				auto bv = a.value.length ? a.value : bk;
				if (!bind.length)
				{
					bind = bv;
					bindKind = bk;
				}
				bindKinds ~= bk;
				bindVals ~= bv;
			}
			else if (a.isMustache && isMustacheIdent(a.value))
			{
				attrMustNames ~= a.name;
				attrMustIdents ~= ident(a.value);
			}
			else if (a.name == "class")
				cls = a.value;
			else if (a.name == "type")
				typ = a.value;
			else if (a.name == "placeholder")
				placeholder = a.value;
		}
		auto cap = textOf(n);
		auto mustache = "";
		foreach (k; n.kids)
			if (k.kind == MkNode.Kind.text && k.isMustache && isMustacheIdent(k.text))
				mustache = k.text;

		auto idx = gSeq++;
		string fname;
		string sname;
		if (onHandler.length)
		{
			fname = ident(onHandler) ~ pascal(n.tag);
			sname = pascal(onHandler) ~ pascal(n.tag);
		}
		else if (bind.length && bindKind == "this")
		{
			fname = ident(bind) ~ pascal(n.tag);
			sname = pascal(bind) ~ pascal(n.tag);
		}
		else if (mustache.length)
		{
			fname = ident(mustache) ~ pascal(n.tag);
			sname = pascal(mustache) ~ pascal(n.tag);
		}
		else if (nameHint.length)
		{
			fname = ident(nameHint) ~ pascal(n.tag);
			sname = pascal(nameHint) ~ pascal(n.tag);
		}
		else
		{
			fname = ident(n.tag) ~ to!string(idx);
			sname = pascal(n.tag) ~ to!string(idx);
		}
		if (fname == "input" || fname == "module" || fname == "version")
			fname = "el_" ~ fname;
		uniquifyName(parentStruct, fname, sname);
		addField(parentStruct, fname);
		emitChildDecl(parentStruct, "  @child " ~ sname ~ " " ~ fname ~ ";\n");
		auto thisPath = joinPath(parentPath, fname);
		foreach (i, un; useNames)
		{
			auto call = ident(un) ~ "(" ~ thisPath ~ ".node.handle.handle";
			if (i < useArgs.length && useArgs[i].length)
				call ~= ", " ~ ident(useArgs[i]);
			call ~= ");";
			onMountLines ~= "    " ~ call;
		}
		foreach (sp; spreads)
		{
			acc ~= "  // spread " ~ sp ~ "\n";
			onMountLines ~= "    " ~ thisPath ~ ".applySpread(" ~ sp ~ ");";
		}
		if (dynTag.length)
		{
			tagChild[dynTag] = thisPath;
			constructLines ~= "    " ~ thisPath ~ ".data_tag = " ~ dynTag ~ ";";
			onMountLines ~= "    " ~ thisPath ~ ".applyTag(" ~ dynTag ~ ");";
		}
		if (onEvs.length)
		{
			foreach (i, e; onEvs)
			{
				auto h = i < onHandlers.length ? onHandlers[i] : onHandler;
				if (!h.length)
					continue;
				acc ~= "  @connect!\"" ~ thisPath ~ "." ~ e ~ "\" void on_" ~ fname ~ "_" ~ ident(e) ~ "()\n";
				acc ~= "  {\n    auto scoped = ScopedPool(m_pool);\n    " ~ h ~ "();\n";
				if (mustache.length)
					acc ~= "    this.update." ~ thisPath ~ ".textContent = " ~ mustache ~ ";\n";
				acc ~= "  }\n";
			}
			r.udas ~= ["connect", "callback", "Slot", "ScopedPool", "inject"];
		}

		takeStruct(sname);
		nested ~= "struct " ~ sname ~ "\n{\nnothrow:\n  @trusted:\n";
		foreach (ln; letNames)
			if (ident(ln).length)
				nested ~= "  string " ~ ident(ln) ~ "; // let:" ~ ident(ln) ~ "\n";
		if (typ.length)
		{
			nested ~= "  @attr!\"type\" string type_ = \"" ~ typ ~ "\";\n";
			r.udas ~= "attr";
		}
		if (placeholder.length)
		{
			nested ~= "  @attr!\"placeholder\" string placeholder = \"" ~ placeholder ~ "\";\n";
			r.udas ~= "attr";
		}
		foreach (a; n.attrs)
		{
			if (a.isOn || a.isBind || a.isClassDir || a.isStyleDir || a.isMustache
					|| a.isUse || a.isTransition || a.isAnimate || a.isSpread || a.isLet)
				continue;
			if (a.name == "class" || a.name == "type" || a.name == "placeholder"
					|| a.name == "this" || a.name == "...")
				continue;
			if (!a.name.length)
				continue;
			if (!a.value.length)
			{
				if (isBoolAttr(a.name))
				{
					nested ~= "  @attr!\"" ~ a.name ~ "\" bool " ~ ident(a.name) ~ "_ = true;\n";
					r.udas ~= "attr";
				}
				continue;
			}
			nested ~= "  @attr!\"" ~ a.name ~ "\" string " ~ ident(a.name) ~ "_ = \""
				~ a.value.replace(`"`, `'`) ~ "\";\n";
			r.udas ~= "attr";
		}
		if (!bindKinds.length && bind.length)
		{
			bindKinds ~= bindKind;
			bindVals ~= bind;
		}
		foreach (bi, bk; bindKinds)
		{
			auto bv = bi < bindVals.length ? bindVals[bi] : bind;
			if (bk == "this")
			{
				bindThis[ident(bv)] = thisPath;
				r.udas ~= "prop";
			}
			else if (bk == "group")
			{
				nested ~= "  @attr!\"name\" string name_ = \"" ~ ident(bv) ~ "\";\n";
				nested ~= "  @prop!\"checked\" bool checked;\n";
				string gval;
				foreach (ga; n.attrs)
					if (ga.name == "value")
						gval = ga.value;
				if (gval.length)
					constructLines ~= "    " ~ thisPath ~ ".checked = (" ~ ident(bv)
						~ " == \"" ~ gval.replace(`"`, `'`) ~ "\");";
				nested ~= "  mixin Slot!\"change\";\n";
				nested ~= "  @callback!\"change\" void onChange(Event ev) @trusted { this.emit(change); }\n";
				acc ~= "  @connect!\"" ~ thisPath ~ ".change\" void on_" ~ fname ~ "_change()\n";
				acc ~= "  {\n    if (" ~ thisPath ~ ".checked) " ~ ident(bv) ~ " = \""
					~ gval.replace(`"`, `'`) ~ "\";\n  }\n";
				r.udas ~= ["attr", "prop", "connect", "callback", "Slot"];
			}
			else if (bk == "files")
			{
				nested ~= "  @prop!\"files\" Handle " ~ ident(bv) ~ ";\n";
				r.udas ~= "prop";
			}
			else if (bk == "checked" || bk == "open" || bk == "indeterminate"
					|| bk == "paused" || bk == "muted")
			{
				nested ~= "  @prop!\"" ~ bk ~ "\" bool " ~ ident(bv) ~ ";\n";
				mustacheChild[ident(bv)] = thisPath;
				if (hostHasName(ident(bv)))
					constructLines ~= "    " ~ thisPath ~ "." ~ ident(bv) ~ " = " ~ ident(bv) ~ ";";
				if (bk == "checked" || bk == "open")
				{
					nested ~= "  mixin Slot!\"change\";\n";
					nested ~= "  @callback!\"change\" void onChange(Event ev) @trusted { this.emit(change); }\n";
					acc ~= "  @connect!\"" ~ thisPath ~ ".change\" void on_" ~ fname ~ "_change()\n";
					acc ~= "  {\n    " ~ ident(bv) ~ " = " ~ thisPath ~ "." ~ ident(bv) ~ ";\n  }\n";
					r.udas ~= ["connect", "callback", "Slot"];
				}
				r.udas ~= "prop";
			}
			else if (bk == "innerHTML" || bk == "innerText" || bk == "textContent")
			{
				nested ~= "  @prop!\"" ~ bk ~ "\" string " ~ ident(bv) ~ ";\n";
				mustacheChild[ident(bv)] = thisPath;
				constructLines ~= "    " ~ thisPath ~ "." ~ ident(bv) ~ " = " ~ ident(bv) ~ ";";
				r.udas ~= "prop";
			}
			else if (bk == "volume" || bk == "playbackRate" || bk == "currentTime"
					|| bk == "duration")
			{
				nested ~= "  @prop!\"" ~ bk ~ "\" double " ~ ident(bv) ~ ";\n";
				mustacheChild[ident(bv)] = thisPath;
				r.udas ~= "prop";
			}
			else if (bk == "clientWidth" || bk == "clientHeight" || bk == "offsetWidth"
					|| bk == "offsetHeight" || bk == "scrollX" || bk == "scrollY"
					|| bk == "innerWidth" || bk == "innerHeight")
			{
				// getter-only layout metrics; @prop would assign and throw
				nested ~= "  int " ~ ident(bv) ~ "; // bind:" ~ bk ~ "\n";
				mustacheChild[ident(bv)] = thisPath;
			}
			else if (bk == "value" && (n.tag == "progress" || n.tag == "meter"
					|| typ == "number"))
			{
				nested ~= "  @prop!\"value\" double " ~ ident(bv) ~ ";\n";
				mustacheChild[ident(bv)] = thisPath;
				r.udas ~= "prop";
			}
			else if (bk == "value")
			{
				nested ~= "  @prop!\"value\" string " ~ ident(bv) ~ ";\n";
				mustacheChild[ident(bv)] = thisPath;
				constructLines ~= "    " ~ thisPath ~ "." ~ ident(bv) ~ " = " ~ ident(bv) ~ ";";
				nested ~= "  mixin Slot!\"input\";\n";
				nested ~= "  @callback!\"input\" void onInput(InputEvent ev) @trusted { this.emit(input); }\n";
				acc ~= "  @connect!\"" ~ thisPath ~ ".input\" void on_" ~ fname ~ "_input()\n";
				acc ~= "  {\n    " ~ ident(bv) ~ " = " ~ thisPath ~ "." ~ ident(bv) ~ ";\n  }\n";
				r.udas ~= ["prop", "connect", "callback", "Slot"];
			}
			else
			{
				nested ~= "  @prop!\"" ~ bk ~ "\" string " ~ ident(bv) ~ ";\n";
				mustacheChild[ident(bv)] = thisPath;
				r.udas ~= "prop";
			}
		}
		foreach (i, cn; classDirs)
		{
			nested ~= "  @style!\"" ~ cn ~ "\" bool " ~ classDirFlags[i] ~ ";\n";
			classSync[classDirFlags[i]] ~= thisPath;
			constructLines ~= "    " ~ thisPath ~ "." ~ classDirFlags[i] ~ " = " ~ classDirFlags[i] ~ ";";
			r.udas ~= "style";
		}
		if (styleDirs.length)
		{
			nested ~= "  @prop!\"style\" string style;\n";
			mustacheChild["style"] = thisPath;
			string concat;
			foreach (i, sn; styleDirs)
			{
				if (concat.length)
					concat ~= " ~ \";\" ~ ";
				concat ~= "\"" ~ sn ~ ":\" ~ " ~ styleDirVals[i];
				if (i < styleDirImps.length && styleDirImps[i])
					concat ~= " ~ \" !important\"";
			}
			onMountLines ~= "    " ~ thisPath ~ ".update.style = " ~ concat ~ ";";
			r.udas ~= "prop";
		}
		if (dynTag.length)
		{
			nested ~= "  @attr!\"data-tag\" string data_tag;\n";
			nested ~= "  void applyTag(string tag) @trusted\n  {\n";
			nested ~= "    if (!tag.length) return;\n";
			nested ~= "    if (data_tag == tag && node.handle.handle != 0) return;\n";
			nested ~= "    data_tag = tag;\n";
			nested ~= "    if (node.handle.handle == 0) return;\n";
			nested ~= "    auto fresh = document().createElement(tag);\n";
			nested ~= "    auto parentOpt = node.parentNode();\n";
			nested ~= "    if (!parentOpt.empty)\n    {\n";
			nested ~= "      while (node.hasChildNodes())\n      {\n";
			nested ~= "        auto kid = node.firstChild();\n";
			nested ~= "        if (kid.empty) break;\n";
			nested ~= "        auto k = kid.front;\n";
			nested ~= "        fresh.appendChild(k);\n";
			nested ~= "      }\n";
			nested ~= "      parentOpt.front.replaceChild(fresh, node);\n";
			nested ~= "    }\n";
			nested ~= "    Handle h = fresh.handle.handle;\n";
			nested ~= "    fresh.handle.handle = 0;\n";
			nested ~= "    node.handle.handle = h;\n";
			nested ~= "    node.setAttribute(\"data-tag\", tag);\n";
			nested ~= "  }\n";
			r.udas ~= "attr";
		}
		if (spreads.length)
		{
			nested ~= "  @attr!\"data-spread\" string data_spread;\n";
			nested ~= "  void applySpread(string bag) @trusted\n  {\n";
			nested ~= "    data_spread = bag;\n";
			nested ~= "    size_t i;\n";
			nested ~= "    while (i < bag.length)\n    {\n";
			nested ~= "      while (i < bag.length && (bag[i] == ' ' || bag[i] == ';')) i++;\n";
			nested ~= "      auto k0 = i;\n";
			nested ~= "      while (i < bag.length && bag[i] != '=' && bag[i] != ' ' && bag[i] != ';') i++;\n";
			nested ~= "      if (i < bag.length && bag[i] == '=' && i > k0)\n      {\n";
			nested ~= "        auto key = bag[k0 .. i];\n";
			nested ~= "        i++;\n";
			nested ~= "        auto v0 = i;\n";
			nested ~= "        while (i < bag.length && bag[i] != ';' && bag[i] != ' ') i++;\n";
			nested ~= "        node.setAttribute(key, bag[v0 .. i]);\n";
			nested ~= "      }\n";
			nested ~= "      else if (i == k0) i++;\n";
			nested ~= "    }\n";
			nested ~= "  }\n";
			nested ~= "  void applySpread(Handle bag) @trusted\n  {\n";
			nested ~= "    if (bag == 0) return;\n";
			nested ~= "    applyObjectSpread(node.handle.handle, bag);\n";
			nested ~= "  }\n";
			r.udas ~= "attr";
		}
		foreach (i, an; attrMustNames)
		{
			auto af = ident(an) ~ "_";
			if (mustache.length && attrMustIdents[i] == ident(mustache))
				nested ~= "  @attr!\"" ~ an ~ "\"\n";
			else if (isBoolAttr(an))
			{
				nested ~= "  @attr!\"" ~ an ~ "\" bool " ~ af ~ ";\n";
				constructLines ~= "    " ~ thisPath ~ "." ~ af ~ " = " ~ attrMustIdents[i] ~ ";";
			}
			else
			{
				// Do not reuse the host ident — bind:value={tone} + id={tone}
				// must not declare two fields named tone on the child.
				nested ~= "  @attr!\"" ~ an ~ "\" string " ~ af ~ ";\n";
				constructLines ~= "    " ~ thisPath ~ "." ~ af ~ " = " ~ attrMustIdents[i] ~ ";";
			}
			r.udas ~= "attr";
		}
		if (onEvs.length)
		{
			foreach (i, e; onEvs)
			{
				auto mods = i < onModss.length ? onModss[i] : onMods;
				bool once;
				foreach (m; mods)
					if (m == "once")
						once = true;
				if (once)
					nested ~= "  bool _once_" ~ ident(e) ~ ";\n";
				nested ~= "  mixin Slot!\"" ~ slotField(e) ~ "\";\n";
				nested ~= "  @callback!\"" ~ e ~ "\" void on" ~ pascal(e) ~ "(" ~ eventType(e) ~ " ev) @trusted\n";
				nested ~= "  {\n";
				if (once)
					nested ~= "    if (_once_" ~ ident(e) ~ ") return;\n    _once_" ~ ident(e) ~ " = true;\n";
				foreach (m; mods)
				{
					if (m == "preventDefault")
						nested ~= "    ev.preventDefault();\n";
					else if (m == "stopPropagation")
						nested ~= "    ev.stopPropagation();\n";
					else if (m == "stopImmediatePropagation")
						nested ~= "    ev.stopImmediatePropagation();\n";
					else if (m == "trusted")
						nested ~= "    if (!ev.isTrusted()) return;\n";
					else if (m == "self")
						nested ~= "    // on:self\n";
					else if (m == "capture" || m == "passive" || m == "nonpassive")
						nested ~= "    // on:" ~ m ~ "\n";
				}
				nested ~= "    this.emit(" ~ e ~ ");\n  }\n";
			}
		}
		if (cap.length && !mustache.length)
		{
			nested ~= "  @prop!\"textContent\" string text = \"" ~ cap.replace(`"`, `'`) ~ "\";\n";
			r.udas ~= "prop";
		}
		if (mustache.length)
		{
			// Named after the Svelte ident. Parent this.update.msg is rewritten
			// to msgSpan.update.msg (golden: heading.update.innerText).
			nested ~= "  @prop!\"textContent\" string " ~ ident(mustache) ~ ";\n";
			mustacheChild[ident(mustache)] = thisPath;
			if (hostHasName(ident(mustache)))
				constructLines ~= "    " ~ thisPath ~ "." ~ ident(mustache) ~ " = " ~ ident(mustache) ~ ";";
			r.udas ~= "prop";
		}
		nested ~= "  // svelte-d:kids " ~ sname ~ "\n";
		if (cls.length)
		{
			foreach (c; cls.splitClasses())
				if (c.length)
					nested ~= "  @style!\"" ~ c ~ "\"\n";
			r.udas ~= "style";
		}
		foreach (ms; motionStyles)
		{
			nested ~= "  @style!\"" ~ ms ~ "\"\n";
			r.udas ~= "style";
		}
		nested ~= "  mixin NodeDef!\"" ~ n.tag.toLower ~ "\";\n}\n";
		r.udas ~= ["NodeDef", "child"];
		foreach (k; n.kids)
			if (walkable(k))
				walk(k, sname, nameHint, thisPath);
	}

	string rootTag = "div";
	string[] rootStyles;
	if (forest.length == 1 && forest[0].kind == MkNode.Kind.element)
	{
		// hoist root tag as this struct's NodeDef; walk children
		auto root = forest[0];
		foreach (a; root.attrs)
			if (a.name == "class")
				foreach (c; a.value.splitClasses())
					if (c.length)
						rootStyles ~= c;
		foreach (k; root.kids)
			walk(k, hostName);
		rootTag = root.tag.toLower;
		r.udas ~= ["NodeDef", "style"];
	}
	else
	{
		foreach (n; forest)
			walk(n, hostName);
		r.udas ~= "NodeDef";
	}

	foreach (name, fname; bindThis)
	{
		if (!canFind(dbody, "Handle " ~ name) && !canFind(acc.data, "Handle " ~ name))
			acc ~= "  Handle " ~ name ~ ";\n";
		onMountLines ~= "    " ~ name ~ " = " ~ fname ~ ".node.handle.handle;";
	}
	if (constructLines.length && !hasConstruct)
	{
		acc ~= "  void construct() @trusted\n  {\n";
		foreach (ln; constructLines)
			acc ~= ln ~ "\n";
		acc ~= "  }\n";
		hasConstruct = true;
	}
	if (onMountLines.length && !hasOnMount)
	{
		acc ~= "  void onMount() @trusted\n  {\n";
		foreach (ln; onMountLines)
			acc ~= ln ~ "\n";
		foreach (ln; onMountTail)
			acc ~= ln ~ "\n";
		acc ~= "  }\n";
		hasOnMount = true;
		onMountTail.length = 0;
	}
	else if (onMountLines.length && hasOnMount)
		dbody = injectOnMount(dbody, onMountLines);
	if (onMountTail.length)
	{
		if (hasOnMount)
			dbody = injectOnMountEnd(dbody, onMountTail);
		else
		{
			acc ~= "  void onMount() @trusted\n  {\n";
			foreach (ln; onMountTail)
				acc ~= ln ~ "\n";
			acc ~= "  }\n";
			hasOnMount = true;
		}
	}
	auto kitPs = kitParamNames(srcRel);
	if (kitPs.length)
	{
		acc ~= "  void applyKitParams() @trusted\n  {\n";
		foreach (pn; kitPs)
		{
			if (pn in mustacheChild)
				acc ~= "    " ~ mustacheChild[pn] ~ ".update." ~ pn ~ " = " ~ pn ~ ";\n";
			foreach (ln; constructLines)
				if (canFind(ln, pn))
					acc ~= ln ~ "\n";
		}
		acc ~= "  }\n";
	}
	foreach (sn; emitSlotNames(dbody))
	{
		if (hasMixinSlot(dbody, sn) || hasMixinSlot(acc.data, sn))
			continue;
		acc ~= "  mixin Slot!\"" ~ slotField(sn) ~ "\";\n";
		r.udas ~= "Slot";
	}
	foreach (cn; rootStyles)
		acc ~= "  @style!\"" ~ cn ~ "\"\n";
	foreach (cn; cssClassNames(cssText))
		acc ~= "  @style!\"" ~ cn ~ "\"\n";
	acc ~= "  mixin NodeDef!\"" ~ rootTag ~ "\";\n";
	if (itemFieldSyncs.length)
	{
		acc ~= "  void wireEach() @trusted\n  {\n";
		foreach (s; itemFieldSyncs)
			acc ~= "    " ~ s ~ "();\n";
		acc ~= "  }\n";
	}
	if (awaitWires.length)
	{
		string bindFill(string path, string name, string helper)
		{
			auto id = ident(name);
			if (!id.length || !path.length)
				return "";
			return "          auto _awb = " ~ helper ~ "();\n"
				~ "          " ~ path ~ "." ~ id ~ " = _awb;\n"
				~ "          " ~ path ~ ".update." ~ id ~ " = _awb;\n";
		}
		string vis(string recv, string child, string flag, string val)
		{
			if (!child.length)
				return "";
			auto tgt = recv == "this" ? "this" : recv;
			auto fld = recv == "this" ? flag : (recv ~ "." ~ flag);
			return "    " ~ fld ~ " = " ~ val ~ ";\n"
				~ "    if (" ~ (recv == "this" ? child : (recv ~ "." ~ child))
				~ ".node.handle.handle > 2 || " ~ val ~ ")\n"
				~ "      setVisible!\"" ~ child ~ "\"(" ~ tgt ~ ", " ~ val ~ ");\n";
		}
		acc ~= "  void wireAwait() @trusted\n  {\n";
		acc ~= "    import await_status;\n";
		foreach (w; awaitWires)
		{
			auto recv = w.recv.length ? w.recv : "this";
			auto thenVis = vis(recv, w.pend, w.pendFlag, "false")
				~ vis(recv, w.then, w.thenFlag, "true")
				~ vis(recv, w.catchChild, w.catchFlag, "false");
			auto catchVis = vis(recv, w.pend, w.pendFlag, "false")
				~ vis(recv, w.then, w.thenFlag, "false")
				~ vis(recv, w.catchChild, w.catchFlag, "true");
			auto catchFill = bindFill(w.catchPath, w.catchName, "libwasmAwaitError");
			auto thenFill = bindFill(w.thenPath, w.thenName, "libwasmAwaitValue");
			acc ~= "    if (" ~ w.job ~ ".handle.handle <= 2)\n    {\n";
			acc ~= "      auto _awr = document().fonts().ready();\n";
			acc ~= "      " ~ w.job ~ ".handle.handle = _awr.handle.handle;\n";
			acc ~= "      _awr.handle.handle = 0;\n    }\n";
			acc ~= "    if (" ~ w.job ~ ".handle.handle > 2)\n    {\n";
			acc ~= "      if (libwasmAwaitSupported())\n      {\n";
			acc ~= "        " ~ w.job ~ ".await;\n";
			acc ~= "        if (libwasmAwaitFailed())\n        {\n";
			acc ~= catchFill;
			acc ~= catchVis;
			acc ~= "        }\n        else\n        {\n";
			acc ~= thenFill;
			acc ~= thenVis;
			acc ~= "        }\n";
			acc ~= "      }\n      else\n      {\n";
			acc ~= "        " ~ w.job ~ ".then(delegate void(Any _v) {\n";
			acc ~= "          libwasmNoteAwaitOk(_v.handle.handle);\n";
			acc ~= thenFill;
			acc ~= thenVis;
			acc ~= "        });\n";
			acc ~= "        " ~ w.job ~ ".error(delegate void(Any _e) {\n";
			acc ~= "          libwasmNoteAwaitFail(_e.handle.handle);\n";
			acc ~= catchFill;
			acc ~= catchVis;
			acc ~= "        });\n";
			acc ~= "      }\n";
			acc ~= "    }\n";
		}
		acc ~= "  }\n";
	}

	// Author methods after fields + NodeDef. this.update.x is rewritten onto
	// the child handle (mustache) or setVisible ( {#if} ).
	dbody = rewriteListClear(dbody, listNames, listEmptyChild, listEmptyRecv);
	dbody = rewriteThisUpdate(dbody, mustacheChild, visibleChild, elseVisible, classSync,
		visibleMany, elseMany, invertMany, andVis, andExpr, tagChild, visibleOwner,
		visSyncField, visSyncExpr, visSyncElse, visDirect, andExprChild, derivedAssigns);
	if (dbody.length)
	{
		acc ~= dbody;
		if (dbody[$ - 1] != '\n')
			acc ~= "\n";
	}
	if (hasOnDestroy && !hasOnUnmount)
		acc ~= "  void onUnmount() { onDestroy(); }\n";

	acc ~= "}\n\n";
	auto nestTxt = nested.data;
	foreach (sname, lines; pendingKids)
	{
		string ins;
		foreach (ln; lines)
			ins ~= ln;
		nestTxt = nestTxt.replace("// svelte-d:kids " ~ sname ~ "\n", ins);
	}
	acc ~= nestTxt;
	acc ~= emitTsThunks(xc);
	acc ~= emitDExportWrappers(xc);

	r.hasList = sawList;
	r.hasInject = true; // m_pool inject on every compiled struct
	enum tmpl = import("d-dom.d.tmpl");
	if (ifConds.length)
		r.detail = "libwasm-dom-if";
	else
		r.detail = sawList ? "libwasm-dom-list" : "libwasm-dom";
	r.generated = tmpl.replace("{{SOURCE}}", srcRel.replace(`\`, `/`))
		.replace("{{MODULE}}", "MODPLACE")
		.replace("{{PARSE}}", r.parseKind.length ? r.parseKind : "scan-fail")
		.replace("{{IMPORTS}}", emitImportBlock(peeled))
		.replace("{{BODY}}", acc.data);
	if (hasKeptPrefix(peeled, "std") && r.detail == "libwasm-dom")
		r.detail = "libwasm-phobos";
	return r;
}

private string[] splitClasses(string s)
{
	string[] o;
	size_t i;
	foreach (j, c; s)
	{
		if (c == ' ' || c == '\t')
		{
			if (j > i)
				o ~= s[i .. j];
			i = j + 1;
		}
	}
	if (i < s.length)
		o ~= s[i .. $];
	return o;
}

private void collectIfConds(MkNode[] ns, ref string[] conds)
{
	foreach (n; ns)
	{
		if (n.kind == MkNode.Kind.if_ && n.text.length)
		{
			auto t = stripOuterParens(n.text.strip);
			if (t.length && t[0] == '!')
				t = t[1 .. $].strip;
			if (cmpIfLeft(t).length)
			{
				// `{#if n > 0}` — not a bool decl
			}
			else
			{
			auto ap = splitAndParts(t);
			auto op = splitOrParts(t);
			if (ap.length >= 2 && op.length < 2)
			{
				foreach (p; ap)
				{
					auto pt = p.strip;
					if (pt.length && pt[0] == '!')
						pt = pt[1 .. $].strip;
					if (pt.length)
						conds ~= pt;
				}
			}
			else if (op.length >= 2 && ap.length < 2)
			{
				foreach (p; op)
				{
					auto pt = p.strip;
					if (pt.length && pt[0] == '!')
						pt = pt[1 .. $].strip;
					if (pt.length)
						conds ~= pt;
				}
			}
			else if (t.length)
				conds ~= t;
			}
		}
		if (n.kids.length)
			collectIfConds(n.kids, conds);
		if (n.elseKids.length)
			collectIfConds(n.elseKids, conds);
		if (n.catchKids.length)
			collectIfConds(n.catchKids, conds);
	}
}

private void collectEachNames(MkNode[] ns, ref string[] names)
{
	foreach (n; ns)
	{
		if (n.kind == MkNode.Kind.each && n.text.length)
		{
			auto nm = ident(n.text);
			if (nm.length && !canFind(names, nm))
				names ~= nm;
		}
		if (n.kids.length)
			collectEachNames(n.kids, names);
		if (n.elseKids.length)
			collectEachNames(n.elseKids, names);
		if (n.catchKids.length)
			collectEachNames(n.catchKids, names);
	}
}

private bool isLiteralInit(string e)
{
	if (!e.length || e == "true" || e == "false" || e == "null")
		return true;
	if (e[0] == '"' || e[0] == '\'')
		return true;
	if (e[0] == '-' || (e[0] >= '0' && e[0] <= '9'))
	{
		foreach (c; e)
			if (!(c >= '0' && c <= '9') && c != '.' && c != '-' && c != '+')
				return false;
		return true;
	}
	return false;
}

/// Struct field inits must be CTFE. Move `string x = other;` into construct().
string peelRuntimeInits(string dbody, ref string[] constructLines)
{
	enum types = ["string", "bool", "int", "long", "size_t", "double", "float"];
	string outp;
	size_t i;
	while (i < dbody.length)
	{
		bool hit;
		foreach (ty; types)
		{
			if (i + ty.length > dbody.length || dbody[i .. i + ty.length] != ty)
				continue;
			if (i > 0 && (isAlphaNum(dbody[i - 1]) || dbody[i - 1] == '_'))
				continue;
			auto j = i + ty.length;
			if (j >= dbody.length || (dbody[j] != ' ' && dbody[j] != '\t'))
				continue;
			while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
				j++;
			string name;
			while (j < dbody.length && (isAlphaNum(dbody[j]) || dbody[j] == '_'))
			{
				name ~= dbody[j];
				j++;
			}
			auto k = j;
			while (k < dbody.length && (dbody[k] == ' ' || dbody[k] == '\t'))
				k++;
			if (!name.length || k >= dbody.length || dbody[k] != '=')
				continue;
			k++;
			auto v0 = k;
			while (k < dbody.length && dbody[k] != ';' && dbody[k] != '\n')
				k++;
			auto expr = dbody[v0 .. k].strip;
			if (!expr.length || isLiteralInit(expr))
				continue;
			outp ~= dbody[i .. j] ~ ";";
			constructLines ~= "    " ~ name ~ " = " ~ expr ~ ";";
			i = (k < dbody.length && dbody[k] == ';') ? k + 1 : k;
			hit = true;
			break;
		}
		if (!hit)
		{
			outp ~= dbody[i];
			i++;
		}
	}
	return outp;
}

/// Pull `bool name = init;` out of the lang=d body so we can re-emit it with @visible.
string takeBoolDecl(string dbody, string name, ref string[string] inits)
{
	import std.string : indexOf;
	auto needle = "bool " ~ name;
	auto i = indexOf(dbody, needle);
	if (i < 0)
		return dbody;
	auto j = i + needle.length;
	while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
		j++;
	string initv = "false";
	if (j < dbody.length && dbody[j] == '=')
	{
		j++;
		auto v0 = j;
		while (j < dbody.length && dbody[j] != ';' && dbody[j] != '\n')
			j++;
		initv = dbody[v0 .. j].strip;
		if (!initv.length)
			initv = "false";
	}
	inits[name] = initv;
	while (j < dbody.length && dbody[j] != ';' && dbody[j] != '\n')
		j++;
	if (j < dbody.length && dbody[j] == ';')
		j++;
	return dbody[0 .. i] ~ dbody[j .. $];
}

/// Pull `string[] name = ["a"];` so UnorderedList can own `name`. Empty `[]` / no
/// init seeds `{#each}{:else}`. Quoted items become `put` labels.
string takeArrayDecl(string dbody, string name, ref string[][string] seeds)
{
	import std.string : indexOf;
	if (!name.length)
		return dbody;
	ptrdiff_t i = dbody.indexOf("string");
	while (i >= 0)
	{
		auto okL = i == 0 || !(isAlphaNum(dbody[i - 1]) || dbody[i - 1] == '_');
		auto j = i + 6;
		while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
			j++;
		if (!okL || j >= dbody.length || dbody[j] != '[')
		{
			i = dbody.indexOf("string", i + 6);
			continue;
		}
		j++;
		while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
			j++;
		if (j >= dbody.length || dbody[j] != ']')
		{
			i = dbody.indexOf("string", i + 6);
			continue;
		}
		j++;
		while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
			j++;
		auto n0 = j;
		while (j < dbody.length && (isAlphaNum(dbody[j]) || dbody[j] == '_'))
			j++;
		if (dbody[n0 .. j] != name)
		{
			i = dbody.indexOf("string", i + 6);
			continue;
		}
		while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
			j++;
		string[] vals;
		if (j < dbody.length && dbody[j] == '=')
		{
			j++;
			while (j < dbody.length && (dbody[j] == ' ' || dbody[j] == '\t'))
				j++;
			if (j < dbody.length && dbody[j] == '[')
			{
				j++;
				while (j < dbody.length && dbody[j] != ']' && dbody[j] != ';' && dbody[j] != '\n')
				{
					if (dbody[j] == '"' || dbody[j] == '\'')
					{
						auto q = dbody[j];
						j++;
						auto v0 = j;
						while (j < dbody.length && dbody[j] != q)
							j++;
						vals ~= dbody[v0 .. j];
						if (j < dbody.length)
							j++;
					}
					else
						j++;
				}
				if (j < dbody.length && dbody[j] == ']')
					j++;
			}
		}
		while (j < dbody.length && dbody[j] != ';' && dbody[j] != '\n')
			j++;
		if (j < dbody.length && dbody[j] == ';')
			j++;
		seeds[name] = vals;
		return dbody[0 .. i] ~ dbody[j .. $];
	}
	return dbody;
}

/// `extras = []` → `extras.shrinkTo(0)` and show `{#each}{:else}` when present.
string rewriteListClear(string dbody, string[] lists, string[string] emptyChild,
	string[string] emptyRecv = null)
{
	import std.array : appender;
	if (!dbody.length || !lists.length)
		return dbody;
	auto outp = appender!string();
	size_t i;
	while (i < dbody.length)
	{
		auto rest = dbody[i .. $];
		ptrdiff_t hit = -1;
		string name;
		foreach (ln; lists)
		{
			auto at = rest.indexOf(ln);
			while (at >= 0)
			{
				auto okL = at == 0 || !(isAlphaNum(rest[at - 1]) || rest[at - 1] == '_');
				auto after = at + ln.length;
				auto okR = after >= rest.length || !(isAlphaNum(rest[after]) || rest[after] == '_');
				if (okL && okR)
				{
					auto k = after;
					while (k < rest.length && (rest[k] == ' ' || rest[k] == '\t'))
						k++;
					if (k < rest.length && rest[k] == '=')
					{
						k++;
						while (k < rest.length && (rest[k] == ' ' || rest[k] == '\t'))
							k++;
						if (k < rest.length && rest[k] == '[')
						{
							k++;
							while (k < rest.length && (rest[k] == ' ' || rest[k] == '\t'))
								k++;
							if (k < rest.length && rest[k] == ']')
							{
								hit = at;
								name = ln;
								break;
							}
						}
					}
				}
				at = rest.indexOf(ln, at + ln.length);
			}
			if (hit >= 0)
				break;
		}
		if (hit < 0)
		{
			outp ~= rest;
			break;
		}
		outp ~= rest[0 .. hit];
		auto k = hit + name.length;
		while (k < rest.length && rest[k] != ']')
			k++;
		if (k < rest.length)
			k++;
		outp ~= name ~ ".shrinkTo(0)";
		if (auto ch = name in emptyChild)
		{
			auto eflag = name ~ "_empty";
			auto recv = "this";
			if (auto rcv = name in emptyRecv)
				if ((*rcv).length)
					recv = *rcv;
			if (recv == "this")
				outp ~= "; " ~ eflag ~ " = true; setVisible!\"" ~ *ch ~ "\"(this, true)";
			else
				outp ~= "; " ~ recv ~ "." ~ eflag ~ " = true; setVisible!\"" ~ *ch
					~ "\"(" ~ recv ~ ", true)";
		}
		i = i + k;
	}
	return outp.data;
}

string takeGenerated(ref DomPrint p, string modName)
{
	return p.generated.replace("MODPLACE", modName);
}

/// Lower `this.update.msg` onto the child NamedNode (golden: `heading.update.innerText`).
/// `{#if ident}` becomes assign + `setVisible!"child"`.
string rewriteThisUpdate(string dbody, string[string] mustacheChild,
	string[string] visibleChild, string[string] elseVisible = null,
	string[][string] classSync = null, string[][string] visibleMany = null,
	string[][string] elseMany = null, string[][string] invertMany = null,
	string[][string] andVis = null, string[string] andExpr = null,
	string[string] tagChild = null, string[string] visibleOwner = null,
	string[string] visSyncField = null, string[string] visSyncExpr = null,
	string[string] visSyncElse = null, string[][string] visDirect = null,
	string[string] andExprChild = null, string[][string] derivedAssigns = null)
{
	import std.array : appender;
	if (!dbody.length)
		return dbody;
	auto outp = appender!string();
	string visRecv(string name)
	{
		if (auto o = name in visibleOwner)
			if ((*o).length)
				return *o;
		return "this";
	}
	string visRhs(string name)
	{
		if (auto e = name in visSyncExpr)
			return *e;
		return name;
	}
	void emitSetVis(string fn, string recv, string pred)
	{
		outp ~= "; setVisible!\"" ~ fn ~ "\"(" ~ recv ~ ", " ~ pred ~ ")";
	}
	void emitVisSync(string name)
	{
		auto recv = visRecv(name);
		auto rhs = visRhs(name);
		if (recv != "this")
		{
			if (auto vf = name in visSyncField)
			{
				auto field = *vf;
				if (field != name)
					outp ~= "; " ~ field ~ " = " ~ rhs;
				outp ~= "; " ~ recv ~ ".update." ~ field ~ " = " ~ (field != name ? field : name);
			}
			else
			{
				if (auto vs = name in visibleMany)
					foreach (fn; *vs)
						emitSetVis(fn, recv, rhs);
				else if (auto vis = name in visibleChild)
					emitSetVis(*vis, recv, rhs);
				else if (auto iv = name in invertMany)
					foreach (fn; *iv)
						emitSetVis(fn, recv, rhs);
				else if (auto av = name in andVis)
					foreach (fn; *av)
						emitSetVis(fn, recv, rhs);
			}
		}
		else
		{
			// Several host {#if}s can share one ident (`on`, `!on`, `on && !hide`).
			// Fire every map; last-write visSyncExpr is not the only pred.
			if (auto vs = name in visibleMany)
				foreach (fn; *vs)
					emitSetVis(fn, recv, name);
			else if (auto vis = name in visibleChild)
				emitSetVis(*vis, recv, name);
			if (auto iv = name in invertMany)
				foreach (fn; *iv)
					emitSetVis(fn, recv, "!(" ~ name ~ ")");
			if (auto av = name in andVis)
			{
				foreach (fn; *av)
				{
					auto pred = rhs;
					if (auto e = fn in andExprChild)
						pred = *e;
					else if (auto e2 = name in andExpr)
						pred = *e2;
					emitSetVis(fn, recv, pred);
				}
			}
			if (auto as = name in derivedAssigns)
				foreach (a; *as)
					outp ~= "; " ~ a;
		}
		if (auto ef = name in visSyncElse)
		{
			if (recv != "this")
				outp ~= "; " ~ recv ~ ".update." ~ *ef ~ " = !(" ~ rhs ~ ")";
			else
			{
				if (auto es = name in elseMany)
					foreach (fn; *es)
						outp ~= "; setVisible!\"" ~ fn ~ "\"(this, !(" ~ rhs ~ "))";
				else if (auto ev = name in elseVisible)
					outp ~= "; setVisible!\"" ~ *ev ~ "\"(this, !(" ~ rhs ~ "))";
				outp ~= "; " ~ *ef ~ " = !(" ~ rhs ~ ")";
			}
		}
		else if (recv == "this")
		{
			if (auto es = name in elseMany)
				foreach (fn; *es)
					outp ~= "; setVisible!\"" ~ fn ~ "\"(this, !(" ~ rhs ~ "))";
			else if (auto ev = name in elseVisible)
				outp ~= "; setVisible!\"" ~ *ev ~ "\"(this, !(" ~ rhs ~ "))";
		}
		if (auto ds = name in visDirect)
		{
			foreach (fn; *ds)
			{
				auto call = "sync_" ~ fn ~ "_" ~ name ~ "()";
				if (recv != "this")
					outp ~= "; " ~ recv ~ "." ~ call;
				else
					outp ~= "; " ~ call;
			}
		}
	}
	size_t i;
	while (i < dbody.length)
	{
		auto rest = dbody[i .. $];
		auto at = rest.indexOf("this.update.");
		if (at < 0)
		{
			outp ~= rest;
			break;
		}
		outp ~= rest[0 .. at];
		auto after = rest[at + "this.update.".length .. $];
		string name;
		size_t n;
		while (n < after.length && (isAlphaNum(after[n]) || after[n] == '_'))
		{
			name ~= after[n];
			n++;
		}
		if (name.length)
		{
			if (auto ch = name in mustacheChild)
			{
				size_t eq = n;
				while (eq < after.length && (after[eq] == ' ' || after[eq] == '\t'))
					eq++;
				if (eq < after.length && after[eq] == '=')
				{
					eq++;
					auto e0 = eq;
					while (eq < after.length && after[eq] != ';' && after[eq] != '\n')
						eq++;
					auto expr = after[e0 .. eq].strip;
					// Keep the host field and the @prop child in lockstep so
					// remount / {#key} / bind: see the same value.
					outp ~= name ~ " = " ~ expr ~ "; " ~ (*ch) ~ ".update." ~ name ~ " = " ~ name;
					emitVisSync(name);
					i = i + at + "this.update.".length + eq;
					continue;
				}
				outp ~= (*ch) ~ ".update." ~ name;
				i = i + at + "this.update.".length + n;
				continue;
			}
			if (name in visSyncField || name in visibleChild || name in invertMany
					|| name in andVis || name in visDirect)
			{
				size_t eq = n;
				while (eq < after.length && (after[eq] == ' ' || after[eq] == '\t'))
					eq++;
				if (eq < after.length && after[eq] == '=')
				{
					eq++;
					auto e0 = eq;
					while (eq < after.length && after[eq] != ';' && after[eq] != '\n')
						eq++;
					auto expr = after[e0 .. eq].strip;
					outp ~= name ~ " = " ~ expr;
					emitVisSync(name);
					if (auto cs = name in classSync)
						foreach (ch; *cs)
							outp ~= "; " ~ ch ~ ".update." ~ name ~ " = " ~ name;
					i = i + at + "this.update.".length + eq;
					continue;
				}
			}
			if (auto cs = name in classSync)
			{
				size_t eq = n;
				while (eq < after.length && (after[eq] == ' ' || after[eq] == '\t'))
					eq++;
				if (eq < after.length && after[eq] == '=')
				{
					eq++;
					auto e0 = eq;
					while (eq < after.length && after[eq] != ';' && after[eq] != '\n')
						eq++;
					auto expr = after[e0 .. eq].strip;
					outp ~= name ~ " = " ~ expr;
					foreach (ch; *cs)
						outp ~= "; " ~ ch ~ ".update." ~ name ~ " = " ~ name;
					i = i + at + "this.update.".length + eq;
					continue;
				}
			}
			if (auto tc = name in tagChild)
			{
				size_t eq = n;
				while (eq < after.length && (after[eq] == ' ' || after[eq] == '\t'))
					eq++;
				if (eq < after.length && after[eq] == '=')
				{
					eq++;
					auto e0 = eq;
					while (eq < after.length && after[eq] != ';' && after[eq] != '\n')
						eq++;
					auto expr = after[e0 .. eq].strip;
					outp ~= name ~ " = " ~ expr;
					outp ~= "; " ~ *tc ~ ".applyTag(" ~ name ~ ")";
					i = i + at + "this.update.".length + eq;
					continue;
				}
			}
		}
		outp ~= rest[at .. at + "this.update.".length];
		i = i + at + "this.update.".length;
	}
	return outp.data;
}

/// Kept for call sites that still want a `@prop!"name"` prefix on scalars.
string promoteUpdateProps(string dbody)
{
	import std.string : indexOf;
	if (!dbody.length)
		return dbody;
	string[] names;
	auto rest = dbody;
	while (true)
	{
		auto i = rest.indexOf("this.update.");
		if (i < 0)
			break;
		auto s = rest[i + "this.update.".length .. $];
		string name;
		foreach (c; s)
		{
			if (isAlphaNum(c) || c == '_')
				name ~= c;
			else
				break;
		}
		rest = s;
		if (!name.length)
			continue;
		bool seen;
		foreach (n; names)
			if (n == name)
				seen = true;
		if (!seen)
			names ~= name;
	}
	enum types = ["string", "bool", "int", "long", "size_t", "double", "float", "Handle"];
	foreach (name; names)
	{
		foreach (ty; types)
		{
			auto pat = ty ~ " " ~ name;
			auto i = dbody.indexOf(pat);
			if (i < 0)
				continue;
			auto pre = i >= 16 ? dbody[i - 16 .. i] : dbody[0 .. i];
			if (canFind(pre, "@prop") || canFind(pre, "@visible") || canFind(pre, "@attr"))
				break;
			dbody = dbody[0 .. i] ~ "@prop " ~ dbody[i .. $];
			break;
		}
	}
	return dbody;
}

/// Insert ScopedPool at the start of heavy author methods (this.update / Lodash / execute!).
/// Do not wrap construct / onMount / onUnmount / onDestroy (Spa hooks).
string wrapHeavyMethods(string dbody)
{
	if (!dbody.length)
		return dbody;
	string outp;
	size_t i;
	while (i < dbody.length)
	{
		auto rest = dbody[i .. $];
		auto v = indexOfVoid(rest);
		if (v < 0)
		{
			outp ~= rest;
			break;
		}
		outp ~= rest[0 .. v];
		auto after = rest[v + 4 .. $]; // skip "void"
		size_t n;
		while (n < after.length && (after[n] == ' ' || after[n] == '\t' || after[n] == '\n'))
			n++;
		string name;
		while (n < after.length && (isAlphaNum(after[n]) || after[n] == '_'))
		{
			name ~= after[n];
			n++;
		}
		auto paren = indexOfFrom(after, "(", n);
		auto brace = paren >= 0 ? indexOfFrom(after, "{", paren) : -1;
		if (brace < 0)
		{
			outp ~= rest[v .. $];
			break;
		}
		auto end = matchBrace(after, brace);
		if (end < 0)
		{
			outp ~= rest[v .. $];
			break;
		}
		auto head = rest[v .. v + 4 + brace + 1];
		auto body = after[brace + 1 .. end];
		auto skip = name == "construct" || name == "onMount" || name == "onUnmount"
			|| name == "onDestroy";
		auto heavy = canFind(body, "this.update") || canFind(body, "execute!")
			|| canFind(body, "Lodash") || canFind(body, ".await");
		if (!skip && heavy && !canFind(body, "ScopedPool"))
			outp ~= head ~ "\n    auto scoped = ScopedPool(m_pool);" ~ body ~ after[end .. end + 1];
		else
			outp ~= rest[v .. v + 4 + end + 1];
		i = i + v + 4 + end + 1;
	}
	return outp;
}

private ptrdiff_t indexOfVoid(string s)
{
	foreach (i; 0 .. s.length)
		if (i + 4 <= s.length && s[i .. i + 4] == "void")
		{
			auto okL = i == 0 || !(isAlphaNum(s[i - 1]) || s[i - 1] == '_');
			auto okR = i + 4 >= s.length || !(isAlphaNum(s[i + 4]) || s[i + 4] == '_');
			if (okL && okR)
				return cast(ptrdiff_t) i;
		}
	return -1;
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
				return cast(ptrdiff_t) i;
		}
	}
	return -1;
}

private ptrdiff_t indexOfFrom(string s, string needle, size_t start = 0)
{
	import std.string : indexOf;
	if (start >= s.length)
		return -1;
	auto i = indexOf(s[start .. $], needle);
	return i < 0 ? -1 : cast(ptrdiff_t)(start + i);
}

private ptrdiff_t matchParen(string s, size_t open)
{
	int depth;
	foreach (i; open .. s.length)
	{
		if (s[i] == '(')
			depth++;
		else if (s[i] == ')')
		{
			depth--;
			if (depth == 0)
				return cast(ptrdiff_t) i;
		}
	}
	return -1;
}

/// Pull `<style>…</style>` out of markup so it is not a NodeDef!"style".
private string stripStyleBlocks(string src, ref string css)
{
	auto outp = appender!string();
	size_t pos;
	auto low = src.toLower;
	while (pos < src.length)
	{
		auto i = indexOf(low, "<style", pos);
		if (i < 0)
		{
			outp ~= src[pos .. $];
			break;
		}
		outp ~= src[pos .. i];
		auto gt = indexOf(src, ">", i);
		if (gt < 0)
		{
			outp ~= src[i .. $];
			break;
		}
		auto end = indexOf(low, "</style>", gt);
		if (end < 0)
		{
			css ~= src[gt + 1 .. $].strip;
			break;
		}
		auto body = src[gt + 1 .. end].strip;
		if (body.length)
			css ~= body ~ "\n";
		pos = end + 8;
	}
	return outp.data;
}

private string escapeDString(string s)
{
	string o;
	foreach (c; s)
	{
		if (c == '\\')
			o ~= `\\`;
		else if (c == '"')
			o ~= `\"`;
		else if (c == '\n')
			o ~= `\n`;
		else if (c == '\r')
			continue;
		else
			o ~= c;
	}
	return o;
}

private string[] cssClassNames(string css)
{
	string[] o;
	size_t i;
	while (i < css.length)
	{
		if (css[i] == '.' && i + 1 < css.length
				&& (isAlphaNum(css[i + 1]) || css[i + 1] == '_' || css[i + 1] == '-'))
		{
			auto j = i + 1;
			while (j < css.length
					&& (isAlphaNum(css[j]) || css[j] == '_' || css[j] == '-'))
				j++;
			auto n = css[i + 1 .. j];
			bool seen;
			foreach (x; o)
				if (x == n)
					seen = true;
			if (!seen && n.length)
				o ~= n;
			i = j;
		}
		else
			i++;
	}
	return o;
}

/// `{@render greet()}` / `greet(name)` → `greet`
private string renderName(string s)
{
	s = s.strip;
	auto p = indexOf(s, "(");
	auto n = p < 0 ? s : s[0 .. p];
	return ident(n);
}

/// `{@render greet(who)}` → `who`
private string renderArg(string s)
{
	auto args = splitCommaIdents(renderInner(s));
	return args.length ? args[0] : "";
}

private string renderInner(string s)
{
	s = s.strip;
	auto p = indexOf(s, "(");
	if (p < 0)
		return "";
	auto q = indexOf(s, ")", p + 1);
	return (q < 0 ? s[p + 1 .. $] : s[p + 1 .. q]).strip;
}

private string[] splitCommaIdents(string s)
{
	string[] o;
	size_t i;
	foreach (j; 0 .. s.length)
	{
		if (s[j] == ',')
		{
			auto p = s[i .. j].strip;
			if (p.length)
				o ~= p;
			i = j + 1;
		}
	}
	auto last = s[i .. $].strip;
	if (last.length)
		o ~= last;
	return o;
}

private string stripOuterParens(string s)
{
	s = s.strip;
	while (s.length >= 2 && s[0] == '(' && s[$ - 1] == ')')
	{
		int d;
		bool wrap = true;
		foreach (i, c; s)
		{
			if (c == '(')
				d++;
			else if (c == ')')
			{
				d--;
				if (d == 0 && i + 1 < s.length)
					wrap = false;
			}
		}
		if (!wrap)
			break;
		s = s[1 .. $ - 1].strip;
	}
	return s;
}

/// `{#if ready && ok}` → `["ready", "ok"]`; bare ident → one part
private string[] splitAndParts(string s)
{
	string[] o;
	size_t i;
	foreach (j; 0 .. s.length)
	{
		if (j + 1 < s.length && s[j] == '&' && s[j + 1] == '&')
		{
			auto p = s[i .. j].strip;
			if (p.length)
				o ~= p;
			i = j + 2;
		}
	}
	auto last = s[i .. $].strip;
	if (last.length)
		o ~= last;
	return o;
}

/// `{#if left || right}` → `["left", "right"]`
private string[] splitOrParts(string s)
{
	string[] o;
	size_t i;
	foreach (j; 0 .. s.length)
	{
		if (j + 1 < s.length && s[j] == '|' && s[j + 1] == '|')
		{
			auto p = s[i .. j].strip;
			if (p.length)
				o ~= p;
			i = j + 2;
		}
	}
	auto last = s[i .. $].strip;
	if (last.length)
		o ~= last;
	return o;
}

/// `transition:fade` / `in:fly` / `animate:flip` → class token
private string motionName(string attr)
{
	auto p = indexOf(attr, ":");
	if (p < 0 || p + 1 >= attr.length)
		return ident(attr);
	return ident(attr[p + 1 .. $]);
}

/// `<svelte:element this="section">` / `this={tag}` → compile-time NodeDef tag
private string svelteThisTag(MkNode n, string fallback)
{
	foreach (a; n.attrs)
	{
		if (a.name != "this")
			continue;
		if (!a.isMustache && a.value.length)
			return a.value.toLower;
	}
	return fallback;
}

/// `<svelte:component this={ClickField}>`
private string svelteThisIdent(MkNode n)
{
	foreach (a; n.attrs)
	{
		if (a.name != "this")
			continue;
		if (a.value.length)
			return a.value.strip;
	}
	return "";
}

/// `{@const doubled = 2}` → name / expr / D type
private void splitConst(string s, ref string name, ref string expr, ref string ty)
{
	s = s.strip;
	auto eq = indexOf(s, "=");
	if (eq < 0)
	{
		name = ident(s);
		expr = "";
		ty = "string";
		return;
	}
	name = ident(s[0 .. eq].strip);
	expr = s[eq + 1 .. $].strip;
	ty = "string";
	if (!expr.length)
		return;
	if (expr == "true" || expr == "false")
		ty = "bool";
	else if (expr[0] >= '0' && expr[0] <= '9' || expr[0] == '-')
		ty = "int";
	else if (expr[0] == '"' || expr[0] == '\'')
		ty = "string";
}

/// `$state(x)` / `$derived(x)` peel to `x`. `$effect(() => { … })` → onMount lines.
string rewriteRunes(string dbody, ref string[] onMountLines)
{
	if (!dbody.length)
		return dbody;
	dbody = extractEffects(dbody, onMountLines);
	dbody = replaceRuneCall(dbody, "$state");
	dbody = replaceRuneCall(dbody, "$derived");
	dbody = replaceRuneCall(dbody, "$props");
	return dbody;
}

private string replaceRuneCall(string s, string name)
{
	auto outp = appender!string();
	size_t i;
	while (i < s.length)
	{
		auto at = indexOfFrom(s, name ~ "(", i);
		if (at < 0)
		{
			outp ~= s[i .. $];
			break;
		}
		if (at > 0 && (isAlphaNum(s[at - 1]) || s[at - 1] == '_'))
		{
			outp ~= s[i .. at + name.length];
			i = at + name.length;
			continue;
		}
		auto open = at + name.length;
		auto close = matchParen(s, open);
		if (close < 0)
		{
			outp ~= s[i .. $];
			break;
		}
		outp ~= s[i .. at];
		if (name != "$props")
			outp ~= s[open + 1 .. close];
		i = close + 1;
	}
	return outp.data;
}

private string extractEffects(string s, ref string[] onMountLines)
{
	auto outp = appender!string();
	size_t i;
	while (i < s.length)
	{
		auto at = indexOfFrom(s, "$effect", i);
		if (at < 0)
		{
			outp ~= s[i .. $];
			break;
		}
		if (at > 0 && (isAlphaNum(s[at - 1]) || s[at - 1] == '_'))
		{
			outp ~= s[i .. at + 7];
			i = at + 7;
			continue;
		}
		auto p = at + 7;
		while (p < s.length && (s[p] == ' ' || s[p] == '\t'))
			p++;
		if (p >= s.length || s[p] != '(')
		{
			outp ~= s[i .. at + 7];
			i = at + 7;
			continue;
		}
		auto close = matchParen(s, p);
		if (close < 0)
		{
			outp ~= s[i .. $];
			break;
		}
		auto inner = s[p + 1 .. close];
		auto body = effectBody(inner);
		if (body.length)
		{
			foreach (ln; splitLinesKeep(body))
			{
				auto t = ln.strip;
				if (t.length)
					onMountLines ~= "    " ~ t;
			}
		}
		auto end = close + 1;
		while (end < s.length && (s[end] == ' ' || s[end] == '\t'))
			end++;
		if (end < s.length && s[end] == ';')
			end++;
		outp ~= s[i .. at];
		i = end;
	}
	return outp.data;
}

private string effectBody(string inner)
{
	auto ar = indexOf(inner, "=>");
	if (ar < 0)
		return inner.strip;
	auto rest = inner[ar + 2 .. $].strip;
	if (rest.length && rest[0] == '{')
	{
		auto end = matchBrace(rest, 0);
		if (end < 0)
			return rest;
		return rest[1 .. end].strip;
	}
	return rest.strip;
}

private string[] splitLinesKeep(string s)
{
	string[] o;
	size_t i;
	foreach (j, c; s)
	{
		if (c == '\n')
		{
			o ~= s[i .. j];
			i = j + 1;
		}
	}
	o ~= s[i .. $];
	return o;
}

string injectOnMount(string dbody, string[] lines)
{
	if (!dbody.length || !lines.length)
		return dbody;
	auto i = indexOf(dbody, "void onMount");
	if (i < 0)
		return dbody;
	auto brace = indexOfFrom(dbody, "{", i);
	if (brace < 0)
		return dbody;
	string ins;
	foreach (ln; lines)
		ins ~= ln ~ "\n";
	return dbody[0 .. brace + 1] ~ "\n" ~ ins ~ dbody[brace + 1 .. $];
}

/// Append lines before the closing `}` of author `onMount` (await `.then` after job assign).
string injectOnMountEnd(string dbody, string[] lines)
{
	if (!dbody.length || !lines.length)
		return dbody;
	auto i = indexOf(dbody, "void onMount");
	if (i < 0)
		return dbody;
	auto brace = indexOfFrom(dbody, "{", i);
	if (brace < 0)
		return dbody;
	auto end = matchBrace(dbody, brace);
	if (end < 0)
		return dbody;
	string ins;
	foreach (ln; lines)
		ins ~= ln ~ "\n";
	return dbody[0 .. end] ~ ins ~ dbody[end .. $];
}

/// `<svelte:window>` / `document` / `body` → handle 1/2 + on: modifiers. Other svelte:* skipped.
private void walkSvelteSpecial(MkNode n, ref Appender!string acc,
	ref string[] onMountLines, ref DomPrint r, string dbody)
{
	auto kind = n.tag.length > 7 ? n.tag[7 .. $] : n.tag;
	if (kind == "window")
		onMountLines ~= "    auto _svelte_window = window();";
	else if (kind == "document")
		onMountLines ~= "    auto _svelte_document = document();";
	else if (kind == "body")
		onMountLines ~= "    auto _svelte_body = document(); // svelte:body — handle 1";
	else if (kind == "head" || kind == "title")
		onMountLines ~= "    auto _svelte_doc = document(); // svelte:" ~ kind ~ " handle 1";
	else
		return; // svelte:options / element / component / self / fragment / boundary
	foreach (a; n.attrs)
	{
		if (!a.isOn)
			continue;
		auto ev = eventName(a.name);
		auto mods = eventMods(a.name);
		auto h = a.value.length ? a.value : ("on_" ~ ev);
		acc ~= "  void on_svelte_" ~ ident(kind) ~ "_" ~ ident(ev) ~ "(" ~ eventType(ev)
			~ " ev) @trusted\n  {\n";
		foreach (m; mods)
		{
			if (m == "preventDefault")
				acc ~= "    ev.preventDefault();\n";
			else if (m == "stopPropagation")
				acc ~= "    ev.stopPropagation();\n";
			else if (m == "stopImmediatePropagation")
				acc ~= "    ev.stopImmediatePropagation();\n";
		}
		if (h.length && (canFind(dbody, "void " ~ h) || canFind(dbody, h ~ "(") || h.length))
			acc ~= "    " ~ h ~ "();\n";
		acc ~= "  }\n";
		r.udas ~= ["callback"];
	}
	foreach (a; n.attrs)
	{
		if (!a.isBind)
			continue;
		auto bk = a.name.length > 5 ? a.name[5 .. $] : "value";
		auto bv = a.value.length ? a.value : bk;
		if (kind == "window" && (bk == "scrollY" || bk == "scrollX"))
			onMountLines ~= "    " ~ ident(bv) ~ " = window()." ~ bk ~ "();";
		else
			onMountLines ~= "    // svelte:" ~ kind ~ " bind:" ~ bk;
	}
}
