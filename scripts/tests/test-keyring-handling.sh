#!/usr/bin/env bash
# XrOS — тесты обработки ошибок keyring (R-06, R-07).
#
# Проверяется НАСТОЯЩИЙ движок src/xros-install в unshare -rm
# с LD_PRELOAD-шимом (как в test-raid-block.sh, секция D):
#   * pacman-key --init с ненулевым кодом → установка прерывается
#     ДО шага ядра/pacman -S (R-07, фатальная ошибка);
#   * pacman-key --populate archlinux с ненулевым кодом → то же;
#   * отсутствие gpg в цели (pacman-key --init падает) → то же;
#   * успешные --init/--populate → движок проходит блок keyring
#     (позитивный контроль: в выводе есть шаг ядра).
# Диск — только файл $T/fakedisk, все разрушительные утилиты —
# заглушки, монтирования — внутри unshare. Реальные диски
# не трогаются.
#
# Запуск: ./scripts/tests/test-keyring-handling.sh
# Выход: 0 — все PASS, 1 — есть FAIL. SKIP — честный пропуск.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
PASS=0; FAIL=0; SKIPN=0
FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP  $1 ($2)"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# ---------- Статика: R-06 + R-07 ----------
grep -qx 'gnupg' "$ROOT/profile/packages.x86_64" \
  && ok "R-06: gnupg в profile/packages.x86_64" \
  || bad "R-06: gnupg в profile/packages.x86_64"
grep -qx 'archlinux-keyring' "$ROOT/profile/packages.x86_64" \
  && ok "R-06: archlinux-keyring в profile/packages.x86_64" \
  || bad "R-06: archlinux-keyring в profile/packages.x86_64"
if grep -q 'pacman-key --init не удался.*проверка подписей пакетов может не работать' "$ENGINE"; then
  bad "R-07: мягкое предупреждение для --init удалено"
else
  ok "R-07: мягкое предупреждение для --init удалено"
fi
if grep -q 'ВНИМАНИЕ: pacman-key --populate archlinux не удался' "$ENGINE"; then
  bad "R-07: мягкое предупреждение для --populate удалено"
else
  ok "R-07: мягкое предупреждение для --populate удалено"
fi
grep -q 'pacman-key --init не удался в установленной системе.*установка прервана (R-07)' "$ENGINE" \
  && ok "R-07: --init — фатальная ошибка" \
  || bad "R-07: --init — фатальная ошибка"
grep -q 'pacman-key --populate archlinux не удался в установленной системе.*установка прервана (R-07)' "$ENGINE" \
  && ok "R-07: --populate — фатальная ошибка" \
  || bad "R-07: --populate — фатальная ошибка"

# ---------- e2e: реальный движок в unshare ----------
if ! command -v gcc >/dev/null 2>&1 || ! command -v unshare >/dev/null 2>&1 || ! unshare -rm true 2>/dev/null; then
  skip "e2e реальный движок в unshare" "нет gcc или unshare -rm не работает в этом окружении"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  [[ "$FAIL" -eq 0 ]] || exit 1
  exit 0
fi

# LD_PRELOAD-шим (та же идея, что в test-child-process-extended.sh).
# XROS_FAKEBLK — список путей через ':' (диск + его разделы):
# stat() подменяет их тип на блочное устройство, чтобы [[ -b ]]
# и проба чтения R-18 работали на обычных файлах.
cat > "$T/fakeblk.c" <<'C_EOF'
#define _GNU_SOURCE
#include <sys/stat.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
static int is_fake(const char *p){
  const char *t = getenv("XROS_FAKEBLK");
  if (!t || !p) return 0;
  const char *s = t;
  while (1) {
    const char *c = strchr(s, ':');
    size_t n = c ? (size_t)(c - s) : strlen(s);
    if (strlen(p) == n && strncmp(p, s, n) == 0) return 1;
    if (!c) return 0;
    s = c + 1;
  }
}
static void fake_mode(struct stat *st){
  if (S_ISREG(st->st_mode)) st->st_mode = (st->st_mode & ~S_IFMT) | S_IFBLK;
}
int stat(const char *p, struct stat *b){ static int (*r)(const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"stat"); int rc=r(p,b); if(rc==0&&is_fake(p)) fake_mode(b); return rc; }
int lstat(const char *p, struct stat *b){ static int (*r)(const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"lstat"); int rc=r(p,b); if(rc==0&&is_fake(p)) fake_mode(b); return rc; }
int __xstat(int v, const char *p, struct stat *b){ static int (*r)(int,const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"__xstat"); int rc=r(v,p,b); if(rc==0&&is_fake(p)) fake_mode(b); return rc; }
int __lxstat(int v, const char *p, struct stat *b){ static int (*r)(int,const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"__lxstat"); int rc=r(v,p,b); if(rc==0&&is_fake(p)) fake_mode(b); return rc; }
C_EOF
if gcc -shared -fPIC -o "$T/fakeblk.so" "$T/fakeblk.c" -ldl 2>/dev/null; then
  ok "e2e LD_PRELOAD-шим собран (gcc)"
else
  bad "e2e LD_PRELOAD-шим собран (gcc)"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  exit 1
fi
touch "$T/fakedisk"
# R-18: узлы разделов тоже нужны как fake-блочные устройства: после
# sgdisk движок вызывает mkfs_root, а тот — пробу чтения
# xros_device_readable на ${DISK}2. Без узлов разделов движок
# останавливался бы до блока keyring (позитивный контроль).
touch "$T/fakedisk1" "$T/fakedisk2" "$T/fakediskp1" "$T/fakediskp2"
FAKEBLK_LIST="$T/fakedisk:$T/fakedisk1:$T/fakedisk2:$T/fakediskp1:$T/fakediskp2"
if XROS_FAKEBLK="$FAKEBLK_LIST" LD_PRELOAD="$T/fakeblk.so" bash -c "test -b '$T/fakedisk' && test -b '$T/fakedisk2'"; then
  ok "e2e шим: файл и разделы видны как блочные устройства"
else
  bad "e2e шим: файл и разделы видны как блочные устройства"
fi

mkdir -p "$T/e2e/bin"
mkstub() { # $1=имя, $2=тело
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\n%s\n' "$1" "$T" "$2" > "$T/e2e/bin/$1"
  chmod +x "$T/e2e/bin/$1"
}
mkstub sgdisk 'exit 0'
mkstub wipefs 'exit 0'
mkstub partprobe 'exit 0'
mkstub mkfs.ext4 'exit 0'
mkstub mkfs.fat 'exit 0'
mkstub mkfs.btrfs 'exit 0'
mkstub mkfs.xfs 'exit 0'
mkstub findmnt 'exit 1'
mkstub genfstab 'exit 0'
mkstub dialog 'exit 0'
mkstub rsync 'exit 0'
cat > "$T/e2e/bin/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$T/calls.log"
case "\$*" in
  *"-o FSTYPE"*) echo "" ;;
  *"-o TYPE"*) echo "disk" ;;
  *"-o PATH"*) echo "\${@: -1}" ;;
  *"-o SIZE"*) echo "21474836480" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/e2e/bin/lsblk"
mkstub blkid 'exit 2'
cat > "$T/e2e/bin/arch-chroot" <<EOF
#!/usr/bin/env bash
echo "arch-chroot \$*" >> "$T/calls.log"
# KEYRING_MODE: ok | init-fail | populate-fail | no-gpg.
# no-gpg: pacman-key не находит gpg в цели — тот же отказ --init.
case "\${KEYRING_MODE:-ok}" in
  init-fail|no-gpg)
    case "\$*" in
      *"pacman-key --init"*) exit 1 ;;
    esac
    ;;
  populate-fail)
    case "\$*" in
      *"pacman-key --populate"*) exit 1 ;;
    esac
    ;;
esac
exit 0
EOF
chmod +x "$T/e2e/bin/arch-chroot"
cat > "$T/e2e/bin/mount" <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$T/calls.log"
tgt="\${@: -1}"
/bin/mount -t tmpfs tmpfs "\$tgt"
EOF
chmod +x "$T/e2e/bin/mount"
cat > "$T/e2e/bin/umount" <<EOF
#!/usr/bin/env bash
echo "umount \$*" >> "$T/calls.log"
/bin/umount -R "\$@" 2>/dev/null
exit 0
EOF
chmod +x "$T/e2e/bin/umount"

run_e2e() { # $1=имя $2=режим keyring
  local name="$1" mode="$2"
  local d="$T/e2e/$name"; mkdir -p "$d"
  rm -f "$T/calls.log" /tmp/xros-install.log
  cat > "$d/conf" <<EOF
DISK='$T/fakedisk'
PARTMODE='erase'
FS='ext4'
HOSTNAME='xros-test'
FULLNAME='Test User'
USERNAME='testuser'
USERPASS='TestPass123'
ROOTPASS='TestPass123'
AUTOLOGIN='0'
TIMEZONE='Europe/Astrakhan'
KEYMAP='ru'
DE='kde'
OFFICE='none'
EOF
  cat > "$d/inner.sh" <<EOF
#!/usr/bin/env bash
set -u
T="$T"; ENGINE="$ENGINE"
FAKEBLK_LIST="$T/fakedisk:$T/fakedisk1:$T/fakedisk2:$T/fakediskp1:$T/fakediskp2"
mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/xros-install/etc /mnt/xros-install/boot
export XROS_FAKEBLK="\$FAKEBLK_LIST"
export XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf"
export PATH="\$T/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export KEYRING_MODE="$mode"
setsid --wait env LD_PRELOAD="\$T/fakeblk.so" XROS_FAKEBLK="\$FAKEBLK_LIST" XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf" PATH="\$T/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" KEYRING_MODE="$mode" bash "\$ENGINE" > "$d/engine.out" 2>&1
RC=\$?
{
  echo "rc=\$RC"
  grep -q "pacman-key --init не удался" "$d/engine.out" 2>/dev/null && echo "init_msg=yes" || echo "init_msg=no"
  grep -q "pacman-key --populate archlinux не удался" "$d/engine.out" 2>/dev/null && echo "populate_msg=yes" || echo "populate_msg=no"
  grep -q "Ядро и initramfs с установочного диска" "$d/engine.out" 2>/dev/null && echo "kernel_step=yes" || echo "kernel_step=no"
} > "$d/result.txt"
umount -R /mnt/xros-install 2>/dev/null || true
EOF
  chmod +x "$d/inner.sh"
  unshare -rm bash "$d/inner.sh"
}
result_val() { grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- | head -1; }

run_e2e "init-fail" "init-fail"
R="$T/e2e/init-fail/result.txt"
[[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e init-fail: движок остановился (rc!=0)" || bad "e2e init-fail: движок остановился (rc!=0)"
[[ "$(result_val "$R" init_msg)" == "yes" ]] && ok "e2e init-fail: сообщение о неудаче --init" || bad "e2e init-fail: сообщение о неудаче --init"
[[ "$(result_val "$R" kernel_step)" == "no" ]] && ok "e2e init-fail: до шага ядра не дошёл" || bad "e2e init-fail: до шага ядра не дошёл"

run_e2e "populate-fail" "populate-fail"
R="$T/e2e/populate-fail/result.txt"
[[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e populate-fail: движок остановился (rc!=0)" || bad "e2e populate-fail: движок остановился (rc!=0)"
[[ "$(result_val "$R" populate_msg)" == "yes" ]] && ok "e2e populate-fail: сообщение о неудаче --populate" || bad "e2e populate-fail: сообщение о неудаче --populate"
[[ "$(result_val "$R" kernel_step)" == "no" ]] && ok "e2e populate-fail: до шага ядра не дошёл" || bad "e2e populate-fail: до шага ядра не дошёл"

run_e2e "no-gpg" "no-gpg"
R="$T/e2e/no-gpg/result.txt"
[[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e no-gpg: движок остановился (rc!=0)" || bad "e2e no-gpg: движок остановился (rc!=0)"
[[ "$(result_val "$R" init_msg)" == "yes" ]] && ok "e2e no-gpg: отказ --init (нет gpg) — фатальная ошибка" || bad "e2e no-gpg: отказ --init (нет gpg) — фатальная ошибка"
[[ "$(result_val "$R" kernel_step)" == "no" ]] && ok "e2e no-gpg: до шага ядра не дошёл" || bad "e2e no-gpg: до шага ядра не дошёл"

run_e2e "ok" "ok"
R="$T/e2e/ok/result.txt"
[[ "$(result_val "$R" init_msg)" == "no" ]] && ok "e2e ok: нет сообщения об ошибке --init" || bad "e2e ok: нет сообщения об ошибке --init"
[[ "$(result_val "$R" populate_msg)" == "no" ]] && ok "e2e ok: нет сообщения об ошибке --populate" || bad "e2e ok: нет сообщения об ошибке --populate"
[[ "$(result_val "$R" kernel_step)" == "yes" ]] && ok "e2e ok: блок keyring пройден (шаг ядра)" || bad "e2e ok: блок keyring пройден (шаг ядра)"

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
if [[ $FAIL -gt 0 ]]; then
  echo "Не пройдено:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
