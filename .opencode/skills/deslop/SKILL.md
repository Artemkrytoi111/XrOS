---
name: deslop
description: Clean up AI-generated code slop in XrOS (Bash, Rust, PyQt6, QML, PKGBUILD) while preserving behavior and running XrOS diagnostics.
---

# Deslop — XrOS Cleanup

Check `git diff` against `main` (or specified files) and remove all AI-generated slop, bloat, and unnatural patterns.

## Scope & Exclusions
- Inspect changes in `src/`, `packages/`, `scripts/`, and `profile/`.
- **NEVER modify** `xros-gpg-prod/`, `xros-gpg-test/`, or binary `.pkg.tar.zst` files in `repo/`.

## What to Remove
- **General**: Redundant line-by-line comments, single-use wrapper functions, premature abstractions, verbose AI-style logs.
- **Bash / PKGBUILD**: Unused empty arrays in `PKGBUILD`, redundant `$?` checks under `set -euo pipefail`, unnecessary subshells.
- **Rust**: Redundant `.clone()`, unnecessary lifetime annotations, `.unwrap()` where `?` belongs, overly nested `match` blocks.
- **Python / PyQt6 / QML**: Unused imports, redundant `try/except Exception` blocks, imperative UI assignments that should be declarative bindings.

## Verification
1. Keep runtime behavior 100% unchanged.
2. Run relevant checks (`shellcheck`, `namcap`, `cargo check`, or `./scripts/xros-diagnose.sh` if applicable).
3. Output only a 1–3 sentence summary of what was cleaned up.
