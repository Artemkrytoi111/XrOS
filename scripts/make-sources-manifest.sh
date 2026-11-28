#!/usr/bin/env bash
# XrOS — manifest исходников для релизной проверки свежести (R-10).
#
# Использование: make-sources-manifest.sh <root> <repo-dir> [fpr]
# Создаёт <repo-dir>/xros-sources.manifest — sha256 явных release inputs:
# src/**, branding/**, profile/**, scripts/** и PKGBUILD пакетов.
# Generated/backup-файлы, подписи, архивы и Markdown-документация в release
# surface не входят.
# Пути — относительные от <root>, формат — как у sha256sum (проверяется
# `sha256sum -c`).
# Если задан [fpr] — manifest подписывается этим ключом
# (gpg --detach-sign -> xros-sources.manifest.sig) в GNUPGHOME
# вызывающего (офлайн-машина владельца).
# Без [fpr] — только manifest без подписи (для сверки в тестах
# и в verify-sources-manifest.sh).
# Вызывается из sign-repo-offline.sh (шаг 5) после подписания
# пакетов и БД. Подмены manifest не допускается: релизная сборка
# проверяет его подпись production-ключом (verify-sources-manifest.sh).
set -euo pipefail

ROOT="${1:-}"
REPO_DIR="${2:-}"
FPR="${3:-}"
[[ -n "$ROOT" && -n "$REPO_DIR" ]] || { echo "make-sources-manifest: использование: $0 <root> <repo-dir> [fpr]" >&2; exit 2; }
[[ -d "$ROOT/src" && -d "$REPO_DIR" ]] || { echo "make-sources-manifest: нет каталогов: $ROOT/src или $REPO_DIR" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "make-sources-manifest: нет sha256sum" >&2; exit 1; }

MANIFEST="$REPO_DIR/xros-sources.manifest"
# Один источник истины для состава manifest: тот же find используется
# в verify-sources-manifest.sh (сверка через повторную генерацию).
# Пустые/отсутствующие release roots не роняют генерацию; пустой manifest
# ловится проверкой -s ниже.
(cd "$ROOT" && {
  find src branding profile scripts -type f \
    ! -name '*.bak' ! -name '*.pyc' ! -name '*.sig' ! -name '*.old' \
    ! -name '*.pkg.tar.*' ! -path '*/__pycache__/*' \
    ! -path '*/target/*' \
    ! -name '*.md' \
    ! -path 'profile/airootfs/usr/share/xros/repo/*' \
    ! -path 'profile/airootfs/usr/local/bin/*' \
    ! -path 'profile/airootfs/usr/local/lib/*' \
    -print0 2>/dev/null || true
  find packages -maxdepth 2 -name PKGBUILD -type f -print0 2>/dev/null || true
} | sort -z | xargs -0 sha256sum > "$MANIFEST.tmp") \
  || { echo "make-sources-manifest: не удалось вычислить хеши" >&2; exit 1; }
[[ -s "$MANIFEST.tmp" ]] || { echo "make-sources-manifest: пустой manifest — нет исходников?" >&2; exit 1; }
mv "$MANIFEST.tmp" "$MANIFEST"
echo "make-sources-manifest: создан $MANIFEST ($(wc -l < "$MANIFEST") файлов)"

if [[ -n "$FPR" ]]; then
  command -v gpg >/dev/null 2>&1 || { echo "make-sources-manifest: нет gpg" >&2; exit 1; }
  gpg --batch --yes --detach-sign --local-user "$FPR" --output "$MANIFEST.sig" "$MANIFEST" \
    || { echo "make-sources-manifest: не удалось подписать manifest ключом $FPR" >&2; exit 1; }
  echo "make-sources-manifest: подписан: $MANIFEST.sig"
fi
