# Playbook: write

Edit the **Project State** section of a project's `CLAUDE.md`, preserving everything else in the file.

## Input

```yaml
project_root: <abs-path>           # required
last_updated: <YYYY-MM-DD>         # required; today's date (with optional parenthetical context)
re_entry_cue: <string>             # required; ONE sentence
current_state: <string>            # optional; overwrites if provided
waiting_for: <list of items>       # optional; overwrites if provided. Use empty list to write "None"
decisions_needed: <list of items>  # optional; overwrites if provided. Use empty list to write "None"
```

## Protocol

1. **Resolve** project root per navigator's cross-cutting rule. Fail clearly if CLAUDE.md missing.

2. **Read** `<project_root>/CLAUDE.md`.

3. **Validate Re-entry Cue** is ONE sentence before writing — if it contains multiple sentences (multiple `. ` or `! ` or `? ` followed by capital), fail with `"Re-entry Cue must be one sentence; got N sentences"`. The caller composed the cue; this skill enforces the format.

4. **Locate Project State.** Find `## Project State`. Within it locate each field marker:
   - `**Last Updated:**`
   - `### Re-entry Cue`
   - `### Current State`
   - `### Waiting For`
   - `### Decisions Needed`

5. **For each input field provided**, replace the content in place — from the field's heading/marker through the start of the next section (`###` for sub-headings, `##` for the next major section). Leave fields not provided in input untouched. Preserve heading hierarchy and surrounding whitespace.

6. **If the section or a field doesn't exist**, match the project template structure (path configured in global CLAUDE.md > Configuration > `templates.project`) and create the missing field with the new content. Surface a warning if the CLAUDE.md was missing Project State entirely (caller likely wants to know).

7. **Write the file back.**

## Output

```yaml
fields_updated: [last_updated, re_entry_cue, ...]
warnings: [<warning strings if any>]
file_path: <abs-path to CLAUDE.md>
```

## Field semantics (enforced rules)

- **Last Updated** — always today's date in `YYYY-MM-DD` format. Optionally include a brief parenthetical context: `2026-05-24 (deconstruction work)`.
- **Re-entry Cue** — ONE sentence. Validation enforced in step 3. The single most important field. References the active Linear issue or specific next-action.
- **Current State** — free-form paragraph or bullet list. Component-level status. Updated when components change. Provisional thoughts go here (decay naturally on overwrite).
- **Waiting For** — external blockers. Each item should name: what's blocking + resolver + expected trigger. If input is an empty list, write `None` for the section body. If the section content reads "None.", that's fine; do not insist on null.
- **Decisions Needed** — questions blocking progress. Each item: the question + who can answer + when needed. Same null-vs-"None" treatment as Waiting For.

## Anti-patterns to flag (output WARNING)

- **"Recent Changes" content in `current_state`** — if the caller passes `current_state` with dated bullet entries that look like a changelog (regex: line starts with a date like `YYYY-MM-DD` or `\d{4}/\d{2}/\d{2}` followed by `:`), emit a structured WARNING in the output's `warnings` field: `"current_state contains dated changelog-style entries; provisional thoughts decay on overwrite per Project State discipline — consider whether this content belongs in a Linear Project Update instead."` Do the write (the caller has authority), but surface the warning so the orchestrator can decide whether to flag to the operator. This rule lives HERE (not in `/knowledge-layer` hygiene) because the anti-pattern is CLAUDE.md-domain-specific and this skill is the domain expert. The hygiene scan in `/knowledge-layer` is for Knowledge docs, not for CLAUDE.md.
- **Multi-sentence Re-entry Cue** — fail (step 3 validation). The caller must collapse before re-invoking.

## What this playbook does NOT do

- Does NOT write to the Intake section (that's a different scope — would be a separate playbook if needed).
- Does NOT update frontmatter (use Obsidian's `update_frontmatter` MCP directly).
- Does NOT validate Linear Project ID resolves to a real project (out of scope; that's `/linear` territory).

## Tool notes

- Use Obsidian MCP `patch_note` for the per-field replacements (more efficient than full rewrite via `write_note`).
- If multiple fields change, batch the patches.
- The harness's `vault-mcp-redirect` hook will route generic `Edit`/`Write` to MCP automatically; using MCP directly is faster and avoids the redirect.
