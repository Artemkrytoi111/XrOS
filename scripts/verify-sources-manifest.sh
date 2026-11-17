#!/usr/bin/env bash
# XrOS — проверка manifest исходников перед релизной сборкой (R-10).
#
# Использование: verify-sources-manifest.sh <root> <repo-dir> <публичный-ключ> <отпечаток>
# Проверяет:
#   * manifest и его подпись существуют;
#   * подпись сделана production-ключом (проверка во ВРЕМЕННОМ
#     GNUPGHOME, отпечаток импортированного ключа обязан совпасть
#     с ожидаемым; подменённый manifest — FAIL);
#   * текущие исходники совпадают с manifest (повторная генерация
#     тем же скриптом и побайтовое сравнение: изменённый, добавленный
#     или удалённый файл — FAIL).
# Не использует mtime: свежий git clone не роняет проверку.
# Выход 0 — исходники соответствуют подписанному manifest; иначе
# ненулевой код и причина в stderr.
# Используется в релизной ветке шага 6 scripts/build.sh (вместо
# прежней mtime-проверки, R-10) и в sign-repo-offline.sh (самопроверка).
set -euo pipefail

ROOT="${1:-}"
REPO_DIR="${2:-}"
KEY_FILE="${3:-}"
EXPECTED="${4:-}"
[[ -n "$ROOT" && -n "$REPO_DIR" && -n "$KEY_FILE" && -n "$EXPECTED" ]] || { echo "verify-sources-manifest: использование: $0 <root> <repo-dir> <публичный-ключ> <отпечаток>" >&2; exit 2; }
[[ -d "$ROOT/src" && -d "$REPO_DIR" ]] || { echo "verify-sources-manifest: нет каталогов: $ROOT/src или $REPO_DIR" >&2; exit 1; }
[[ -f "$KEY_FILE" ]] || { echo "verify-sources-manifest: нет публичного ключа: $KEY_FILE" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKE="$SCRIPT_DIR/make-sources-manifest.sh"
[[ -x "$MAKE" ]] || { echo "verify-sources-manifest: нет исполняемого $MAKE" >&2; exit 1; }

MANIFEST="$REPO_DIR/xros-sources.manifest"
[[ -f "$MANIFEST" ]] || { echo "verify-sources-manifest: нет manifest: $MANIFEST — пакеты подписаны до введения manifest; подпишите офлайн заново (sign-repo-offline.sh)" >&2; exit 1; }
[[ -f "$MANIFEST.sig" ]] || { echo "verify-sources-manifest: нет подписи manifest: $MANIFEST.sig" >&2; exit 1; }

# Подпись — production-ключом (временный GNUPGHOME, как в
# verify-repo-signatures.sh).
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
chmod 700 "$TMP_HOME"
gpg --batch --homedir "$TMP_HOME" --import "$KEY_FILE" >/dev/null 2>&1 \
  || { echo "verify-sources-manifest: не удалось импортировать ключ во временный keyring" >&2; exit 1; }
IMPORTED="$(gpg --batch --homedir "$TMP_HOME" --list-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
IMPORTED="$(printf '%s' "$IMPORTED" | tr -d '[:space:]' | tr 'a-f' 'A-F')"
NORM_EXPECTED="$(printf '%s' "$EXPECTED" | tr -d '[:space:]' | tr 'a-f' 'A-F')"
[[ "$IMPORTED" == "$NORM_EXPECTED" ]] || { echo "verify-sources-manifest: импортированный ключ $IMPORTED != ожидаемый $NORM_EXPECTED" >&2; exit 1; }
gpg --batch --homedir "$TMP_HOME" --verify "$MANIFEST.sig" "$MANIFEST" >/dev/null 2>&1 \
  || { echo "verify-sources-manifest: НЕВЕРНАЯ подпись manifest (подменён или подписан не production-ключом)" >&2; exit 1; }
echo "verify-sources-manifest: подпись manifest проверена (ключ $NORM_EXPECTED)"

# Состав и хеши — повторная генерация и побайтовое сравнение.
FRESH_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME" "$FRESH_DIR"' EXIT
"$MAKE" "$ROOT" "$FRESH_DIR" >/dev/null \
  || { echo "verify-sources-manifest: не удалось сгенерировать свежий manifest" >&2; exit 1; }
if diff -u "$MANIFEST" "$FRESH_DIR/xros-sources.manifest" > "$FRESH_DIR/diff.txt" 2>&1; then
  echo "verify-sources-manifest: исходники соответствуют подписанному manifest ($(wc -l < "$MANIFEST") файлов)"
  exit 0
fi
echo "verify-sources-manifest: исходники НЕ соответствуют подписанному manifest:" >&2
grep -E '^[+-][^+-]' "$FRESH_DIR/diff.txt" | head -20 | sed 's/^/  /' >&2
echo "verify-sources-manifest: пересоберите с --confirm и подпишите офлайн заново (см. docs/REPO-PUBLISHING.md)" >&2
exit 1
