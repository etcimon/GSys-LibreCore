// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lightweight Svelte markup scan → element / each / text tree.
// Not svelte/compiler. Enough for NodeDef / @callback / UnorderedList print.
module svelte_d.parse.markup;

import std.algorithm : canFind;
import std.array : appender, join;
import std.string : strip, toLower, indexOf;
import std.uni : isAlphaNum;

struct MkAttr
{
	string name;
	string value;
	bool isOn; /// on:click
	bool isBind; /// bind:value
	bool isClassDir; /// class:x
	bool isStyleDir; /// style:color
	bool isMustache; /// value from {expr}
	bool isUse; /// use:action
	bool isTransition; /// transition: / in: / out:
	bool isAnimate; /// animate:
	bool isSpread; /// {...props}
	bool isLet; /// let:x
}

struct MkNode
{
	enum Kind
	{
		element,
		text,
		each,
		if_,
		await_,
		snippet,
		render,
		key_,
		const_,
		debug_,
		attach_
	}

	Kind kind;
	string tag;
	string text; /// text content, or each collection expr
	string aliasName; /// each item alias, or await then-binding
	string catchName; /// `{#await}` `{:catch e}`
	string indexName; /// `{#each xs as x, i}`
	string keyName; /// `{#each xs as x (key)}`
	bool isMustache; /// text came from {ident}, not raw "Go"
	bool isHtml; /// `{@html expr}` → innerHTML
	MkAttr[] attrs;
	MkNode[] kids;
	MkNode[] elseKids; /// `{#if}`/`{#each}` `{:else}`, or await `{:then}`
	MkNode[] catchKids; /// `{#await}` `{:catch}`
}

/// PascalCase tag → official `Component` (not RegularElement).
bool isComponentTag(string tag)
{
	return tag.length && tag[0] >= 'A' && tag[0] <= 'Z';
}

private bool eachElseDropped(string src, MkNode[] ns)
{
	if (!canFind(src, "{#each") || !canFind(src, "{:else}"))
		return false;
	return !anyEachElse(ns);
}

private bool anyEachElse(MkNode[] ns)
{
	foreach (n; ns)
	{
		if (n.kind == MkNode.Kind.each && n.elseKids.length)
			return true;
		if (anyEachElse(n.kids) || anyEachElse(n.elseKids))
			return true;
	}
	return false;
}

bool markupIsInteractive(string markup)
{
	auto s = markup.toLower;
	return canFind(s, "on:") || canFind(s, "{#each") || canFind(s, "{#if")
		|| canFind(s, "bind:") || canFind(s, "class:") || canFind(s, "style:")
		|| canFind(s, "{@html") || canFind(s, "{#await") || canFind(s, "{#snippet")
		|| canFind(s, "{@render") || canFind(s, "{#key") || canFind(s, "{@const")
		|| canFind(s, "{@debug") || canFind(s, "{@attach") || canFind(s, "<svelte:")
		|| canFind(s, "use:") || canFind(s, "transition:") || canFind(s, "animate:")
		|| canFind(s, "{...") || canFind(s, "{let") || canFind(s, "<button")
		|| canFind(s, "<input") || canFind(s, "<ul") || canFind(s, "<slot")
		|| hasExprMustache(s);
}

/// `{title}` / `{status}` — official ExpressionTag, not `{#` / `{@`.
private bool hasExprMustache(string s)
{
	foreach (i, c; s)
	{
		if (c != '{' || i + 1 >= s.length)
			continue;
		auto n = s[i + 1];
		if (n != '#' && n != '@' && n != '/' && n != ':' && n != '?')
			return true;
	}
	return false;
}

/// How markup became MkNode. Pegged first; scan only when MarkupDoc is thin
/// or a construct the walker does not lower yet.
struct MarkupParse
{
	MkNode[] nodes;
	string kind; /// pegged | scan-thin | scan-else | scan-construct | scan-fail
	string reason;
}

MkNode[] parseMarkup(string src)
{
	return parseMarkupEx(src).nodes;
}

MarkupParse parseMarkupEx(string src)
{
	MarkupParse r;
	try
	{
		import svelte_d.grammar.sveltekit : SvelteKit;
		auto t = SvelteKit.MarkupDoc(src);
		if (t.successful)
		{
			auto lowered = lowerMarkup(t);
			auto thin = lowered.length == 1 && lowered[0].kind == MkNode.Kind.element
				&& !lowered[0].kids.length && canFind(src, "</");
			string why;
			if (!lowered.length)
				why = "empty";
			else if (thin)
				why = "thin";
			else if (eachElseDropped(src, lowered))
				why = "each-else";
			else if (canFind(src, "{:else"))
				why = "else";
			else if (canFind(src, "{#await"))
				why = "await";
			else if (canFind(src, "{#snippet"))
				why = "snippet";
			else if (canFind(src, "{@render"))
				why = "render";
			else if (canFind(src, "{#key"))
				why = "key";
			else if (canFind(src, "{@const"))
				why = "const";
			else if (canFind(src, "{@debug"))
				why = "debug";
			else if (canFind(src, "{@attach"))
				why = "attach";
			else if (canFind(src, "<svelte:"))
				why = "svelte";
			else if (canFind(src, "use:"))
				why = "use";
			else if (canFind(src, "transition:"))
				why = "transition";
			else if (canFind(src, "animate:"))
				why = "animate";
			else if (canFind(src, "{..."))
				why = "spread";
			else if (canFind(src, "{let") || canFind(src, "{const"))
				why = "let";
			if (!why.length)
			{
				r.nodes = lowered;
				r.kind = "pegged";
				r.reason = "MarkupDoc";
				return r;
			}
			if (why == "thin" || why == "empty")
				r.kind = "scan-thin";
			else if (why == "else" || why == "each-else")
				r.kind = "scan-else";
			else
				r.kind = "scan-construct";
			r.reason = why;
		}
		else
		{
			r.kind = "scan-fail";
			r.reason = "MarkupDoc unsuccessful";
		}
	}
	catch (Exception e)
	{
		r.kind = "scan-fail";
		r.reason = e.msg.length ? e.msg : "MarkupDoc exception";
	}
	size_t pos;
	r.nodes = parseSeq(src, pos, null);
	return r;
}

private MkNode[] parseSeq(string src, ref size_t pos, string stop)
{
	auto acc = appender!(MkNode[]);
	while (pos < src.length)
	{
		if (stop.length && startsAt(src, pos, stop))
			break;
		if (startsAt(src, pos, "{/"))
			break;
		if (startsAt(src, pos, "{:"))
			break;
		if (startsAt(src, pos, "<!--"))
		{
			auto e = indexOf(src, "-->", pos);
			pos = e < 0 ? src.length : e + 3;
			continue;
		}
		if (startsAt(src, pos, "{#each"))
		{
			acc ~= parseEach(src, pos);
			continue;
		}
		if (startsAt(src, pos, "{#if"))
		{
			acc ~= parseIf(src, pos);
			continue;
		}
		if (startsAt(src, pos, "{#await"))
		{
			acc ~= parseAwait(src, pos);
			continue;
		}
		if (startsAt(src, pos, "{#snippet"))
		{
			acc ~= parseSnippet(src, pos);
			continue;
		}
		if (startsAt(src, pos, "{#key"))
		{
			acc ~= parseKey(src, pos);
			continue;
		}
		if (src[pos] == '<')
		{
			acc ~= parseElement(src, pos);
			continue;
		}
		if (src[pos] == '{')
		{
			MkNode n;
			n.kind = MkNode.Kind.text;
			n.isMustache = true;
			if (startsAt(src, pos, "{@html"))
			{
				pos += 6; // `{@html`
				while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
					pos++;
				auto e0 = pos;
				n.isHtml = true;
				while (pos < src.length && src[pos] != '}')
					pos++;
				n.text = src[e0 .. pos].strip;
				if (pos < src.length)
					pos++;
			}
			else if (startsAt(src, pos, "{@render"))
			{
				n.kind = MkNode.Kind.render;
				pos += 8;
				while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
					pos++;
				auto e0 = pos;
				while (pos < src.length && src[pos] != '}')
					pos++;
				n.text = src[e0 .. pos].strip;
				if (pos < src.length)
					pos++;
			}
			else if (startsAt(src, pos, "{@const"))
			{
				n.kind = MkNode.Kind.const_;
				pos += 7;
				while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
					pos++;
				auto e0 = pos;
				while (pos < src.length && src[pos] != '}')
					pos++;
				n.text = src[e0 .. pos].strip;
				if (pos < src.length)
					pos++;
			}
			else if (startsAt(src, pos, "{@debug"))
			{
				n.kind = MkNode.Kind.debug_;
				pos += 7;
				while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
					pos++;
				auto e0 = pos;
				while (pos < src.length && src[pos] != '}')
					pos++;
				n.text = src[e0 .. pos].strip;
				if (pos < src.length)
					pos++;
			}
			else if (startsAt(src, pos, "{@attach"))
			{
				n.kind = MkNode.Kind.attach_;
				pos += 8;
				while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
					pos++;
				auto e0 = pos;
				while (pos < src.length && src[pos] != '}')
					pos++;
				n.text = src[e0 .. pos].strip;
				if (pos < src.length)
					pos++;
			}
			else if (startsAt(src, pos, "{let") || startsAt(src, pos, "{const"))
			{
				n.kind = MkNode.Kind.const_;
				if (startsAt(src, pos, "{let"))
					pos += 4;
				else
					pos += 6;
				while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
					pos++;
				auto e0 = pos;
				while (pos < src.length && src[pos] != '}')
					pos++;
				n.text = src[e0 .. pos].strip;
				if (pos < src.length)
					pos++;
			}
			else
				n.text = readMustache(src, pos);
			acc ~= n;
			continue;
		}
		auto start = pos;
		while (pos < src.length && src[pos] != '<' && src[pos] != '{')
			pos++;
		auto t = src[start .. pos].strip;
		if (t.length)
		{
			MkNode n;
			n.kind = MkNode.Kind.text;
			n.text = t;
			acc ~= n;
		}
	}
	return acc.data;
}

private MkNode parseEach(string src, ref size_t pos)
{
	pos += 6; // {#each
	while (pos < src.length && src[pos] == ' ')
		pos++;
	auto expr0 = pos;
	while (pos < src.length && src[pos] != ' ' && src[pos] != '}')
		pos++;
	auto expr = src[expr0 .. pos].strip;
	while (pos < src.length && src[pos] == ' ')
		pos++;
	if (startsAt(src, pos, "as"))
		pos += 2;
	while (pos < src.length && src[pos] == ' ')
		pos++;
	string alias_;
	if (pos < src.length && src[pos] == '{')
	{
		pos++;
		while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
			pos++;
		auto al0 = pos;
		while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
			pos++;
		alias_ = src[al0 .. pos];
		while (pos < src.length && src[pos] != '}')
			pos++;
		if (pos < src.length)
			pos++;
	}
	else if (pos < src.length && src[pos] == '[')
	{
		pos++;
		auto a0 = pos;
		while (pos < src.length && src[pos] != ']')
			pos++;
		alias_ = src[a0 .. pos].strip;
		if (pos < src.length)
			pos++;
	}
	else
	{
		auto al0 = pos;
		while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
			pos++;
		alias_ = src[al0 .. pos];
	}
	string idxName;
	while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
		pos++;
	if (pos < src.length && src[pos] == ',')
	{
		pos++;
		while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
			pos++;
		auto i0 = pos;
		while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
			pos++;
		idxName = src[i0 .. pos];
	}
	string keyExpr;
	while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
		pos++;
	if (pos < src.length && src[pos] == '(')
	{
		pos++;
		auto k0 = pos;
		int depth = 1;
		while (pos < src.length && depth)
		{
			if (src[pos] == '(')
				depth++;
			else if (src[pos] == ')')
			{
				depth--;
				if (depth == 0)
					break;
			}
			if (depth)
				pos++;
		}
		keyExpr = src[k0 .. pos].strip;
		if (pos < src.length && src[pos] == ')')
			pos++;
	}
	while (pos < src.length && src[pos] != '}')
		pos++;
	if (pos < src.length)
		pos++;
	MkNode n;
	n.kind = MkNode.Kind.each;
	n.text = expr;
	n.aliasName = alias_;
	n.indexName = idxName;
	n.keyName = keyExpr;
	n.kids = parseSeq(src, pos, "{/each}");
	if (startsAt(src, pos, "{:else}"))
	{
		pos += 7;
		n.elseKids = parseSeq(src, pos, "{/each}");
	}
	if (startsAt(src, pos, "{/each}"))
		pos += 7;
	return n;
}

private MkNode parseIf(string src, ref size_t pos)
{
	pos += 4; // {#if
	while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
		pos++;
	auto e0 = pos;
	while (pos < src.length && src[pos] != '}')
		pos++;
	auto cond = src[e0 .. pos].strip;
	if (pos < src.length)
		pos++;
	MkNode n;
	n.kind = MkNode.Kind.if_;
	n.text = cond;
	n.kids = parseSeq(src, pos, "{/if}");
	parseIfAlternate(src, pos, n);
	if (startsAt(src, pos, "{/if}"))
		pos += 5;
	return n;
}

/// `{:else if cond}` becomes a nested `if_` in `elseKids`; `{:else}` is the rest.
private void parseIfAlternate(string src, ref size_t pos, ref MkNode n)
{
	if (startsAt(src, pos, "{:else if"))
	{
		pos += 9; // {:else if
		while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
			pos++;
		auto e0 = pos;
		while (pos < src.length && src[pos] != '}')
			pos++;
		auto cond = src[e0 .. pos].strip;
		if (pos < src.length)
			pos++;
		MkNode inner;
		inner.kind = MkNode.Kind.if_;
		inner.text = cond;
		inner.kids = parseSeq(src, pos, "{/if}");
		parseIfAlternate(src, pos, inner);
		n.elseKids ~= inner;
		return;
	}
	if (startsAt(src, pos, "{:else}"))
	{
		pos += 7;
		n.elseKids = parseSeq(src, pos, "{/if}");
	}
}

private MkNode parseAwait(string src, ref size_t pos)
{
	pos += 7; // {#await
	while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
		pos++;
	auto h0 = pos;
	while (pos < src.length && src[pos] != '}')
		pos++;
	auto header = src[h0 .. pos].strip;
	if (pos < src.length)
		pos++;
	MkNode n;
	n.kind = MkNode.Kind.await_;
	auto th = indexOf(header, " then ");
	if (th >= 0)
	{
		n.text = header[0 .. th].strip;
		n.aliasName = header[th + 6 .. $].strip;
		n.elseKids = parseSeq(src, pos, "{/await}");
		if (startsAt(src, pos, "{:catch"))
		{
			pos += 7;
			while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
				pos++;
			auto c0 = pos;
			while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
				pos++;
			n.catchName = src[c0 .. pos];
			while (pos < src.length && src[pos] != '}')
				pos++;
			if (pos < src.length)
				pos++;
			n.catchKids = parseSeq(src, pos, "{/await}");
		}
	}
	else
	{
		n.text = header;
		n.kids = parseSeq(src, pos, "{/await}");
		if (startsAt(src, pos, "{:then"))
		{
			pos += 6;
			while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
				pos++;
			auto a0 = pos;
			while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
				pos++;
			n.aliasName = src[a0 .. pos];
			while (pos < src.length && src[pos] != '}')
				pos++;
			if (pos < src.length)
				pos++;
			n.elseKids = parseSeq(src, pos, "{/await}");
		}
		if (startsAt(src, pos, "{:catch"))
		{
			pos += 7;
			while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
				pos++;
			auto c0 = pos;
			while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
				pos++;
			n.catchName = src[c0 .. pos];
			while (pos < src.length && src[pos] != '}')
				pos++;
			if (pos < src.length)
				pos++;
			n.catchKids = parseSeq(src, pos, "{/await}");
		}
	}
	if (startsAt(src, pos, "{/await}"))
		pos += 8;
	return n;
}

private MkNode parseSnippet(string src, ref size_t pos)
{
	pos += 9; // {#snippet
	while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
		pos++;
	auto n0 = pos;
	while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '_'))
		pos++;
	MkNode n;
	n.kind = MkNode.Kind.snippet;
	n.text = src[n0 .. pos];
	if (pos < src.length && src[pos] == '(')
	{
		auto a0 = pos + 1;
		while (pos < src.length && src[pos] != ')')
			pos++;
		n.aliasName = src[a0 .. pos].strip;
		if (pos < src.length)
			pos++;
	}
	while (pos < src.length && src[pos] != '}')
		pos++;
	if (pos < src.length)
		pos++;
	n.kids = parseSeq(src, pos, "{/snippet}");
	if (startsAt(src, pos, "{/snippet}"))
		pos += 10;
	return n;
}

private MkNode parseKey(string src, ref size_t pos)
{
	pos += 5; // {#key
	while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t'))
		pos++;
	auto e0 = pos;
	while (pos < src.length && src[pos] != '}')
		pos++;
	MkNode n;
	n.kind = MkNode.Kind.key_;
	n.text = src[e0 .. pos].strip;
	if (pos < src.length)
		pos++;
	n.kids = parseSeq(src, pos, "{/key}");
	if (startsAt(src, pos, "{/key}"))
		pos += 6;
	return n;
}

private MkNode parseElement(string src, ref size_t pos)
{
	pos++; // <
	if (pos < src.length && src[pos] == '/')
	{
		while (pos < src.length && src[pos] != '>')
			pos++;
		if (pos < src.length)
			pos++;
		MkNode empty;
		empty.kind = MkNode.Kind.text;
		return empty;
	}
	auto t0 = pos;
	while (pos < src.length && (isAlphaNum(src[pos]) || src[pos] == '-' || src[pos] == ':'))
		pos++;
	MkNode n;
	n.kind = MkNode.Kind.element;
	n.tag = src[t0 .. pos];
	n.attrs = parseAttrs(src, pos);
	bool self;
	while (pos < src.length && src[pos] != '>')
	{
		if (src[pos] == '/')
			self = true;
		pos++;
	}
	if (pos < src.length)
		pos++;
	if (self || isVoid(n.tag))
		return n;
	auto close = "</" ~ n.tag ~ ">";
	n.kids = parseSeq(src, pos, close);
	if (startsAt(src, pos, close))
		pos += close.length;
	return n;
}

private MkAttr[] parseAttrs(string src, ref size_t pos)
{
	auto acc = appender!(MkAttr[]);
	while (pos < src.length)
	{
		while (pos < src.length && (src[pos] == ' ' || src[pos] == '\n' || src[pos] == '\t'
				|| src[pos] == '\r'))
			pos++;
		if (pos >= src.length || src[pos] == '>' || src[pos] == '/')
			break;
		if (src[pos] == '{')
		{
			MkAttr spread;
			spread.isMustache = true;
			auto v = readMustache(src, pos);
			if (v.length >= 3 && v[0 .. 3] == "...")
			{
				spread.isSpread = true;
				spread.name = "...";
				spread.value = v[3 .. $].strip;
			}
			else
			{
				spread.name = "";
				spread.value = v;
			}
			acc ~= spread;
			continue;
		}
		auto n0 = pos;
		while (pos < src.length && src[pos] != '=' && src[pos] != ' ' && src[pos] != '>'
			&& src[pos] != '/')
			pos++;
		MkAttr a;
		a.name = src[n0 .. pos];
		classifyAttr(a);
		if (pos < src.length && src[pos] == '=')
		{
			pos++;
			if (pos < src.length && src[pos] == '{')
			{
				a.isMustache = true;
				a.value = readMustache(src, pos);
			}
			else if (pos < src.length && (src[pos] == '"' || src[pos] == '\''))
			{
				auto q = src[pos++];
				auto v0 = pos;
				while (pos < src.length && src[pos] != q)
					pos++;
				a.value = src[v0 .. pos];
				if (pos < src.length)
					pos++;
			}
		}
		if (a.name.length)
			acc ~= a;
	}
	return acc.data;
}

private string readMustache(string src, ref size_t pos)
{
	if (pos >= src.length || src[pos] != '{')
		return "";
	pos++;
	auto s0 = pos;
	int depth = 1;
	while (pos < src.length && depth)
	{
		if (src[pos] == '{')
			depth++;
		else if (src[pos] == '}')
			depth--;
		if (depth)
			pos++;
	}
	auto v = src[s0 .. pos];
	if (pos < src.length && src[pos] == '}')
		pos++;
	return v.strip;
}

private bool startsAt(string src, size_t pos, string p)
{
	if (pos + p.length > src.length)
		return false;
	return src[pos .. pos + p.length] == p;
}

private bool isVoid(string tag)
{
	auto t = tag.toLower;
	return t == "br" || t == "hr" || t == "img" || t == "input" || t == "meta"
		|| t == "link" || t == "area" || t == "col" || t == "source" || t == "wbr"
		|| t == "track" || t == "embed" || t == "param";
}

private MkNode[] lowerMarkup(T)(auto ref T t)
{
	MkNode[] acc;
	void collect(TT)(auto ref TT n)
	{
		if (isNamed(n, "SvelteKit.Attr") || isNamed(n, "SvelteKit.AttrName")
				|| isNamed(n, "SvelteKit.AttrValue") || isNamed(n, "SvelteKit.Quoted")
				|| isNamed(n, "SvelteKit.TagName") || isNamed(n, "SvelteKit.VoidName")
				|| isNamed(n, "SvelteKit.IfCond") || isNamed(n, "SvelteKit.EachList"))
			return;
		if (isNamed(n, "SvelteKit.MarkupNode") || isNamed(n, "SvelteKit.IfBlock")
				|| isNamed(n, "SvelteKit.EachBlock") || isNamed(n, "SvelteKit.Element")
				|| isNamed(n, "SvelteKit.OpenElement") || isNamed(n, "SvelteKit.VoidElement")
				|| isNamed(n, "SvelteKit.Mustache") || isNamed(n, "SvelteKit.Text"))
		{
			acc ~= lowerNode(n);
			return;
		}
		foreach (c; n.children)
			collect(c);
	}
	collect(t);
	return acc;
}

private bool isRule(string name)
{
	return name.length > 10 && name[0 .. 10] == "SvelteKit." && !canFind(name, "!");
}

private bool isNamed(T)(auto ref T t, string n)
{
	return t.name == n;
}

/// Peel Pegged or!/and!/wrapAround until a SvelteKit rule (no `!` in the name).
private T unwrapRule(T)(auto ref T t)
{
	auto cur = t;
	foreach (_; 0 .. 16)
	{
		if (isRule(cur.name))
			return cur;
		if (!cur.children.length)
			return cur;
		T next;
		bool found;
		foreach (c; cur.children)
			if (isRule(c.name))
			{
				next = c;
				found = true;
				break;
			}
		if (!found && cur.children.length == 1)
		{
			next = cur.children[0];
			found = true;
		}
		if (!found)
			return cur;
		cur = next;
	}
	return cur;
}

private T[] walkNamed(T)(auto ref T t, string n)
{
	T[] acc;
	if (isNamed(t, n))
		acc ~= t;
	foreach (c; t.children)
		acc ~= walkNamed(c, n);
	return acc;
}

private string firstMatches(T)(auto ref T t)
{
	if (t.matches.length)
		return t.matches[0];
	foreach (c; t.children)
	{
		auto m = firstMatches(c);
		if (m.length)
			return m;
	}
	return "";
}

private string ruleName(T)(auto ref T t)
{
	foreach (c; walkNamed(t, "SvelteKit.Name"))
		if (c.matches.length)
			return c.matches.join;
	foreach (m; t.matches)
		if (m != "{" && m != "}" && m.length)
			return m;
	return firstMatches(t);
}

private MkNode lowerNode(T)(auto ref T t)
{
	auto inner = unwrapRule(t);
	if (isNamed(inner, "SvelteKit.MarkupNode") && inner.children.length)
		inner = unwrapRule(inner.children[0]);
	if (isNamed(inner, "SvelteKit.IfBlock"))
		return lowerIf(inner);
	if (isNamed(inner, "SvelteKit.EachBlock"))
		return lowerEach(inner);
	if (isNamed(inner, "SvelteKit.Element") || isNamed(inner, "SvelteKit.OpenElement")
			|| isNamed(inner, "SvelteKit.VoidElement"))
		return lowerElement(inner);
	if (isNamed(inner, "SvelteKit.Mustache"))
	{
		MkNode n;
		n.kind = MkNode.Kind.text;
		n.isMustache = true;
		n.text = ruleName(inner);
		return n;
	}
	MkNode n;
	n.kind = MkNode.Kind.text;
	n.text = inner.matches.length ? inner.matches.join : firstMatches(inner);
	n.text = n.text.strip;
	return n;
}

private MkNode lowerIf(T)(auto ref T t)
{
	MkNode n;
	n.kind = MkNode.Kind.if_;
	foreach (c; walkNamed(t, "SvelteKit.IfCond"))
		if (c.matches.length)
			n.text = c.matches.join.strip;
	n.kids = lowerChildNodes(t);
	foreach (c; walkNamed(t, "SvelteKit.ElsePart"))
		n.elseKids ~= lowerChildNodes(c);
	return n;
}

private MkNode lowerEach(T)(auto ref T t)
{
	MkNode n;
	n.kind = MkNode.Kind.each;
	foreach (c; walkNamed(t, "SvelteKit.EachList"))
		if (c.matches.length)
			n.text = c.matches.join.strip;
	string[] idents;
	foreach (c; walkNamed(t, "SvelteKit.Name"))
		if (c.matches.length)
			idents ~= c.matches.join;
	if (idents.length)
		n.aliasName = idents[$ - 1];
	n.kids = lowerChildNodes(t);
	foreach (c; walkNamed(t, "SvelteKit.ElsePart"))
		n.elseKids ~= lowerChildNodes(c);
	return n;
}

private MkNode[] lowerChildNodes(T)(auto ref T t)
{
	MkNode[] acc;
	foreach (c; t.children)
	{
		if (isNamed(c, "SvelteKit.IfCond") || isNamed(c, "SvelteKit.EachList")
				|| isNamed(c, "SvelteKit.Name") || isNamed(c, "SvelteKit.Attr")
				|| isNamed(c, "SvelteKit.TagName") || isNamed(c, "SvelteKit.VoidName")
				|| isNamed(c, "SvelteKit.Spacing") || isNamed(c, "SvelteKit.ElsePart"))
			continue;
		auto sub = lowerMarkup(c);
		if (sub.length)
			acc ~= sub;
	}
	return acc;
}

private MkNode lowerElement(T)(auto ref T t)
{
	auto el = unwrapRule(t);
	if (isNamed(el, "SvelteKit.Element") && el.children.length)
		el = unwrapRule(el.children[0]);
	MkNode n;
	n.kind = MkNode.Kind.element;
	foreach (c; walkNamed(el, "SvelteKit.TagName"))
		if (c.matches.length)
			n.tag = c.matches.join;
	if (!n.tag.length)
		foreach (c; walkNamed(el, "SvelteKit.VoidName"))
			if (c.matches.length)
				n.tag = c.matches.join;
	void takeAttrs(TT)(auto ref TT p, bool top)
	{
		if (isNamed(p, "SvelteKit.Attr"))
		{
			n.attrs ~= lowerAttr(p);
			return;
		}
		if (!top && (isNamed(p, "SvelteKit.MarkupNode") || isNamed(p, "SvelteKit.OpenElement")
				|| isNamed(p, "SvelteKit.VoidElement") || isNamed(p, "SvelteKit.Element")
				|| isNamed(p, "SvelteKit.IfBlock") || isNamed(p, "SvelteKit.EachBlock")))
			return;
		foreach (c; p.children)
			takeAttrs(c, false);
	}
	takeAttrs(el, true);
	n.kids = lowerChildNodes(el);
	return n;
}

private MkAttr lowerAttr(T)(auto ref T t)
{
	MkAttr a;
	foreach (c; walkNamed(t, "SvelteKit.AttrName"))
		if (c.matches.length)
			a.name = c.matches.join;
	foreach (c; walkNamed(t, "SvelteKit.Mustache"))
	{
		a.isMustache = true;
		a.value = ruleName(c);
	}
	if (!a.value.length)
		foreach (c; walkNamed(t, "SvelteKit.Quoted"))
			if (c.matches.length)
			{
				auto q = c.matches.join;
				if (q.length >= 2 && (q[0] == '"' || q[0] == '\''))
					a.value = q[1 .. $ - 1];
				else
					a.value = q;
			}
	classifyAttr(a);
	return a;
}

private void classifyAttr(ref MkAttr a)
{
	a.isOn = a.name.length > 3 && a.name[0 .. 3] == "on:";
	a.isBind = a.name.length > 5 && a.name[0 .. 5] == "bind:";
	a.isClassDir = a.name.length > 6 && a.name[0 .. 6] == "class:";
	a.isStyleDir = a.name.length > 6 && a.name[0 .. 6] == "style:";
	a.isUse = a.name.length > 4 && a.name[0 .. 4] == "use:";
	a.isAnimate = a.name.length > 8 && a.name[0 .. 8] == "animate:";
	a.isLet = a.name.length > 4 && a.name[0 .. 4] == "let:";
	a.isTransition = (a.name.length > 11 && a.name[0 .. 11] == "transition:")
		|| (a.name.length > 3 && a.name[0 .. 3] == "in:")
		|| (a.name.length > 4 && a.name[0 .. 4] == "out:");
}

private void skipBlock(string src, ref size_t pos, string open, string close)
{
	auto i = indexOf(src, close, pos);
	pos = i < 0 ? src.length : i + close.length;
}
