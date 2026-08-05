// man — Human man-page style Q&A (read-only), session-friendly follow-ups.
// Invoke from Grok TUI: /workflow man  or  /man when registered.
// Prefer the build-platform CLI for browser HTML + id continuity:
//   bun build-platform/src/cli/index.ts man [id] [files...] <query>
//
// Args (object):
//   query  (required)  question text
//   files  (optional)  array of repo paths to ground the answer
//   id     (optional)  man session label for the report header

let meta = #{
    name: "man",
    description: "Write a man-page style answer for human readers, grounded in listed files",
    when_to_use: "Human documentation Q&A over the CVA6 / build-platform tree",
    phases: [
        #{ title: "Research", detail: "read listed files and related docs" },
        #{ title: "Write", detail: "man-page structured answer" },
    ],
};

let answer_schema = #{
    "type": "object",
    "required": ["title", "body_markdown"],
    "properties": #{
        "title": #{ "type": "string" },
        "body_markdown": #{ "type": "string" },
        "see_also": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

if args == () { pause("verification", "Pass args.query (string). Optional: args.files (array), args.id (string)."); }
let query = args.query;
if query == () || query == "" { pause("verification", "args.query is required."); }

let files = if args.files == () { [] } else { args.files };
let man_id = if args.id == () { "man-adhoc" } else { args.id };

phase("Research");
let file_list = "";
if type_of(files) == "array" {
    for f in files {
        file_list += "- " + f + "\n";
    }
}

let research_prompt = "";
research_prompt += "You are preparing a man-page for a HUMAN engineer (browser/reader).\n";
research_prompt += "Man session id: " + man_id + "\n";
research_prompt += "Question: " + query + "\n";
if file_list != "" {
    research_prompt += "Read these files with tools before answering:\n" + file_list;
}
research_prompt += "Also search build-platform/AGENTS.md, build-platform/README.md, AGENTS-build.md when relevant.\n";
research_prompt += "Do not invent CLI flags. Prefer probe → tools install → diag → verify.\n";
research_prompt += "Return {title, body_markdown, see_also} only after reading sources.\n";

let r = agent(research_prompt, #{
    label: "man-research",
    capability_mode: "read-only",
    output_schema: answer_schema,
});

if r == () || !r.success || r.output == () {
    pause("infra", "Man research agent failed; resume or re-run with clearer args.");
}

phase("Write");
let title = r.output.title;
let body = r.output.body_markdown;
let see = r.output.see_also;
let report = "# " + title + "\n\n";
report += "> man **" + man_id + "**\n\n";
report += body + "\n";
if see != () && type_of(see) == "array" && see.len() > 0 {
    report += "\n## See also\n";
    for s in see {
        report += "- " + s + "\n";
    }
}

let path = write_scratch_file("man-page.md", report);
complete(#{
    path: path,
    id: man_id,
    title: title,
    report: report,
    summary: "Man page for " + man_id + ": " + title,
});
