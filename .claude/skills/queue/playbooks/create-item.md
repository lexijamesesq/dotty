# Playbook: create-item

Write one operator-judgment item into `Wiki/Queue/` as a distinct file.

**Who the item speaks to:** the operator — a person, not a future Claude session. The body is a question she can answer from what SHE knows. Every scrap of machine detail (kind, check ids, subject paths, proposed mechanical edits, evidence excerpts) lives in frontmatter and a trailing `## Mechanics` section she can skim past. The executing session gets everything it needs from those two places; she never has to read them.

**Charter gate:** queue items are vault-knowledge questions — is this true, where does this live, is this finished, may I apply this rule. Repo/code housekeeping and engineering tasks are NOT queue items; they go to Linear (integrity-on-creation rules apply). If the payload is a task, refuse and tell the caller which surface owns it.

**Context floor:** "What this is" must carry enough of the source itself (a short excerpt, or what the document is and what it's for) that she can answer without opening anything. An item that makes her go look is an item that wasn't finished.

## Input

- `queue_kind` — one of `disposition | proposal` (collapsed — until reality demands more)
- `source` — what produced the item (a skill name, lane name, or session descriptor; e.g. `scope-lint`, `capture-lane`, `session-closeout`)
- `reasons` — array of short strings: why this needs operator judgment rather than autonomous handling. Machine-honest; they go in frontmatter and get TRANSLATED into the "why I'm stuck" sentence — never pasted into the ask.
- `scope_tags` — one or more `project/<name>` or `area/<hierarchy>` tags locating the item's domain (load-bearing: the statusline scoped count and triage's scope resolution read these)
- `payload` — the candidate/question the operator will adjudicate
- `evidence` — supporting material (file paths, quotes, search results) sufficient for the executing session to act without re-derivation — lands in `## Mechanics`
- `today` — ISO date (caller passes for testability)

## Protocol

1. **Resolve the queue directory.** Vault root via the `workspace_root` config key (global CLAUDE.md > Configuration); queue dir = `{workspace_root}/Wiki/Queue/`. If the directory does not exist, halt and surface — do not create it silently (Stop rule).

2. **Compose the filename:** `{YYYY-MM-DD}-{queue-kind}-{slug}.md`
   - Date = `today`.
   - Slug = 3–6 lowercase hyphenated words naming the payload topic (not the source lane). The filename stays a slug; the TITLE inside is a question.
   - On collision (file already exists), append `-2`, `-3`, … Never overwrite an existing item.
   - The filename's `{queue-kind}` token is cosmetic and set once at creation; frontmatter `queue-kind` is authoritative and may be re-stamped later without renaming the file.

3. **Compose frontmatter** — exactly this shape, keys in canonical unquoted form (`status: pending` literally — the SessionStart hook greps this string; do not quote or restyle it):

   ```yaml
   ---
   queue-kind: <queue_kind>
   source: <source>
   reasons:
     - <reason 1>
     - <reason 2>
   created: 'YYYY-MM-DD'
   status: pending
   subject: <vault path(s) the item is about — optional>
   checks:
     - <machine check id(s), when a lint/scan produced the item — optional>
   tags:
     - <project/* or area/* scope tag(s)>
   ---
   ```

   `created` is quoted (YAML date-vs-string safety); `status` and `queue-kind` are not. `subject` and `checks` are the machine-detail keys — use them so the body doesn't have to carry paths and check names.

4. **Compose the body** — the three-part human ask, then Mechanics:

   ```markdown
   # <A plain question the operator can answer from what she knows>

   **What this is:** <the content in human terms — the thing itself, not the check that fired>

   **Why I'm stuck:** <the specific fork the evidence can't close: what I believe, what I can't confirm, and why only she can close it>

   **What your answer changes:** If <answer in her terms>, I'll <consequence in her terms>. If <other answer>, I'll <other consequence>.

   ## Mechanics

   *(Claude-facing — detail for the session that executes the resolution. Skip past it.)*

   <proposed mechanical action, finding/check detail, evidence excerpts, provenance>
   ```

   Consequences come first; mechanics are a footnote at most inside the ask ("I'll file them as archived" — not "I'll add status/archived to the tags list").

5. **The human-question test (hard rule)** — see the section below. An item body that fails it does not get written; recompose first.

6. **Write via `mcp__obsidian__write_note`** (create mode). Vault `.md` files are MCP-only — never generic Write.

7. **Verify:** read back the frontmatter (`mcp__obsidian__get_frontmatter`) and confirm `status: pending` and `queue-kind` are present. On write or verification failure, report **FAIL** to the caller with the attempted path and error — never silently drop (a dropped judgment is invisible forever; the design treats queue-write failure as a loud, run-failing event).

## The human-question test (hard rule)

Every item body must pass ALL of these before it is written:

- **The title is a question in plain language.** Not a slug, not a filename, not a finding statement. She should be able to answer the title alone, or know instantly why she can't yet.
- **She answers from what SHE knows.** The question asks about her work, her files' content, her intentions, where things live — never about vault machinery. If the honest answer requires her to understand the machinery, the question is wrong; find the content-level fork underneath it.
- **Zero vault machinery in the ask.** No tags, frontmatter, sources fields, index names, "stamp", slugs, check names, kind enums, lane names, or wikilink syntax anywhere in the title or the three parts. All of that belongs in frontmatter and `## Mechanics`.
- **Three mandatory parts, in order:** *what this is* (the content in human terms), *why I'm stuck* (the specific fork the evidence can't close), *what your answer changes* (each plausible answer mapped to its consequence).
- **Three-weeks test:** could she answer this at a triage three weeks from now, with zero session context, from the ask alone? If she'd have to ask "what are we even talking about?", part (a) is too thin.

**Before / after (synthetic examples):**

BEFORE — machine voice, fails the test:
> **Widget-console Context set missing status/\* tags.** Six files trip HIGH missing-status-tag; they carry a bare `status:` frontmatter key instead of a `status/*` tag, which the taxonomy requires. Operator picks status/archived vs status/draft per file.

AFTER — passes:
> **Is the widget-console redesign finished?** The six working docs from that design push (brief, design, findings, plan, scenarios, ground truth) read like a completed project — the console itself shipped last month. If it's finished, I'll file all six as archived; if it's still live, say so and I'll leave them active.

BEFORE — machine voice, fails the test:
> **hiring-brief-tool-x.md broken wikilink to missing PDF.** `[[evaluation-rubric.pdf]]` — target not found in vault (2 occurrences). Operator adds the attachment, repoints, or removes the link.

AFTER — passes:
> **Do you have the evaluation rubric PDF?** Your Tool-X hiring brief points at it twice, but the file itself was never added to your notes. I can't produce it — only you know whether it exists and where. If you have it, tell me where and I'll attach it; if it lives somewhere linkable, I'll point the references there; if it's gone, I'll remove the two dead references.

## Discipline

- **One item per file, one judgment per item.** Two unrelated findings are two files. Related findings on the same subject (e.g. several lint findings on one page) batch into ONE item — the operator adjudicates subjects, not line numbers. A batched item still asks ONE question; secondary findings ride along as consequences ("…and I'll also list it where its siblings appear").
- **Derivable fixes still get the best human ask.** If the resolution is mechanically derivable without operator knowledge (the item exists only because the producing lane lacked write authority), say so honestly in the ask ("there's nothing here only you would know") and mark it `auto-fix candidate` in `## Mechanics` — an automated resolution lane may pay it down, but until then the operator can still answer it in a word.
- **No structural-contract envelope, no filing-validator.** Queue items are transient judgment artifacts outside the Location Gate. Do not add `type/knowledge`, `status/active`, `updated`, or `sources` — the schema above is complete.
- **Scope tags are the routing signal.** Derive them from the payload's domain. An item with no plausible scope tag still gets filed (it surfaces in Wiki scope and triage-all) — note the absence in `reasons`.

## What this playbook does NOT do

- Does NOT decide whether something belongs in the queue — the caller makes that call per its own decision authority; this playbook files what it is handed.
- Does NOT notify the operator — the statusline count is the surfacing mechanism.
