# Critical & High Fixes — XrOS Installer & Build

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate CRITICAL and HIGH severity findings (C1, C2, C3, H1–H4) plus MEDIUM M1–M3 from the XrOS installation and build pipeline, without changing GPG keys, packages in `repo/`, or adding undeclared dependencies.

**Architecture:** Component-by-component fixes grouped by file ownership. Each task touches one component, runs its own verification (shellcheck / cargo check / diagnose / targeted tests), and commits independently before the next task starts.

**Tech Stack:** Bash (set -euo pipefail, shellcheck-clean), Rust (std only for zeroize unless confirmed), Python (bridge.py only, no new deps).

**Spec:** AGENTS.md project rules + audit findings report (severity-ranked). The audit findings are the spec for this plan.

## Global Constraints

- No AI dependencies, no AI-style comments, minimal dependencies (AGENTS.md).
- Bash: `#!/usr/bin/env bash` + `set -euo pipefail`, shellcheck-clean on touched files.
- Rust: no `.unwrap()` in production code; errors via `?`. Password zeroing uses `std` only unless user confirms `zeroize` crate.
- Do not touch `xros-gpg-prod/`, `xros-gpg-test/`, or anything under `repo/`.
- No new entries in `Cargo.toml` or `profile/packages.x86_64` without explicit user confirmation.
- After every stage: `shellcheck` on changed shell files, `cargo check` on changed Rust crates, `./scripts/xros-diagnose.sh`, relevant `scripts/tests/`.
- Final: `deslop` skill over all changed files.

## Review Focus

- Password values surviving in `App.sel` after `write_conf()` (C1).
- `PYTHONPATH`/`QT_*`/`QML2_*` reaching a root-run installer process (C2).
- `bridge.py` in `profile/` missing `lstat`/`errno`/`_device_readable` hardening present in `src/` (C3).
- Pipeline `run_install | dialog` returning dialog's exit code, not the installer's (H1).
- `chpasswd`/`useradd` failures swallowed without `set -e` (H2).
- Arch bootstrap key fingerprint extracted from the signature itself, not pinned (H3).
- Dev build continuing with `SigLevel=Optional` without an explicit opt-in flag (H4).
- `chpasswd` stderr potentially leaking login+password into `/tmp/xros-install.log` (M1).
- `trap ''` disabling signals forever and `umount -R` without timeout (M2).
- `umount ... || true` swallowing mount errors in build-env (M3).

---

### Task 1: bridge.py — sanitize environment + sync with profile copy

**Files:**
- Modify: `src/xros-installer-diamond/bridge.py:378-380` (env sanitization)
- Modify: `profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py` (full sync from src)

**Interfaces:**
- Consumes: `os.environ` (current full env pass-through).
- Produces: sanitized env dict with only `XROS_NONINTERACTIVE`, `XROS_INSTALL_CONF`, `PATH`, `LANG`, `DISPLAY`/`WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, `XAUTHORITY`, `DBUS_SESSION_BUS_ADDRESS`; all `PYTHONPATH`, `QT_*`, `QML2_*`, `LD_LIBRARY_PATH` dropped.

- [ ] **Step 1: Write the failing test**

```bash
# test: bridge.py must not pass PYTHONPATH/QT_PLUGIN_PATH/QML2_IMPORT_PATH/LD_LIBRARY_PATH to Popen env
python3 - <<'EOF'
import ast, sys
src = open('src/xros-installer-diamond/bridge.py').read()
tree = ast.parse(src)
for node in ast.walk(tree):
    if isinstance(node, ast.Call) and getattr(node.func, 'attr', None) == 'Popen':
        for kw in node.keywords:
            if kw.arg == 'env':
                print('env kw present')
                sys.exit(0)
print('FAIL: no env kw found on Popen')
sys.exit(1)
EOF
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test-env-sanitization.sh` (inline python above). Expected: FAIL (env=dict(os.environ) present).

- [ ] **Step 3: Implement env sanitization in `src/xros-installer-diamond/bridge.py`**

Replace `env=dict(os.environ)` with a `safe_env()` helper returning only the allowlisted keys.

- [ ] **Step 4: Run test to verify it passes**

Expected: PASS (safe_env contains no `PYTHONPATH`/`QT_PLUGIN_PATH`/`QML2_IMPORT_PATH`/`LD_LIBRARY_PATH`).

- [ ] **Step 5: Sync profile copy**

Copy `src/xros-installer-diamond/bridge.py` over `profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py` (also sync `errno` import, `_device_readable`, `_secure_create` with `lstat`, newline-in-value check — see Task 2).

- [ ] **Step 6: Verify**

`diff -u src/xros-installer-diamond/bridge.py profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py` → no output.

- [ ] **Step 7: Commit**

`git add src/xros-installer-diamond/bridge.py profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py && git commit -m "fix: sanitize installer env, sync bridge.py to live image"`

---

### Task 2: bridge.py profile copy — restore missing security hardening (C3)

**Files:**
- Modify: `profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py` (already synced in Task 1, but listed separately for clarity of the hardening diff)

**Interfaces:**
- Consumes: none new.
- Produces: profile copy identical to src (453 lines, with `errno`, `_device_readable`, `lstat`-checked `_secure_create`, newline/reject check on config values).

- [ ] **Step 1: Verify diff is empty**

Run: `diff -q src/xros-installer-diamond/bridge.py profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py`. Expected: identical.

- [ ] **Step 2: Run bridge security tests**

Run: `python3 -m pytest scripts/tests/test_bridge_security.py -v` (or the project's bridge test path). Expected: PASS.

- [ ] **Step 3: Commit** (if not already committed in Task 1)

---

### Task 3: src/xros-install-gui-rs — zeroize passwords, remove Debug on Choices (C1)

**Files:**
- Modify: `src/xros-install-gui-rs/src/app.rs:75-95` (remove `#[derive(Debug)]` from `Choices`, add manual `Debug` without passwords or zeroize-on-drop)
- Modify: `src/xros-install-gui-rs/src/install.rs:147-152, 205-208` (zeroize `sel` fields after `write_conf()` returns, before spawning child)

**Interfaces:**
- Consumes: `Choices` with `userpass`, `pass2`, `rootpass` fields.
- Produces: `Choices` whose password fields are cleared (`String::new()` or zeroed bytes) after config write; `Debug` impl that omits password fields.

- [ ] **Step 1: Decide zeroize approach**

Confirm with user: use `std::mem::take` + `String::new()` (std only, no new dep) vs adding `zeroize` crate. Plan assumes std only.

- [ ] **Step 2: Write failing test**

Rust test: `write_conf` followed by inspection of `sel.userpass`/`sel.rootpass` → assert empty after install starts.

- [ ] **Step 3: Implement zeroize + Debug removal**

In `install.rs::start_install`, after `write_conf(sel)?`, clear `sel.userpass`, `sel.pass2`, `sel.rootpass`. In `app.rs`, remove `#[derive(Debug)]` from `Choices` (or implement `Debug` manually omitting secrets).

- [ ] **Step 4: Run `cargo check`**

Expected: PASS on `src/xros-install-gui-rs`.

- [ ] **Step 5: Run GUI tests**

Run crate's test suite. Expected: PASS.

- [ ] **Step 6: Commit**

---

### Task 4: src/xros-install — pipeline exit code (H1)

**Files:**
- Modify: `src/xros-install:2001-2004`

**Interfaces:**
- Consumes: `run_install` exit code.
- Produces: `RC` reflecting `run_install`'s exit, not `dialog --gauge`'s.

- [ ] **Step 1: Write failing test**

```bash
# Simulate: run_install exits 1, dialog exits 0 → RC must be 1
run_install() { echo "INSTALL_FAILED"; exit 1; }
run_install | dialog --gauge "..."; RC=${PIPESTATUS[0]}
[[ $RC -eq 1 ]] && echo PASS || echo FAIL
```

- [ ] **Step 2: Run test**

Expected: FAIL with current code (`RC=0` from dialog).

- [ ] **Step 3: Implement**

Replace `RC=$?` with `RC=${PIPESTATUS[0]}` (Bash 4+, pipefail already set at line 16). Or run `run_install` without pipe and feed dialog separately.

- [ ] **Step 4: Run test**

Expected: PASS (`RC=1`).

- [ ] **Step 5: shellcheck**

Run `shellcheck src/xros-install` → no new warnings on changed lines.

- [ ] **Step 6: Commit**

---

### Task 5: src/xros-install — set -e + chpasswd/useradd checks (H2, M1)

**Files:**
- Modify: `src/xros-install:16` (add `-e`)
- Modify: `src/xros-install:1647-1649` (check `useradd` and `chpasswd` exit codes)
- Modify: `src/xros-install:1648-1649` (separate `chpasswd` stderr from log to avoid password leak)

**Interfaces:**
- Consumes: `USERNAME`, `ROOTPASS_Q`, `USERPASS_Q` variables.
- Produces: script exits non-zero if user creation or password setting fails; `chpasswd` stderr not mixed into install log.

- [ ] **Step 1: Write failing test**

```bash
# chpasswd failure must not be swallowed
chpasswd() { echo "chpasswd: bad password" >&2; return 1; }
source src/xros-install  # up to user creation section
[[ $? -eq 0 ]] && echo FAIL || echo PASS
```

- [ ] **Step 2: Run test**

Expected: FAIL (chpasswd failure currently swallowed).

- [ ] **Step 3: Implement**

Add `set -e` at line 16 (or explicit `|| exit 1` after `useradd` and `chpasswd`). Redirect `chpasswd` stderr to a separate handle not written to `$LOG`.

- [ ] **Step 4: Run test**

Expected: PASS.

- [ ] **Step 5: shellcheck + `./scripts/xros-diagnose.sh`**

Expected: no new shellcheck warnings; diagnose PASS or same SKIPs as before.

- [ ] **Step 6: Commit**

---

### Task 6: scripts/xros-build-env.sh — pin Arch bootstrap key fingerprint (H3)

**Files:**
- Modify: `scripts/xros-build-env.sh:320-353` (add pinned Arch master key fingerprint constant; verify against it instead of extracting from signature)

**Interfaces:**
- Consumes: `$BOOTSTRAP_SIG`, `$BOOTSTRAP_FILE`.
- Produces: `die` unless `gpg --verify` succeeds with the pinned fingerprint.

- [ ] **Step 1: Obtain pinned fingerprint**

Read current Arch master key fingerprint from official Arch documentation (archlinux.org/master-keys) — do not invent; verify against `xros-gpg-prod/` if a reference exists there (read-only).

- [ ] **Step 2: Write failing test**

```bash
# Forged signature with attacker key must be rejected
gpg --verify forged.sig bootstrap.tar.zst  # with attacker's key imported
# script must die, not proceed
```

- [ ] **Step 3: Implement**

Add `ARCH_MASTER_KEY_FPR="..."` constant; after `gpg --verify`, check that the verifying key's fingerprint matches the constant; `die` otherwise.

- [ ] **Step 4: Run test**

Expected: PASS (forged signature rejected).

- [ ] **Step 5: shellcheck**

Expected: no new warnings.

- [ ] **Step 6: Commit**

---

### Task 7: scripts/build.sh — dev build explicit unsigned opt-in (H4)

**Files:**
- Modify: `scripts/build.sh:419-425` (require explicit `XROS_DEV_UNSIGNED=1` or `--confirm` with warning for dev builds with `SigLevel=Optional`)

**Interfaces:**
- Consumes: `$RELEASE`, `$XROS_GPG_PROD_FPR`.
- Produces: dev build proceeds only with explicit unsigned opt-in; release build unchanged (gated by `--release`).

- [ ] **Step 1: Write failing test**

```bash
# Dev build without XROS_DEV_UNSIGNED must warn loudly / require --confirm
RELEASE=0 XROS_GPG_PROD_FPR="" ./scripts/build.sh --dry-run
# must contain "SigLevel=Optional" warning and require explicit opt-in
```

- [ ] **Step 2: Run test**

Expected: FAIL (dev build silently continues with Optional).

- [ ] **Step 3: Implement**

Add explicit check: if `RELEASE=0` and `XROS_GPG_PROD_FPR` empty, require `XROS_DEV_UNSIGNED=1` env var, else `die` with message.

- [ ] **Step 4: Run test**

Expected: PASS.

- [ ] **Step 5: shellcheck**

Expected: no new warnings.

- [ ] **Step 6: Commit**

---

### Task 8: src/xros-install — trap/umount cleanup (M2)

**Files:**
- Modify: `src/xros-install:167, 178, 257` (restore traps after first signal, add timeout to `umount -R`)

**Interfaces:**
- Consumes: `$TARGET` mount path.
- Produces: cleanup that does not disable signals forever, and `umount -R` bounded by `timeout`.

- [ ] **Step 1: Write failing test**

Simulate `umount -R` hang; script must not disable SIGTERM forever.

- [ ] **Step 2: Run test**

Expected: FAIL with current `trap ''` + no timeout.

- [ ] **Step 3: Implement**

Replace `trap '' HUP TERM INT` with re-arming or selective handling; wrap `umount -R "$TARGET"` in `timeout 15 umount -R "$TARGET"`.

- [ ] **Step 4: Run test**

Expected: PASS.

- [ ] **Step 5: shellcheck**

Expected: no new warnings.

- [ ] **Step 6: Commit**

---

### Task 9: scripts/xros-build-env.sh — umount error handling (M3)

**Files:**
- Modify: `scripts/xros-build-env.sh:576-185` region (umount without `|| true`, fallback `umount -l`, die on repeated failure)

**Interfaces:**
- Consumes: mount points from `$MOUNTS_FILE`.
- Produces: mount points either cleanly unmounted or script aborts preserving `.mounts` for inspection.

- [ ] **Step 1: Write failing test**

Simulate busy mount; `umount ... || true` must not silently swallow.

- [ ] **Step 2: Run test**

Expected: FAIL (error swallowed).

- [ ] **Step 3: Implement**

Replace `umount "$mp" 2>/dev/null || true` with `umount "$mp" || umount -l "$mp" || { die "cannot unmount $mp"; }`.

- [ ] **Step 4: Run test**

Expected: PASS.

- [ ] **Step 5: shellcheck**

Expected: no new warnings.

- [ ] **Step 6: Commit**

---

### Task 10: Final verification + deslop

**Files:** all changed files above

- [ ] **Step 1: Run shellcheck** on all changed shell files → zero new warnings.
- [ ] **Step 2: Run `cargo check`** on `src/xros-install-gui-rs` and `src/xros-cli` → PASS.
- [ ] **Step 3: Run `./scripts/xros-diagnose.sh`** → PASS or same SKIPs as baseline.
- [ ] **Step 4: Run profile tests** `scripts/tests/` relevant to changed components.
- [ ] **Step 5: Run `deslop`** over all changed files.
- [ ] **Step 6: Final commit** of any deslop changes.

---

**Plan complete and saved to `docs/superpowers/plans/2026-11-21-critical-high-fixes.md`.**

Please review the plan. Does it capture what you want? Which execution approach should we use?

- **Subagent-driven** — a fresh subagent implements each task and a fresh reviewer checks it before the next starts, then a whole-branch review. Most thorough; costs a fresh context per task and per review.
- **Native** — I implement every task myself in this session, then one fresh reviewer checks the whole branch. Cheapest and fastest; no independent review until the end.

For this plan I recommend **Native**, because the tasks are small, well-scoped, and mostly independent (one file each), and each has an explicit verification step built in.