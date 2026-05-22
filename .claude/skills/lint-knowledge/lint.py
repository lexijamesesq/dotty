#!/usr/bin/env python3
"""
lint.py — Mechanical pass for the vault knowledge-integrity lint system.

Derives rule values at runtime from:
  - <vault-root>/System/tag-taxonomy.md   (Parsing Contract: namespaces, vocabularies, depth limits)
  - <vault-root>/System/structural-contract.md  (Parsing Contract: invariant core, per-type, destination modifiers, scope boundaries)

Never hardcodes vocabulary values. Read-only. No model. No network.
Exit 0 on successful run (findings are data). Non-zero only on script-level failure.

Spec: {workspace_root}/System/lint-surface.md
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

# ---------------------------------------------------------------------------
# Frontmatter parser (no PyYAML — stdlib only)
# ---------------------------------------------------------------------------

def _parse_flow_list(value_str: str) -> list[str]:
    """Parse a flow-style YAML list: ["a","b"] or [a, b]."""
    inner = value_str.strip()
    if inner.startswith("[") and inner.endswith("]"):
        inner = inner[1:-1]
    items = []
    # tokenize: handle quoted and unquoted items
    for token in re.findall(r'"([^"]*)"' + r"|'([^']*)'|([^,\[\]\"\']+)", inner):
        val = token[0] or token[1] or token[2]
        val = val.strip()
        if val:
            items.append(val)
    return items


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """
    Return (frontmatter_dict, body_text).
    frontmatter_dict keys: tags (list[str]), updated (str|None),
      verified (str|None), sources (list[str]|None), status (str|None),
      stale_suspects (list[str]|None).
    body_text is everything after the closing ---.
    """
    fm: dict = {
        "tags": [],
        "updated": None,
        "verified": None,
        "sources": None,
        "status": None,
        "stale_suspects": None,
    }
    body = text

    # Must open with ---
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return fm, text

    # Find closing ---
    close_idx = None
    for i, line in enumerate(lines[1:], 1):
        if line.strip() == "---":
            close_idx = i
            break
    if close_idx is None:
        return fm, text

    fm_lines = lines[1:close_idx]
    body = "\n".join(lines[close_idx + 1 :])

    # Parse key-value pairs
    i = 0
    while i < len(fm_lines):
        line = fm_lines[i]
        # Skip blank / comment
        if not line.strip() or line.strip().startswith("#"):
            i += 1
            continue

        m = re.match(r"^(\w[\w-]*):\s*(.*)", line)
        if not m:
            i += 1
            continue

        key = m.group(1).lower()
        value = m.group(2).strip()

        if key == "tags":
            if value.startswith("["):
                # flow list on same line
                fm["tags"] = _parse_flow_list(value)
                i += 1
            elif value == "" or value is None:
                # block list follows
                tags = []
                i += 1
                while i < len(fm_lines) and re.match(r"^\s+-\s+", fm_lines[i]):
                    tag_val = re.sub(r"^\s+-\s+", "", fm_lines[i]).strip()
                    # strip quotes
                    tag_val = tag_val.strip('"\'')
                    if tag_val:
                        tags.append(tag_val)
                    i += 1
                fm["tags"] = tags
            else:
                # single-value tags: (unusual but handle)
                fm["tags"] = [value.strip('"\'')]
                i += 1
        elif key in ("updated", "verified"):
            fm[key] = value.strip('"\'') if value else None
            i += 1
        elif key == "status":
            fm["status"] = value.strip('"\'') if value else None
            i += 1
        elif key == "sources":
            if value.startswith("["):
                fm["sources"] = _parse_flow_list(value)
            elif value == "":
                srcs = []
                i += 1
                while i < len(fm_lines) and re.match(r"^\s+-\s+", fm_lines[i]):
                    src_val = re.sub(r"^\s+-\s+", "", fm_lines[i]).strip().strip('"\'')
                    if src_val:
                        srcs.append(src_val)
                    i += 1
                fm["sources"] = srcs
                continue
            else:
                fm["sources"] = [value.strip('"\'')]
            i += 1
        elif key == "stale_suspects":
            if value.startswith("["):
                fm["stale_suspects"] = _parse_flow_list(value)
            elif value == "":
                suspects = []
                i += 1
                while i < len(fm_lines) and re.match(r"^\s+-\s+", fm_lines[i]):
                    s = re.sub(r"^\s+-\s+", "", fm_lines[i]).strip().strip('"\'')
                    if s:
                        suspects.append(s)
                    i += 1
                fm["stale_suspects"] = suspects
                continue
            else:
                fm["stale_suspects"] = [value.strip('"\'')]
            i += 1
        else:
            i += 1

    return fm, body


# ---------------------------------------------------------------------------
# Contract parser — tag-taxonomy.md
# ---------------------------------------------------------------------------

def _extract_table_column(text: str, section_header: str, col_index: int = 0) -> list[str]:
    """
    Find the section starting with `section_header` and return col_index values
    from all data rows of the first markdown table found.
    """
    # Find section
    pattern = re.compile(
        r"^#{1,4}\s+" + re.escape(section_header) + r".*$", re.MULTILINE
    )
    m = pattern.search(text)
    if not m:
        return []

    section_start = m.end()
    # Find next section of same or higher level
    level = len(re.match(r"^(#{1,4})", m.group()).group(1))
    next_sec = re.search(r"^#{1," + str(level) + r"}\s+", text[section_start:], re.MULTILINE)
    section_text = text[section_start : section_start + next_sec.start()] if next_sec else text[section_start:]

    return _extract_table_col_from_text(section_text, col_index)


def _extract_table_col_from_text(text: str, col_index: int) -> list[str]:
    """Extract column values from the first markdown table in text."""
    values = []
    in_table = False
    header_seen = False
    for line in text.splitlines():
        line = line.strip()
        if not line:
            if in_table:
                break
            continue
        if line.startswith("|"):
            in_table = True
            # Skip separator row
            if re.match(r"^\|[\s\-|:]+\|$", line):
                header_seen = True
                continue
            if not header_seen:
                header_seen = True  # first row is header
                continue
            cols = [c.strip() for c in line.split("|")[1:-1]]
            if len(cols) > col_index:
                val = cols[col_index].strip().strip("`")
                if val and val not in ("-", "—"):
                    values.append(val)
        else:
            if in_table:
                break
    return values


def parse_tag_taxonomy(path: Path) -> dict:
    """
    Parse tag-taxonomy.md and return a dict with:
      namespace_prefixes: list[str]   — ["type","project","area","topic","person","status"]
      type_vocab: set[str]            — closed set of type/ values (full tag e.g. "type/knowledge")
      status_vocab: set[str]          — closed set of status/ values
      depth_limits: dict[str, dict]   — {ns: {"typical": str, "max": int}}
      area_top_levels: set[str]       — first path segment under area/
      person_roster: set[str]         — kebab-cased person names
      grandfathered_project_prefixes: list[str]  — e.g. ["project/neudesic/","project/grin/"]
    """
    text = path.read_text(encoding="utf-8")
    result = {}

    # ---- Namespace prefixes from "## The Namespaces" table ----
    ns_section = re.search(r"## The Namespaces\s", text)
    if not ns_section:
        raise ValueError(f"Cannot find '## The Namespaces' table in {path}")
    ns_raw = _extract_table_column(text, "The Namespaces", col_index=0)
    # Each entry looks like "`type/<x>`" — extract namespace prefix
    prefixes = []
    for raw in ns_raw:
        m = re.match(r"`?(\w+)/<", raw)
        if m:
            prefixes.append(m.group(1))
    if len(prefixes) < 6:
        raise ValueError(
            f"Expected ≥6 namespace prefixes from 'The Namespaces' table in {path}, "
            f"got {prefixes}"
        )
    result["namespace_prefixes"] = prefixes

    # ---- Closed type/ vocabulary ----
    # Find ### `type/` section
    type_section_m = re.search(r"^###\s+`type/`", text, re.MULTILINE)
    if not type_section_m:
        raise ValueError(f"Cannot find '### `type/`' section in {path}")
    type_section_start = type_section_m.end()
    next_sec = re.search(r"^###\s+`", text[type_section_start:], re.MULTILINE)
    type_section_text = (
        text[type_section_start : type_section_start + next_sec.start()]
        if next_sec
        else text[type_section_start:]
    )

    # Find "Vocabulary (closed set)" sub-section or just get the first table
    vocab_m = re.search(r"\*\*Vocabulary[^*]*\*\*", type_section_text)
    table_text = type_section_text[vocab_m.start() :] if vocab_m else type_section_text

    type_vocab = set()
    in_table = False
    header_seen = False
    for line in table_text.splitlines():
        line_s = line.strip()
        if not line_s:
            if in_table:
                break
            continue
        if line_s.startswith("|"):
            in_table = True
            if re.match(r"^\|[\s\-|:]+\|$", line_s):
                header_seen = True
                continue
            if not header_seen:
                header_seen = True
                continue
            cols = [c.strip() for c in line_s.split("|")[1:-1]]
            if cols:
                cell = cols[0]
                # Cell may contain multiple backticked type/ values
                for token in re.findall(r"`(type/[^`]+)`", cell):
                    for t in re.split(r"[,\s]+", token):
                        t = t.strip()
                        if t.startswith("type/"):
                            type_vocab.add(t)
        else:
            if in_table:
                break
    if not type_vocab:
        raise ValueError(f"Could not extract type/ vocabulary from {path}")
    result["type_vocab"] = type_vocab

    # ---- Closed status/ vocabulary ----
    status_section_m = re.search(r"^###\s+`status/`", text, re.MULTILINE)
    if not status_section_m:
        raise ValueError(f"Cannot find '### `status/`' section in {path}")
    status_start = status_section_m.end()
    next_s = re.search(r"^###\s+`", text[status_start:], re.MULTILINE)
    status_text = (
        text[status_start : status_start + next_s.start()]
        if next_s
        else text[status_start:]
    )
    status_vocab = set()
    in_table = False
    header_seen = False
    for line in status_text.splitlines():
        line_s = line.strip()
        if not line_s:
            if in_table:
                break
            continue
        if line_s.startswith("|"):
            in_table = True
            if re.match(r"^\|[\s\-|:]+\|$", line_s):
                header_seen = True
                continue
            if not header_seen:
                header_seen = True
                continue
            cols = [c.strip() for c in line_s.split("|")[1:-1]]
            if cols:
                cell = cols[0].strip().strip("`")
                if cell.startswith("status/"):
                    status_vocab.add(cell)
        else:
            if in_table:
                break
    if not status_vocab:
        raise ValueError(f"Could not extract status/ vocabulary from {path}")
    result["status_vocab"] = status_vocab

    # ---- Depth limits from "## Depth Limits (Summary)" table ----
    depth_m = re.search(r"^## Depth Limits \(Summary\)", text, re.MULTILINE)
    if not depth_m:
        raise ValueError(f"Cannot find '## Depth Limits (Summary)' in {path}")
    depth_start = depth_m.end()
    next_sec2 = re.search(r"^##\s+", text[depth_start:], re.MULTILINE)
    depth_text = (
        text[depth_start : depth_start + next_sec2.start()]
        if next_sec2
        else text[depth_start:]
    )
    depth_limits = {}
    in_table = False
    header_seen = False
    for line in depth_text.splitlines():
        line_s = line.strip()
        if not line_s:
            if in_table:
                break
            continue
        if line_s.startswith("|"):
            in_table = True
            if re.match(r"^\|[\s\-|:]+\|$", line_s):
                header_seen = True
                continue
            if not header_seen:
                header_seen = True
                continue
            cols = [c.strip() for c in line_s.split("|")[1:-1]]
            if len(cols) >= 3:
                ns_raw = cols[0].strip().strip("`")
                # strip /<x>
                ns = re.sub(r"/<.+>", "", ns_raw).strip("/")
                typical = cols[1].strip()
                max_raw = cols[2].strip()
                # max may be "3 (historical tags grandfathered deeper)"
                max_m = re.search(r"\d+", max_raw)
                max_val = int(max_m.group()) if max_m else 2
                depth_limits[ns] = {"typical": typical, "max": max_val}
        else:
            if in_table:
                break
    if not depth_limits:
        raise ValueError(f"Could not parse depth limits from {path}")
    result["depth_limits"] = depth_limits

    # ---- area/ top-levels ----
    area_m = re.search(r"^###\s+`area/`", text, re.MULTILINE)
    if not area_m:
        raise ValueError(f"Cannot find '### `area/`' section in {path}")
    area_start = area_m.end()
    next_area = re.search(r"^###\s+`", text[area_start:], re.MULTILINE)
    area_text = (
        text[area_start : area_start + next_area.start()]
        if next_area
        else text[area_start:]
    )
    # Look for "Current top-levels" section; collect bullet items
    top_levels_m = re.search(r"Current top-levels[^\n]*\n", area_text)
    area_top_levels = set()
    if top_levels_m:
        top_start = top_levels_m.end()
        for line in area_text[top_start:].splitlines():
            ls = line.strip()
            if not ls:
                continue
            if ls.startswith("-"):
                # Extract area/xxx value
                # Line like: "- `area/work/{employer}` — ..."
                # Or: "- `area/health` — ..."
                for tok in re.findall(r"`(area/[^`]+)`", ls):
                    # First path segment under area/
                    parts = tok.split("/")
                    if len(parts) >= 2:
                        area_top_levels.add(parts[1])
            elif not ls.startswith("|") and not ls.startswith("#"):
                # Might be a non-bullet continuation or next section
                if re.match(r"^\*\*", ls):
                    break
    result["area_top_levels"] = area_top_levels

    # ---- person/ roster ----
    person_m = re.search(r"^###\s+`person/`", text, re.MULTILINE)
    if not person_m:
        raise ValueError(f"Cannot find '### `person/`' section in {path}")
    person_start = person_m.end()
    next_person = re.search(r"^###\s+`", text[person_start:], re.MULTILINE)
    person_text = (
        text[person_start : person_start + next_person.start()]
        if next_person
        else text[person_start:]
    )
    # Find "Current roster" line
    roster_m = re.search(r"Current roster[^\n]*:\s*([^\n]+)", person_text)
    person_roster = set()
    if roster_m:
        roster_line = roster_m.group(1)
        # "Alli Sobiecki, Christina Pirzada, ..."
        for name in re.split(r",\s*", roster_line):
            name = name.strip().strip(".")
            if name:
                # kebab-case
                kebab = name.lower().replace(" ", "-")
                person_roster.add(kebab)
    result["person_roster"] = person_roster

    # ---- grandfathered project/ prefixes ----
    proj_m = re.search(r"^###\s+`project/`", text, re.MULTILINE)
    grandfathered = []
    if proj_m:
        proj_start = proj_m.end()
        next_proj = re.search(r"^###\s+`", text[proj_start:], re.MULTILINE)
        proj_text = (
            text[proj_start : proj_start + next_proj.start()]
            if next_proj
            else text[proj_start:]
        )
        # Look for grandfathered patterns like project/neudesic/*, project/grin/*
        for token in re.findall(r"`(project/\w+)/\*`", proj_text):
            grandfathered.append(token + "/")
        # Also check text mentions without backticks
        for token in re.findall(r"\bproject/(\w+)/\*", proj_text):
            candidate = f"project/{token}/"
            if candidate not in grandfathered:
                grandfathered.append(candidate)
    result["grandfathered_project_prefixes"] = grandfathered

    # ---- Deprecated type/ values (fix C) ----
    # Parse any type/ row in the closed-vocab table whose Meaning cell contains
    # "Deprecated" (case-insensitive).  This derives the deprecated set from the
    # contract rather than hardcoding type-specific values like "type/raw".
    # Source: tag-taxonomy.md ### `type/` Vocabulary table, col 1 (Meaning).
    deprecated_types: set[str] = set()
    in_table_d = False
    header_seen_d = False
    for line in table_text.splitlines():  # reuse type_vocab table_text parsed above
        line_s = line.strip()
        if not line_s:
            if in_table_d:
                break
            continue
        if line_s.startswith("|"):
            in_table_d = True
            if re.match(r"^\|[\s\-|:]+\|$", line_s):
                header_seen_d = True
                continue
            if not header_seen_d:
                header_seen_d = True
                continue
            cols = [c.strip() for c in line_s.split("|")[1:-1]]
            if len(cols) >= 2:
                meaning_cell = cols[1]
                if "deprecated" in meaning_cell.lower():
                    # same extraction logic as type_vocab above
                    cell = cols[0]
                    for token in re.findall(r"`(type/[^`]+)`", cell):
                        for t in re.split(r"[,\s]+", token):
                            t = t.strip()
                            if t.startswith("type/"):
                                deprecated_types.add(t)
        else:
            if in_table_d:
                break
    result["deprecated_types"] = deprecated_types

    return result


# ---------------------------------------------------------------------------
# Contract parser — structural-contract.md
# ---------------------------------------------------------------------------

def _parse_section_text(text: str, section_header: str) -> str:
    """Return the text of a ## section (from header end to next ## header)."""
    m = re.search(r"^## " + re.escape(section_header), text, re.MULTILINE)
    if not m:
        return ""
    start = m.end()
    next_m = re.search(r"^##\s+", text[start:], re.MULTILINE)
    return text[start : start + next_m.start()] if next_m else text[start:]


def _parse_table_rows(section_text: str) -> list[list[str]]:
    """Return list of column-value lists for all data rows in the first table."""
    rows = []
    in_table = False
    header_seen = False
    for line in section_text.splitlines():
        ls = line.strip()
        if not ls:
            if in_table:
                break
            continue
        if ls.startswith("|"):
            in_table = True
            if re.match(r"^\|[\s\-|:]+\|$", ls):
                header_seen = True
                continue
            if not header_seen:
                header_seen = True  # first row is header
                continue
            cols = [c.strip() for c in ls.split("|")[1:-1]]
            rows.append(cols)
        else:
            if in_table:
                break
    return rows


def parse_structural_contract(path: Path) -> dict:
    """
    Parse structural-contract.md and return:
      invariant_core: dict of element -> {"requirement": str, "tightening": bool}
      per_type: dict[type_value -> {"extra_tags": list[str], "sources": str,
                                    "topic_conditional": bool, "topic_unconditional": bool}]
      destination_modifiers: dict  (wiki_scope_tag, project_scope_tag, wiki_topic_knowledge,
                                    project_needs_index)
      invariant_core_only: set[str]   — type/ values: Invariant Core enforced, per-type skipped
      structure_not_imposed: set[str] — type/ values: only tag-validity checks apply
      tightening_checks: set[str]     — element names from Invariant Core marked [tightening]

    Exemption tiers (fix A):
      Source: structural-contract.md › Scope Boundaries › Exemption tiers table.
      The Parsing Contract row "Exemption tiers" mandates this table as the authoritative
      source.  Two tiers are defined:
        - Invariant-core-only: Invariant Core enforced; Per-Type Additions skipped.
        - Structure-not-imposed: no structural-contract check at all; only tag-taxonomy
          tag validity applies.
      Any closed-vocab type/ value not listed in either tier or the Per-Type Additions
      table defaults to Invariant-core-only.

    Per-type topic_conditional / topic_unconditional (fix B):
      Distinguish by cell text: if the cell references "Wiki-hosted", the topic/ is
      conditional on destination; otherwise it is unconditional.
    """
    text = path.read_text(encoding="utf-8")
    result = {}

    # ---- Invariant Core + [tightening] markers (fix F) ----
    ic_text = _parse_section_text(text, "Invariant Core")
    if not ic_text:
        raise ValueError(f"Cannot find '## Invariant Core' in {path}")
    invariant_core = {}
    tightening_checks: set[str] = set()
    for cols in _parse_table_rows(ic_text):
        if len(cols) >= 2:
            elem = cols[0].strip().strip("`")
            req = cols[1].strip()
            is_tightening = "[tightening" in req.lower()
            invariant_core[elem] = {"requirement": req, "tightening": is_tightening}
            if is_tightening:
                # Strip all backticks and normalize to a stable semantic key
                clean_elem = elem.replace("`", "").strip()
                tightening_checks.add(clean_elem)
    if not invariant_core:
        raise ValueError(f"Could not parse Invariant Core table from {path}")
    result["invariant_core"] = invariant_core
    result["tightening_checks"] = tightening_checks

    # ---- Per-Type Additions (fix B — data-driven, topic_conditional vs topic_unconditional) ----
    pt_text = _parse_section_text(text, "Per-Type Additions")
    if not pt_text:
        raise ValueError(f"Cannot find '## Per-Type Additions' in {path}")
    per_type = {}
    for cols in _parse_table_rows(pt_text):
        if len(cols) >= 3:
            type_val = cols[0].strip().strip("`")
            if not type_val.startswith("type/"):
                continue
            extra_raw = cols[1].strip()
            sources_req = cols[2].strip()
            # Determine whether topic/ is required:
            #   - topic_conditional=True  → Wiki-hosted only (cell text references "Wiki-hosted")
            #   - topic_unconditional=True → always required (no Wiki-hosted qualifier)
            #   Both may be False if the row has no topic/ at all.
            # Fix B: the old parser set topic_conditional for ALL topic/ mentions, which
            # incorrectly made type/project-pointer's unconditional topic/ look conditional.
            extra_tags = []
            topic_conditional = False
            topic_unconditional = False
            if extra_raw not in ("—", "-", ""):
                # Does the cell reference "Wiki-hosted" in any form?
                wiki_qualified = bool(re.search(r"wiki.hosted", extra_raw, re.IGNORECASE))
                for tok in re.findall(r"`?(\w[\w/-]+)`?", extra_raw):
                    if "/" in tok and not tok.endswith("-"):
                        bare = tok.rstrip("/")
                        if bare == "topic":
                            if wiki_qualified:
                                topic_conditional = True
                            else:
                                topic_unconditional = True
                        else:
                            extra_tags.append(bare)
            per_type[type_val] = {
                "extra_tags": extra_tags,
                "sources": sources_req,
                "topic_conditional": topic_conditional,
                "topic_unconditional": topic_unconditional,
            }
    if not per_type:
        raise ValueError(f"Could not parse Per-Type Additions table from {path}")
    result["per_type"] = per_type

    # ---- Destination Modifiers ----
    dm_text = _parse_section_text(text, "Destination Modifiers")
    if not dm_text:
        raise ValueError(f"Cannot find '## Destination Modifiers' in {path}")
    dest_mods = {
        "wiki_scope_tag": "area",
        "project_scope_tag": "project",
        "wiki_topic_knowledge": True,
        "project_needs_index": True,
    }
    for cols in _parse_table_rows(dm_text):
        if len(cols) >= 3:
            aspect = cols[0].strip()
            wiki_val = cols[1].strip()
            proj_val = cols[2].strip()
            if "Scope tag" in aspect:
                wm = re.search(r"`(\w+)/", wiki_val)
                pm = re.search(r"`(\w+)/", proj_val)
                if wm:
                    dest_mods["wiki_scope_tag"] = wm.group(1)
                if pm:
                    dest_mods["project_scope_tag"] = pm.group(1)
    result["destination_modifiers"] = dest_mods

    # ---- Scope Boundaries: Location Gate + Exemption tiers ----
    # Source: ## Scope Boundaries section.  Two tables:
    #   - Location Gate table: col 0 = a path glob; the union is the governed set.
    #   - Exemption tiers table: col 0 = Tier name, col 2 = type/ values.
    # Parsing Contract rows "Location Gate" and "Exemption tiers".
    # Fail loud (non-zero exit) if either table cannot be parsed — silent
    # check-disablement on contract reformatting is unacceptable (fix E).
    sb_text = _parse_section_text(text, "Scope Boundaries")
    if not sb_text:
        raise ValueError(f"Cannot find '## Scope Boundaries' in {path}")

    # --- Location Gate ---
    # The table follows the "Location Gate" subsection header.  Col 0 of each
    # data row is a path glob (in backticks) naming a governed location.
    lg_m = re.search(r"Location Gate", sb_text, re.IGNORECASE)
    if not lg_m:
        raise ValueError(
            f"Cannot find 'Location Gate' table in '## Scope Boundaries' of {path}. "
            "This table is required by the Parsing Contract."
        )
    lg_text = sb_text[lg_m.start():]
    governed_globs: list[str] = []
    for cols in _parse_table_rows(lg_text):
        if not cols:
            continue
        # col 0 may contain multiple backticked globs joined by "and"
        for tok in re.findall(r"`([^`]+)`", cols[0]):
            tok = tok.strip()
            if tok:
                governed_globs.append(tok)
    if not governed_globs:
        raise ValueError(
            f"Parsed zero governed-location globs from the Location Gate table in {path}. "
            "Check that the table's first column holds backticked path globs."
        )
    result["governed_globs"] = governed_globs

    # --- Exemption tiers ---
    # The Exemption tiers table follows the "Exemption tiers" text.  Col 0 =
    # Tier name, col 2 = type/ values.  Four tiers; we extract the three that
    # change lint behaviour (fully-governed is implied by the Per-Type table).
    et_m = re.search(r"Exemption tiers", sb_text, re.IGNORECASE)
    if not et_m:
        raise ValueError(
            f"Cannot find 'Exemption tiers' table in '## Scope Boundaries' of {path}. "
            "This table is required by the Parsing Contract; ensure structural-contract.md "
            "contains the Exemption tiers table with the Invariant-core-only, "
            "Structure-not-imposed, and Out-of-scope rows."
        )
    et_text = sb_text[et_m.start():]

    invariant_core_only: set[str] = set()
    structure_not_imposed: set[str] = set()
    out_of_scope_types: set[str] = set()

    for cols in _parse_table_rows(et_text):
        if len(cols) < 3:
            continue
        tier_cell = cols[0].strip()
        types_cell = cols[2].strip()
        # Extract all type/ values from the cell
        extracted: set[str] = set()
        for token in re.findall(r"`(type/[^`]+)`", types_cell):
            for t in re.split(r"[,\s]+", token):
                t = t.strip()
                if t.startswith("type/"):
                    extracted.add(t)
        # Classify by tier name (case-insensitive substring match)
        tier_lower = tier_cell.lower()
        if "out of scope" in tier_lower or "out-of-scope" in tier_lower:
            out_of_scope_types.update(extracted)
        elif "structure-not-imposed" in tier_lower or "structure not imposed" in tier_lower:
            structure_not_imposed.update(extracted)
        elif "invariant-core-only" in tier_lower or "invariant core only" in tier_lower or "invariant-core" in tier_lower:
            invariant_core_only.update(extracted)
        # "fully governed" row: type/ values are implied by the Per-Type table — no set needed.

    # Fix E: Fail loud if either core tier set is empty — silent check-disablement
    # is unacceptable.  An empty set here means the table was reformatted in a way
    # the parser can't handle; surface the error rather than silently skipping checks.
    if not invariant_core_only:
        raise ValueError(
            f"Parsed zero 'Invariant-core-only' type/ values from the Exemption tiers table "
            f"in {path}. Check that the table has a row matching 'Invariant-core-only' with "
            "type/ values in backticks in the third column."
        )
    if not structure_not_imposed:
        raise ValueError(
            f"Parsed zero 'Structure-not-imposed' type/ values from the Exemption tiers table "
            f"in {path}. Check that the table has a row matching 'Structure-not-imposed' with "
            "type/ values in backticks in the third column."
        )
    if not out_of_scope_types:
        raise ValueError(
            f"Parsed zero 'Out of scope' type/ values from the Exemption tiers table "
            f"in {path}. Check that the table has a row matching 'Out of scope' with "
            "type/ values in backticks in the third column."
        )

    result["invariant_core_only"] = invariant_core_only
    result["structure_not_imposed"] = structure_not_imposed
    result["out_of_scope_types"] = out_of_scope_types

    return result


# ---------------------------------------------------------------------------
# Vault index — enumerate files, wikilink targets
# ---------------------------------------------------------------------------

def build_vault_index(vault_root: Path) -> dict[str, Path]:
    """
    Return a dict mapping lowercase note title (stem) -> first matching Path.
    Also maps vault-relative-path (lowercased) -> Path for direct resolution.
    """
    index: dict[str, Path] = {}
    for md_path in vault_root.rglob("*.md"):
        stem = md_path.stem.lower()
        rel = str(md_path.relative_to(vault_root)).lower()
        if stem not in index:
            index[stem] = md_path
        index[rel] = md_path
        # Also without extension
        rel_noext = rel[:-3] if rel.endswith(".md") else rel
        index[rel_noext] = md_path
    return index


def enumerate_projects(vault_root: Path) -> set[str]:
    """Return kebab-cased project names from Projects/ folder + 'system'.

    Fix (critic D): kebab-case only — raw-lowercase variant removed.
    The project/ tag taxonomy uses kebab-case (matching folder names normalised with
    re.sub(r'[\\s_]+', '-', name).lower()), so validating against raw-lowercase names
    was wrong and could silently accept tags that don't match any real folder.
    """
    projects_dir = vault_root / "Projects"
    names = {"system"}
    if projects_dir.exists():
        for entry in projects_dir.iterdir():
            if entry.is_dir() and not entry.name.startswith("."):
                # kebab-case only — do NOT also add raw entry.name.lower()
                kname = re.sub(r"[\s_]+", "-", entry.name).lower()
                names.add(kname)
    return names


def kebab(name: str) -> str:
    return re.sub(r"[\s_]+", "-", name.strip()).lower()


# ---------------------------------------------------------------------------
# Code-context stripping — prevents false positives on pattern scans
# ---------------------------------------------------------------------------

def strip_code_context(body: str) -> str:
    """Return a view of body with Markdown code context neutralised.

    Two transforms, applied in order:
    1. Fenced code blocks (``` or ~~~, with optional language tag):
       Lines from the opening fence to the matching closing fence (inclusive)
       are replaced with blank lines.  Line count is preserved so any
       line-number-based check that runs on the result stays correct.
       Matching rule: a closing fence is the first subsequent line whose
       stripped content consists ONLY of the same fence character repeated
       ≥3 times (e.g. opening "```bash" closes on "```" or "````" etc.).
    2. Inline code spans (backtick-delimited runs on a single line):
       Every balanced backtick-run (same number of opening/closing backticks,
       on the same line, not already inside a fenced block) is replaced with
       an equal-length run of spaces so character positions are preserved.
       Handles single-backtick and multi-backtick delimiters.

    Frontmatter (before the second "---") is NOT stripped — callers receive
    the body-only slice (post-frontmatter) from parse_frontmatter, so this
    is moot in practice.

    Indented (4-space) code blocks are NOT stripped — the wikilink pattern
    [[...]] is uncommon there and handling them would risk false negatives on
    genuine prose that happens to be indented.
    """
    lines = body.splitlines(keepends=True)
    result: list[str] = []
    in_fence = False
    fence_char = ""  # e.g. "```" or "~~~"

    for line in lines:
        stripped = line.rstrip("\n\r")
        stripped_s = stripped.strip()

        if not in_fence:
            # Detect opening fence: line stripped starts with 3+ ` or ~
            fence_m = re.match(r"^(\s*)(`{3,}|~{3,})", stripped)
            if fence_m:
                in_fence = True
                # The fence character is just the backtick or tilde type,
                # ignoring count so "```" closes "````" — use the char type.
                fence_char = fence_m.group(2)[0]  # '`' or '~'
                # Emit blank line (preserve line count)
                result.append(re.sub(r"[^\n\r]", " ", line).rstrip() + "\n" if line.endswith(("\n", "\r")) else " " * len(line))
                continue

            # Not in a fence: strip inline code spans on this line
            result.append(_strip_inline_code(line))
        else:
            # Inside a fence: replace with blank, watch for closing fence
            result.append(re.sub(r"[^\n\r]", " ", line).rstrip() + "\n" if line.endswith(("\n", "\r")) else " " * len(line))
            # Closing fence: same char type, ≥3 of them, nothing else on the line
            if re.match(r"^\s*" + re.escape(fence_char) + r"{3,}\s*$", stripped):
                in_fence = False

    return "".join(result)


def _strip_inline_code(line: str) -> str:
    """Replace balanced backtick-delimited inline code spans with spaces.

    Only handles runs of 1–6 backticks.  Processes longest runs first to
    avoid misidentifying inner backticks of a multi-backtick span.
    Operates on a single line only (no newline crossing).
    """
    # Work on the content without the newline, reattach at end
    nl = ""
    content = line
    if line.endswith("\r\n"):
        nl = "\r\n"
        content = line[:-2]
    elif line.endswith(("\n", "\r")):
        nl = line[-1]
        content = line[:-1]

    # Replace inline code spans, longest delimiter first to avoid
    # treating `` as two ` spans
    for n_ticks in range(6, 0, -1):
        delim = "`" * n_ticks
        # Find balanced pairs
        out = []
        i = 0
        while i < len(content):
            if content[i:i + n_ticks] == delim and (i == 0 or content[i - 1] != "`"):
                # Check it's not a longer run (e.g. ``` when n_ticks=2)
                if (i == 0 or content[i - 1] != "`") and (i + n_ticks >= len(content) or content[i + n_ticks] != "`"):
                    # Find closing delimiter
                    close = content.find(delim, i + n_ticks)
                    # Closing must also not be part of a longer run
                    while close != -1 and close + n_ticks < len(content) and content[close + n_ticks] == "`":
                        close = content.find(delim, close + 1)
                    if close != -1:
                        # Replace the entire span (delimiters + content) with spaces
                        span_len = close + n_ticks - i
                        out.append(" " * span_len)
                        i = close + n_ticks
                        continue
            out.append(content[i])
            i += 1
        content = "".join(out)

    return content + nl


# ---------------------------------------------------------------------------
# Wikilink extractor
# ---------------------------------------------------------------------------

# Matches [[target]], [[target|alias]], [[target#heading]]. The (?<!!) negative
# lookbehind excludes ![[...]] embeds: an embed is a distinct Obsidian construct
# that may legitimately target a non-.md attachment (image, PDF) outside the
# .md-only vault index. The broken-wikilink check is specced for [[wikilinks]]
# only -- see lint-surface.md's check inventory.
WIKILINK_RE = re.compile(r"(?<!!)\[\[([^\]|#]+)(?:[|#][^\]]*)?\]\]")


def extract_wikilinks(body: str) -> list[str]:
    """Return list of wikilink targets (the part before | or #)."""
    return [m.group(1).strip() for m in WIKILINK_RE.finditer(body)]


def resolve_wikilink(target: str, vault_index: dict[str, Path], vault_root: Path) -> bool:
    """Return True if the wikilink target resolves to an existing file.

    Implements Obsidian's resolution rules:
    1. Bare name (no '/'): matches any vault .md file whose stem equals the target.
    2. Path-qualified (contains '/'): matches any vault .md file whose vault-relative
       path (no .md extension) ends with the target on a path-segment boundary.
       e.g. [[Knowledge/foo]] matches System/Knowledge/foo.md but NOT
       System/OtherKnowledge/foo.md (segment boundary enforced).
    Matching is case-insensitive throughout.
    """
    t_lower = target.lower().strip()
    # Strip .md extension from target if present, for normalised comparison
    if t_lower.endswith(".md"):
        t_lower = t_lower[:-3]

    if "/" not in t_lower:
        # --- Rule 1: bare name — exact stem match ---
        # vault_index maps stem -> Path for all vault .md files
        return t_lower in vault_index
    else:
        # --- Rule 2: path-qualified — segment-boundary suffix match ---
        # vault_index maps rel_noext (e.g. "system/knowledge/foo") -> Path for all vault
        # .md files.  We need to find any key whose segments end with the target's
        # segments.
        target_parts = tuple(t_lower.split("/"))
        target_len = len(target_parts)
        for key in vault_index:
            # Only check keys that look like paths (contain "/") to avoid testing stem
            # entries or keys that are too short.
            if "/" not in key:
                continue
            key_parts = tuple(key.split("/"))
            if len(key_parts) >= target_len and key_parts[-target_len:] == target_parts:
                return True
        return False


# ---------------------------------------------------------------------------
# Topic consolidation — Jaccard 3-gram + same-stem
# ---------------------------------------------------------------------------

def _trigrams(s: str) -> set[str]:
    s = s.lower()
    return {s[i : i + 3] for i in range(len(s) - 2)} if len(s) >= 3 else set()


def find_topic_consolidation_candidates(
    topic_tags: list[str],
) -> list[tuple[str, str, str]]:
    """
    Return list of (tag_a, tag_b, reason) for candidate pairs.
    topic_tags: list of full "topic/xxx" tags.
    """
    # deduplicate
    unique = list(set(topic_tags))
    # Extract the value part
    values = [t[len("topic/"):] for t in unique]
    candidates = []
    seen = set()

    for i, a in enumerate(values):
        for b in values[i + 1 :]:
            pair = tuple(sorted([a, b]))
            if pair in seen:
                continue
            seen.add(pair)
            # Jaccard on 3-grams
            tg_a = _trigrams(a)
            tg_b = _trigrams(b)
            if tg_a or tg_b:
                union = tg_a | tg_b
                inter = tg_a & tg_b
                if union:
                    jaccard = len(inter) / len(union)
                    if jaccard >= 0.6:
                        candidates.append(
                            (f"topic/{a}", f"topic/{b}", f"Jaccard={jaccard:.2f}")
                        )
                        continue
            # Same-stem: one is prefix/suffix of the other, length-delta ≤ 3
            la, lb = len(a), len(b)
            if abs(la - lb) <= 3:
                shorter, longer = (a, b) if la <= lb else (b, a)
                if longer.startswith(shorter) or longer.endswith(shorter):
                    candidates.append(
                        (f"topic/{a}", f"topic/{b}", "same-stem (prefix/suffix)")
                    )

    # Group by shared 4-6 char stem (groups of 3+)
    # Fix H: replace convoluted O(n²) `already` dedup with a simple per-pair `seen` check.
    # The old code built a set of all group pairs and tested if any `seen` pair was in it —
    # backwards and quadratic.  The correct check is just `pair not in seen` per pair,
    # which is what the inner loop already does when it emits.  The outer `already` gate
    # is dropped; the inner `if pair not in seen` is the only guard needed.
    stem_groups: dict[str, list[str]] = defaultdict(list)
    for v in values:
        for length in range(4, 7):
            if len(v) >= length:
                stem_groups[v[:length]].append(v)
    for stem, group in stem_groups.items():
        group = list(set(group))
        if len(group) >= 3:
            group_tags = [f"topic/{v}" for v in sorted(group)]
            for i, ta in enumerate(group_tags):
                for tb in group_tags[i + 1:]:
                    pair = tuple(sorted([ta[6:], tb[6:]]))
                    if pair not in seen:
                        seen.add(pair)
                        candidates.append(
                            (ta, tb, f"shared stem '{stem}' (group of {len(group)})")
                        )
    return candidates


# ---------------------------------------------------------------------------
# SHA-256 file hashing
# ---------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

def manifest_path(state_dir: Path, scope_paths: list[Path]) -> Path:
    key = hashlib.sha256(
        "|".join(sorted(str(p) for p in scope_paths)).encode()
    ).hexdigest()[:16]
    return state_dir / f"manifest-{key}.json"


def load_manifest(mpath: Path) -> dict[str, str]:
    if mpath.exists():
        try:
            data = json.loads(mpath.read_text(encoding="utf-8"))
            return data.get("files", {})
        except Exception:
            return {}
    return {}


def save_manifest(mpath: Path, files: dict[str, str]) -> None:
    mpath.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "files": files,
    }
    mpath.write_text(json.dumps(data, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Destination classification
# ---------------------------------------------------------------------------

def classify_destination(file_path: Path, vault_root: Path) -> str:
    """
    Returns 'wiki' if under Wiki/Knowledge or Wiki/Contexts;
    'project' if under Projects/<name>/Knowledge, Projects/<name>/Context,
      System/ root, System/Knowledge, or System/Context;
    'other' otherwise.

    NOTE: this only classifies the *destination class* (which scope tag a
    governed file needs).  Whether a file is governed *at all* is decided by
    is_governed_location() — the Location Gate — which is the outer filter.
    Wiki/Data is intentionally NOT 'wiki' here: it is domain content, out of
    governed scope entirely (see is_governed_location).
    """
    try:
        rel = file_path.relative_to(vault_root)
    except ValueError:
        return "other"
    parts = rel.parts
    if not parts:
        return "other"
    top = parts[0]
    if top == "Wiki":
        if len(parts) >= 2 and parts[1] in ("Knowledge", "Contexts"):
            return "wiki"
        return "other"
    if top == "System":
        return "project"
    if top == "Projects":
        if len(parts) >= 3 and parts[2] in ("Knowledge", "Context"):
            return "project"
        return "other"
    return "other"


# Folder/file name segments that mark a file as an archive, out of governed
# scope regardless of location.  Source: structural-contract.md › Scope
# Boundaries › Location Gate prose ("Archives").
_ARCHIVE_DIR_SEGMENTS = {"archived", "archive"}


def is_governed_location(file_path: Path, vault_root: Path) -> bool:
    """Location Gate — the outer filter of the knowledge-layer scope boundary.

    Returns True only if the file's vault path is a governed knowledge-layer
    location per structural-contract.md › Scope Boundaries › Location Gate:

      - System/*.md            (System project root, depth-1 .md only)
      - System/Knowledge/**
      - System/Context/**
      - Projects/<name>/Knowledge/**
      - Projects/<name>/Context/**
      - Wiki/Knowledge/**
      - Wiki/Contexts/**

    Every other path is ungoverned: domain content (Wiki/Data/**), operational
    records (Recruiting Roles/Playbooks/Candidates), archives, raw/operational
    scratch (Projects/<name>/ working folders), Incubator cards.

    Two universal exclusions override a governed location:
      - archive files: name ends '-archive.md', or any path segment is
        'Archived'/'archive' (case-insensitive).
    """
    try:
        rel = file_path.relative_to(vault_root)
    except ValueError:
        return False
    parts = rel.parts
    if not parts:
        return False

    # --- Universal exclusion: archives ---
    if file_path.name.lower().endswith("-archive.md"):
        return False
    if any(p.lower() in _ARCHIVE_DIR_SEGMENTS for p in parts[:-1]):
        return False

    top = parts[0]

    # --- System/ ---
    if top == "System":
        # System/*.md — depth-1 .md files at the System root
        if len(parts) == 2 and parts[1].endswith(".md"):
            return True
        # System/Knowledge/** and System/Context/**
        if len(parts) >= 3 and parts[1] in ("Knowledge", "Context"):
            return True
        return False

    # --- Projects/<name>/{Knowledge,Context}/** ---
    if top == "Projects":
        if len(parts) >= 4 and parts[2] in ("Knowledge", "Context"):
            return True
        return False

    # --- Wiki/{Knowledge,Contexts}/** ---
    if top == "Wiki":
        if len(parts) >= 3 and parts[1] in ("Knowledge", "Contexts"):
            return True
        return False

    return False


def get_project_name_from_path(file_path: Path, vault_root: Path) -> str | None:
    """Return the project folder name (kebab) for a project-hosted file."""
    try:
        rel = file_path.relative_to(vault_root)
    except ValueError:
        return None
    parts = rel.parts
    if parts[0] == "System":
        return "system"
    if parts[0] == "Projects" and len(parts) >= 2:
        return kebab(parts[1])
    return None


# ---------------------------------------------------------------------------
# Index.md parsing
# ---------------------------------------------------------------------------

_INDEX_CACHE: dict[Path, set[str]] = {}


def get_index_entries(index_path: Path) -> set[str]:
    """Return set of lowercased stems/paths referenced in an index.md file."""
    if index_path in _INDEX_CACHE:
        return _INDEX_CACHE[index_path]
    if not index_path.exists():
        _INDEX_CACHE[index_path] = set()
        return set()
    text = index_path.read_text(encoding="utf-8")
    entries = set()
    # Look for wikilinks and markdown links
    for m in WIKILINK_RE.finditer(text):
        entries.add(m.group(1).strip().lower())
    # Also bare .md references
    for m in re.finditer(r"\[([^\]]+)\]\(([^)]+\.md)\)", text):
        href = m.group(2).strip()
        entries.add(href.lower())
        entries.add(Path(href).stem.lower())
    _INDEX_CACHE[index_path] = entries
    return entries


# ---------------------------------------------------------------------------
# Core lint checks
# ---------------------------------------------------------------------------

SEVERITY_ORDER = ["HIGH", "MEDIUM", "WARNING", "INFO"]


def make_finding(severity: str, check: str, file_rel: str, detail: str, suggestion: str = "",
                 tightening: bool = False) -> dict:
    f = {
        "severity": severity,
        "check": check,
        "file": file_rel,
        "detail": detail,
        "suggestion": suggestion,
    }
    if tightening:
        f["tightening"] = True
    return f


def lint_file(
    file_path: Path,
    vault_root: Path,
    vault_index: dict[str, Path],
    valid_projects: set[str],
    taxonomy: dict,
    sc: dict,
    today: datetime.date,
) -> list[dict]:
    findings = []
    try:
        text = file_path.read_text(encoding="utf-8")
    except Exception as e:
        return [make_finding("HIGH", "read-error", str(file_path), f"Cannot read file: {e}")]

    try:
        rel_path = str(file_path.relative_to(vault_root))
    except ValueError:
        rel_path = str(file_path)

    # --- Location Gate (knowledge-layer scope boundary, outer filter) ---
    # Source: structural-contract.md › Scope Boundaries › Location Gate.
    # If the file is not in a governed knowledge-layer location, lint produces
    # NO findings for it at all — domain content, operational records, archives,
    # and raw/operational scratch are out of governed scope by location.
    if not is_governed_location(file_path, vault_root):
        return []

    fm, body = parse_frontmatter(text)
    # body_clean: body with fenced code blocks and inline code spans neutralised.
    # All body-content pattern scans (wikilinks, H1 count, bare-path refs) run on
    # body_clean to avoid false positives from code examples.  Frontmatter parsing
    # and stale_suspects checks use the raw fm/body since they operate on structured
    # fields, not raw text.
    body_clean = strip_code_context(body)
    tags = fm["tags"]
    dest = classify_destination(file_path, vault_root)

    # --- Type Gate: out-of-scope type/ values ---
    # Source: structural-contract.md › Scope Boundaries › Exemption tiers,
    # "Out of scope" row.  A file carrying an out-of-scope type/ (type/data,
    # type/meeting-capture) is ungoverned wherever it sits — domain content /
    # raw capture.  No check at all.
    out_of_scope_types = sc.get("out_of_scope_types", set())
    if any(t in out_of_scope_types for t in tags):
        return []

    # --- Check: no type/ tag ---
    type_tags = [t for t in tags if t.startswith("type/")]
    if not type_tags:
        # Check if it might just be an ungoverned file (no frontmatter at all)
        findings.append(
            make_finding(
                "WARNING",
                "no-type-tag",
                rel_path,
                "No `type/` tag — ungoverned or missing classification",
                "Add a type/ tag from the closed vocabulary, or confirm this file is intentionally untagged",
            )
        )
        # Still run tag checks on whatever tags exist
        _check_tag_validity(tags, rel_path, valid_projects, taxonomy, findings)
        return findings

    # --- Exactly one type/ tag ---
    if len(type_tags) > 1:
        findings.append(
            make_finding(
                "HIGH",
                "multiple-type-tags",
                rel_path,
                f"Multiple `type/` tags found: {type_tags}",
                "Keep exactly one type/ tag",
            )
        )
    type_val = type_tags[0] if type_tags else None

    # ---- Determine exemption tier (fix A) ----
    # Source: structural-contract.md › Scope Boundaries › Exemption tiers table.
    # Parsing Contract row "Exemption tiers":
    #   - Structure-not-imposed: only tag-taxonomy tag validity; all structural-contract
    #     checks are skipped (no scope-tag, status/, updated, H1, per-type, sources, etc.).
    #   - Invariant-core-only: Invariant Core enforced; Per-Type Additions skipped.
    #   - Fully-governed (in Per-Type Additions table): Invariant Core + per-type row.
    #   - Default (any closed-vocab type/ not in either tier nor per-type): Invariant-core-only.
    # Note: multiple-type-tags check stays universal (sanity check, fires before tier logic).
    structure_not_imposed = sc["structure_not_imposed"]
    invariant_core_only = sc["invariant_core_only"]

    is_structure_not_imposed = type_val in structure_not_imposed
    is_in_per_type = type_val in sc["per_type"]
    # Fully governed = explicitly listed in per_type table (not exempted)
    is_fully_governed = is_in_per_type and not is_structure_not_imposed
    # Invariant-core-only = explicitly in invariant_core_only set, OR default (not in per_type
    # and not in structure_not_imposed)
    is_invariant_core_only = (
        type_val in invariant_core_only
        or (not is_fully_governed and not is_structure_not_imposed)
    )

    # --- Tag validity (all tags) — runs for ALL tiers ---
    _check_tag_validity(tags, rel_path, valid_projects, taxonomy, findings)

    # --- Structure-not-imposed tier: only tag validity; stop here ---
    if is_structure_not_imposed:
        # Per contract: "no structural-contract check applies; only tag-taxonomy tag validity"
        # Wikilink and stale_suspects checks are structural-contract checks; skip them.
        return findings

    # === Invariant Core checks (both invariant-core-only and fully-governed types) ===

    # --- Scope tag: ≥1 project/ or area/ ---
    scope_tags = [t for t in tags if t.startswith("project/") or t.startswith("area/")]
    if not scope_tags:
        findings.append(
            make_finding(
                "HIGH",
                "missing-scope-tag",
                rel_path,
                "No scope tag found (need ≥1 `project/` or `area/`)",
                "Add a project/ or area/ tag",
            )
        )

    # --- Scope tag matches destination ---
    if dest == "wiki":
        # Must carry area/
        area_tags = [t for t in tags if t.startswith("area/")]
        if not area_tags:
            findings.append(
                make_finding(
                    "HIGH",
                    "scope-destination-mismatch",
                    rel_path,
                    "Wiki-hosted file (under Wiki/Knowledge, Data, or Contexts) requires `area/` scope tag, found none",
                    "Add an area/ tag",
                )
            )
    elif dest == "project":
        # Must carry project/
        project_tags = [t for t in tags if t.startswith("project/")]
        if not project_tags:
            findings.append(
                make_finding(
                    "HIGH",
                    "scope-destination-mismatch",
                    rel_path,
                    "Project-hosted file (under Projects/*/Knowledge or System/) requires `project/` scope tag, found none",
                    "Add a project/ tag",
                )
            )

    # --- Exactly one status/ tag [tightening] ---
    status_tags = [t for t in tags if t.startswith("status/")]
    # tightening_checks uses clean (backtick-stripped) element names
    # e.g. "`status/` tag" → "status/ tag", "Title" → "Title"
    is_tightening_status = "status/ tag" in sc.get("tightening_checks", set())
    if len(status_tags) == 0:
        findings.append(
            make_finding(
                "HIGH",
                "missing-status-tag",
                rel_path,
                "No `status/` tag found",
                "Add a status/ tag (stub/active/archived/deprecated/draft)",
                tightening=is_tightening_status,
            )
        )
    elif len(status_tags) > 1:
        findings.append(
            make_finding(
                "HIGH",
                "multiple-status-tags",
                rel_path,
                f"Multiple `status/` tags found: {status_tags}",
                "Keep exactly one status/ tag",
                tightening=is_tightening_status,
            )
        )

    # --- updated: present and YYYY-MM-DD ---
    _check_updated(fm, rel_path, findings)

    # --- Exactly one H1 [tightening] ---
    # Uses body_clean so that shell/python comment lines (# comment) inside
    # fenced code blocks are not counted as level-1 headings.
    is_tightening_h1 = "Title" in sc.get("tightening_checks", set())
    _check_single_h1(body_clean, rel_path, findings, tightening=is_tightening_h1)

    # === Per-Type Additions (fully-governed types only) ===
    # Fix B: data-driven — driven by sc["per_type"] dict, not if-ladders per type name.
    # For invariant-core-only types, skip per-type entirely.
    if is_fully_governed and type_val in sc["per_type"]:
        pt = sc["per_type"][type_val]

        # sources requirement
        if pt["sources"] == "Required" and fm["sources"] is None:
            findings.append(
                make_finding(
                    "HIGH",
                    "missing-sources",
                    rel_path,
                    f"`{type_val}` requires `sources` frontmatter",
                    'Add sources: ["url or description"]',
                )
            )

        # topic/ requirement — conditional (Wiki-hosted only) or unconditional
        topic_tags = [t for t in tags if t.startswith("topic/")]
        if pt.get("topic_unconditional"):
            # Always required regardless of destination (e.g. type/project-pointer)
            if not topic_tags:
                findings.append(
                    make_finding(
                        "HIGH",
                        "missing-topic-tag",
                        rel_path,
                        f"`{type_val}` requires ≥1 `topic/` tag",
                        "Add a topic/ tag",
                    )
                )
        elif pt.get("topic_conditional") and dest == "wiki":
            # Required only for Wiki-hosted files (e.g. type/knowledge)
            if not topic_tags:
                findings.append(
                    make_finding(
                        "HIGH",
                        "missing-topic-wiki-knowledge",
                        rel_path,
                        f"Wiki-hosted `{type_val}` requires ≥1 `topic/` tag",
                        "Add one or more topic/ tags",
                        tightening="topic/" in sc.get("tightening_checks", set()),
                    )
                )

        # Extra required tags (e.g. project/ for type/project-pointer)
        for required_tag_prefix in pt.get("extra_tags", []):
            matching = [t for t in tags if t.startswith(required_tag_prefix + "/") or t == required_tag_prefix]
            if not matching:
                check_id = f"missing-{required_tag_prefix.split('/')[-1]}-tag"
                findings.append(
                    make_finding(
                        "HIGH",
                        check_id,
                        rel_path,
                        f"`{type_val}` requires a `{required_tag_prefix}/` tag",
                        f"Add a {required_tag_prefix}/ tag",
                    )
                )

        # Stub drift for type/project-pointer (data-driven on extra_tags having "project")
        if "project" in pt.get("extra_tags", []):
            proj_tags = [t for t in tags if t.startswith("project/")]
            for pt_tag in proj_tags:
                proj_name = pt_tag[len("project/"):]
                if "/" in proj_name:
                    continue  # grandfathered deep tags
                projects_dir = vault_root / "Projects"
                if projects_dir.exists():
                    found = any(
                        kebab(d.name) == kebab(proj_name)
                        for d in projects_dir.iterdir()
                        if d.is_dir()
                    )
                    if not found:
                        findings.append(
                            make_finding(
                                "HIGH",
                                "stub-drift",
                                rel_path,
                                f"`type/project-pointer` tag `{pt_tag}` has no matching `Projects/{proj_name}/` folder",
                                f"Create Projects/{proj_name}/ or update the pointer's project/ tag",
                            )
                        )

    # --- Structural integrity ---
    # Uses body_clean: fenced code blocks and inline code spans are blanked out so
    # bash [[ ... ]] conditionals and [[placeholder]] examples in code are not
    # extracted as wikilinks, and bare Projects/... paths in code are not flagged.
    _check_wikilinks(body_clean, rel_path, vault_root, vault_index, valid_projects, findings)

    # --- Index entry for project-hosted files ---
    if dest == "project" and file_path.name != "index.md":
        proj_name = get_project_name_from_path(file_path, vault_root)
        if proj_name:
            # Find index.md in the same Knowledge/ folder or parent
            index_path = file_path.parent / "index.md"
            if not index_path.exists():
                index_path = file_path.parent.parent / "index.md"
            if index_path.exists():
                entries = get_index_entries(index_path)
                stem = file_path.stem.lower()
                if stem not in entries:
                    findings.append(
                        make_finding(
                            "MEDIUM",
                            "missing-index-entry",
                            rel_path,
                            f"Project-hosted file has no entry in `{index_path.relative_to(vault_root)}`",
                            f"Add a [[{file_path.stem}]] wikilink to the index",
                        )
                    )
            # (If no index.md exists at all, that's a project-level gap but we don't fail per-file for it)

    # --- Context-page coverage ---
    # Checked corpus-wide, not per file (done in lint_scope)

    # --- Stale suspects ---
    _check_stale_suspects(fm, rel_path, vault_root, vault_index, findings)

    # --- Status coherence ---
    _check_status_coherence(fm, tags, rel_path, findings)

    # --- Freshness ---
    _check_freshness(fm, rel_path, today, findings)

    return findings


def _check_updated(fm: dict, rel_path: str, findings: list) -> None:
    updated = fm.get("updated")
    if not updated:
        findings.append(
            make_finding(
                "HIGH",
                "missing-updated",
                rel_path,
                "`updated` frontmatter field is absent",
                "Add `updated: YYYY-MM-DD`",
            )
        )
    else:
        updated_str = str(updated)
        # Strip time component if datetime-like
        date_m = re.match(r"(\d{4}-\d{2}-\d{2})", updated_str)
        if not date_m:
            findings.append(
                make_finding(
                    "HIGH",
                    "invalid-updated-format",
                    rel_path,
                    f"`updated` value `{updated_str}` is not YYYY-MM-DD",
                    "Set updated: YYYY-MM-DD",
                )
            )


def _check_single_h1(body: str, rel_path: str, findings: list, tightening: bool = False) -> None:
    """Check exactly one H1. tightening=True marks this as a [tightening] rule (fix F)."""
    h1_matches = re.findall(r"^# .+", body, re.MULTILINE)
    if len(h1_matches) == 0:
        findings.append(
            make_finding(
                "HIGH",
                "missing-h1",
                rel_path,
                "No level-1 heading (`# Title`) found in body",
                "Add exactly one # Title heading",
                tightening=tightening,
            )
        )
    elif len(h1_matches) > 1:
        findings.append(
            make_finding(
                "HIGH",
                "multiple-h1",
                rel_path,
                f"Multiple level-1 headings found ({len(h1_matches)})",
                "Keep exactly one # Title heading",
                tightening=tightening,
            )
        )


def _check_tag_validity(
    tags: list[str],
    rel_path: str,
    valid_projects: set[str],
    taxonomy: dict,
    findings: list,
) -> None:
    ns_prefixes = taxonomy["namespace_prefixes"]
    type_vocab = taxonomy["type_vocab"]
    status_vocab = taxonomy["status_vocab"]
    depth_limits = taxonomy["depth_limits"]
    area_top_levels = taxonomy["area_top_levels"]
    person_roster = taxonomy["person_roster"]
    grandfathered = taxonomy["grandfathered_project_prefixes"]

    for tag in tags:
        parts = tag.split("/")
        ns = parts[0] if parts else ""

        # Legacy people/* tags
        if ns == "people":
            findings.append(
                make_finding(
                    "MEDIUM",
                    "legacy-people-tag",
                    rel_path,
                    f"Legacy `people/*` tag `{tag}` — migrate to `person/<kebab-name>`",
                    f"Replace with person/{parts[1].replace('_', '-') if len(parts) > 1 else '?'}",
                )
            )
            continue

        # Legacy phase/* tags
        if ns == "phase":
            findings.append(
                make_finding(
                    "MEDIUM",
                    "legacy-phase-tag",
                    rel_path,
                    f"Legacy `phase/*` tag `{tag}` — migrate to `status/<value>`",
                    "Replace with status/active, status/stub, etc.",
                )
            )
            continue

        # Namespace membership
        if ns not in ns_prefixes:
            findings.append(
                make_finding(
                    "HIGH",
                    "unknown-namespace",
                    rel_path,
                    f"Tag `{tag}` uses unknown namespace `{ns}` (not in {ns_prefixes})",
                    "Use one of the six registered namespaces, or update tag-taxonomy.md",
                )
            )
            continue

        # Depth limits
        max_depth = depth_limits.get(ns, {}).get("max", 2)
        actual_depth = len(parts)
        if actual_depth > max_depth:
            # Check grandfathered project tags
            is_grandfathered = any(tag.startswith(gp) for gp in grandfathered)
            if not is_grandfathered:
                findings.append(
                    make_finding(
                        "HIGH",
                        "tag-depth-exceeded",
                        rel_path,
                        f"Tag `{tag}` has depth {actual_depth}, exceeds max {max_depth} for namespace `{ns}`",
                        f"Split into multiple tags across namespaces",
                    )
                )

        # Closed vocab: type/
        if ns == "type":
            deprecated_types = taxonomy.get("deprecated_types", set())
            if tag not in type_vocab:
                findings.append(
                    make_finding(
                        "HIGH",
                        "unknown-type-tag",
                        rel_path,
                        f"Unknown `type/` value `{tag}` (not in closed vocabulary)",
                        "Use a value from tag-taxonomy.md's type/ vocabulary",
                    )
                )
            elif tag in deprecated_types:
                # Fix C: emit MEDIUM deprecated-type instead of hardcoding type/raw.
                # The deprecated set is parsed at runtime from tag-taxonomy.md: any type/
                # whose Meaning cell contains "Deprecated" is added to the set.
                findings.append(
                    make_finding(
                        "MEDIUM",
                        "deprecated-type",
                        rel_path,
                        f"`{tag}` is deprecated — see tag-taxonomy.md for the replacement",
                        f"Retag this file away from `{tag}`",
                    )
                )

        # Closed vocab: status/
        elif ns == "status":
            if tag not in status_vocab:
                findings.append(
                    make_finding(
                        "HIGH",
                        "unknown-status-tag",
                        rel_path,
                        f"Unknown `status/` value `{tag}` (not in closed vocabulary)",
                        "Use one of: stub, active, archived, deprecated, draft",
                    )
                )

        # Closed vocab: project/
        elif ns == "project":
            proj_name = "/".join(parts[1:])
            # Check if grandfathered
            is_grandfathered = any(tag.startswith(gp) for gp in grandfathered)
            if not is_grandfathered:
                # Get the first segment
                first_seg = parts[1] if len(parts) > 1 else ""
                if first_seg not in valid_projects and first_seg:
                    findings.append(
                        make_finding(
                            "HIGH",
                            "unknown-project-tag",
                            rel_path,
                            f"Unknown `project/` value `{tag}` — no matching `Projects/{first_seg}/` folder",
                            "Create the project folder or fix the tag",
                        )
                    )

        # area/ recognition
        elif ns == "area":
            if len(parts) >= 2 and area_top_levels:
                top = parts[1]
                if top not in area_top_levels:
                    findings.append(
                        make_finding(
                            "WARNING",
                            "unrecognized-area-tag",
                            rel_path,
                            f"Unrecognized `area/` top-level `{top}` in tag `{tag}`",
                            "Check tag-taxonomy.md's area/ top-levels; add if new area is intentional",
                        )
                    )

        # person/ recognition
        elif ns == "person":
            if len(parts) >= 2:
                person_key = "-".join(parts[1:]).lower()
                if person_roster and person_key not in person_roster:
                    findings.append(
                        make_finding(
                            "WARNING",
                            "unrecognized-person-tag",
                            rel_path,
                            f"Unrecognized `person/` value `{tag}` — not in current roster",
                            "Add to roster in tag-taxonomy.md on second+ appearance, or check spelling",
                        )
                    )


def _check_wikilinks(
    body: str,
    rel_path: str,
    vault_root: Path,
    vault_index: dict[str, Path],
    valid_projects: set[str],
    findings: list,
) -> None:
    links = extract_wikilinks(body)
    for target in links:
        if not resolve_wikilink(target, vault_index, vault_root):
            # MEDIUM, not HIGH: a broken wikilink is vault entropy (renamed/moved/
            # uncreated target), not a knowledge-layer *envelope* violation.
            # Source: lint-surface.md › Structural integrity table.
            findings.append(
                make_finding(
                    "MEDIUM",
                    "broken-wikilink",
                    rel_path,
                    f"Broken wikilink `[[{target}]]` — target not found in vault",
                    f"Create the target note or fix the link text",
                )
            )
        else:
            # Cross-project reference check
            # Is the target in a different project?
            _check_cross_project_link(target, rel_path, vault_root, vault_index, valid_projects, findings)

    # Also check for bare path-shaped cross-project references (not wikilinks)
    # Pattern: Projects/Other/... in text but NOT inside [[...]]
    bare_proj_re = re.compile(r"(?<!\[\[)Projects/(\w[\w\s-]+)/")
    src_proj = None
    # Determine source project from path
    parts = Path(rel_path).parts
    if len(parts) >= 2 and parts[0] == "Projects":
        src_proj = kebab(parts[1])

    for m in bare_proj_re.finditer(body):
        tgt_proj = kebab(m.group(1))
        if src_proj and tgt_proj != src_proj:
            findings.append(
                make_finding(
                    "MEDIUM",
                    "cross-project-bare-path",
                    rel_path,
                    f"Bare path reference `{m.group(0)}...` crosses project boundary — use `[[wikilink]]` instead",
                    "Wrap the reference in [[...]]",
                )
            )


def _check_cross_project_link(
    target: str,
    rel_path: str,
    vault_root: Path,
    vault_index: dict[str, Path],
    valid_projects: set[str],
    findings: list,
) -> None:
    """Check if a wikilink target crosses a project boundary."""
    # Determine source project
    src_parts = Path(rel_path).parts
    src_proj = None
    if len(src_parts) >= 2 and src_parts[0] == "Projects":
        src_proj = kebab(src_parts[1])

    if src_proj is None:
        return  # Not in a project, no cross-project check needed

    # Resolve target using the same Obsidian-compatible rules as resolve_wikilink
    t_lower = target.lower().strip()
    if t_lower.endswith(".md"):
        t_lower = t_lower[:-3]
    resolved: Path | None = None
    if "/" not in t_lower:
        # Bare name: exact stem match
        if t_lower in vault_index:
            resolved = vault_index[t_lower]
    else:
        # Path-qualified: segment-boundary suffix match
        target_parts = tuple(t_lower.split("/"))
        target_len = len(target_parts)
        for key, path in vault_index.items():
            if "/" not in key:
                continue
            key_parts = tuple(key.split("/"))
            if len(key_parts) >= target_len and key_parts[-target_len:] == target_parts:
                resolved = path
                break

    if resolved is None:
        return  # Already flagged as broken

    try:
        tgt_rel_parts = resolved.relative_to(vault_root).parts
    except ValueError:
        return

    if len(tgt_rel_parts) >= 2 and tgt_rel_parts[0] == "Projects":
        tgt_proj = kebab(tgt_rel_parts[1])
        if tgt_proj != src_proj:
            # Cross-project wikilink — already a wikilink (good), just verify it resolves
            # (it does, we checked above). No additional finding needed beyond broken-wikilink.
            pass


def _check_status_coherence(fm: dict, tags: list[str], rel_path: str, findings: list) -> None:
    """If both scalar status: and status/ tag exist, they must match."""
    scalar_status = fm.get("status")
    if not scalar_status:
        return
    status_tags = [t for t in tags if t.startswith("status/")]
    if not status_tags:
        return
    status_tag_val = status_tags[0][len("status/"):]
    if scalar_status.lower() != status_tag_val.lower():
        findings.append(
            make_finding(
                "HIGH",
                "status-coherence",
                rel_path,
                f"Scalar `status: {scalar_status}` conflicts with `status/` tag `{status_tags[0]}`",
                f"Remove the scalar `status:` field (use only the tag)",
            )
        )


def _check_freshness(fm: dict, rel_path: str, today: datetime.date, findings: list) -> None:
    """Stale (>90 days) and unverified checks."""
    STALE_DAYS = 90
    updated_str = fm.get("updated")
    verified_str = fm.get("verified")

    # Use verified if present, otherwise updated
    check_date_str = verified_str if verified_str else updated_str
    if not check_date_str:
        return

    check_date_str = str(check_date_str)
    date_m = re.match(r"(\d{4}-\d{2}-\d{2})", check_date_str)
    if not date_m:
        return

    try:
        check_date = datetime.date.fromisoformat(date_m.group(1))
    except ValueError:
        return

    age_days = (today - check_date).days

    if age_days > STALE_DAYS:
        field_used = "verified" if verified_str else "updated"
        findings.append(
            make_finding(
                "WARNING",
                "stale",
                rel_path,
                f"Content may be stale: `{field_used}` is {age_days} days ago ({date_m.group(1)})",
                "Review content and update the `verified` date if still accurate",
            )
        )
    # The `unverified` check (updated present, verified absent) is SUPPRESSED.
    # Source: lint-surface.md › Freshness table — `[suppressed]`.  `verified` has
    # no producer in the vault today; nothing sets it, so the check would fire on
    # essentially every governed file — pure noise.  Re-enable (restore the
    # `elif not verified_str and updated_str:` INFO branch here) once a
    # `verified`-writing stewardship step exists.


def _check_stale_suspects(
    fm: dict,
    rel_path: str,
    vault_root: Path,
    vault_index: dict[str, Path],
    findings: list,
) -> None:
    suspects = fm.get("stale_suspects")
    if not suspects:
        return
    for suspect_path in suspects:
        if not resolve_wikilink(suspect_path, vault_index, vault_root):
            findings.append(
                make_finding(
                    "WARNING",
                    "stale-suspects-missing-target",
                    rel_path,
                    f"`stale_suspects` path `{suspect_path}` does not resolve to an existing file",
                    "Remove or update the stale_suspects entry",
                )
            )


# ---------------------------------------------------------------------------
# Corpus-scale checks
# ---------------------------------------------------------------------------

def check_orphan_index_entries(
    scope_files: list[Path],
    vault_root: Path,
    vault_index: dict[str, Path],
) -> list[dict]:
    """Find index.md entries that reference non-existent files."""
    findings = []
    # Only index.md files in governed locations are checked — an index in an
    # ungoverned folder (operational/raw scratch) is out of scope.
    index_files = [
        f for f in scope_files
        if f.name == "index.md" and is_governed_location(f, vault_root)
    ]
    for idx_path in index_files:
        rel_idx = str(idx_path.relative_to(vault_root))
        entries = get_index_entries(idx_path)
        for entry in entries:
            # Check if entry resolves
            if not resolve_wikilink(entry, vault_index, vault_root):
                findings.append(
                    make_finding(
                        "MEDIUM",
                        "orphan-index-entry",
                        rel_idx,
                        f"Index entry `{entry}` does not resolve to an existing file",
                        "Remove or fix the entry in index.md",
                    )
                )
    return findings


def check_context_page_coverage(
    scope_files: list[Path],
    vault_root: Path,
    vault_index: dict[str, Path],
    taxonomy: dict,
) -> list[dict]:
    """
    For each area/ with Knowledge files, check that a
    Wiki/Contexts/{domain}-context.md exists.
    """
    findings = []
    contexts_dir = vault_root / "Wiki" / "Contexts"

    # Collect area/ namespaces that have Knowledge files
    area_namespaces: set[str] = set()
    for f in scope_files:
        try:
            rel_parts = f.relative_to(vault_root).parts
        except ValueError:
            continue
        if len(rel_parts) >= 2 and rel_parts[0] == "Wiki" and rel_parts[1] == "Knowledge":
            try:
                text = f.read_text(encoding="utf-8")
                fm, _ = parse_frontmatter(text)
                for tag in fm["tags"]:
                    if tag.startswith("area/"):
                        parts = tag.split("/")
                        if len(parts) >= 2:
                            # Use the top-level area segment as domain key
                            area_namespaces.add(parts[1])
            except Exception:
                pass

    # Check for context pages
    for area_ns in area_namespaces:
        context_name = f"{area_ns}-context"
        if not resolve_wikilink(context_name, vault_index, vault_root):
            # Also try area_ns directly
            alt_context = f"{area_ns}"
            if not resolve_wikilink(alt_context + "-context", vault_index, vault_root):
                findings.append(
                    make_finding(
                        "WARNING",
                        "missing-context-page",
                        f"Wiki/Contexts/{area_ns}-context.md",
                        f"`area/{area_ns}` has Knowledge files but no `Wiki/Contexts/{area_ns}-context.md`",
                        f"Create Wiki/Contexts/{area_ns}-context.md as a context page",
                    )
                )
    return findings


def check_topic_consolidation(all_files_findings_tags: list[list[str]]) -> list[dict]:
    """Run topic consolidation candidate detection across all topic/ tags."""
    all_topics = []
    for tags in all_files_findings_tags:
        all_topics.extend(t for t in tags if t.startswith("topic/"))

    candidates = find_topic_consolidation_candidates(all_topics)
    findings = []
    for a, b, reason in candidates:
        findings.append(
            make_finding(
                "INFO",
                "topic-consolidation-candidate",
                "(corpus)",
                f"Possible consolidation candidates: `{a}` and `{b}` — {reason} [heuristic — review required]",
                "Consider merging these topic/ tags if they cover the same concept",
            )
        )
    return findings


# ---------------------------------------------------------------------------
# Main lint runner
# ---------------------------------------------------------------------------

def walk_scope(scope_paths: list[Path]) -> list[Path]:
    """Return all .md files under the given scope directories."""
    files = []
    for p in scope_paths:
        if p.is_file() and p.suffix == ".md":
            files.append(p)
        elif p.is_dir():
            for f in sorted(p.rglob("*.md")):
                files.append(f)
    return files


def run_lint(
    scope_paths: list[Path],
    vault_root: Path,
    state_dir: Path | None,
    no_manifest: bool,
    taxonomy: dict,
    sc: dict,
) -> dict:
    today = datetime.date.today()

    # Walk scope
    scope_files = walk_scope(scope_paths)

    # Build vault index (for wikilink resolution)
    vault_index = build_vault_index(vault_root)

    # Enumerate valid projects
    valid_projects = enumerate_projects(vault_root)

    # Manifest / delta
    delta = {"changed": [], "new": [], "deleted": []}
    if not no_manifest and state_dir is not None:
        mpath = manifest_path(state_dir, scope_paths)
        old_manifest = load_manifest(mpath)
        new_manifest: dict[str, str] = {}

        for f in scope_files:
            try:
                rel = str(f.relative_to(vault_root))
            except ValueError:
                rel = str(f)
            h = sha256_file(f)
            new_manifest[rel] = h
            if rel not in old_manifest:
                delta["new"].append(rel)
            elif old_manifest[rel] != h:
                delta["changed"].append(rel)

        for old_rel in old_manifest:
            if old_rel not in new_manifest:
                delta["deleted"].append(old_rel)

        save_manifest(mpath, new_manifest)

    # Per-file lint
    all_findings = []
    all_tags_by_file: list[list[str]] = []

    for f in scope_files:
        file_findings = lint_file(f, vault_root, vault_index, valid_projects, taxonomy, sc, today)
        all_findings.extend(file_findings)
        # Collect tags for corpus checks — only from governed-location files, so
        # topic-consolidation candidates aren't drawn from ungoverned domain
        # content (Location Gate; structural-contract.md › Scope Boundaries).
        if not is_governed_location(f, vault_root):
            continue
        try:
            text = f.read_text(encoding="utf-8")
            fm, _ = parse_frontmatter(text)
            all_tags_by_file.append(fm["tags"])
        except Exception:
            all_tags_by_file.append([])

    # Corpus-scale checks
    all_findings.extend(check_orphan_index_entries(scope_files, vault_root, vault_index))
    all_findings.extend(check_context_page_coverage(scope_files, vault_root, vault_index, taxonomy))
    all_findings.extend(check_topic_consolidation(all_tags_by_file))

    # Summary
    summary = {s: 0 for s in SEVERITY_ORDER}
    clean = 0
    files_with_findings: set[str] = set()
    for f_finding in all_findings:
        summary[f_finding["severity"]] += 1
        files_with_findings.add(f_finding["file"])
    scanned = len(scope_files)
    clean = scanned - len(files_with_findings)

    scope_strs = [str(p) for p in scope_paths]

    return {
        "scope": scope_strs,
        "scanned": scanned,
        "delta": delta if not no_manifest else {"changed": None, "new": None, "deleted": None},
        "findings": all_findings,
        "summary": {**summary, "clean": clean},
    }


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------

def format_text(result: dict) -> str:
    lines = []
    lines.append(f"Lint report — scanned {result['scanned']} files")
    lines.append(f"Scope: {', '.join(result['scope'])}")
    delta = result.get("delta", {})
    if delta.get("changed") is not None:
        lines.append(
            f"Delta: {len(delta['changed'])} changed, {len(delta['new'])} new, {len(delta['deleted'])} deleted"
        )
    lines.append("")

    findings = result["findings"]
    if not findings:
        lines.append("No findings. All files clean.")
    else:
        for severity in SEVERITY_ORDER:
            group = [f for f in findings if f["severity"] == severity]
            if not group:
                continue
            lines.append(f"{'='*60}")
            lines.append(f"{severity} ({len(group)} findings)")
            lines.append(f"{'='*60}")
            for finding in group:
                lines.append(f"  [{finding['check']}] {finding['file']}")
                lines.append(f"    {finding['detail']}")
                if finding.get("suggestion"):
                    lines.append(f"    -> {finding['suggestion']}")
            lines.append("")

    s = result["summary"]
    lines.append(f"{'='*60}")
    lines.append("Summary")
    lines.append(f"{'='*60}")
    lines.append(
        f"  HIGH={s['HIGH']}  MEDIUM={s['MEDIUM']}  WARNING={s['WARNING']}  INFO={s['INFO']}  clean={s['clean']}/{result['scanned']}"
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mechanical lint pass for the Obsidian vault knowledge-integrity system."
    )
    parser.add_argument(
        "scope",
        nargs="+",
        metavar="SCOPE_PATH",
        help="One or more directory (or file) paths to lint recursively.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit findings as JSON to stdout.",
    )
    parser.add_argument(
        "--format",
        choices=["text", "json"],
        default=None,
        help="Output format (text or json). Overrides --json.",
    )
    parser.add_argument(
        "--state-dir",
        default=os.path.expanduser("~/.cache/lint-knowledge"),
        help="Directory for manifest storage (default: ~/.cache/lint-knowledge/).",
    )
    parser.add_argument(
        "--no-manifest",
        action="store_true",
        help="Stateless run: skip manifest read/write and delta computation.",
    )
    parser.add_argument(
        "--vault-root",
        default=os.path.expanduser("~/Vaults/Notes"),
        help="Vault root for wikilink resolution and contract doc lookup.",
    )
    args = parser.parse_args()

    # Resolve output format
    emit_json = args.json or (args.format == "json")

    vault_root = Path(args.vault_root).expanduser().resolve()

    # Load contract docs
    taxonomy_path = vault_root / "System" / "tag-taxonomy.md"
    sc_path = vault_root / "System" / "structural-contract.md"

    if not taxonomy_path.exists():
        print(f"ERROR: tag-taxonomy.md not found at {taxonomy_path}", file=sys.stderr)
        return 2
    if not sc_path.exists():
        print(f"ERROR: structural-contract.md not found at {sc_path}", file=sys.stderr)
        return 2

    try:
        taxonomy = parse_tag_taxonomy(taxonomy_path)
    except ValueError as e:
        print(f"ERROR parsing tag-taxonomy.md: {e}", file=sys.stderr)
        return 2

    try:
        sc = parse_structural_contract(sc_path)
    except ValueError as e:
        print(f"ERROR parsing structural-contract.md: {e}", file=sys.stderr)
        return 2

    # Resolve scope paths
    scope_paths = []
    for s in args.scope:
        p = Path(s).expanduser().resolve()
        if not p.exists():
            print(f"ERROR: scope path does not exist: {p}", file=sys.stderr)
            return 2
        scope_paths.append(p)

    state_dir = None if args.no_manifest else Path(args.state_dir).expanduser()

    # Run
    try:
        result = run_lint(
            scope_paths=scope_paths,
            vault_root=vault_root,
            state_dir=state_dir,
            no_manifest=args.no_manifest,
            taxonomy=taxonomy,
            sc=sc,
        )
    except Exception as e:
        import traceback
        print(f"ERROR during lint run: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 1

    if emit_json:
        print(json.dumps(result, indent=2))
    else:
        print(format_text(result))

    return 0


if __name__ == "__main__":
    sys.exit(main())
