#!/usr/bin/env bash
# XrOS — офлайн-подписание пакетов и базы репозитория (A-40).
#
# ТОЛЬКО на офлайн-машине владельца, где лежит приватный production-ключ.
# НЕ запускать в build-env, не копировать приватный ключ в репозиторий.
# Использование: sign-repo-offline.sh <каталог-repo> <отпечаток-ключа>
# Что делает:
#   1. Проверяет, что приватный ключ с заданным отпечатком есть
#      в GNUPGHOME владельца и умеет подписывать.
#   2. Подписывает каждый *.pkg.tar.zst (gpg --detach-sign -> .sig).
#   3. Пересобирает БД с подписью (repo-add -s).
#      R-12: ключ подписи задаётся явно через GPGKEY (у repo-add нет
#      флага --key; GPGKEY читается из makepkg.conf или окружения).
#      Если ключ выбран неверно — подпись БД не пройдёт проверку
#      production-ключом на шаге 4 (fail-closed).
#   4. Проверяет все подписи (scripts/verify-repo-signatures.sh).
#   5. Создаёт и подписывает manifest исходников (R-10):
#      scripts/make-sources-manifest.sh — хеши src/, branding/
#      и PKGBUILD; релизная сборка проверяет manifest вместо mtime.
#      После создания — самопроверка (verify-sources-manifest.sh).
# После этого релизная сборка (scripts/build.sh --release) проверяет
# подписи гейтом и использует подписанный репозиторий как есть
# (пакеты и БД не пересобираются, чтобы не аннулировать подписи).
set -euo pipefail

REPO_DIR="${1:-}"
FPR="${2:-}"
[[ -n "$REPO_DIR" && -n "$FPR" ]] || { echo "sign-repo-offline: использование: $0 <repo-dir> <отпечаток>" >&2; exit 2; }
[[ -d "$REPO_DIR" ]] || { echo "sign-repo-offline: нет каталога: $REPO_DIR" >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "sign-repo-offline: нет gpg" >&2; exit 1; }
command -v repo-add >/dev/null 2>&1 || { echo "sign-repo-offline: нет repo-add (пакет pacman)" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Приватный ключ обязан быть в keyring владельца.
gpg --batch --list-secret-keys --with-colons "$FPR" 2>/dev/null | grep -q '^sec' \
  || { echo "sign-repo-offline: в GNUPGHOME нет приватного ключа $FPR — подписывать нечем" >&2; exit 1; }
echo "sign-repo-offline: подписываю пакеты в $REPO_DIR ключом $FPR"
shopt -s nullglob
pkgs=("$REPO_DIR"/*.pkg.tar.zst)
[[ "${#pkgs[@]}" -gt 0 ]] || { echo "sign-repo-offline: нет пакетов в $REPO_DIR" >&2; exit 1; }
for p in "${pkgs[@]}"; do
  gpg --batch --yes --detach-sign --local-user "$FPR" --output "$p.sig" "$p" \
    || { echo "sign-repo-offline: не удалось подписать $p" >&2; exit 1; }
  echo "sign-repo-offline: подписано: $p.sig"
done
# repo-add: пересборка БД + подпись БД (.db.sig, .files.sig).
# R-12: явный выбор ключа подписи через GPGKEY (у repo-add нет
# флага --key в pacman < 7; в pacman 7.1.0 есть -k/--key, но GPGKEY
# оставлен для совместимости со старыми версиями на машине владельца).
# Если makepkg.conf владельца задаёт другой GPGKEY,
# он перекроет окружение — поэтому подпись БД дополнительно
# проверяется production-ключом на шаге 4 (fail-closed).
# Фаза 5.1: опция -f УБРАНА — pacman 7.1.0 её не поддерживает
# (repo-add: invalid option -- 'f'). Без -f repo-add сам удаляет
# существующие записи и пересоздаёт их (проверено на pacman 7.1.0).
(cd "$REPO_DIR" && GPGKEY="$FPR" repo-add -s xros.db.tar.gz *.pkg.tar.zst) \
  || { echo "sign-repo-offline: repo-add -s не удался" >&2; exit 1; }
# Фаза 5A: aliases подписи БД как побайтовые копии (не симлинки).
# pacman требует xros.db.sig / xros.files.sig (имя БД + .sig). repo-add -s
# создаёт их как симлинки на xros.db.tar.gz.sig / xros.files.tar.gz.sig,
# но GitHub Pages (статический хостинг) надёжно отдаёт только обычные файлы.
# Заменяем симлинки побайтовыми копиями, иначе pacman -Sy падает
# (блокер №2, Фаза 4.5). Выполнять при КАЖДОМ подписании, иначе копии
# устареют после пересборки БД.
for _db in xros.db xros.files; do
  _src="$REPO_DIR/$_db.tar.gz.sig"
  _dst="$REPO_DIR/$_db.sig"
  [[ -f "$_src" ]] || { echo "sign-repo-offline: нет $_src после repo-add -s" >&2; exit 1; }
  rm -f "$_dst"
  cp "$_src" "$_dst" || { echo "sign-repo-offline: не удалось создать $_dst" >&2; exit 1; }
  chmod 644 "$_dst" || { echo "sign-repo-offline: не удалось выставить 644 на $_dst" >&2; exit 1; }
  cmp -s "$_src" "$_dst" || { echo "sign-repo-offline: $_dst не совпадает с $_src" >&2; exit 1; }
  echo "sign-repo-offline: alias создан: $_dst (копия $_src)"
done
# Проверка всех подписей публичным ключом.
PUB_KEY="$ROOT/xros-gpg-prod/xros-public.key"
[[ -f "$PUB_KEY" ]] || { echo "sign-repo-offline: нет публичного ключа $PUB_KEY — положите его рядом (см. xros-gpg-prod/README.md)" >&2; exit 1; }
"$ROOT/scripts/verify-repo-signatures.sh" "$REPO_DIR" "$PUB_KEY" "$FPR" \
  || { echo "sign-repo-offline: проверка подписей не прошла" >&2; exit 1; }
# R-10: manifest исходников + его подпись production-ключом.
"$ROOT/scripts/make-sources-manifest.sh" "$ROOT" "$REPO_DIR" "$FPR" \
  || { echo "sign-repo-offline: не удалось создать manifest исходников" >&2; exit 1; }
"$ROOT/scripts/verify-sources-manifest.sh" "$ROOT" "$REPO_DIR" "$PUB_KEY" "$FPR" \
  || { echo "sign-repo-offline: самопроверка manifest не прошла" >&2; exit 1; }
echo "sign-repo-offline: готово — пакеты и БД подписаны и проверены, manifest создан и проверен"
