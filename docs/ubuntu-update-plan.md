# Plan: `ubuntu_update.sh` — a Debian/Ubuntu port of `update.sh`

**Status:** SUPERSEDED 2026-07-07 — this bash-port approach was replaced by the
Python multi-distro rewrite **fettle** (https://github.com/pasadoorian/fettle).
Debian/Ubuntu support is now a backend in fettle, not a separate bash script.
Kept for historical context; see fettle's `PLAN.md` for the live plan.
**Goal:** a feature-complete Debian/Ubuntu counterpart to `update.sh`, covering
`apt`, `flatpak`, and `snap`, reusing `lib/output.sh` verbatim and mirroring the
config/CLI/test architecture. Same UX, same flags where they make sense,
distro-appropriate commands underneath.

## Guiding principles

1. **Reuse what is distro-agnostic.** `lib/output.sh` is pure terminal I/O and
   ports with zero changes — `ubuntu_update.sh` sources it directly. Do NOT copy
   it.
2. **Do NOT fake the AUR layer.** Debian has no AUR, no PKGBUILD, no per-package
   pre-install Lua hook, and no equivalent community IOC feed. `lib/aur-common.sh`,
   `aur-precheck.sh`, and the yay hooks have no honest 1:1 port. The moral
   equivalent — auditing third-party sources (PPAs, non-official apt repos,
   unsigned/http sources, snap/flatpak publisher trust) — is genuinely useful but
   is *new* logic, scoped as an optional phase (M6), not a port.
3. **Preserve the UX contract.** Same flag letters where the concept exists, same
   config precedence (defaults < config file < CLI), same section/step/summary
   output, same "advisory, never surprises you" philosophy, same sourceable-for-
   tests guard.
4. **Keep parity documented.** Where a flag is dropped (`-y`) or added
   (`--flatpak-updater`, source audit), say so explicitly in help + README.

## Package-manager model

`update.sh` has SYSTEM_UPDATER + AUR_UPDATER. The Ubuntu world has three
independent subsystems, so the updater model grows a third knob:

- **SYSTEM_UPDATER** — `apt` (default) | `nala` (nicer apt frontend, optional) | `none`
- **FLATPAK_UPDATER** — `flatpak` (default, if installed) | `none`
- **SNAP_UPDATER** — `snap` (default, if installed) | `none`

Each auto-detects: if the binary is absent, that subsystem is silently skipped
(with a `note`), never an error. `-u` runs all three present subsystems in order:
apt → flatpak → snap.

## Feature mapping (authoritative)

| Flag | update.sh | ubuntu_update.sh |
|------|-----------|------------------|
| `-c` clean | pacman/pamac/yay caches | `apt-get clean && apt-get autoclean`; `flatpak uninstall --unused`; prune disabled snap revisions (`snap list --all` → remove `disabled` rev); `snap set system refresh.retain=2` note |
| `-o` orphans | `-Qtdq` orphans, `-Qm` foreign | orphans: `deborphan` (if present) + `apt-get autoremove` (dry-run, then confirm); foreign/obsolete: `aptitude search '~o'` or `apt-show-versions \| grep 'No available version'` → `~/alien-pkgs.txt` |
| `-u` update | repos + AUR | apt `update && full-upgrade`; then flatpak `update`; then snap `refresh` — per SYSTEM/FLATPAK/SNAP_UPDATER |
| `-r` rebuilds | `checkrebuild` | `needrestart -r l` (fallback `checkrestart` from debian-goodies); lists services/processes on stale libs. `-R` triggers the interactive `needrestart` restart flow |
| `-y` python-rebuild | stale python dir | **DROPPED** (apt manages python transitions). Documented as intentionally absent |
| `-p` pacnew | `pacdiff` | find `/etc -name '*.dpkg-dist' -o -name '*.dpkg-new' -o -name '*.ucf-dist'`; `dpkg --audit`; next_step points at `apt-get dist-upgrade`/manual merge |
| `-f` firmware | `fwupdmgr` | `fwupdmgr refresh` + `get-updates` — **identical logic**, could even be lifted into a shared `lib/firmware.sh` later |
| `-k` kernel | `mhwd-kernel` | list `dpkg -l 'linux-image-*'`, mark running `uname -r`, offer to purge kernels older than running (never the running one), `apt-get purge` + `autoremove` |
| `-A`/`-S` | AUR audit/scan | **no direct analog** → M6 source-audit (optional) |
| `-R` auto-rebuild | rebuild via backend | wired to `needrestart` restart flow |
| config/CLI/output | — | ported structurally 1:1 |

## Milestones

### M1 — Skeleton + shared output (no package logic)
- `ubuntu_update.sh` with: shebang, `set -euo pipefail`, root re-exec guard,
  `USER_HOME`, source `lib/output.sh`, the sourceable-for-tests guard
  (`UPDATE_SH_TEST`-style, e.g. `UBUNTU_UPDATE_TEST`), arg-parse loop, `usage()`,
  `main()` dispatch scaffold with the step counter.
- **Exit:** `./ubuntu_update.sh -h` prints usage; `bash -n` clean; sourcing it
  defines functions without running `main`.

### M2 — Core update path (`-u`, `-c`)
- Implement the three-knob updater (apt/flatpak/snap) + `clean_caches`.
- Auto-detect present tools; skip absent ones with a `note`.
- **Exit:** `-u`/`-c` work on a live Ubuntu box (or against stubs in tests).

### M3 — Maintenance checks (`-o`, `-r`, `-p`, `-f`, `-k`)
- orphans/foreign, needrestart, dpkg-dist/ucf, fwupd, kernel management.
- **Exit:** each runs and reports correctly; `-f` verified against real fwupd.

### M4 — Config file + `--print-config`
- `ubuntu_update.conf.example` mirroring `update.conf.example`: `DEFAULT_ACTIONS`,
  `SYSTEM_UPDATER`, `FLATPAK_UPDATER`, `SNAP_UPDATER`, `AUTO_RESTART` (≈AUTO_REBUILD),
  `EXCLUDE_FOREIGN`, `KEEP_ORPHANS`. Same safety gate (owner/world-writable),
  same auto-seed, same `--config/--no-config/--print-config`.
- Live config path: `~/.config/ubuntu_update.sh/config`.
- **Exit:** precedence (defaults < config < CLI) verified; `--print-config` works.

### M5 — Tests + docs
- New bats suite under `tests/` reusing the stub/sandbox pattern: stubs for
  `apt-get`, `apt`, `flatpak`, `snap`, `needrestart`, `fwupdmgr`, `dpkg`,
  `deborphan`, `sudo`. Sandbox HOME via the common helper. Wire into
  `tests/run-tests.sh` (both scripts share the runner).
- `UBUNTU_UPDATE_README.md` (parity doc, calling out drops/additions vs Arch);
  update root `README.md` + `CLAUDE.md` script inventory.
- **Exit:** full suite green for both scripts.

### M6 — (OPTIONAL) Third-party source audit — the honest "AUR analog"
- Explicit-only (`-A`/`--source-audit`), read-only, never part of `--all`, in the
  same spirit as `-A`/`-S` on Arch. Reports:
  - apt sources: enumerate `/etc/apt/sources.list` + `sources.list.d/*`; flag
    `http://` (non-TLS) repos, `[trusted=yes]` (signature-disabled) entries, and
    repos with no `signed-by=`/no matching key.
  - PPAs: list `ppa:*` sources and their Launchpad owner for eyeballing.
  - GPG keys: list `/etc/apt/trusted.gpg.d` + `/usr/share/keyrings` keys; note
    keys in the deprecated global `trusted.gpg`.
  - snap/flatpak: flag apps whose publisher is not verified
    (`snap info` "publisher" without the green check; flatpak remotes not flathub-verified).
  - held/pinned packages (`apt-mark showhold`, `/etc/apt/preferences.d`).
- **No malware-IOC feed exists for Debian** — this is a *hygiene/attack-surface*
  audit, not a malware scan. Say so plainly in output + docs. If a credible
  Debian/PPA IOC source appears later, wire it into a `lib/deb-sources.sh`.
- **Exit:** `-A` prints a source-hygiene report to `~/apt-source-audit.txt`.

## What deliberately does NOT port
- `-y python-rebuild` (apt handles python transitions).
- `lib/aur-common.sh`, `aur-precheck.sh`, `yay-init.lua`, `AUR_IOC_*`,
  `LUA_ALLOWLIST` — all AUR/yay-specific.
- pamac (Arch-only). `nala` is the optional Debian nicety if we want a fancy frontend.

## Reuse / refactor opportunities surfaced during the port
- `lib/output.sh` — shared verbatim (already generic).
- `check_firmware` is nearly identical on both distros — candidate for a shared
  `lib/firmware.sh` once the Ubuntu version exists (do it in M3 only if it falls
  out cleanly; otherwise leave duplicated and note it).
- `matches_any` (glob/exact matcher) is generic — either lift it out of
  `lib/aur-common.sh` into a neutral `lib/common.sh`, or duplicate the ~8 lines.
  Lifting is cleaner but touches the Arch script; defer unless free.

## The Python question (see chat answer)
Recommendation: **write M1–M5 in bash first** (cheap validation of the mapping,
keeps parity with the tested Arch script). Convert to Python when ANY of these
trip: (a) a *third* distro/backend is wanted, (b) you're fixing the same bug in
two scripts, (c) the supply-chain/JSON layer grows enough that `curl`+`jq`
becomes the bottleneck, or (d) total bash exceeds ~1500 lines across the two.
The natural Python shape: one `sysupdate` CLI with a `PackageBackend` ABC
(`ArchBackend`/`DebianBackend`), one config schema, `pytest`. The AUR/RPC JSON
code is the first thing that should move (requests + json ≫ curl + jq).
