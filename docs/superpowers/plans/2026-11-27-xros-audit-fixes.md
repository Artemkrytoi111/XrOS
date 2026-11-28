# XrOS Audit Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Устранить подтверждённые security, installer, GUI validation и release integrity проблемы, найденные read-only аудитом XrOS.

**Architecture:** Root-операции останутся в `src/xros-install`, но конфигурация будет разбираться как данные по строгому allowlist вместо shell `source`. GUI будет использовать закрытый runtime-каталог и единый разрешённый wrapper; записи результатов станут защищены от symlink race. Release manifest будет ограничен воспроизводимым набором исходников, а staged checksum и snapshots будут синхронизированы.

**Tech Stack:** Bash, Python/PyQt6, Rust, Qt/QML, Arch PKGBUILD, SHA-256 manifests.

**Spec:** Findings из read-only аудита XrOS и прямое указание пользователя «давай исправляй».

## Global Constraints

- Не изменять `xros-gpg-prod/`, `xros-gpg-test/` и готовые пакеты в `repo/` вручную.
- Не добавлять AI-зависимости и новые зависимости в профиль/Cargo без необходимости.
- Bash должен сохранять `set -euo pipefail`/совместимость с shellcheck.
- Rust production-код без новых `unwrap()`.
- Все изменения проверять доступными тестами; Linux-only проверки явно отделять от ограничений среды.

## Review Focus

- Пользовательский конфиг с shell-командами должен быть отвергнут как данные, а не выполнен.
- Предсказуемые `/tmp`-пути и symlink должны приводить к безопасному отказу.
- GUI должен прекращать root-движок после аварийного завершения.
- Root/EFI, hostname и timezone должны иметь одинаковую проверку в QML и engine.
- Manifest не должен включать generated/backup-файлы и должен покрывать release inputs.

---

### Task 1: Secure installer configuration and runtime files

**Files:**
- Modify: `src/xros-install`
- Modify: `src/xros-installer-diamond/bridge.py`
- Modify: `src/xros-install-gui-rs/src/install.rs`
- Test: `scripts/tests/test-installer-security.sh`
- Test: `src/xros-installer-diamond/test_bridge_security.py`

- [ ] Add regression tests proving a config value containing a command is treated as data/rejected, and temp paths reject symlinks.
- [ ] Replace `. "$CONF"` with an allowlisted `KEY=VALUE` parser that rejects unknown keys, malformed lines, duplicate keys, newlines and shell syntax; keep defaults and validation behavior.
- [ ] Create a root-owned private runtime directory for config/log/result files or use safe file descriptors; remove partial config on all write failures.
- [ ] Ensure cleanup removes runtime files without following symlinks.
- [ ] Run security tests and `bash -n`.

### Task 2: Privileged GUI entry point and process lifetime

**Files:**
- Modify: `profile/airootfs/root/customize_airootfs.sh`
- Modify: `src/xros-installer-diamond/main.py`
- Modify: `src/xros-installer-diamond/bridge.py`
- Modify: `src/xros-install-gui-rs/src/main.rs`
- Modify: `src/xros-install-gui-rs/src/install.rs`
- Test: `scripts/tests/test-child-process.sh`
- Test: `scripts/tests/test-child-process-extended.sh`

- [ ] Add a single fixed root-owned launcher/wrapper path to the profile and allow only that path in sudoers.
- [ ] Make GUI-to-engine runtime paths explicit and avoid preserving arbitrary user `PATH`/config paths.
- [ ] Add PDEATHSIG/watchdog behavior to Diamond or route it through the wrapper so engine lifetime follows GUI lifetime.
- [ ] Add regression checks for launcher policy and process cleanup.
- [ ] Run child-process tests in WSL/native Linux where possible.

### Task 3: GUI validation and CLI behavior

**Files:**
- Modify: `src/xros-installer-diamond/qml/screens/Disk.qml`
- Modify: `src/xros-installer-diamond/qml/screens/User.qml`
- Modify: `src/xros-installer-diamond/qml/screens/Region.qml`
- Modify: `src/xros-installer-diamond/bridge.py`
- Modify: `src/xros-cli/src/main.rs`
- Modify: `src/xros-cli/src/info.rs`
- Test: existing bridge/security tests and static test scripts

- [ ] Reject identical root/EFI partitions and stale restored paths.
- [ ] Validate hostname and timezone against the same rules used by engine.
- [ ] Check `setxkbmap` return code.
- [ ] Change full upgrade to `pacman -Syu`.
- [ ] Make desktop info derive from installed metadata or use a documented metadata file.

### Task 4: Release manifest, staged checksum and package snapshot

**Files:**
- Modify: `scripts/make-sources-manifest.sh`
- Modify: `scripts/verify-sources-manifest.sh` if needed
- Modify: `scripts/build.sh` if needed
- Modify: `packages/xros-installer/PKGBUILD`
- Modify: `profile/airootfs/usr/share/xros/repo/` only through the existing build/snapshot workflow
- Test: `scripts/tests/test-sources-manifest.sh`, release gate tests

- [ ] Restrict manifest to explicit release inputs and exclude `.bak`, `__pycache__`, `.pyc`, and documentation-only/generated files.
- [ ] Include profile/build inputs or document and enforce a complete signed release surface.
- [ ] Update the installer checksum from the actual staged source after source synchronization.
- [ ] Synchronize package metadata through the supported build workflow; do not hand-edit signed binary artifacts.
- [ ] Run manifest and release gate tests.

### Task 5: Full verification and review

- [ ] Run Python compilation, bridge tests, Bash syntax checks, security tests, manifest tests and release-gate tests.
- [ ] Run `./scripts/xros-diagnose.sh`; record remaining failures as environment limitations or code defects.
- [ ] Run `cargo check --offline`, `shellcheck`, `namcap`, `qmllint`, `makepkg` when available.
- [ ] Review diff for user changes, secrets, generated files and unintended edits.
- [ ] Run deslop review without touching protected GPG/package artifacts.

---
