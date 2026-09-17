#!/usr/bin/env bash
# gitleaks-fixtures.sh — shared fixtures for the gitleaks eval suites
# (gitleaks-hooks.test.sh, gitleaks-range-scan.test.sh).
# One implementation of the operator-rules fixture, the config-chain writers, the
# repo initializer, and the canary generator — sourced by both suites so a
# fixture change lands once, not twice. Source AFTER lib/assert.sh (this
# relies on assert_repo_identity).
#
# Canaries: random AKIA + 16 of [A-Z2-7], NEVER ending in EXAMPLE (gitleaks'
# aws-access-token rule allowlists '.+EXAMPLE$'). No operator PII anywhere.

# --- gitleaks + pre-commit are REQUIRED (hard fail, never a silent skip) ------
# A silently-green no-op is a gamed metric. Each suite calls this after sourcing.
require_gitleaks_tools() { # <needs_precommit: 0|1>
    command -v gitleaks >/dev/null 2>&1 \
        || { echo "FATAL: gitleaks not on PATH — suite cannot run. Install gitleaks 8.30.1."; exit 2; }
    if [[ "${1:-0}" == "1" ]]; then
        command -v pre-commit >/dev/null 2>&1 \
            || { echo "FATAL: pre-commit not on PATH. Install pre-commit==4.6.0."; exit 2; }
    fi
}

rand_akia() { echo "AKIA$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"; }

# gl_fixtures_init <tmpdir> — set up the private XDG_CONFIG_HOME + the fixed
# operator-rules fixture. Exports XDG_CONFIG_HOME, FIXED, XDG_EMPTY, CANARY.
# The fixed-path fixture carries useDefault (so gitleaks' aws-access-token rule
# fires on the canary) PLUS two marker rules that exist nowhere else:
#   fixture-fixedpath-marker (FIXEDPATHMARKER) — proves WHICH ruleset loaded
#   operator-network-domain-1 (NETWORKDOMAINMARKER) — stands in for the real
#     identity/overlay-class rule the private-repo profile drops.
gl_fixtures_init() { # <tmpdir>
    # XDG_OVERRIDE and CANARY are consumed by the sourcing suites, not here.
    export XDG_CONFIG_HOME="$1/xdg"
    XDG_EMPTY="$1/xdg-empty"; mkdir -p "$XDG_EMPTY"
    FIXED="$XDG_CONFIG_HOME/gitleaks/operator-rules.toml"
    # shellcheck disable=SC2034  # consumed by sourcing suites
    XDG_OVERRIDE=""
    # shellcheck disable=SC2034  # consumed by sourcing suites
    CANARY="$(rand_akia)"
    write_fixed_rules
}

write_fixed_rules() {
    mkdir -p "$(dirname "$FIXED")"
    cat > "$FIXED" <<'EOF'
title = "fixture operator rules (fixed path)"
[extend]
useDefault = true
[[rules]]
id = "fixture-fixedpath-marker"
description = "marker present ONLY in the fixed-path fixture (test only)"
regex = '''FIXEDPATHMARKER'''
[[rules]]
id = "operator-network-domain-1"
description = "stands in for the real public-disclosure rule the private-repo profile disables (test only)"
regex = '''NETWORKDOMAINMARKER'''
EOF
}

# The repo config every estate repo carries: a checkout-relative [extend] token
# the resolver rewrites to the fixed path. No rules file is written beside it.
write_config_chain() { # <repo-dir>
    cat > "$1/.gitleaks.toml" <<'EOF'
title = "fixture"
[extend]
path = ".gitleaks-operator-rules.toml"
EOF
}

# Never consulted (a gitignored symlink in the estate) — written only to prove
# precedence: it carries a DIFFERENT marker, so a case can show the fixed path
# wins even when this file exists and names a different ruleset.
write_checkout_rules() { # <repo-dir>
    cat > "$1/.gitleaks-operator-rules.toml" <<'EOF'
title = "fixture operator rules (checkout-relative)"
[extend]
useDefault = true
[[rules]]
id = "fixture-symlink-marker"
description = "marker present ONLY in the checkout-relative fixture (test only)"
regex = '''SYMLINKMARKER'''
EOF
}

git_init_repo() { # <dir>
    git init -q -b main "$1" 2>/dev/null || { git init -q "$1"; git -C "$1" symbolic-ref HEAD refs/heads/main; }
    assert_repo_identity "$1"
    # noreply address: the identity guard blocks any non-noreply author/committer
    # email, so fixture commits must comply for clean-pass assertions to isolate
    # the gitleaks behavior under test.
    git -C "$1" config user.email "test@users.noreply.github.com"
    git -C "$1" config user.name "Test Runner"
    git -C "$1" config commit.gpgsign false
}
