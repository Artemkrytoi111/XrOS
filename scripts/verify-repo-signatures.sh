#!/usr/bin/env bash
# XrOS — проверка подписей пакетов и базы репозитория (A-40).
#
# Использование: verify-repo-signatures.sh <каталог-repo> <публичный-ключ> <отпечаток>
# Проверяет:
#   * публичный ключ — через xros-gpg-check (формат, отпечаток, срок, sign);
#   * каждый *.pkg.tar.zst имеет .sig, и подпись проверяется этим ключом;
#   * xros.db.tar.gz и xros.files.tar.gz (если есть) имеют .sig,
#     и подписи проверяются.
# Ключ импортируется только во ВРЕМЕННЫЙ GNUPGHOME (trap удаляет его).
# Выход 0 — все подписи валидны; иначе ненулевой код и причина в stderr.
# Подменённый пакет или БД — FAIL (gpg --verify не проходит).
set -euo pipefail

REPO_DIR="${1:-}"
KEY_FILE="${2:-}"
EXPECTED="${3:-}"
[[ -n "$REPO_DIR" && -n "$KEY_FILE" && -n "$EXPECTED" ]] || { echo "verify-repo-signatures: использование: $0 <repo-dir> <публичный-ключ> <отпечаток>" >&2; exit 2; }
[[ -d "$REPO_DIR" ]] || { echo "verify-repo-signatures: нет каталога репозитория: $REPO_DIR" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/profile/airootfs/usr/local/bin/xros-gpg-check"
[[ -x "$CHECK" ]] || { echo "verify-repo-signatures: нет исполняемого $CHECK" >&2; exit 1; }
"$CHECK" "$KEY_FILE" "$EXPECTED" || exit 1

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
chmod 700 "$TMP_HOME"
gpg --batch --homedir "$TMP_HOME" --import "$KEY_FILE" >/dev/null 2>&1 \
  || { echo "verify-repo-signatures: не удалось импортировать ключ во временный keyring" >&2; exit 1; }
# Отпечаток импортированного ключа обязан совпасть с ожидаемым.
IMPORTED="$(gpg --batch --homedir "$TMP_HOME" --list-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
IMPORTED="$(printf '%s' "$IMPORTED" | tr -d '[:space:]' | tr 'a-f' 'A-F')"
NORM_EXPECTED="$(printf '%s' "$EXPECTED" | tr -d '[:space:]' | tr 'a-f' 'A-F')"
[[ "$IMPORTED" == "$NORM_EXPECTED" ]] || { echo "verify-repo-signatures: импортированный ключ $IMPORTED != ожидаемый $NORM_EXPECTED" >&2; exit 1; }

fail=0
check_sig() { # $1=файл, $2=.sig
  local f="$1" sig="$2"
  if [[ ! -f "$sig" ]]; then
    echo "verify-repo-signatures: нет подписи: $sig" >&2; fail=1; return
  fi
  if gpg --batch --homedir "$TMP_HOME" --verify "$sig" "$f" >/dev/null 2>&1; then
    echo "verify-repo-signatures: OK: $f"
  else
    echo "verify-repo-signatures: НЕВЕРНАЯ подпись: $sig (файл $f)" >&2; fail=1
  fi
}

shopt -s nullglob
pkgs=("$REPO_DIR"/*.pkg.tar.zst)
[[ "${#pkgs[@]}" -gt 0 ]] || { echo "verify-repo-signatures: в $REPO_DIR нет пакетов *.pkg.tar.zst" >&2; exit 1; }
for p in "${pkgs[@]}"; do check_sig "$p" "$p.sig"; done
[[ -f "$REPO_DIR/xros.db.tar.gz" ]] || { echo "verify-repo-signatures: нет БД $REPO_DIR/xros.db.tar.gz" >&2; exit 1; }
check_sig "$REPO_DIR/xros.db.tar.gz" "$REPO_DIR/xros.db.tar.gz.sig"
if [[ -f "$REPO_DIR/xros.files.tar.gz" ]]; then
  check_sig "$REPO_DIR/xros.files.tar.gz" "$REPO_DIR/xros.files.tar.gz.sig"
fi
[[ "$fail" -eq 0 ]] || exit 1
echo "verify-repo-signatures: все подписи валидны (${#pkgs[@]} пакетов + БД)"
