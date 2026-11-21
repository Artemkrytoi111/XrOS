#!/usr/bin/env bash
# XrOS — тест P4-AUD-01: fail-closed включение SDDM / graphical.target.
#
# Проверяет исправление: ошибки `systemctl enable sddm` /
# `systemctl enable $DE_DM` / `systemctl set-default graphical.target`
# в движке больше не подавляются `|| true`, а прерывают установку
# с понятной ошибкой в журнале (exit 1, INSTALL_FAILED, без INSTALL_DONE).
#
# Слои:
#   S — статика: паттерн исправления во всех 3 копиях движка +
#       гарантия, что соседние строки (P4-AUD-02, DE=none) не тронуты.
#   R — рантайм: РЕАЛЬНЫЙ движок в `unshare -rm` с фиктивным диском
#       (файл + LD_PRELOAD-шим, как в test-child-process-extended.sh):
#       R1 kde успех, R2 kde + падение enable sddm, R3 kde + падение
#       set-default graphical.target, R4 gnome + падение enable gdm,
#       R5 gnome успех.
#
# Безопасность: только фиктивные файлы внутри $T, никаких физических
# дисков, ISO, QEMU, коммитов. /run/archiso/bootmnt — фиктивный
# источник ядра, создаётся внутри mount namespace (tmpfs + make-rprivate),
# на хост не протекает (проверяется в R0).
#
# Запуск: ./scripts/tests/test-sddm-failclosed.sh
# Выход: 0 — все проверки PASS; 1 — есть FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
ENGINE_PROFILE="$ROOT/profile/airootfs/usr/local/bin/xros-install"
ENGINE_PKG="$ROOT/packages/xros-installer/xros-install"
T="$(mktemp -d /tmp/xros-sddm-test.XXXXXX)"
PASS=0; FAIL=0; SKIP=0; FAILED_NAMES=""
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1 ($2)"; }
trap 'rm -rf "$T"; umount -R /mnt/xros-install 2>/dev/null || true' EXIT

# ================= S. Статика ==============================
# S1: нет `|| true` на enable sddm ни в одной копии движка.
s1_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  if grep -q 'systemctl enable sddm.service.*|| true' "$f"; then s1_fail=1; fi
done
[[ "$s1_fail" == "0" ]] \
  && ok "S1: нет '|| true' на 'systemctl enable sddm.service' (3 копии)" \
  || bad "S1: нет '|| true' на 'systemctl enable sddm.service' (3 копии)"
# S2: нет `|| true` на set-default graphical.target.
s2_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  if grep -q 'systemctl set-default graphical.target.*|| true' "$f"; then s2_fail=1; fi
done
[[ "$s2_fail" == "0" ]] \
  && ok "S2: нет '|| true' на 'systemctl set-default graphical.target' (3 копии)" \
  || bad "S2: нет '|| true' на 'systemctl set-default graphical.target' (3 копии)"
# S3: нет `|| true` на enable "$DE_DM.service".
s3_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  if grep -q 'systemctl enable "\$DE_DM.service".*|| true' "$f"; then s3_fail=1; fi
done
[[ "$s3_fail" == "0" ]] \
  && ok "S3: нет '|| true' на 'systemctl enable \"\$DE_DM.service\"' (3 копии)" \
  || bad "S3: нет '|| true' на 'systemctl enable \"\$DE_DM.service\"' (3 копии)"
# S4: fail-closed паттерн с понятной ошибкой — во всех 3 копиях.
# (команда и `|| { ...; exit 1; }` — на соседних строках, поэтому -A1.)
s4_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q 'не удалось включить SDDM в установленной системе' "$f" || s4_fail=1
  grep -q 'не удалось задать graphical.target по умолчанию' "$f" || s4_fail=1
  grep -q 'не удалось включить менеджер входа \$DE_DM' "$f" || s4_fail=1
  grep -A1 'systemctl enable sddm.service' "$f" | grep -q 'exit 1' || s4_fail=1
  grep -A1 'systemctl set-default graphical.target' "$f" | grep -q 'exit 1' || s4_fail=1
  grep -A1 'systemctl enable "\$DE_DM.service"' "$f" | grep -q 'exit 1' || s4_fail=1
done
[[ "$s4_fail" == "0" ]] \
  && ok "S4: fail-closed '|| { say ОШИБКА ...; exit 1; }' для SDDM/DM/graphical.target (3 копии)" \
  || bad "S4: fail-closed '|| { say ОШИБКА ...; exit 1; }' для SDDM/DM/graphical.target (3 копии)"
# S5: P4-AUD-02 исправлен ПОСЛЕ этого теста: `|| true` на disable DM
# больше нет (fail-closed через xros_disable_dm). P4-AUD-04 FIX-B:
# set-default multi-user.target — тоже fail-closed, `|| true` убрано.
s5_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  if grep -q 'systemctl disable.*|| true' "$f"; then s5_fail=1; fi
  if grep -q 'systemctl set-default multi-user.target.*|| true' "$f"; then s5_fail=1; fi
  grep -q 'не удалось установить multi-user.target как цель по умолчанию' "$f" || s5_fail=1
done
[[ "$s5_fail" == "0" ]] \
  && ok "S5: disable DM без '|| true' (P4-AUD-02), set-default multi-user.target fail-closed (FIX-B)" \
  || bad "S5: disable DM без '|| true' (P4-AUD-02), set-default multi-user.target fail-closed (FIX-B)"
# S6: три копии движка байт-в-байт.
if cmp -s "$ENGINE" "$ENGINE_PROFILE" && cmp -s "$ENGINE" "$ENGINE_PKG"; then
  ok "S6: три копии движка байт-в-байт"
else
  bad "S6: три копии движка байт-в-байт"
fi

# ================= R0. Подготовка рантайм-стенда ==============================
# LD_PRELOAD-шим: тестовые файлы выглядят блочными устройствами
# (тот же код, что в test-child-process-extended.sh).
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
  ok "R0a: LD_PRELOAD-шим собран (gcc)"
else
  skip "рантайм R1–R5" "gcc недоступен — нет fakeblk.so"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (упавшие:$FAILED_NAMES)"
  [[ "$FAIL" == "0" ]] && exit 0 || exit 1
fi
touch "$T/fakedisk" "$T/fakedisk1" "$T/fakedisk2" "$T/fakediskp1" "$T/fakediskp2"
FAKEBLK_LIST="$T/fakedisk:$T/fakedisk1:$T/fakedisk2:$T/fakediskp1:$T/fakediskp2"
if XROS_FAKEBLK="$FAKEBLK_LIST" LD_PRELOAD="$T/fakeblk.so" bash -c "test -b '$T/fakedisk' && test -b '$T/fakedisk2'"; then
  ok "R0b: шим: фиктивный диск и разделы видны как блочные устройства"
else
  bad "R0b: шим: фиктивный диск и разделы видны как блочные устройства"
fi
if command -v unshare >/dev/null 2>&1 && unshare -rm true 2>/dev/null; then
  ok "R0c: unshare -rm доступен"
else
  skip "рантайм R1–R5" "unshare -rm недоступен"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (упавшие:$FAILED_NAMES)"
  [[ "$FAIL" == "0" ]] && exit 0 || exit 1
fi

# ================= R. Заглушки ==============================
mkdir -p "$T/realbin"
mkstub() { # $1=имя, $2=тело
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\n%s\n' "$1" "$T" "$2" > "$T/realbin/$1"
  chmod +x "$T/realbin/$1"
}
mkstub sgdisk 'exit 0'
mkstub wipefs 'exit 0'
mkstub partprobe 'exit 0'
mkstub mkfs.ext4 'exit 0'
mkstub mkfs.fat 'exit 0'
mkstub mkfs.btrfs 'exit 0'
mkstub mkfs.xfs 'exit 0'
mkstub blkid 'exit 0'
mkstub findmnt 'exit 1'
# genfstab: как настоящий — печатает строку fstab (движок пишет её
# через `> $TARGET/etc/fstab`, пустой вывод дал бы «fstab пуст»).
mkstub genfstab 'echo "UUID=fake-uuid / ext4 defaults 0 1"'
mkstub dialog 'exit 0'
cat > "$T/realbin/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$T/calls.log"
case "\$*" in *"-o TYPE"*) echo "disk";; *"-o SIZE"*) echo "21474836480";; *) echo "";; esac
exit 0
EOF
chmod +x "$T/realbin/lsblk"
# mount: записать вызов и сделать НАСТОЯЩИЙ tmpfs-mount на TARGET
# (внутри unshare — приватно пространству имён).
cat > "$T/realbin/mount" <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$T/calls.log"
/bin/mount -t tmpfs tmpfs "\${@: -1}"
EOF
chmod +x "$T/realbin/mount"
# umount: записать вызов и сделать НАСТОЯЩЕЕ размонтирование.
cat > "$T/realbin/umount" <<EOF
#!/usr/bin/env bash
echo "umount \$*" >> "$T/calls.log"
/bin/umount -R "\$@" 2>/dev/null
exit 0
EOF
chmod +x "$T/realbin/umount"
# rsync: быстрый успех + симуляция скопированной живой системы:
# файлы, которые проверяет финальная проверка движка.
cat > "$T/realbin/rsync" <<EOF
#!/usr/bin/env bash
echo "rsync \$*" >> "$T/calls.log"
tgt="\${@: -1}"
mkdir -p "\$tgt/boot/grub" "\$tgt/etc" "\$tgt/usr/share/xros/grub-theme"
printf 'fake-vmlinuz' > "\$tgt/boot/vmlinuz-linux"
printf 'fake-initramfs' > "\$tgt/boot/initramfs-linux.img"
printf 'fake-grub.cfg' > "\$tgt/boot/grub/grub.cfg"
printf 'UUID=fake / ext4 defaults 0 1\n' > "\$tgt/etc/fstab"
printf 'root:x:0:0:root:/root:/bin/bash\ntestuser:x:1000:1000:Test User:/home/testuser:/bin/bash\n' > "\$tgt/etc/passwd"
printf 'xros-test\n' > "\$tgt/etc/hostname"
printf 'fake-theme' > "\$tgt/usr/share/xros/grub-theme/theme.txt"
# V-07: unit-файлы DM обязаны существовать в цели (как в реальной
# установке — их ставят пакеты DE в /usr/lib). Финальная проверка
# движка (xros_verify_dm) проверяет реальное состояние цели, поэтому
# заглушка создаёт валидные юниты с секцией [Unit]. Раньше заглушка
# создавала только alias, без файла юнита, — финальная проверка
# (V-07) справедливо считала такой alias висячим.
mkdir -p "\$tgt/usr/lib/systemd/system"
for _dm in sddm gdm lightdm; do
  printf '[Unit]\nDescription=Fake %s\n\n[Service]\nExecStart=/usr/bin/%s\n\n[Install]\nWantedBy=graphical.target\nAlias=display-manager.service\n' "\$_dm" "\$_dm" > "\$tgt/usr/lib/systemd/system/\$_dm.service"
done
exit 0
EOF
chmod +x "$T/realbin/rsync"
# arch-chroot: симулирует ЭФФЕКТЫ команд в цели (симлинки DM,
# default target, grub-загрузчик), остальные команды — exit 0.
# Флаги отказа — из окружения: FAIL_SDDM_ENABLE, FAIL_SET_DEFAULT,
# FAIL_DM_ENABLE (1 = команда падает). Состояние пишется в calls.log
# (он вне TARGET и доступен после размонтирования).
cat > "$T/realbin/arch-chroot" <<'STUB_EOF'
#!/usr/bin/env bash
echo "arch-chroot $*" >> "${XROS_TEST_T}/calls.log"
tgt="$1"; shift
cmd="$*"
if [[ "$cmd" =~ systemctl\ enable\ ([a-z0-9-]+)\.service ]]; then
  dm="${BASH_REMATCH[1]}"
  if [[ "$dm" == "sddm" && "${FAIL_SDDM_ENABLE:-0}" == "1" ]]; then
    echo "stub-sddm-enable: FAILED" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  if [[ "$dm" != "sddm" && "${FAIL_DM_ENABLE:-0}" == "1" ]]; then
    echo "stub-dm-enable: FAILED ($dm)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  mkdir -p "$tgt/etc/systemd/system" "$tgt/etc/systemd/system/graphical.target.wants"
  ln -sf "/usr/lib/systemd/system/$dm.service" "$tgt/etc/systemd/system/display-manager.service"
  ln -sf "/usr/lib/systemd/system/$dm.service" "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
  echo "stub-dm-link: $dm" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" =~ systemctl\ disable\ ([a-z0-9-]+)\.service ]]; then
  dm="${BASH_REMATCH[1]}"
  link="$tgt/etc/systemd/system/display-manager.service"
  if [[ "$(readlink "$link" 2>/dev/null)" == *"$dm.service" ]]; then rm -f "$link"; fi
  echo "stub-dm-disable: $dm" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" == *"systemctl set-default graphical.target"* ]]; then
  if [[ "${FAIL_SET_DEFAULT:-0}" == "1" ]]; then
    echo "stub-set-default: FAILED" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  echo "stub-default-target: graphical.target" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" == *"systemctl set-default multi-user.target"* ]]; then
  echo "stub-default-target: multi-user.target" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" == *"grub-install --target=x86_64-efi"* ]]; then
  mkdir -p "$tgt/boot/efi/EFI/XrOS"
  printf 'fake-grubx64' > "$tgt/boot/efi/EFI/XrOS/grubx64.efi"
  echo "stub-grub-efi: ok" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" == *"grub-install --target=i386-pc"* ]]; then
  head -c 440 /dev/zero | tr '\0' 'X' | dd of="${XROS_TEST_FAKEDISK}" bs=440 count=1 conv=notrunc status=none 2>/dev/null
  echo "stub-grub-mbr: ok" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
exit 0
STUB_EOF
chmod +x "$T/realbin/arch-chroot"

# ================= R. Запуск реального движка ==============================
# $1=name $2=DE $3=FAIL_SDDM_ENABLE $4=FAIL_SET_DEFAULT $5=FAIL_DM_ENABLE
run_scenario() {
  local name="$1" de="$2" fail_sddm="$3" fail_setdefault="$4" fail_dm="$5"
  local d="$T/$name"; mkdir -p "$d"
  rm -f "$T/calls.log" /tmp/xros-install.log /tmp/xros-de-result
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
DE='$de'
OFFICE='none'
EOF
  cat > "$d/inner.sh" <<EOF
#!/usr/bin/env bash
set -u
T="$T"; ENGINE="$ENGINE"
# Фиктивный источник ядра — внутри mount namespace (tmpfs поверх
# /run/archiso, rprivate — на хост не протекает).
mkdir -p /run/archiso
mount --make-rprivate /run/archiso 2>/dev/null || true
mount -t tmpfs tmpfs /run/archiso 2>/dev/null || true
mkdir -p /run/archiso/bootmnt/xros/boot/x86_64
printf 'fake-vmlinuz' > /run/archiso/bootmnt/xros/boot/x86_64/vmlinuz-linux
printf 'fake-initramfs' > /run/archiso/bootmnt/xros/boot/x86_64/initramfs-linux.img
mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/xros-install/etc /mnt/xros-install/boot
echo "sentinel-passwd-content" > /mnt/xros-install/etc/passwd-sentinel
echo "sentinel-vmlinuz-content" > /mnt/xros-install/boot/vmlinuz-sentinel
sha256sum /mnt/xros-install/etc/passwd-sentinel /mnt/xros-install/boot/vmlinuz-sentinel > "$d/sentinel.before"
export XROS_FAKEBLK="$FAKEBLK_LIST"
export XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf"
export PATH="\$T/realbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export XROS_TEST_T="\$T" XROS_TEST_FAKEDISK="\$T/fakedisk"
export FAIL_SDDM_ENABLE="$fail_sddm" FAIL_SET_DEFAULT="$fail_setdefault" FAIL_DM_ENABLE="$fail_dm"
ENG_CMD=(setsid --wait env LD_PRELOAD="\$T/fakeblk.so" XROS_FAKEBLK="$FAKEBLK_LIST" XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf" PATH="\$T/realbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" XROS_TEST_T="\$T" XROS_TEST_FAKEDISK="\$T/fakedisk" FAIL_SDDM_ENABLE="$fail_sddm" FAIL_SET_DEFAULT="$fail_setdefault" FAIL_DM_ENABLE="$fail_dm" bash "\$ENGINE")
"\${ENG_CMD[@]}" > "$d/engine.out" 2>&1
RC=\$?
{
  echo "rc=\$RC"
  grep -q "INSTALL_FAILED" "$d/engine.out" && echo "stdout_install_failed=yes" || echo "stdout_install_failed=no"
  grep -q "INSTALL_DONE" "$d/engine.out" && echo "stdout_install_done=yes" || echo "stdout_install_done=no"
  grep -q "Очистка завершена" /tmp/xros-install.log && echo "log_cleanup=yes" || echo "log_cleanup=no"
  grep -q "не удалось включить SDDM" /tmp/xros-install.log && echo "log_sddm_error=yes" || echo "log_sddm_error=no"
  grep -q "не удалось задать graphical.target" /tmp/xros-install.log && echo "log_setdefault_error=yes" || echo "log_setdefault_error=no"
  grep -q "не удалось включить менеджер входа" /tmp/xros-install.log && echo "log_dm_error=yes" || echo "log_dm_error=no"
  grep -q "ядро не найдено" /tmp/xros-install.log && echo "log_kernel_missing=yes" || echo "log_kernel_missing=no"
  grep -q "менеджер входа .* не включён" /tmp/xros-install.log && echo "log_dm_not_enabled=yes" || echo "log_dm_not_enabled=no"
  grep -q "/mnt/xros-install" /proc/mounts && echo "target_mounted=yes" || echo "target_mounted=no"
  if [[ -f /tmp/xros-de-result ]]; then echo "de_result=\$(cat /tmp/xros-de-result)"; else echo "de_result=MISSING"; fi
  grep -q "stub-dm-link: sddm" "\$T/calls.log" && echo "dm_link=sddm" || echo "dm_link=not-sddm"
  grep -q "stub-dm-link: gdm" "\$T/calls.log" && echo "dm_link_gdm=yes" || echo "dm_link_gdm=no"
  grep -q "stub-default-target: graphical.target" "\$T/calls.log" && echo "default_target=graphical" || echo "default_target=not-graphical"
  grep -q "stub-sddm-enable: FAILED" "\$T/calls.log" && echo "stub_sddm_failed=yes" || echo "stub_sddm_failed=no"
  grep -q "stub-set-default: FAILED" "\$T/calls.log" && echo "stub_setdefault_failed=yes" || echo "stub_setdefault_failed=no"
  grep -q "stub-dm-enable: FAILED" "\$T/calls.log" && echo "stub_dm_failed=yes" || echo "stub_dm_failed=no"
  if [[ -f /mnt/xros-install/etc/passwd-sentinel ]]; then (cd / && sha256sum -c "$d/sentinel.before" >/dev/null 2>&1 && echo "sentinel=ok" || echo "sentinel=CHANGED"); else echo "sentinel=HIDDEN"; fi
} > "$d/result.txt"
umount -R /mnt/xros-install 2>/dev/null || true
EOF
  chmod +x "$d/inner.sh"
  unshare -rm bash "$d/inner.sh"
}
result_val() { # $1=result.txt $2=ключ
  grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- | head -1
}

# ================= R1. KDE, успех ==============================
run_scenario "r1-kde-ok" "kde" 0 0 0
R="$T/r1-kde-ok/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R1a: kde успех — движок вышел с кодом 0" \
  || bad "R1a: kde успех — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R1b: kde успех — в stdout INSTALL_DONE" \
  || bad "R1b: kde успех — в stdout INSTALL_DONE"
[[ "$(result_val "$R" stdout_install_failed)" == "no" ]] \
  && ok "R1c: kde успех — нет INSTALL_FAILED" \
  || bad "R1c: kde успех — нет INSTALL_FAILED"
[[ "$(result_val "$R" log_sddm_error)" == "no" && "$(result_val "$R" log_setdefault_error)" == "no" ]] \
  && ok "R1d: kde успех — в журнале нет ошибок SDDM/graphical.target" \
  || bad "R1d: kde успех — в журнале нет ошибок SDDM/graphical.target"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R1e: kde успех — display-manager.service указывает на sddm" \
  || bad "R1e: kde успех — display-manager.service указывает на sddm"
[[ "$(result_val "$R" default_target)" == "graphical" ]] \
  && ok "R1f: kde успех — default target = graphical.target" \
  || bad "R1f: kde успех — default target = graphical.target"
[[ "$(result_val "$R" de_result)" == "KDE Plasma" ]] \
  && ok "R1g: kde успех — /tmp/xros-de-result = KDE Plasma" \
  || bad "R1g: kde успех — /tmp/xros-de-result = KDE Plasma (получено: $(result_val "$R" de_result))"

# ================= R2. KDE, падение enable sddm ==============================
run_scenario "r2-kde-sddm-fail" "kde" 1 0 0
R="$T/r2-kde-sddm-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R2a: sddm fail — движок вышел с кодом 1" \
  || bad "R2a: sddm fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R2b: sddm fail — в stdout INSTALL_FAILED" \
  || bad "R2b: sddm fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R2c: sddm fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R2c: sddm fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_sddm_error)" == "yes" ]] \
  && ok "R2d: sddm fail — в журнале понятная ошибка 'не удалось включить SDDM'" \
  || bad "R2d: sddm fail — в журнале понятная ошибка 'не удалось включить SDDM'"
[[ "$(result_val "$R" log_kernel_missing)" == "no" ]] \
  && ok "R2e: sddm fail — остановка именно на SDDM (до финальной проверки ядра)" \
  || bad "R2e: sddm fail — остановка именно на SDDM (до финальной проверки ядра)"
[[ "$(result_val "$R" dm_link)" == "not-sddm" ]] \
  && ok "R2f: sddm fail — display-manager.service НЕ указывает на sddm" \
  || bad "R2f: sddm fail — display-manager.service НЕ указывает на sddm"
[[ "$(result_val "$R" de_result)" == "MISSING" ]] \
  && ok "R2g: sddm fail — /tmp/xros-de-result не записан (нет ложного итога)" \
  || bad "R2g: sddm fail — /tmp/xros-de-result не записан (получено: $(result_val "$R" de_result))"
[[ "$(result_val "$R" log_cleanup)" == "yes" && "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "R2h: sddm fail — cleanup выполнен, TARGET размонтирован" \
  || bad "R2h: sddm fail — cleanup выполнен, TARGET размонтирован"

# ================= R3. KDE, падение set-default graphical.target ==============================
run_scenario "r3-kde-setdefault-fail" "kde" 0 1 0
R="$T/r3-kde-setdefault-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R3a: set-default fail — движок вышел с кодом 1" \
  || bad "R3a: set-default fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R3b: set-default fail — в stdout INSTALL_FAILED" \
  || bad "R3b: set-default fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R3c: set-default fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R3c: set-default fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_setdefault_error)" == "yes" ]] \
  && ok "R3d: set-default fail — в журнале понятная ошибка 'не удалось задать graphical.target'" \
  || bad "R3d: set-default fail — в журнале понятная ошибка 'не удалось задать graphical.target'"
[[ "$(result_val "$R" log_sddm_error)" == "no" ]] \
  && ok "R3e: set-default fail — ошибка именно set-default (enable sddm прошёл)" \
  || bad "R3e: set-default fail — ошибка именно set-default (enable sddm прошёл)"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R3f: set-default fail — sddm всё же включён (отказ только в default target)" \
  || bad "R3f: set-default fail — sddm всё же включён (отказ только в default target)"
[[ "$(result_val "$R" default_target)" == "not-graphical" ]] \
  && ok "R3g: set-default fail — default target НЕ graphical.target" \
  || bad "R3g: set-default fail — default target НЕ graphical.target"
[[ "$(result_val "$R" log_cleanup)" == "yes" && "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "R3h: set-default fail — cleanup выполнен, TARGET размонтирован" \
  || bad "R3h: set-default fail — cleanup выполнен, TARGET размонтирован"

# ================= R4. GNOME, падение enable gdm ==============================
run_scenario "r4-gnome-dm-fail" "gnome" 0 0 1
R="$T/r4-gnome-dm-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R4a: gdm fail — движок вышел с кодом 1" \
  || bad "R4a: gdm fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R4b: gdm fail — в stdout INSTALL_FAILED" \
  || bad "R4b: gdm fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R4c: gdm fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R4c: gdm fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_dm_error)" == "yes" ]] \
  && ok "R4d: gdm fail — в журнале понятная ошибка 'не удалось включить менеджер входа gdm'" \
  || bad "R4d: gdm fail — в журнале понятная ошибка 'не удалось включить менеджер входа gdm'"
[[ "$(result_val "$R" log_cleanup)" == "yes" && "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "R4e: gdm fail — cleanup выполнен, TARGET размонтирован" \
  || bad "R4e: gdm fail — cleanup выполнен, TARGET размонтирован"

# ================= R5. GNOME, успех ==============================
run_scenario "r5-gnome-ok" "gnome" 0 0 0
R="$T/r5-gnome-ok/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R5a: gnome успех — движок вышел с кодом 0" \
  || bad "R5a: gnome успех — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R5b: gnome успех — в stdout INSTALL_DONE" \
  || bad "R5b: gnome успех — в stdout INSTALL_DONE"
[[ "$(result_val "$R" dm_link_gdm)" == "yes" ]] \
  && ok "R5c: gnome успех — display-manager.service указывает на gdm" \
  || bad "R5c: gnome успех — display-manager.service указывает на gdm"
[[ "$(result_val "$R" default_target)" == "graphical" ]] \
  && ok "R5d: gnome успех — default target = graphical.target" \
  || bad "R5d: gnome успех — default target = graphical.target"

# ================= R0d. Проверка отсутствия протечки на хост ==============================
if [[ -e /run/archiso/bootmnt/xros/boot/x86_64/vmlinuz-linux ]]; then
  bad "R0d: фиктивное ядро НЕ должно быть видно на хосте (/run/archiso)"
else
  ok "R0d: фиктивный /run/archiso не потёк на хост"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (упавшие:$FAILED_NAMES)"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
