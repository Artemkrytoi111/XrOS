#!/bin/bash
# XrOS GPG-тест (D10): подписание тестового пакета и проверка того, что
# pacman с SigLevel = Required принимает подписанный пакет и ОТКАЗЫВАЕТ
# неподписанному пакету и пакету с плохой подписью.
#
# ЗАПУСКАТЬ ТОЛЬКО ПОСЛЕ СБОРКИ (build rootfs свободен, mkarchiso не идёт):
#   ./xros-gpg-test/run-gpg-test.sh
# Работает ТОЛЬКО с локальным тестовым репозиторием
# ~/workspace/xros/xros-gpg-test/ — настоящий репозиторий XrOS
# (~/workspace/xros/repo/ и XrOS-Security-Updates) НЕ трогается.
# Приватный ключ в chroot НЕ копируется: подписание делается gpg
# НА ХОСТЕ (ключ там и живёт), repo-add в chroot — БЕЗ --sign
# (только построение БД), pacman — тоже в chroot, со своим
# отдельным GPGDir и DBPath (системные базы не трогаются).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$ROOT/xros-gpg-test"
REPO_DIR="$TEST_DIR/test/os/x86_64"
FPR="0EC935D2A8E31AEC1878BBE5797805A298A55BAA"
# Тестовый пакет — xros-installer 1.0-5 (текущая реальная сборка с Diamond):
# в build rootfs установлен 1.0-2, поэтому pacman -Sw видит 1.0-5 как
# ОБНОВЛЕНИЕ и реально скачивает его с проверкой подписи. Пакеты,
# уже установленные в той же версии (xros-cli 1.0-1 и др.), pacman
# пропускает как «up to date» — их подпись при -Sw не проверяется,
# поэтому они для этого теста не подходят.
PKG="xros-installer-1.0-5-x86_64.pkg.tar.zst"
PKG_SRC="$ROOT/repo/xros/os/x86_64/$PKG"
# xros-branding — зависимость xros-installer; тестовый pacman работает
# с пустой локальной БД (DBPath=/tmp/xros-gpg-test/db), поэтому все
# зависимости должны быть в sync-БД: xros-branding — только в [test].
BRANDING_SRC="$ROOT/repo/xros/os/x86_64/xros-branding-1.0-2-any.pkg.tar.zst"
BUILD_ENV="$ROOT/scripts/xros-build-env.sh"
export GNUPGHOME="$HOME/.gnupg-xros"
PASSFILE="$HOME/workspace/xros-secure/gpg/passphrase.txt"

die() { echo "gpg-test: ОШИБКА: $*" >&2; exit 1; }
log() { echo "gpg-test: $*"; }

[[ -f "$PKG_SRC" ]] || die "нет тестового пакета: $PKG_SRC"
[[ -f "$PASSFILE" ]] || die "нет файла парольной фразы (нужен для подписи)"
[[ -x "$BUILD_ENV" ]] || die "нет $BUILD_ENV"
# Сборка не должна идти параллельно: mkarchiso держит rootfs.
if pgrep -f "scripts/build.sh" >/dev/null 2>&1; then
  die "идёт сборка (build.sh) — запускайте тест после неё"
fi

# --- 1. тестовый репозиторий (локальный) --------------------------------------
log "== 1. Тестовый репозиторий =="
mkdir -p "$REPO_DIR"
cp "$PKG_SRC" "$REPO_DIR/"
cp "$BRANDING_SRC" "$REPO_DIR/"
cp "$HOME/workspace/xros-secure/gpg/xros-public.key" "$TEST_DIR/xros-public.key"
chmod 644 "$TEST_DIR/xros-public.key"

# --- 2. БД репозитория (repo-add БЕЗ подписи — ключ для этого не нужен) ------
log "== 2. repo-add (без подписи) в chroot =="
"$BUILD_ENV" --exec -- bash -c 'cd /xros/xros-gpg-test/test/os/x86_64 && repo-add test.db.tar.gz *.pkg.tar.zst' \
  || die "repo-add не удался"
[[ -f "$REPO_DIR/test.db.tar.gz" ]] || die "нет test.db.tar.gz после repo-add"

# --- 3. Подписание НА ХОСТЕ (gpg, ключ не покидает хост) ---------------------
log "== 3. Подписание пакета и БД (gpg на хосте) =="
for f in "$REPO_DIR"/*.pkg.tar.zst; do
  gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASSFILE" \
    --detach-sign --armor "$f" \
    || die "подпись пакета $f не удалась"
  mv "$f.asc" "$f.sig"
done
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASSFILE" \
  --detach-sign --armor "$REPO_DIR/test.db.tar.gz" \
  || die "подпись БД не удалась"
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$PASSFILE" \
  --detach-sign --armor "$REPO_DIR/test.files.tar.gz" \
  || die "подпись files-БД не удалась"
# gpg --armor пишет подписи как .asc; pacman ждёт .sig — переименовываем.
mv "$REPO_DIR/test.db.tar.gz.asc" "$REPO_DIR/test.db.tar.gz.sig"
mv "$REPO_DIR/test.files.tar.gz.asc" "$REPO_DIR/test.files.tar.gz.sig"
# pacman запрашивает test.db.sig (а не test.db.tar.gz.sig) — ссылка.
ln -sf test.db.tar.gz.sig "$REPO_DIR/test.db.sig"
ln -sf test.files.tar.gz.sig "$REPO_DIR/test.files.sig"
gpg --batch --verify "$REPO_DIR/$PKG.sig" "$REPO_DIR/$PKG" \
  || die "gpg --verify подписи пакета не прошла"
log "подписи созданы и проверены gpg --verify"

# --- 4. Тестовый pacman.conf (только [test] с SigLevel = Required) --------
log "== 4. Тестовый pacman.conf =="
cat >"$TEST_DIR/pacman-test.conf" <<'EOF'
[options]
RootDir = /
DBPath = /tmp/xros-gpg-test/db
CacheDir = /tmp/xros-gpg-test/cache
GPGDir = /tmp/xros-gpg-test/gnupg
Architecture = x86_64
SigLevel = Never
# [core]/[extra] нужны только для разрешения зависимостей тестового
# пакета (glibc, python-pyqt6 и др.); их подписи в этом тесте НЕ
# проверяются (SigLevel = Never) — предмет теста только [test].
[core]
SigLevel = Never
Include = /etc/pacman.d/mirrorlist
[extra]
SigLevel = Never
Include = /etc/pacman.d/mirrorlist
[test]
SigLevel = Required
Server = file:///xros/xros-gpg-test/test/os/x86_64
EOF

# --- 5. pacman-тесты в chroot -------------------------------------------------
log "== 5. pacman-тесты в chroot =="
CHROOT_TEST="$TEST_DIR/chroot-test.sh"
cat >"$CHROOT_TEST" <<'EOF'
#!/bin/bash
# Выполняется ВНУТРИ build-env rootfs. CONF — /xros/xros-gpg-test/pacman-test.conf.
set -u
CONF="/xros/xros-gpg-test/pacman-test.conf"
GPGDIR="/tmp/xros-gpg-test/gnupg"
DBDIR="/tmp/xros-gpg-test/db"
CACHEDIR="/tmp/xros-gpg-test/cache"
FPR="0EC935D2A8E31AEC1878BBE5797805A298A55BAA"
rm -rf /tmp/xros-gpg-test
mkdir -p "$GPGDIR" "$DBDIR" "$CACHEDIR"
pacman-key --config "$CONF" --init || exit 1
pacman-key --config "$CONF" --add /xros/xros-gpg-test/xros-public.key || exit 1
pacman-key --config "$CONF" --lsign-key "$FPR" || exit 1
echo "--- T1: подписанный пакет (ожидается УСПЕХ) ---"
pacman -Sy --config "$CONF" --noconfirm || exit 1
pacman -Sw xros-installer --config "$CONF" --noconfirm || exit 1
echo "T1 PASS: подписанный пакет скачан и проверен"
rm -rf "$CACHEDIR"/* "$DBDIR"/*
echo "--- T2: неподписанный пакет (ожидается ОТКАЗ) ---"
rm -f /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig
if pacman -Sy --config "$CONF" --noconfirm 2>/tmp/xros-gpg-test/t2.log \
   && pacman -Sw xros-installer --config "$CONF" --noconfirm 2>>/tmp/xros-gpg-test/t2.log; then
  echo "T2 FAIL: неподписанный пакет ПРИНЯТ (так быть не должно)"
  exit 1
else
  echo "T2 PASS: неподписанный пакет отклонён"
  grep -iE "signature|подпис" /tmp/xros-gpg-test/t2.log | head -3 || true
fi
rm -rf "$CACHEDIR"/* "$DBDIR"/*
echo "--- T3: плохая подпись (ожидается ОТКАЗ) ---"
cp /xros/xros-gpg-test/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig.bak \
   /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig 2>/dev/null || true
# Портим подпись ВНУТРИ брони: обрезаем файл до 120 байт (тело подписи
# обрывается на середине) — gpg не сможет её разобрать. Просто дописать
# мусор ПОСЛЕ '-----END PGP SIGNATURE-----' НЕ работает: gpg игнорирует
# всё после END, и подпись остаётся валидной (проверено: T3 дал ложный
# FAIL на первом запуске именно из-за этого).
head -c 120 /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig \
  > /tmp/xros-gpg-test/corrupt.sig
mv /tmp/xros-gpg-test/corrupt.sig \
   /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig
if pacman -Sy --config "$CONF" --noconfirm 2>/tmp/xros-gpg-test/t3.log \
   && pacman -Sw xros-installer --config "$CONF" --noconfirm 2>>/tmp/xros-gpg-test/t3.log; then
  echo "T3 FAIL: пакет с плохой подписью ПРИНЯТ (так быть не должно)"
  exit 1
else
  echo "T3 PASS: пакет с плохой подписью отклонён"
  grep -iE "signature|подпис" /tmp/xros-gpg-test/t3.log | head -3 || true
fi
echo "GPG-ТЕСТ: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ (T1 PASS, T2 PASS, T3 PASS)"
EOF
chmod +x "$CHROOT_TEST"
# Сохраняем эталон подписи для восстановления в T3.
cp "$REPO_DIR/$PKG.sig" \
   "$TEST_DIR/$PKG.sig.bak"
"$BUILD_ENV" --exec -- bash /xros/xros-gpg-test/chroot-test.sh \
  | tee "$TEST_DIR/gpg-test.log"
grep -q "GPG-ТЕСТ: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" "$TEST_DIR/gpg-test.log" \
  || die "pacman-тесты не прошли — см. $TEST_DIR/gpg-test.log"
log "ГОТОВО: $TEST_DIR/gpg-test.log"
