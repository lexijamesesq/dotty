#!/usr/bin/env bash
# github-policy.sh
#
# Per-project policy reader for /github-prep and /github-push.
#
# Usage (source, then call):
#   source ~/bin/dotty/.claude/lib/github-policy.sh
#   load_policy "$REPO_ROOT"
#   echo "$GH_POLICY_VISIBILITY"
#   echo "$GH_POLICY_PREP_STRICTNESS"
#   echo "$GH_POLICY_HASH"
#
# Reads .claude/github-policy.yaml at REPO_ROOT (if present), merges with
# conservative defaults (treat as public, prep_required, no force push), and
# computes a deterministic policy_hash from the parsed-and-sorted JSON
# representation (not raw YAML bytes — line endings post-git-pull differ).
#
# Spec: ~/Vaults/Notes/Claude/System/Knowledge/github-skills-implementation.md

# Conservative defaults applied when no policy file or fields missing
_gh_policy_defaults() {
    cat <<'EOF'
{
  "visibility": "public",
  "main_branch": "main",
  "main_branch_protection": "direct_push",
  "prep": {
    "required": true,
    "strictness": "strict",
    "ttl_hours": 24
  },
  "allowed_force_push_targets": [],
  "protected_branches": ["main"],
  "secret_scanning_baseline": null,
  "treat_as_public_for_secrets": false
}
EOF
}

# Convert YAML to JSON via yq if available, else minimal awk fallback.
# yq is preferred — it's the standard tool. If absent, we fall back to defaults
# rather than misparse YAML.
_gh_policy_yaml_to_json() {
    local yaml_file="$1"
    if command -v yq >/dev/null 2>&1; then
        yq -o=json '.' "$yaml_file" 2>/dev/null
        return $?
    fi
    return 1
}

# Hash the parsed-and-sorted JSON (deterministic across machines)
_gh_policy_hash() {
    local json="$1"
    if command -v jq >/dev/null 2>&1; then
        # Sort keys recursively, then sha256 the canonical form
        printf '%s' "$json" | jq -cS '.' 2>/dev/null | shasum -a 256 | awk '{print "sha256:" $1}'
    else
        printf 'sha256:no-jq-available'
    fi
}

# Main entry: load_policy <repo_root>
# Sets GH_POLICY_* environment variables in the calling shell.
load_policy() {
    local repo_root="${1:-$PWD}"
    local policy_file="$repo_root/.claude/github-policy.yaml"
    local merged_json defaults_json policy_json

    defaults_json=$(_gh_policy_defaults)

    if [[ -r "$policy_file" ]] && command -v yq >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        policy_json=$(_gh_policy_yaml_to_json "$policy_file")
        if [[ -n "$policy_json" ]]; then
            # Deep-merge: defaults <- declared (declared wins)
            merged_json=$(jq -cn --argjson d "$defaults_json" --argjson p "$policy_json" '$d * $p' 2>/dev/null)
            [[ -z "$merged_json" ]] && merged_json="$defaults_json"
        else
            merged_json="$defaults_json"
        fi
    else
        merged_json="$defaults_json"
    fi

    # Export typed accessors (jq required for clean field extraction)
    if command -v jq >/dev/null 2>&1; then
        export GH_POLICY_VISIBILITY=$(jq -r '.visibility' <<<"$merged_json")
        export GH_POLICY_MAIN_BRANCH=$(jq -r '.main_branch' <<<"$merged_json")
        export GH_POLICY_MAIN_BRANCH_PROTECTION=$(jq -r '.main_branch_protection' <<<"$merged_json")
        export GH_POLICY_PREP_REQUIRED=$(jq -r '.prep.required' <<<"$merged_json")
        export GH_POLICY_PREP_STRICTNESS=$(jq -r '.prep.strictness' <<<"$merged_json")
        export GH_POLICY_PREP_TTL_HOURS=$(jq -r '.prep.ttl_hours' <<<"$merged_json")
        export GH_POLICY_FORCE_PUSH_TARGETS=$(jq -r '.allowed_force_push_targets | join(",")' <<<"$merged_json")
        export GH_POLICY_PROTECTED_BRANCHES=$(jq -r '.protected_branches | join(",")' <<<"$merged_json")
        export GH_POLICY_SECRET_SCANNING_BASELINE=$(jq -r '.secret_scanning_baseline // ""' <<<"$merged_json")
        export GH_POLICY_TREAT_AS_PUBLIC_FOR_SECRETS=$(jq -r '.treat_as_public_for_secrets' <<<"$merged_json")
        export GH_POLICY_HASH=$(_gh_policy_hash "$merged_json")
        export GH_POLICY_JSON="$merged_json"
        return 0
    fi

    # No jq: defaults only, no hash
    export GH_POLICY_VISIBILITY="public"
    export GH_POLICY_MAIN_BRANCH="main"
    export GH_POLICY_MAIN_BRANCH_PROTECTION="direct_push"
    export GH_POLICY_PREP_REQUIRED="true"
    export GH_POLICY_PREP_STRICTNESS="strict"
    export GH_POLICY_PREP_TTL_HOURS="24"
    export GH_POLICY_FORCE_PUSH_TARGETS=""
    export GH_POLICY_PROTECTED_BRANCHES="main"
    export GH_POLICY_SECRET_SCANNING_BASELINE=""
    export GH_POLICY_TREAT_AS_PUBLIC_FOR_SECRETS="false"
    export GH_POLICY_HASH="sha256:no-jq-available"
    export GH_POLICY_JSON="$(_gh_policy_defaults)"
    return 0
}

# When invoked directly (not sourced), load policy for cwd or arg and print
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    load_policy "${1:-$PWD}"
    cat <<EOF
visibility=$GH_POLICY_VISIBILITY
main_branch=$GH_POLICY_MAIN_BRANCH
main_branch_protection=$GH_POLICY_MAIN_BRANCH_PROTECTION
prep.required=$GH_POLICY_PREP_REQUIRED
prep.strictness=$GH_POLICY_PREP_STRICTNESS
prep.ttl_hours=$GH_POLICY_PREP_TTL_HOURS
allowed_force_push_targets=$GH_POLICY_FORCE_PUSH_TARGETS
protected_branches=$GH_POLICY_PROTECTED_BRANCHES
secret_scanning_baseline=$GH_POLICY_SECRET_SCANNING_BASELINE
treat_as_public_for_secrets=$GH_POLICY_TREAT_AS_PUBLIC_FOR_SECRETS
policy_hash=$GH_POLICY_HASH
EOF
fi
