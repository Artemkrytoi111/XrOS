#!/usr/bin/env bash
# XrOS — тесты manifest исходников (R-10).
#
# Проверяются РЕАЛЬНЫЕ скрипты scripts/make-sources-manifest.sh
# и scripts/verify-sources-manifest.sh на временном дереве
# исходников и эфемерных GPG-ключах (production-ключ не нужен):
#   * неизменённые исходники → PASS;
#   * изменённый/добавленный/удалённый исходник → FAIL;
#   * отсутствующий manifest или подпись → FAIL;
#   * подменённый manifest (хеш изменён, подпись старая) → FAIL;
#   * manifest, подписанный другим ключом → FAIL;
#   * manifest без подписи (без FPR) → FAIL при проверке.
# Временное дерево — в mktemp; production-конфигурации не трогаются.
#
# Запуск: ./scripts/tests/test-sources-manifest.sh
# Выход: 0 — все PASS, 1 — есть FAIL. SKIP — честный пропуск.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MAKE="$ROOT/scripts/make-sources-manifest.sh"
VERIFY="$ROOT/scripts/verify-sources-manifest.sh"
PASS=0; FAIL=0; SKIPN=0
FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP  $1 ($2)"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

[[ -x "$MAKE" ]] || { bad "make-sources-manifest.sh исполняем"; echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"; exit 1; }
[[ -x "$VERIFY" ]] || { bad "verify-sources-manifest.sh исполняем"; echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"; exit 1; }
ok "скрипты manifest исполнимы"

if ! command -v gpg >/dev/null 2>&1; then
  skip "manifest: все кейсы" "нет gpg"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  exit 0
fi

# --- временное дерево исходников ---
R="$T/root"; REPO="$T/repo"
mkdir -p "$R/src/xros-installer-diamond" "$R/branding" "$R/packages/xros-installer" "$REPO"
printf 'engine v1\n' > "$R/src/xros-install"
printf 'bridge v1\n' > "$R/src/xros-installer-diamond/bridge.py"
printf 'logo\n' > "$R/branding/logo.png"
printf 'pkgname=xros-installer\n' > "$R/packages/xros-installer/PKGBUILD"

# --- эфемерные ключи ---
# Обёртка gpg для скриптов: в тестовом окружении нет tty/pinentry,
# поэтому подпись выполняется через loopback с пустой парольной
# фразой (тот же приём, что в test-gpg-handling.sh: GPG с
# --pinentry-mode loopback --passphrase ''). Production-скрипты
# при этом не меняются: на офлайн-машине владельца pinentry
# работает штатно.
GPG_REAL="$(command -v gpg)"
mkdir -p "$T/bin"
cat > "$T/bin/gpg" <<EOF
#!/usr/bin/env bash
exec "$GPG_REAL" --batch --pinentry-mode loopback --passphrase '' "\$@"
EOF
chmod +x "$T/bin/gpg"
export PATH="$T/bin:$PATH"
export GNUPGHOME="$T/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
# gpg-agent обязан разрешать loopback-pinentry, иначе подпись
# из скрипта (без tty) падает «No passphrase given»: агент
# читает этот конфиг при первом запуске, поэтому пишется ДО
# первого вызова gpg.
printf 'allow-loopback-pinentry\n' > "$GNUPGHOME/gpg-agent.conf"
# ВАЖНО: GPG — массив, а не строка: при раскрытии строковой переменной
# '' превратилось бы в литерал из двух кавычек и стало бы паролем ключа
# (поймано отладкой: подпись падала «No passphrase given»).
GPG=(gpg --batch --pinentry-mode loopback --passphrase '')
"${GPG[@]}" --quick-gen-key "XrOS Manifest <man@xros.invalid>" ed25519 sign 0 2>/dev/null
"${GPG[@]}" --export --armor "XrOS Manifest" > "$T/sign.pub"
FPR="$("${GPG[@]}" --show-keys --with-colons "$T/sign.pub" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
"${GPG[@]}" --quick-gen-key "XrOS Other <other@xros.invalid>" ed25519 sign 0 2>/dev/null
"${GPG[@]}" --export --armor "XrOS Other" > "$T/other.pub"
OTHER_FPR="$("${GPG[@]}" --show-keys --with-colons "$T/other.pub" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
[[ -n "$FPR" && -n "$OTHER_FPR" ]] || { bad "manifest: эфемерные ключи не создались"; echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"; exit 1; }
ok "manifest: эфемерные ключи созданы"

# run_verify <имя> <ожидаемое pass|fail>
run_verify() {
  local name="$1" want="$2"
  local got
  if "$VERIFY" "$R" "$REPO" "$T/sign.pub" "$FPR" > "$T/v.log" 2>&1; then got="pass"; else got="fail"; fi
  if [[ "$got" == "$want" ]]; then ok "manifest $name: $want"; else bad "manifest $name: ожидалось $want, получено $got"; cat "$T/v.log"; fi
}

# 1. Создание + проверка неизменённых исходников → PASS.
"$MAKE" "$R" "$REPO" "$FPR" > "$T/m.log" 2>&1 \
  && ok "manifest: создание с подписью" \
  || { bad "manifest: создание с подписью"; cat "$T/m.log"; }
[[ -f "$REPO/xros-sources.manifest" && -f "$REPO/xros-sources.manifest.sig" ]] \
  && ok "manifest: файлы manifest и .sig созданы" \
  || bad "manifest: файлы manifest и .sig созданы"
run_verify "неизменённые исходники" pass
# Формат manifest — как у sha256sum (проверяется sha256sum -c).
if (cd "$R" && sha256sum -c "$REPO/xros-sources.manifest" > /dev/null 2>&1); then
  ok "manifest: формат совместим с sha256sum -c"
else
  bad "manifest: формат совместим с sha256sum -c"
fi
# 2. Изменённый исходник → FAIL.
printf 'engine v2\n' > "$R/src/xros-install"
run_verify "изменённый исходник" fail
printf 'engine v1\n' > "$R/src/xros-install"
run_verify "возврат к исходному" pass
# 3. Добавленный исходник → FAIL.
printf 'new\n' > "$R/src/new-file"
run_verify "добавленный исходник" fail
rm -f "$R/src/new-file"
# 4. Удалённый исходник → FAIL.
mv "$R/branding/logo.png" "$T/logo.bak"
run_verify "удалённый исходник" fail
mv "$T/logo.bak" "$R/branding/logo.png"
run_verify "возврат после удаления" pass
# 5. Изменённый PKGBUILD → FAIL.
printf 'pkgname=xros-installer\npkgver=2\n' > "$R/packages/xros-installer/PKGBUILD"
run_verify "изменённый PKGBUILD" fail
printf 'pkgname=xros-installer\n' > "$R/packages/xros-installer/PKGBUILD"
# 6. Отсутствующий manifest → FAIL.
mv "$REPO/xros-sources.manifest" "$T/manifest.bak"
run_verify "нет manifest" fail
mv "$T/manifest.bak" "$REPO/xros-sources.manifest"
# 7. Отсутствующая подпись → FAIL.
mv "$REPO/xros-sources.manifest.sig" "$T/manifest.sig.bak"
run_verify "нет подписи manifest" fail
mv "$T/manifest.sig.bak" "$REPO/xros-sources.manifest.sig"
# 8. Подменённый manifest (хеш изменён, подпись старая) → FAIL.
sed -i 's/^[0-9a-f]/0/' "$REPO/xros-sources.manifest"
run_verify "подменённый хеш в manifest" fail
"$MAKE" "$R" "$REPO" "$FPR" > /dev/null 2>&1
run_verify "пересоздание после подмены" pass
# 9. Manifest, подписанный другим ключом → FAIL.
"$MAKE" "$R" "$REPO" "$OTHER_FPR" > /dev/null 2>&1
if "$VERIFY" "$R" "$REPO" "$T/sign.pub" "$FPR" > "$T/v.log" 2>&1; then
  bad "manifest подписан другим ключом: ожидалось fail, получено pass"; cat "$T/v.log"
else
  ok "manifest подписан другим ключом: fail"
fi
"$MAKE" "$R" "$REPO" "$FPR" > /dev/null 2>&1
# 10. Manifest без подписи (без FPR) → FAIL при проверке.
"$MAKE" "$R" "$REPO" > /dev/null 2>&1
rm -f "$REPO/xros-sources.manifest.sig"
run_verify "manifest без подписи" fail
"$MAKE" "$R" "$REPO" "$FPR" > /dev/null 2>&1
run_verify "восстановление подписи" pass
# 11. build.sh использует verify-sources-manifest.sh в релизной ветке
#     и не содержит прежней mtime-проверки.
if grep -q 'verify-sources-manifest.sh' "$ROOT/scripts/build.sh"; then
  ok "build.sh: релизная ветка вызывает verify-sources-manifest.sh"
else
  bad "build.sh: релизная ветка вызывает verify-sources-manifest.sh"
fi
if grep -q 'find "$ROOT/src" "$ROOT/branding" -type f -newer' "$ROOT/scripts/build.sh"; then
  bad "build.sh: mtime-проверка свежести удалена"
else
  ok "build.sh: mtime-проверка свежести удалена"
fi
# 12. sign-repo-offline.sh создаёт manifest (шаг 5).
if grep -q 'make-sources-manifest.sh' "$ROOT/scripts/sign-repo-offline.sh"; then
  ok "sign-repo-offline.sh: создаёт manifest исходников"
else
  bad "sign-repo-offline.sh: создаёт manifest исходников"
fi
# 13. Release inputs include profile/build files and exclude generated,
#     backup and documentation-only files.
mkdir -p "$R/profile" "$R/profile/airootfs/usr/share/xros/repo" \
  "$R/profile/airootfs/usr/local/bin" "$R/profile/airootfs/usr/local/lib" \
  "$R/scripts" "$R/src/__pycache__"
printf 'profile input\n' > "$R/profile/profiledef.sh"
printf 'build input\n' > "$R/scripts/build.sh"
printf 'repo snapshot\n' > "$R/profile/airootfs/usr/share/xros/repo/xros.db.tar.gz"
printf 'staged binary\n' > "$R/profile/airootfs/usr/local/bin/xros"
printf 'staged library\n' > "$R/profile/airootfs/usr/local/lib/bridge.py"
printf 'generated\n' > "$R/src/generated.pyc"
printf 'generated\n' > "$R/src/__pycache__/generated.pyc"
printf 'generated\n' > "$R/src/generated.sig"
printf 'generated\n' > "$R/profile/old.db.old"
printf 'generated\n' > "$R/profile/generated.pkg.tar.zst"
printf 'backup\n' > "$R/src/old.bak"
printf 'docs\n' > "$R/README.md"
printf 'docs\n' > "$R/src/README.md"
"$MAKE" "$R" "$REPO" "$FPR" > /dev/null 2>&1
if grep -qE '  profiledef\.sh$|  scripts/build\.sh$' "$REPO/xros-sources.manifest"; then
  ok "manifest: профиль и build inputs включены"
else
  bad "manifest: профиль и build inputs включены"
fi
if grep -qE '\.bak$|\.pyc$|\.sig$|\.old$|\.pkg\.tar\.|README\.md$|__pycache__|profile/airootfs/usr/share/xros/repo/|profile/airootfs/usr/local/bin/|profile/airootfs/usr/local/lib/' "$REPO/xros-sources.manifest"; then
  bad "manifest: generated/backup/documentation files исключены"
else
  ok "manifest: generated/backup/documentation files исключены"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
if [[ $FAIL -gt 0 ]]; then
  echo "Не пройдено:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
