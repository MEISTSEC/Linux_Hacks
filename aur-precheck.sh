#!/usr/bin/env bash
# aur-precheck.sh <pkgbase> [<pkgbase> ...]
#
# Advisory supply-chain pre-flight for a SINGLE AUR package (the gap the yay
# AURPreInstall event can't fill from its own data: orphan / out-of-date /
# malicious-maintainer / compromised-name). Queries the AUR RPC + cached IOC
# lists and prints one finding per line, each tagged with a severity:
#
#   CRIT <msg>   -- compromised package name or malicious maintainer (warn LOUDLY)
#   WARN <msg>   -- orphaned / out-of-date / stale / not-found
#
# Always exits 0 (advisory; never blocks an install). Designed to be called from
# the yay hook via io.popen, and usable standalone on the CLI.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/aur-common.sh
source "$HERE/lib/aur-common.sh"

USER_HOME="${HOME:-/home/${USER:-root}}"

# --- Settings (env-overridable; optionally from the update.sh config) ---------
# Best-effort: pull AUR_IOC_CAMPAIGNS / AUR_PRECHECK_* / LUA_ALLOWLIST from the
# shared config if it is present and owned by us (we run as the user here).
PRECHECK_CONF="${UPDATE_CONF:-$USER_HOME/.config/update.sh/config}"
if [[ -f "$PRECHECK_CONF" && -O "$PRECHECK_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$PRECHECK_CONF" 2>/dev/null || true
fi

# Master toggle (default on). AUR_PRECHECK=false disables the network-backed
# install-time checks; the hook's local PKGBUILD build-logic scan still runs.
[[ "${AUR_PRECHECK:-true}" == "false" ]] && exit 0

AUR_PRECHECK_MAX_AGE_DAYS="${AUR_PRECHECK_MAX_AGE_DAYS:-365}"
AUR_IOC_CACHE_TTL="${AUR_IOC_CACHE_TTL:-21600}"   # 6h
ALLOWLIST_FILE="${YAY_ALLOWLIST_FILE:-$USER_HOME/.config/yay/allowlist.txt}"
CACHE_DIR="${AUR_PRECHECK_CACHE_DIR:-$USER_HOME/.cache/update-aur/ioc}"

# --- Allowlist (exact names or globs; the same file update.sh syncs) ----------
allow=()
[[ -f "$ALLOWLIST_FILE" ]] && mapfile -t allow < <(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST_FILE")

# --- IOC list cache ----------------------------------------------------------
# Serve a cached copy if fresh; otherwise refetch via the given function. On a
# failed refetch, fall back to a stale cache rather than going blind.
cache_get() {
    local name="$1" fetch_fn="$2"
    local f="$CACHE_DIR/$name" now age data
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    now=$(date +%s)
    if [[ -f "$f" ]]; then
        age=$(( now - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
        (( age < AUR_IOC_CACHE_TTL )) && { cat "$f"; return 0; }
    fi
    data="$("$fetch_fn")"
    if [[ -n "$data" ]]; then
        printf '%s\n' "$data" > "$f" 2>/dev/null || true
        printf '%s\n' "$data"
    elif [[ -f "$f" ]]; then
        cat "$f"   # stale, but better than nothing on a failed fetch
    fi
}

precheck_one() {
    local pkg="$1"
    # Trusted packages: stay silent.
    matches_any "$pkg" "${allow[@]}" && return 0

    # 1) Compromised package name (LOUD) -- cheap, do it even without jq.
    local bad_pkgs
    bad_pkgs="$(cache_get packages.txt aur_fetch_bad_packages)"
    if [[ -n "$bad_pkgs" ]] && grep -qxF "$pkg" <<<"$bad_pkgs"; then
        echo "CRIT $pkg is on the KNOWN-COMPROMISED package list -- do NOT install without verifying"
    fi

    # 2) RPC metadata (orphan / out-of-date / stale / not-found / bad maintainer).
    command -v jq >/dev/null 2>&1 || return 0
    local rpc rec
    rpc="$(aur_query_rpc "$pkg")"
    # aur_query_rpc echoes '{}' on a failed fetch (no "results" key) vs a real
    # response which always has results -- distinguish offline from not-found.
    if ! jq -e 'has("results")' >/dev/null 2>&1 <<<"$rpc"; then
        echo "WARN $pkg: could not reach the AUR RPC (offline?) -- metadata checks skipped"
        return 0
    fi
    rec="$(jq -c --arg n "$pkg" '.results[]? | select(.Name == $n)' <<<"$rpc")"
    if [[ -z "$rec" ]]; then
        echo "WARN $pkg was NOT found in the AUR (deleted / renamed / typo?) -- verify the source"
        return 0
    fi

    local maint ood lastmod now age
    maint=$(jq -r '.Maintainer // ""'    <<<"$rec")
    ood=$(jq   -r '.OutOfDate // ""'      <<<"$rec")
    lastmod=$(jq -r '.LastModified // 0'  <<<"$rec")
    now=$(date +%s); age=$(( (now - lastmod) / 86400 ))

    [[ -z "$maint" ]] && echo "WARN $pkg is ORPHANED in the AUR (no maintainer)"
    [[ -n "$ood"   ]] && echo "WARN $pkg is flagged OUT-OF-DATE in the AUR"
    (( age > AUR_PRECHECK_MAX_AGE_DAYS )) && \
        echo "WARN $pkg PKGBUILD last updated $age days ago (> ${AUR_PRECHECK_MAX_AGE_DAYS}d; stale)"

    # 3) Malicious maintainer account (LOUD).
    if [[ -n "$maint" ]]; then
        local bad_acct
        bad_acct="$(cache_get accounts aur_fetch_bad_accounts)"
        if [[ -n "$bad_acct" ]] && grep -qxF "$maint" <<<"$bad_acct"; then
            echo "CRIT $pkg is maintained by KNOWN-MALICIOUS account '$maint' -- do NOT install"
        fi
    fi
    return 0
}

for p in "$@"; do
    [[ -n "$p" ]] && precheck_one "$p"
done
exit 0
