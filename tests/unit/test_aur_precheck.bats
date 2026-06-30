#!/usr/bin/env bats
# aur-precheck.sh: single-package RPC + IOC supply-chain pre-flight.

load ../helpers/common

write_rpc() {
    local now old recent ood
    now=$(date +%s); old=$((now - 500 * 86400))
    recent=$((now - 5 * 86400)); ood=$((now - 50 * 86400))
    cat > "$FX_RPC_FILE" <<EOF
{ "results": [
  { "Name": "orphan-pkg", "Maintainer": null,     "LastModified": $recent, "OutOfDate": null, "NumVotes": 2 },
  { "Name": "stale-pkg",  "Maintainer": "alice",   "LastModified": $old,    "OutOfDate": null, "NumVotes": 9 },
  { "Name": "ood-pkg",    "Maintainer": "bob",     "LastModified": $recent, "OutOfDate": $ood, "NumVotes": 5 },
  { "Name": "evil-pkg",   "Maintainer": "baduser", "LastModified": $recent, "OutOfDate": null, "NumVotes": 1 },
  { "Name": "good-pkg",   "Maintainer": "carol",   "LastModified": $recent, "OutOfDate": null, "NumVotes": 99 }
] }
EOF
}

setup() {
    load_libs
    TEST_HOME="$(mktemp -d)"
    export HOME="$TEST_HOME"
    export PATH="$STUB_BIN:$PATH"
    export STUB_LOG="$TEST_HOME/stub.log"; : > "$STUB_LOG"
    export FX_RPC_FILE="$TEST_HOME/rpc.json"
    export FX_PKGS_FILE="$FIXTURES/ioc/packages.txt"        # contains evil-pkg
    export FX_ACCOUNTS_FILE="$FIXTURES/ioc/accounts.json"   # contains baduser
    export YAY_ALLOWLIST_FILE="$TEST_HOME/allowlist.txt"
    export AUR_PRECHECK_CACHE_DIR="$TEST_HOME/cache"
    export AUR_PRECHECK_MAX_AGE_DAYS=365
    printf 'mailspring\n' > "$YAY_ALLOWLIST_FILE"
    write_rpc
    PRECHECK="$REPO_ROOT/aur-precheck.sh"
}
teardown() { [[ -d "$TEST_HOME" ]] && rm -rf "$TEST_HOME"; }

@test "flags an orphaned package" {
    run "$PRECHECK" orphan-pkg
    assert_output --partial "WARN orphan-pkg is ORPHANED"
}

@test "flags an out-of-date package" {
    run "$PRECHECK" ood-pkg
    assert_output --partial "WARN ood-pkg is flagged OUT-OF-DATE"
}

@test "flags a stale package past the age threshold" {
    run "$PRECHECK" stale-pkg
    assert_output --partial "WARN stale-pkg PKGBUILD last updated"
    assert_output --partial "stale"
}

@test "loudly flags a compromised package name and malicious maintainer" {
    run "$PRECHECK" evil-pkg
    assert_output --partial "CRIT evil-pkg is on the KNOWN-COMPROMISED package list"
    assert_output --partial "CRIT evil-pkg is maintained by KNOWN-MALICIOUS account 'baduser'"
}

@test "flags a package missing from the AUR" {
    run "$PRECHECK" ghost-pkg
    assert_output --partial "WARN ghost-pkg was NOT found in the AUR"
}

@test "is silent for a clean package" {
    run "$PRECHECK" good-pkg
    assert_success
    assert_output ""
}

@test "is silent for an allowlisted package" {
    run "$PRECHECK" mailspring
    assert_success
    assert_output ""
}

@test "distinguishes an offline RPC from a genuine not-found" {
    CURL_FAIL=1 run "$PRECHECK" orphan-pkg
    assert_output --partial "could not reach the AUR RPC"
    refute_output --partial "NOT found in the AUR"
}

@test "serves the compromised-list from cache when offline" {
    "$PRECHECK" evil-pkg >/dev/null          # prime the IOC cache
    CURL_FAIL=1 run "$PRECHECK" evil-pkg     # offline: RPC gone, IOC from cache
    assert_output --partial "CRIT evil-pkg is on the KNOWN-COMPROMISED package list"
}

@test "always exits 0 (advisory, never blocks)" {
    run "$PRECHECK" evil-pkg
    assert_success
}

@test "AUR_PRECHECK=false disables the network-backed checks" {
    AUR_PRECHECK=false run "$PRECHECK" evil-pkg
    assert_success
    assert_output ""
}
