# XrOS Diagnostic Hardening Design

## Intent

Усилить локальные release checks так, чтобы реальные рассинхронизации и ошибки E2E не превращались в успешный `SKIP`, а GUI-проверка охватывала полный набор входов сборки. Production trust anchor и подписанные repository artifacts остаются вне этой задачи.

## Goals

- Оставлять stale package mismatch как `FAIL` в обычном diagnose; разрешать `SKIP` только через явно включённый developer-only режим с проверяемым Git-состоянием.
- Учитывать staged и unstaged изменения при диагностике локального `PKGBUILD`.
- Различать ожидаемую недоступность mount namespace и ошибку уже запущенного E2E-сценария.
- Требовать обязательные release roots при создании source manifest и не скрывать ошибки обхода дерева.
- Расширить GUI source fingerprint на полный детерминированный набор файлов crate и отдельно проверять recorded binary hash.
- Добавить регрессии для `target/`, отсутствующих manifest roots и неожиданных namespace failures.

## Non-goals

- Ротация, откат или любое редактирование `xros-gpg-prod/` и `xros-gpg-test/`.
- Изменение подписанных файлов и package database в `repo/xros/os/x86_64/`.
- Добавление зависимостей в профиль или Cargo manifests.
- Полная signed build provenance scheme с новым форматом release record; текущая задача добавляет проверяемую binary hash запись в существующую packaging flow.

## Constraints

- Сохранить поведение установщика и существующие capability skips для checkout на `v9fs/9p`.
- Использовать только Bash/Rust и уже доступные системные инструменты.
- Не создавать коммит.
- Финальная проверка: `./scripts/xros-diagnose.sh`, relevant scripts in `scripts/tests/`, `shellcheck`, `cargo check --offline`, `git diff --check`, затем `deslop`.

## Approaches

1. **Minimal diagnostic hardening (chosen).** Ужесточить текущие проверки локально: явный opt-in для developer skip, strict manifest roots, fail closed для внутренних namespace errors, полный source set и binary hash. Это сохраняет существующую структуру и не меняет trust model.
2. **Signed build record and key rotation.** Ввести подписанный record с source hash, binary hash, toolchain и commit, затем провести ротацию production key. Это сильнее для provenance, но требует отдельного согласования формата и изменения защищённого trust anchor.
3. **No code changes.** Оставить текущие skips и документировать ограничения. Это не устраняет подтверждённые false-success пути и не подходит для merge gate.

В выбранном варианте binary hash будет проверяться как конкретная запись, связанная с staged GUI binary и PKGBUILD. Подписанная provenance-схема остаётся отдельной задачей.

## Design

- `scripts/xros-diagnose.sh` проверяет Git availability/repository state перед любым developer-only exception. По умолчанию package file mismatch остаётся `FAIL`; opt-in переменная допускает `SKIP` только при наличии релевантного `PKGBUILD` diff в `HEAD`, index или worktree.
- E2E harness-ы считают только capability probe failures ожидаемым `SKIP`. Non-zero внутреннего `unshare` сценария увеличивает `FAIL` и возвращает ненулевой код.
- `scripts/make-sources-manifest.sh` требует `src`, `branding`, `profile`, `scripts` и `packages`; ошибки `find`, `sort` или `sha256sum` завершают генерацию с ошибкой.
- GUI fingerprint собирается из рекурсивного списка Rust source/config inputs, исключая generated `target/`; sidecar содержит source fingerprint, а отдельная binary hash запись проверяет доставленный executable. Список и формат остаются детерминированными.
- Тесты проверяют новые отрицательные случаи, не изменяя production artifacts.

## Verification

После реализации должны быть подтверждены:

- diagnose без developer opt-in не маскирует stale package mismatch;
- явный developer opt-in работает только для локально изменённого relevant `PKGBUILD`;
- внутренний E2E failure даёт `FAIL`, capability limitation даёт `SKIP`;
- manifest отказывает при отсутствующем обязательном root и исключает `target/`;
- GUI source и binary hashes совпадают с актуальными records;
- существующие POSIX E2E и v9fs capability behavior сохраняются.
