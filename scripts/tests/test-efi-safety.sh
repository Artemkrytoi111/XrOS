#!/usr/bin/env bash
# XrOS — тесты безопасности EFI-раздела (R-19A).
#
# Проверяется НАСТОЯЩИЙ код (не копии логики):
#   A. xros_require_disk_free / xros_disk_blocked / xros_device_readable
#      из src/xros-install — матрица кейсов для EFI-раздела: ожидаемый
#      чистый раздел, неверный тип раздела, неверная файловая система
#      (lsblk- и blkid-нога), отсутствующее устройство, ошибка чтения,
#      изменившаяся идентичность между проверками, пустые/повреждённые
#      результаты обнаружения, отказ повторной проверки (mkfs.fat не
#      вызывается). Проба чтения — настоящая (LD_PRELOAD-шим, как в
#      test-raid-block.sh); lsblk/blkid — поддельные bash-функции.
#   B. Статика: повторная проверка стоит непосредственно перед
#      mkfs.fat, fail-closed (exit 1, без fallback), единственный
#      вызов mkfs.fat в движке, синхронность трёх копий.
#   C. РЕАЛЬНЫЙ движок в unshare -rm с LD_PRELOAD-шимом и поддельным
#      /sys (tmpfs поверх /sys + /sys/firmware/efi, чтобы движок пошёл
#      по UEFI-ветке): чистый EFI — mkfs.fat вызывается; EFI с
#      linux_raid_member / неверным типом / отсутствующий узел /
#      ошибка lsblk — движок останавливается ДО mkfs.fat с сообщением
#      R-19. Диск — только файлы $T/fakedisk*, все разрушительные
#      утилиты — заглушки. Реальные диски не трогаются, mkfs.fat
#      никогда не запускается на реальном устройстве.
#
# Запуск: ./scripts/tests/test-efi-safety.sh
# Выход: 0 — все PASS, 1 — есть FAIL. SKIP — честный пропуск.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
PASS=0; FAIL=0; SKIPN=0
FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP  $1 ($2)"; }

# --- Проба чтения требует настоящего [[ -b ]]: перевыполнение себя же
# с LD_PRELOAD-шимом (шим собирается внешним запуском до exec).
if [[ -z "${XROS_EFI_TEST_SHIM:-}" ]]; then
  T="$(mktemp -d)"
  touch "$T/fakedisk" "$T/fakedisk1" "$T/fakedisk2" "$T/fakediskp1" "$T/fakediskp2"
  FAKEBLK_LIST="$T/fakedisk:$T/fakedisk1:$T/fakedisk2:$T/fakediskp1:$T/fakediskp2"
  if command -v gcc >/dev/null 2>&1; then
    cat > "$T/fakeblk.c" <<'C_EOF'
#define _GNU_SOURCE
#include <sys/stat.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
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
      exec env LD_PRELOAD="$T/fakeblk.so" XROS_FAKEBLK="$FAKEBLK_LIST" \
        XROS_EFI_TEST_SHIM=1 XROS_EFI_T="$T" bash "$0" "$@"
    fi
    echo "SKIP  секции A и C: не удалось собрать LD_PRELOAD-шим (gcc)"
  else
    echo "SKIP  секции A и C: нет gcc на этом хосте"
  fi
  # Без шима — только статика (секция B). XROS_EFI_T не задан.
  export XROS_EFI_NO_SHIM=1
  T="$T"
else
  T="$XROS_EFI_T"
  FAKEBLK_LIST="$XROS_FAKEBLK"
fi
trap 'rm -rf "$T"' EXIT
DISK="$T/fakedisk"; EFI="$T/fakediskp1"; EFI_ALT="$T/fakedisk1"; ROOTP="$T/fakediskp2"

# ================= B. Статика (без шима и без unshare) ======================
# B1: повторная проверка стоит между назначением EFI_PART и mkfs.fat.
ASSIGN=$(grep -n 'EFI_PART="${DISK}' "$ENGINE" | head -1 | cut -d: -f1)
CHECK=$(grep -n 'xros_require_disk_free "$EFI_PART"' "$ENGINE" | head -1 | cut -d: -f1)
MKFS=$(grep -nE '^[[:space:]]*mkfs\.fat -F 32' "$ENGINE" | head -1 | cut -d: -f1)
if [[ -n "$ASSIGN" && -n "$CHECK" && -n "$MKFS" ]] && \
   [[ "$ASSIGN" -lt "$CHECK" ]] && [[ "$CHECK" -lt "$MKFS" ]] && \
   [[ $((MKFS - CHECK)) -le 10 ]]; then
  ok "B1 re-check между назначением EFI_PART (:$ASSIGN) и mkfs.fat (:$MKFS), проверка :$CHECK"
else
  bad "B1 re-check между назначением EFI_PART и mkfs.fat (ASSIGN=$ASSIGN CHECK=$CHECK MKFS=$MKFS)"
fi
# B2: единственный вызов mkfs.fat в движке — в UEFI-ветке erase-режима.
if [[ "$(grep -cE '^[[:space:]]*mkfs\.fat -F 32' "$ENGINE")" == "1" ]]; then
  ok "B2 единственный mkfs.fat в движке (ручной режим EFI не форматирует)"
else
  bad "B2 единственный mkfs.fat в движке (найдено: $(grep -cE '^[[:space:]]*mkfs\.fat -F 32' "$ENGINE"))"
fi
# B3: fail-closed — отказ проверки завершает установку, без fallback.
if grep -n 'xros_require_disk_free "$EFI_PART"' "$ENGINE" | grep -q 'exit 1'; then
  ok "B3 отказ re-check — exit 1, без fallback на другой раздел"
else
  bad "B3 отказ re-check — exit 1, без fallback на другой раздел"
fi
# B4: понятное диагностическое сообщение.
if grep -n 'xros_require_disk_free "$EFI_PART"' "$ENGINE" | grep -q 'повторную проверку.*R-19'; then
  ok "B4 сообщение об отказе объясняет причину (R-19, повторная проверка)"
else
  bad "B4 сообщение об отказе объясняет причину (R-19, повторная проверка)"
fi
# B5: три копии движка идентичны.
if cmp -s "$ENGINE" "$ROOT/packages/xros-installer/xros-install" && \
   cmp -s "$ENGINE" "$ROOT/profile/airootfs/usr/local/bin/xros-install"; then
  ok "B5 три копии движка идентичны (R-19 во всех)"
else
  bad "B5 три копии движка идентичны (R-19 во всех)"
fi
# B6: re-check — в UEFI-ветке (после проверки [[ -d /sys/firmware/efi ]]).
EFI_IF=$(grep -n 'if \[\[ -d /sys/firmware/efi \]\]; then' "$ENGINE" | tail -1 | cut -d: -f1)
if [[ -n "$EFI_IF" ]] && [[ "$EFI_IF" -lt "$CHECK" ]] && [[ "$CHECK" -lt "$MKFS" ]]; then
  ok "B6 re-check внутри UEFI-ветки (if :$EFI_IF, check :$CHECK)"
else
  bad "B6 re-check внутри UEFI-ветки (EFI_IF=$EFI_IF CHECK=$CHECK)"
fi

if [[ -n "${XROS_EFI_NO_SHIM:-}" ]]; then
  skip "секции A и C" "LD_PRELOAD-шим недоступен"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  [[ "$FAIL" -eq 0 ]]
  exit $?
fi

# ================= A. Настоящие функции движка ==============================
awk '/^xros_disk_blocked\(\) \{/{f=1} f{print} f && /^}/{exit}' "$ENGINE" > "$T/blocked.sh"
awk '/^xros_device_readable\(\) \{/{f=1} f{print} f && /^}/{exit}' "$ENGINE" > "$T/readable.sh"
awk '/^xros_require_disk_free\(\) \{/{f=1} f{print} f && /^}/{exit}' "$ENGINE" > "$T/require.sh"
if [[ -s "$T/blocked.sh" ]] && grep -q "linux_raid_member" "$T/blocked.sh" && \
   [[ -s "$T/readable.sh" ]] && grep -q "head -c 512" "$T/readable.sh" && \
   [[ -s "$T/require.sh" ]] && grep -q 'xros_disk_blocked' "$T/require.sh"; then
  ok "A0 функции xros_disk_blocked/xros_device_readable/xros_require_disk_free извлечены из src/xros-install"
else
  bad "A0 функции извлечены из src/xros-install"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  exit 1
fi
say() { echo "SAY: $*" >> "$T/say.log"; }
# Поддельные lsblk/blkid: ответы по устройству (последний аргумент).
# Карты — строки «устройство значение». LSBLK_RC/BLKID_RC/LSBLK_PATH_RC —
# подмена кода возврата для конкретного устройства (переменная вида
# LSBLK_RC_<basename> не используется: достаточно глобальных флагов
# LSBLK_FAIL_DEV / BLKID_FAIL_DEV — устройство, для которого команда
# возвращает ошибку).
FSTYPE_MAP=""; TYPE_MAP=""; BLKID_MAP=""; PATH_MAP=""
LSBLK_FAIL_DEV=""; BLKID_FAIL_DEV=""; LSBLK_PATH_FAIL=""; HEAD_FAIL_DEV=""
lsblk() {
  local d="${*: -1}"
  case "$*" in
    *"-o NAME,SIZE,TYPE,FSTYPE"*) printf '' ;;
    *"-o FSTYPE"*)
      [[ "$d" == "$LSBLK_FAIL_DEV" ]] && return 1
      printf '%s\n' "$FSTYPE_MAP" | awk -v dev="$d" '$1==dev {print $2; exit}' ;;
    *"-o TYPE"*)
      [[ "$d" == "$LSBLK_FAIL_DEV" ]] && return 1
      printf '%s\n' "$TYPE_MAP" | awk -v dev="$d" '$1==dev {print $2; exit}' ;;
    *"-o PATH"*)
      [[ -n "$LSBLK_PATH_FAIL" ]] && return 1
      printf '%s\n' "$PATH_MAP" | awk -v dev="$d" '$1==dev {print $2; exit}' ;;
    *"-o SIZE"*) echo "21474836480" ;;
    *) printf '' ;;
  esac
  return 0
}
blkid() {
  local d="${*: -1}" _type
  [[ "$d" == "$BLKID_FAIL_DEV" ]] && return 1
  _type="$(printf '%s\n' "$BLKID_MAP" | awk -v dev="$d" '$1==dev {print $2; exit}')"
  if [[ -n "$_type" ]]; then printf '%s\n' "$_type"; return 0; fi
  return 2
}
# head: настоящий, кроме устройств из HEAD_FAIL_DEV (ошибка чтения).
head() {
  local d="${*: -1}"
  if [[ -n "$HEAD_FAIL_DEV" && "$d" == "$HEAD_FAIL_DEV" ]]; then return 1; fi
  command head "$@"
}
# shellcheck disable=SC1090
source "$T/readable.sh"
# shellcheck disable=SC1090
source "$T/blocked.sh"
# shellcheck disable=SC1090
source "$T/require.sh"

reset_maps() {
  FSTYPE_MAP=""; TYPE_MAP=""; BLKID_MAP=""; PATH_MAP=""
  LSBLK_FAIL_DEV=""; BLKID_FAIL_DEV=""; LSBLK_PATH_FAIL=""; HEAD_FAIL_DEV=""
  # По умолчанию: диск чистый, его единственный потомок — он сам.
  TYPE_MAP="$DISK disk
$EFI part
$EFI_ALT part
$ROOTP part"
  PATH_MAP="$DISK $DISK"
  rm -f "$T/say.log"
}
run_case() { # $1=имя $2=ожидаемое(blocked|free|error) $3=устройство
  local name="$1" want="$2" dev="$3" _rc got
  xros_disk_blocked "$dev"; _rc=$?
  case "$_rc" in 0) got="blocked" ;; 1) got="free" ;; 2) got="error" ;; *) got="rc$_rc" ;; esac
  if [[ "$got" == "$want" ]]; then ok "A $name: $want"; else bad "A $name: ожидалось $want, получено $got"; fi
  # Ворота: require_disk_free пропускает только free.
  if xros_require_disk_free "$dev"; then
    [[ "$want" == "free" ]] && ok "A $name: ворота пропускают free" || bad "A $name: ворота пропустили $want"
  else
    [[ "$want" != "free" ]] && ok "A $name: ворота не пропускают $want" || bad "A $name: ворота не пропустили free"
  fi
}

# A1: ожидаемый EFI-раздел — чистый, читаемый, без сигнатуры.
reset_maps
run_case "ожидаемый EFI-раздел" "free" "$EFI"
# A2: неверный тип раздела (RAID1 вместо part).
reset_maps
TYPE_MAP="$DISK disk
$EFI raid1
$EFI_ALT part
$ROOTP part"
run_case "неверный тип раздела (raid1)" "blocked" "$EFI"
# A3: неверная файловая система — lsblk-нога (linux_raid_member).
reset_maps
FSTYPE_MAP="$EFI linux_raid_member"
run_case "неверная ФС, lsblk-нога (linux_raid_member)" "blocked" "$EFI"
# A4: неверная файловая система — blkid-нога (lsblk чистый).
reset_maps
BLKID_MAP="$EFI linux_raid_member"
run_case "неверная ФС, blkid-нога (linux_raid_member)" "blocked" "$EFI"
# A5: отсутствующее устройство.
reset_maps
run_case "отсутствующее устройство" "error" "$T/no-such-part"
# A6: ошибка чтения (проба head падает).
reset_maps
HEAD_FAIL_DEV="$EFI"
run_case "ошибка чтения (проба сектора)" "error" "$EFI"
# A7: пустые результаты обнаружения (lsblk молчит, blkid rc=2) — free.
reset_maps
TYPE_MAP=""
run_case "пустые результаты обнаружения" "free" "$EFI"
# A8: повреждённые результаты — lsblk возвращает ошибку.
reset_maps
LSBLK_FAIL_DEV="$EFI"
run_case "повреждённые результаты (lsblk rc=1)" "error" "$EFI"
# A9: идентичность изменилась между проверками: первая проверка диска
# чистая, затем EFI-узел «подменился» на член RAID — повторная
# проверка обязана это поймать.
reset_maps
run_case "первая проверка диска (чистый)" "free" "$DISK"
FSTYPE_MAP="$EFI linux_raid_member"
run_case "повторная проверка EFI после подмены (raid)" "blocked" "$EFI"
# A10: попытка продолжить после отказа — ворота не пропускают, mkfs.fat
# не вызывается (мини-драйвер повторяет логику движка).
reset_maps
FSTYPE_MAP="$EFI linux_raid_member"
: > "$T/mkfs.calls"
if xros_require_disk_free "$EFI"; then echo "mkfs.fat $EFI" >> "$T/mkfs.calls"; fi
if [[ ! -s "$T/mkfs.calls" ]]; then ok "A10 отказ проверки: mkfs.fat НЕ вызван"; else bad "A10 отказ проверки: mkfs.fat НЕ вызван"; fi
# Позитивный контроль A10: чистый раздел — ворота пропускают.
reset_maps
if xros_require_disk_free "$EFI"; then echo "mkfs.fat $EFI" >> "$T/mkfs.calls"; fi
if grep -q "mkfs.fat $EFI" "$T/mkfs.calls"; then ok "A10 чистый раздел: mkfs.fat вызван"; else bad "A10 чистый раздел: mkfs.fat вызван"; fi

# ================= C. РЕАЛЬНЫЙ движок в unshare (UEFI-ветка) ===============
if command -v unshare >/dev/null 2>&1; then
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
  mkstub arch-chroot 'exit 0'
  mkstub dialog 'exit 0'
  mkstub rsync 'exit 1'
  # lsblk: режим задаётся LSBLK_MODE. Узел EFI — ${DISK}p1, если он
  # существует (движок предпочитает p-суффикс), иначе ${DISK}1.
  cat > "$T/e2e/bin/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$T/calls.log"
dev="\${@: -1}"
is_efi=0
[[ "\$dev" == "$T/fakediskp1" || "\$dev" == "$T/fakedisk1" ]] && is_efi=1
case "\$*" in
  *"-o NAME,SIZE,TYPE,FSTYPE"*) echo "" ;;
  *"-o FSTYPE"*)
    if [[ "\${LSBLK_MODE:-efi-clean}" == "efi-lsblk-error" && "\$is_efi" == "1" ]]; then exit 1; fi
    if [[ "\${LSBLK_MODE:-efi-clean}" == "efi-raid-lsblk" && "\$is_efi" == "1" ]]; then echo "linux_raid_member"; fi
    ;;
  *"-o TYPE"*)
    if [[ "\$dev" == "$T/fakedisk" ]]; then echo "disk"; exit 0; fi
    if [[ "\$is_efi" == "1" ]]; then
      if [[ "\${LSBLK_MODE:-efi-clean}" == "efi-wrong-type" ]]; then echo "raid1"; else echo "part"; fi
      exit 0
    fi
    echo "" ;;
  *"-o PATH"*) echo "\$dev" ;;
  *"-o SIZE"*) echo "21474836480" ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/e2e/bin/lsblk"
  cat > "$T/e2e/bin/blkid" <<EOF
#!/usr/bin/env bash
echo "blkid \$*" >> "$T/calls.log"
dev="\${@: -1}"
case "\$*" in
  *"-p -s TYPE"*)
    if [[ "\${LSBLK_MODE:-efi-clean}" == "efi-raid-blkid" && ( "\$dev" == "$T/fakediskp1" || "\$dev" == "$T/fakedisk1" ) ]]; then
      echo "linux_raid_member"; exit 0
    fi
    exit 2 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$T/e2e/bin/blkid"
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

  run_e2e() { # $1=имя $2=режим
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
    # efi-missing: убираем оба кандидата узла EFI (p1 и 1) — движок
    # обязан остановиться на re-check, а не упасть на mkfs.fat.
    local missing=0
    if [[ "$mode" == "efi-missing" ]]; then
      missing=1
      rm -f "$T/fakediskp1" "$T/fakedisk1"
    fi
    cat > "$d/inner.sh" <<EOF
#!/usr/bin/env bash
set -u
T="$T"; ENGINE="$ENGINE"
/bin/mount -t tmpfs tmpfs /mnt
/bin/mount -t tmpfs tmpfs /sys
mkdir -p /sys/firmware/efi /mnt/xros-install/etc /mnt/xros-install/boot
export XROS_FAKEBLK="$FAKEBLK_LIST"
export XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf"
export PATH="\$T/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LSBLK_MODE="$mode"
setsid --wait env LD_PRELOAD="\$T/fakeblk.so" XROS_FAKEBLK="$FAKEBLK_LIST" XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf" PATH="\$T/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LSBLK_MODE="$mode" bash "\$ENGINE" > "$d/engine.out" 2>&1
RC=\$?
{
  echo "rc=\$RC"
  if grep -q "не прошёл повторную проверку" "$d/engine.out" 2>/dev/null || { [[ -f /tmp/xros-install.log ]] && grep -q "не прошёл повторную проверку" /tmp/xros-install.log 2>/dev/null; }; then echo "r19_msg=yes"; else echo "r19_msg=no"; fi
  grep -q "^wipefs" "\$T/calls.log" && echo "wipefs_called=yes" || echo "wipefs_called=no"
  grep -q "^sgdisk" "\$T/calls.log" && echo "sgdisk_called=yes" || echo "sgdisk_called=no"
  if grep -q "^mkfs.fat" "\$T/calls.log" 2>/dev/null; then echo "mkfs_fat_called=yes"; grep "^mkfs.fat" "\$T/calls.log" | head -1 | awk '{print "mkfs_fat_target=" \$NF}'; else echo "mkfs_fat_called=no"; fi
} > "$d/result.txt"
umount -R /mnt/xros-install 2>/dev/null || true
EOF
    chmod +x "$d/inner.sh"
    unshare -rm bash "$d/inner.sh"
    if [[ "$missing" == "1" ]]; then touch "$T/fakediskp1" "$T/fakedisk1"; fi
  }
  result_val() { grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- | head -1; }

  # C1: чистый EFI — mkfs.fat вызывается с правильным разделом.
  run_e2e "efi-clean" "efi-clean"
  R="$T/e2e/efi-clean/result.txt"
  [[ "$(result_val "$R" sgdisk_called)" == "yes" ]] && ok "C1 clean: sgdisk вызван" || bad "C1 clean: sgdisk вызван"
  [[ "$(result_val "$R" mkfs_fat_called)" == "yes" ]] && ok "C1 clean: mkfs.fat вызван" || bad "C1 clean: mkfs.fat вызван"
  [[ "$(result_val "$R" mkfs_fat_target)" == "$EFI" ]] && ok "C1 clean: mkfs.fat на $EFI" || bad "C1 clean: mkfs.fat на $EFI (получено: $(result_val "$R" mkfs_fat_target))"
  [[ "$(result_val "$R" r19_msg)" == "no" ]] && ok "C1 clean: ошибки R-19 нет" || bad "C1 clean: ошибки R-19 нет"

  # C2: EFI — член RAID (lsblk-нога).
  run_e2e "efi-raid-lsblk" "efi-raid-lsblk"
  R="$T/e2e/efi-raid-lsblk/result.txt"
  [[ "$(result_val "$R" sgdisk_called)" == "yes" ]] && ok "C2 raid-lsblk: sgdisk вызван (провал именно на re-check)" || bad "C2 raid-lsblk: sgdisk вызван (провал именно на re-check)"
  [[ "$(result_val "$R" r19_msg)" == "yes" ]] && ok "C2 raid-lsblk: сообщение R-19" || bad "C2 raid-lsblk: сообщение R-19"
  [[ "$(result_val "$R" mkfs_fat_called)" == "no" ]] && ok "C2 raid-lsblk: mkfs.fat НЕ вызван" || bad "C2 raid-lsblk: mkfs.fat НЕ вызван"

  # C3: EFI — член RAID (blkid-нога).
  run_e2e "efi-raid-blkid" "efi-raid-blkid"
  R="$T/e2e/efi-raid-blkid/result.txt"
  [[ "$(result_val "$R" sgdisk_called)" == "yes" ]] && ok "C3 raid-blkid: sgdisk вызван (провал именно на re-check)" || bad "C3 raid-blkid: sgdisk вызван (провал именно на re-check)"
  [[ "$(result_val "$R" r19_msg)" == "yes" ]] && ok "C3 raid-blkid: сообщение R-19" || bad "C3 raid-blkid: сообщение R-19"
  [[ "$(result_val "$R" mkfs_fat_called)" == "no" ]] && ok "C3 raid-blkid: mkfs.fat НЕ вызван" || bad "C3 raid-blkid: mkfs.fat НЕ вызван"

  # C4: неверный тип раздела EFI (raid1 вместо part).
  run_e2e "efi-wrong-type" "efi-wrong-type"
  R="$T/e2e/efi-wrong-type/result.txt"
  [[ "$(result_val "$R" r19_msg)" == "yes" ]] && ok "C4 wrong-type: сообщение R-19" || bad "C4 wrong-type: сообщение R-19"
  [[ "$(result_val "$R" mkfs_fat_called)" == "no" ]] && ok "C4 wrong-type: mkfs.fat НЕ вызван" || bad "C4 wrong-type: mkfs.fat НЕ вызван"

  # C5: узел EFI отсутствует (оба кандидата убраны).
  run_e2e "efi-missing" "efi-missing"
  R="$T/e2e/efi-missing/result.txt"
  [[ "$(result_val "$R" r19_msg)" == "yes" ]] && ok "C5 missing: сообщение R-19" || bad "C5 missing: сообщение R-19"
  [[ "$(result_val "$R" mkfs_fat_called)" == "no" ]] && ok "C5 missing: mkfs.fat НЕ вызван" || bad "C5 missing: mkfs.fat НЕ вызван"

  # C6: ошибка обнаружения (lsblk падает для EFI-узла).
  run_e2e "efi-lsblk-error" "efi-lsblk-error"
  R="$T/e2e/efi-lsblk-error/result.txt"
  [[ "$(result_val "$R" r19_msg)" == "yes" ]] && ok "C6 lsblk-error: сообщение R-19" || bad "C6 lsblk-error: сообщение R-19"
  [[ "$(result_val "$R" mkfs_fat_called)" == "no" ]] && ok "C6 lsblk-error: mkfs.fat НЕ вызван" || bad "C6 lsblk-error: mkfs.fat НЕ вызван"
else
  skip "секция C (e2e реальный движок)" "нет unshare на этом хосте"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
[[ "$FAIL" -eq 0 ]]
