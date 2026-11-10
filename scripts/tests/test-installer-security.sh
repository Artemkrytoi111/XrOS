#!/usr/bin/env bash
# Тест безопасности установщика XrOS (повторный аудит, 2026-11-10).
#
# Что проверяется (БЕЗ форматирования реальных дисков — все
# разрушительные операции либо статически проверяются по коду,
# либо гоняются на заглушках lsblk/blkid/umount/sync через PATH,
# либо на РЕАЛЬНЫХ функциях движка, извлечённых между маркерами):
#  T0  статика: явные проверки вместо мёртвого `set -e` (sgdisk,
#      mkfs, mount, rsync, cp ядра, genfstab, chroot); защита диска
#      (идентификатор, повторная проверка перед wipefs/mkfs,
#      смонтированные разделы, TYPE=part, EFI=vfat); санитизация
#      HOSTNAME в обоих режимах; валидация TIMEZONE/KEYMAP;
#      EXIT-trap очистки при ошибке; симлинк-защита LOG/CONF;
#      пароли не попадают в журнал; GUI: фильтр смонтированных
#      дисков, обновление списка дисков, удаление CONF перед созданием;
#      предупреждение при пустом ISODISK; genfstab `>` вместо `>>`;
#      синхронность staged-копий движка.
#  T1  динамика (заглушка lsblk): xros_has_mounts — диск с ISO
#      (bootmnt) отклоняется, чистый диск проходит, монтирование
#      под $TARGET игнорируется.
#  T2  динамика: xros_dev_identity / xros_verify_identity —
#      отсутствующее устройство даёт MISSING и не проходит проверку;
#      несовпадение идентификатора — жёсткий стоп; T2c — полный путь
#      на реальном блочном устройстве (SKIP, если в /dev нет
#      блочных устройств, как в этой песочнице: mknod запрещён).
#  T3  динамика: %q-экранирование пароля/ФИО — round-trip через
#      shell для «сложных» паролей (как в chroot-heredoc движка).
#  T4  динамика: EXIT-trap — при `exit 1` во время установки
#      cleanup выполняется (umount TARGET, удаление временных файлов,
#      запись в журнал); при штатном `exit 0` cleanup НЕ выполняется.
#  T5  динамика: санитизация HOSTNAME/USERNAME/TIMEZONE/KEYMAP —
#      точные выражения из движка (полный прогон до say-строки
#      невозможен в песочнице: нет блочных устройств в /dev).
#
# Запуск: scripts/tests/test-installer-security.sh
# Выход 0 — все тесты PASS, иначе FAIL и список упавших.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
GUI_INSTALL="$ROOT/src/xros-install-gui-rs/src/install.rs"
GUI_SYSTEM="$ROOT/src/xros-install-gui-rs/src/system.rs"
GUI_APP="$ROOT/src/xros-install-gui-rs/src/app.rs"

PASS=0
FAIL=0
SKIPPED=0
FAILED_NAMES=""

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "FAIL: $1"; }
skip() { SKIPPED=$((SKIPPED+1)); echo "SKIP: $1 ($2)"; }

T="$(mktemp -d /tmp/xros-sec-test.XXXXXX)"
echo "Рабочий каталог теста: $T"
cleanup_test() {
  rm -f /tmp/xros-de-result /tmp/xros-install.conf
  rm -rf "$T"
}
trap cleanup_test EXIT

# --- Извлечь РЕАЛЬНЫЕ блоки из движка (между маркерами) ---
DISK_BLOCK="$T/disk-block.sh"
awk '/^# --- XROS: защита диска \(начало\) ---/{f=1; next}
     /^# --- XROS: защита диска \(конец\) ---/{f=0}
     f' "$ENGINE" > "$DISK_BLOCK"
CHILD_BLOCK="$T/child-block.sh"
awk '/^# --- XROS: защита дочернего процесса \(начало\) ---/{f=1; next}
     /^# --- XROS: защита дочернего процесса \(конец\) ---/{f=0}
     f' "$ENGINE" > "$CHILD_BLOCK"

# --- Заглушки: umount/sync/mountpoint ничего не монтируют ---
mkdir -p "$T/bin"
cat > "$T/bin/umount" <<EOF
#!/usr/bin/env bash
echo "umount \$*" >> "$T/umount.calls"
exit 0
EOF
cat > "$T/bin/sync" <<EOF
#!/usr/bin/env bash
echo "sync" >> "$T/sync.calls"
exit 0
EOF
# mountpoint: «смонтировано» только то, что перечислено в $T/mounted.list
cat > "$T/bin/mountpoint" <<EOF
#!/usr/bin/env bash
# последний аргумент — путь; -q игнорируем
p="\${@: -1}"
grep -Fxq "\$p" "$T/mounted.list" 2>/dev/null
EOF
# lsblk: режимы через файл $T/lsblk-mode (same|changed);
# MOUNTPOINT — по устройству, остальное — canned-вывод для identity.
cat > "$T/bin/lsblk" <<EOF
#!/usr/bin/env bash
dev="\${@: -1}"
mode="\$(cat "$T/lsblk-mode" 2>/dev/null || echo same)"
if [[ "\$*" == *MOUNTPOINT* ]]; then
  case "\$dev" in
    /dev/fakedisk) printf '/run/archiso/bootmnt\n\n' ;;
    /dev/cleandisk) printf '\n' ;;
    /dev/targetdisk) printf '%s\n' "\$TARGET" ;;
    *) printf '\n' ;;
  esac
  exit 0
fi
# запрос идентификатора: NAME,SIZE,TYPE,FSTYPE
if [[ "\$mode" == "changed" ]]; then
  printf '%s  999G disk \n' "\$(basename "\$dev")"
else
  printf '%s  100G disk \n' "\$(basename "\$dev")"
fi
EOF
cat > "$T/bin/blkid" <<EOF
#!/usr/bin/env bash
printf 'deadbeef-01\n'
EOF
chmod +x "$T/bin/umount" "$T/bin/sync" "$T/bin/mountpoint" "$T/bin/lsblk" "$T/bin/blkid"
echo same > "$T/lsblk-mode"
: > "$T/mounted.list"

# ============================================================ T0: статика
echo "== T0: статика =="
bash -n "$ENGINE" && ok "T0-syntax: bash -n src/xros-install" || bad "T0-syntax: bash -n src/xros-install"
if cmp -s "$ENGINE" "$ROOT/profile/airootfs/usr/local/bin/xros-install" \
  && cmp -s "$ENGINE" "$ROOT/packages/xros-installer/xros-install"; then
  ok "T0-sync: xros-install синхронен (src == airootfs == пакет)"
else
  bad "T0-sync: xros-install синхронен (src == airootfs == пакет)"
fi

# T0a: явные проверки вместо мёртвого set -e.
# (set -e в run_install не работает: функция вызывается в ||-списке
# и в пайплайне, bash игнорирует -e для всего её тела — проверено
# отдельным экспериментом; каждая структурная команда обязана иметь
# явный `|| { say "ОШИБКА..."; exit 1; }`.)
grep -Fq 'на `set -e` не полагаемся' "$ENGINE" \
  && ok "T0a0: в run_install задокументировано, что set -e мёртв" \
  || bad "T0a0: в run_install задокументировано, что set -e мёртв"
n=$(grep -Fc 'sgdisk --zap-all "$DISK" >>"$LOG" 2>&1 || { say "ОШИБКА' "$ENGINE")
[[ "$n" == "2" ]] && ok "T0a1: sgdisk --zap-all с проверкой (обе ветки)" || bad "T0a1: sgdisk --zap-all с проверкой (обе ветки, найдено: $n)"
n=$(grep -Fc 'XROS-ROOT" "$DISK" >>"$LOG" 2>&1 || { say "ОШИБКА' "$ENGINE")
[[ "$n" == "2" ]] && ok "T0a2: sgdisk -n (создание разделов) с проверкой (обе ветки)" || bad "T0a2: sgdisk -n (создание разделов) с проверкой (обе ветки, найдено: $n)"
grep -Fq 'mkfs.fat -F 32 -n XROS-EFI "$EFI_PART" >>"$LOG" 2>&1 || { say "ОШИБКА' "$ENGINE" \
  && ok "T0a3: mkfs.fat с проверкой" || bad "T0a3: mkfs.fat с проверкой"
n=$(grep -Fc 'mkfs_root "$ROOT_PART" "${FS:-ext4}" || { say "ОШИБКА' "$ENGINE")
[[ "$n" == "2" ]] && ok "T0a4: mkfs_root с проверкой (обе ветки)" || bad "T0a4: mkfs_root с проверкой (обе ветки, найдено: $n)"
grep -Fq 'mount "$ROOT_PART" "$TARGET" || { say "ОШИБКА' "$ENGINE" \
  && ok "T0a5: mount корня с проверкой" || bad "T0a5: mount корня с проверкой"
grep -Fq 'mount "$EFI_PART" "$TARGET/boot/efi" || { say "ОШИБКА' "$ENGINE" \
  && ok "T0a6: mount EFI с проверкой" || bad "T0a6: mount EFI с проверкой"
grep -Fq '/ "$TARGET"/ >>"$LOG" 2>&1 || { say "ОШИБКА: копирование живой системы' "$ENGINE" \
  && ok "T0a7: rsync с проверкой" || bad "T0a7: rsync с проверкой"
grep -Fq 'cp "$KERN_SRC/vmlinuz-linux" "$TARGET/boot/vmlinuz-linux" || { say "ОШИБКА' "$ENGINE" \
  && ok "T0a8: cp ядра с проверкой" || bad "T0a8: cp ядра с проверкой"
grep -Fq 'genfstab -U "$TARGET" > "$TARGET/etc/fstab" || { say "ОШИБКА' "$ENGINE" \
  && ok "T0a9: genfstab с проверкой" || bad "T0a9: genfstab с проверкой"
grep -Fq 'arch-chroot "$TARGET" bash -euo pipefail <<CHROOT_EOF >>"$LOG" 2>&1 || { say "ОШИБКА' "$ENGINE" \
  && ok "T0a10: chroot (locale, пользователи, mkinitcpio) с проверкой" || bad "T0a10: chroot (locale, пользователи, mkinitcpio) с проверкой"

# T0b: защита диска — функции есть и вызываются перед разрушением.
grep -q "xros_dev_identity()" "$ENGINE" && grep -q "xros_verify_identity()" "$ENGINE" \
  && grep -q "xros_has_mounts()" "$ENGINE" \
  && ok "T0b1: функции xros_dev_identity/verify/has_mounts есть" \
  || bad "T0b1: функции xros_dev_identity/verify/has_mounts есть"
grep -q 'xros_verify_identity "диск" "$DISK" "$XROS_DISK_ID"' "$ENGINE" \
  && grep -q 'xros_verify_identity "корневой раздел" "$ROOT_PART" "$XROS_ROOT_ID"' "$ENGINE" \
  && ok "T0b2: повторная проверка идентификатора перед wipefs/mkfs" \
  || bad "T0b2: повторная проверка идентификатора перед wipefs/mkfs"
grep -q 'if xros_has_mounts "$DISK"' "$ENGINE" \
  && grep -q 'if xros_has_mounts "$ROOT_PART"' "$ENGINE" \
  && ok "T0b3: проверка смонтированных разделов перед wipefs/mkfs" \
  || bad "T0b3: проверка смонтированных разделов перед wipefs/mkfs"
grep -q 'XROS_DISK_ID=$(xros_dev_identity "$DISK")' "$ENGINE" \
  && grep -q 'XROS_ROOT_ID=$(xros_dev_identity "$ROOT_PART")' "$ENGINE" \
  && ok "T0b4: идентификатор запоминается при выборе диска/раздела" \
  || bad "T0b4: идентификатор запоминается при выборе диска/раздела"

# T0c: типы устройств и FAT для EFI.
n=$(grep -Fc '"$(lsblk -n -o TYPE "$ROOT_PART" 2>/dev/null)" == "part"' "$ENGINE")
[[ "$n" == "2" ]] && ok "T0c1: ROOT_PART проверяется на TYPE=part (конфиг + run_install)" || bad "T0c1: ROOT_PART проверяется на TYPE=part (конфиг + run_install, найдено: $n)"
grep -Fq '"$(lsblk -n -o TYPE "$EFI_PART" 2>/dev/null)" == "part"' "$ENGINE" \
  && ok "T0c2: EFI_PART проверяется на TYPE=part" || bad "T0c2: EFI_PART проверяется на TYPE=part"
grep -Fq '"$(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null)" == "vfat"' "$ENGINE" \
  && ok "T0c3: EFI-раздел проверяется на vfat до форматирования корня" || bad "T0c3: EFI-раздел проверяется на vfat до форматирования корня"

# T0d: HOSTNAME обезличивается в ОБОИХ режимах (раньше — только
# в неинтерактивном; перевод строки из dialog ломал /etc/hostname и /etc/hosts).
n=$(grep -Fc "HOSTNAME=\$(printf '%s' \"\$HOSTNAME\" | tr -cd 'a-zA-Z0-9.-')" "$ENGINE")
[[ "$n" == "2" ]] && ok "T0d: санитизация HOSTNAME в обоих режимах" || bad "T0d: санитизация HOSTNAME в обоих режимах (найдено: $n)"

# T0e: TIMEZONE/KEYMAP из конфига валидируются.
grep -Fq 'TIMEZONE:-}" =~ ^[A-Za-z0-9_+/-]+$' "$ENGINE" \
  && grep -Fq 'KEYMAP:-}" =~ ^[a-z0-9_-]+$' "$ENGINE" \
  && grep -Fq '/usr/share/zoneinfo/${TIMEZONE:-Europe/Astrakhan}"' "$ENGINE" \
  && ok "T0e: валидация TIMEZONE/KEYMAP + проверка zoneinfo" \
  || bad "T0e: валидация TIMEZONE/KEYMAP + проверка zoneinfo"

# T0f: EXIT-trap очистки при ошибке + флаг установки.
grep -q "xros_on_exit()" "$ENGINE" && grep -q "trap xros_on_exit EXIT" "$ENGINE" \
  && grep -q "XROS_INSTALLING=1" "$ENGINE" && grep -q "XROS_INSTALLING=0" "$ENGINE" \
  && ok "T0f: EXIT-trap cleanup при ошибке во время установки" \
  || bad "T0f: EXIT-trap cleanup при ошибке во время установки"

# T0g: симлинк-защита /tmp-файлов.
grep -Fq '[[ -L "$LOG" ]] && rm -f "$LOG"' "$ENGINE" \
  && grep -Fq 'rm -f /tmp/xros-de-result' "$ENGINE" \
  && grep -q "remove_file(CONF)" "$GUI_INSTALL" \
  && ok "T0g: LOG/CONF/de-result защищены от симлинков и stale-файлов" \
  || bad "T0g: LOG/CONF/de-result защищены от симлинков и stale-файлов"

# T0h: пароли не попадают в журнал.
if grep -Eq 'say ".*(USERPASS|ROOTPASS|userpass|rootpass)' "$ENGINE" "$GUI_INSTALL" "$GUI_APP"; then
  bad "T0h: пароли не попадают в say()/журнал"
else
  ok "T0h: пароли не попадают в say()/журнал"
fi
grep -Fq 'echo root:$ROOTPASS_Q | chpasswd' "$ENGINE" \
  && grep -Fq 'echo $USERNAME_Q:$USERPASS_Q | chpasswd' "$ENGINE" \
  && grep -Fq 'printf -v USERPASS_Q %q "$USERPASS"' "$ENGINE" \
  && ok "T0h2: chpasswd — только через pipe, пароль %q-экранирован" \
  || bad "T0h2: chpasswd — только через pipe, пароль %q-экранирован"

# T0i: GUI — фильтр смонтированных дисков, обновление списка, CONF.
grep -q "pub fn has_mounts" "$GUI_SYSTEM" \
  && grep -q "if has_mounts(&dev)" "$GUI_SYSTEM" \
  && ok "T0i1: GUI не показывает диски со смонтированными разделами" \
  || bad "T0i1: GUI не показывает диски со смонтированными разделами"
grep -q "self.disks = system::list_disks();" "$GUI_APP" \
  && ok "T0i2: GUI обновляет список дисков при входе на шаг Разделы" \
  || bad "T0i2: GUI обновляет список дисков при входе на шаг Разделы"
grep -q "let _ = std::fs::remove_file(CONF);" "$GUI_INSTALL" \
  && ok "T0i3: GUI удаляет CONF перед созданием (симлинк/stale)" \
  || bad "T0i3: GUI удаляет CONF перед созданием (симлинк/stale)"

# T0j: пустой ISODISK — предупреждение в обоих режимах (ограничение
# первого аудита теперь закрыто проверкой смонтированных разделов).
n=$(grep -Fc "ISODISK пуст" "$ENGINE")
[[ "$n" == "2" ]] && ok "T0j: предупреждение о пустом ISODISK в обоих режимах" || bad "T0j: предупреждение о пустом ISODISK в обоих режимах (найдено: $n)"

# T0k: финальный umount с ретраем и жёсткой ошибкой, а не `|| true`.
grep -Fq 'umount -R "$TARGET" 2>/dev/null || {' "$ENGINE" \
  && grep -Fq 'say "ОШИБКА: не удалось размонтировать $TARGET"' "$ENGINE" \
  && ok "T0k: финальный umount — ретрай + жёсткая ошибка" \
  || bad "T0k: финальный umount — ретрай + жёсткая ошибка"

# T0l: проверка, что $TARGET реально размонтирован перед разрушением.
n=$(grep -Fc 'if mountpoint -q "$TARGET" 2>/dev/null; then' "$ENGINE")
[[ "$n" == "2" ]] && ok "T0l: mountpoint-проверка \$TARGET перед wipefs/mkfs (обе ветки)" || bad "T0l: mountpoint-проверка \$TARGET перед wipefs/mkfs (обе ветки, найдено: $n)"

# T0m: fstab перезаписывается, а не дописывается (дубли при повторе).
if grep -Fq 'genfstab -U "$TARGET" >> "$TARGET/etc/fstab"' "$ENGINE"; then
  bad "T0m: genfstab перезаписывает fstab (без >>)"
else
  ok "T0m: genfstab перезаписывает fstab (без >>)"
fi

# T0n: swapoff с комментарием, почему безопасен (п.6 первого аудита).
grep -Fq "swapoff -a гасит весь swap живой системы" "$ENGINE" \
  && ok "T0n: swapoff -a прокомментирован" \
  || bad "T0n: swapoff -a прокомментирован"

# T0o: блоки защиты извлекаются целиком (как в test-child-process.sh).
if [[ -s "$DISK_BLOCK" ]] && grep -q "xros_verify_identity" "$DISK_BLOCK" && grep -q "xros_has_mounts" "$DISK_BLOCK"; then
  ok "T0o: блок защиты диска извлечён из src/xros-install целиком"
else
  bad "T0o: блок защиты диска извлечён из src/xros-install целиком"
fi
if [[ -s "$CHILD_BLOCK" ]] && grep -q "xros_on_exit" "$CHILD_BLOCK" && grep -q "xros_cleanup" "$CHILD_BLOCK"; then
  ok "T0o2: блок защиты дочернего процесса извлечён целиком (с EXIT-trap)"
else
  bad "T0o2: блок защиты дочернего процесса извлечён целиком (с EXIT-trap)"
fi

# ============================================================ T1: has_mounts
echo "== T1: xros_has_mounts (заглушка lsblk) =="
cat > "$T/t1.sh" <<'T1_EOF'
#!/usr/bin/env bash
set -u
export TARGET="$1"; LOG="$2"
export PATH="$3:$PATH"
say() { printf '%s\n' "[harness] $*" >> "$LOG"; }
# shellcheck disable=SC1090
source "$4"
if xros_has_mounts /dev/fakedisk; then echo "fakedisk:MOUNTED"; else echo "fakedisk:CLEAN"; fi
if xros_has_mounts /dev/cleandisk; then echo "cleandisk:MOUNTED"; else echo "cleandisk:CLEAN"; fi
if xros_has_mounts /dev/targetdisk; then echo "targetdisk:MOUNTED"; else echo "targetdisk:CLEAN"; fi
T1_EOF
chmod +x "$T/t1.sh"
mkdir -p "$T/t1-target"
bash "$T/t1.sh" "$T/t1-target" "$T/t1.log" "$T/bin" "$DISK_BLOCK" > "$T/t1.out" 2>&1
grep -q "fakedisk:MOUNTED" "$T/t1.out" \
  && ok "T1a: диск с ISO (bootmnt) определяется как смонтированный" \
  || bad "T1a: диск с ISO (bootmnt) определяется как смонтированный"
grep -q "cleandisk:CLEAN" "$T/t1.out" \
  && ok "T1b: чистый диск определяется как несмонтированный" \
  || bad "T1b: чистый диск определяется как несмонтированный"
grep -q "targetdisk:CLEAN" "$T/t1.out" \
  && ok "T1c: монтирование под \$TARGET игнорируется (своё)" \
  || bad "T1c: монтирование под \$TARGET игнорируется (своё)"

# ============================================================ T2: identity
echo "== T2: xros_dev_identity / xros_verify_identity =="
cat > "$T/t2.sh" <<'T2_EOF'
#!/usr/bin/env bash
set -u
TARGET="$1"; LOG="$2"
export PATH="$3:$PATH"
say() { printf '%s\n' "[harness] $*" >> "$LOG"; }
# shellcheck disable=SC1090
source "$4"
mode="$5"
# T2a/T2b: отсутствующее устройство
id_missing=$(xros_dev_identity /dev/nonexistent9)
echo "missing-id:$id_missing"
( xros_verify_identity "диск" /dev/nonexistent9 "$id_missing" ) && echo "verify-same:OK" || echo "verify-same:FAIL"
( xros_verify_identity "диск" /dev/nonexistent9 "sysfs=/sys/class/block/other|lsblk=x|partuuid=y" ) && echo "verify-diff:OK" || echo "verify-diff:FAIL"
# T2c: реальное блочное устройство (если есть)
real=""
for d in /dev/*; do [[ -b "$d" ]] && { real="$d"; break; }; done
if [[ -n "$real" ]]; then
  echo "real-dev:$real"
  id1=$(xros_dev_identity "$real")
  id2=$(xros_dev_identity "$real")
  echo "real-id1:$id1"
  [[ "$id1" == "$id2" && -n "$id1" && "$id1" != MISSING:* ]] && echo "real-stable:OK" || echo "real-stable:FAIL"
  ( xros_verify_identity "диск" "$real" "$id1" ) && echo "real-verify:OK" || echo "real-verify:FAIL"
  echo "changed" > "$6"
  ( xros_verify_identity "диск" "$real" "$id1" ) && echo "real-swap:OK" || echo "real-swap:FAIL"
  echo "same" > "$6"
else
  echo "real-dev:NONE"
fi
T2_EOF
chmod +x "$T/t2.sh"
mkdir -p "$T/t2-target"
bash "$T/t2.sh" "$T/t2-target" "$T/t2.log" "$T/bin" "$DISK_BLOCK" x "$T/lsblk-mode" > "$T/t2.out" 2>&1
grep -q "missing-id:MISSING:/dev/nonexistent9" "$T/t2.out" \
  && ok "T2a: отсутствующее устройство даёт MISSING-идентификатор" \
  || bad "T2a: отсутствующее устройство даёт MISSING-идентификатор"
grep -q "verify-same:OK" "$T/t2.out" \
  && ok "T2b1: проверка проходит при совпадении идентификатора" \
  || bad "T2b1: проверка проходит при совпадении идентификатора"
grep -q "verify-diff:FAIL" "$T/t2.out" \
  && ok "T2b2: проверка НЕ проходит при несовпадении (стоп до разрушения)" \
  || bad "T2b2: проверка НЕ проходит при несовпадении (стоп до разрушения)"
if grep -q "real-dev:NONE" "$T/t2.out"; then
  skip "T2c: полный путь identity на реальном диске" "в /dev нет блочных устройств (mknod запрещён в песочнице)"
else
  grep -q "real-stable:OK" "$T/t2.out" \
    && ok "T2c1: идентификатор реального диска стабилен между вызовами" \
    || bad "T2c1: идентификатор реального диска стабилен между вызовами"
  grep -q "real-verify:OK" "$T/t2.out" \
    && ok "T2c2: проверка реального диска проходит" \
    || bad "T2c2: проверка реального диска проходит"
  grep -q "real-swap:FAIL" "$T/t2.out" \
    && ok "T2c3: подмена диска (другой SIZE) ловится проверкой" \
    || bad "T2c3: подмена диска (другой SIZE) ловится проверкой"
fi

# ============================================================ T3: %q round-trip
echo "== T3: %q-экранирование паролей (как в chroot-heredoc) =="
t3_fail=0
# Пароль/ФИО -> %q -> inner-shell -> echo: должно вернуться как было.
# Точная имитация движка: хостовый shell подставляет %q-текст в
# heredoc БЕЗ кавычек, внутренний bash разбирает escapes.
# (eval в кавычках для этого не годится: внутри "..." escapes
# сохраняются буквально и round-trip ломается.)
while IFS= read -r pass; do
  [[ -z "$pass" ]] && continue
  printf -v Q %q "$pass"
  printf 'echo root:%s\n' "$Q" > "$T/t3-inner.sh"
  out=$(bash "$T/t3-inner.sh")
  if [[ "$out" != "root:$pass" ]]; then
    echo "  round-trip FAIL для: [$pass] -> [$out]"
    t3_fail=1
  fi
done <<'PASSES'
p@ss w0rd
a$b`c"d
it's
back\slash
dollar$ign
-leading-dash
semi;colon
star*quest?
$(echo hacked)
tab	char
PASSES
# Пароль с переводом строки: %q сохраняет его, но chpasswd читает
# построчно — такой пароль движок отверг бы ошибкой chpasswd
# (жёсткий стоп, а не тихая установка неверного пароля); GUI
# (singleline) и dialog (passwordbox) перевод строки не дают вовсе.
printf -v Q %q "$(printf 'a\nb')"
printf 'echo root:%s\n' "$Q" > "$T/t3-inner.sh"
out=$(bash "$T/t3-inner.sh")
[[ "$out" == "$(printf 'root:a\nb')" ]] || t3_fail=1
[[ "$t3_fail" == "0" ]] \
  && ok "T3: %q round-trip для сложных паролей (пробелы, \$, кавычки, ;, *)" \
  || bad "T3: %q round-trip для сложных паролей (пробелы, \$, кавычки, ;, *)"

# ============================================================ T4: EXIT-trap
echo "== T4: EXIT-trap очистки при ошибке =="
cat > "$T/t4.sh" <<'T4_EOF'
#!/usr/bin/env bash
set -u
TARGET="$1"; LOG="$2"; MODE="$3"
export PATH="$4:$PATH"
NONINTERACTIVE=1
mkdir -p "$TARGET"
say() { printf '%s\n' "[harness] $*" >> "$LOG"; }
# shellcheck disable=SC1090
source "$5"
touch /tmp/xros-de-result /tmp/xros-install.conf
if [[ "$MODE" == "fail" ]]; then
  XROS_INSTALLING=1
  exit 1
else
  XROS_INSTALLING=0
  exit 0
fi
T4_EOF
chmod +x "$T/t4.sh"
# T4a: ошибка во время установки — cleanup выполнен
rm -f "$T/umount.calls"
bash "$T/t4.sh" "$T/t4-target" "$T/t4-fail.log" fail "$T/bin" "$CHILD_BLOCK" > "$T/t4-fail.out" 2>&1
rc=$?
if [[ "$rc" == "1" ]] && grep -q "Очистка завершена" "$T/t4-fail.log" \
  && grep -q "umount -R $T/t4-target" "$T/umount.calls" 2>/dev/null \
  && [[ ! -f /tmp/xros-de-result && ! -f /tmp/xros-install.conf ]]; then
  ok "T4a: exit 1 во время установки — cleanup (umount + удаление временных файлов + журнал)"
else
  bad "T4a: exit 1 во время установки — cleanup (rc=$rc)"
fi
# T4b: штатный успех — cleanup НЕ выполняется
rm -f "$T/umount.calls"
bash "$T/t4.sh" "$T/t4-target" "$T/t4-ok.log" ok "$T/bin" "$CHILD_BLOCK" > "$T/t4-ok.out" 2>&1
rc=$?
if [[ "$rc" == "0" ]] && ! grep -q "Очистка завершена" "$T/t4-ok.log" 2>/dev/null; then
  ok "T4b: exit 0 — cleanup не выполняется, лишних действий нет"
else
  bad "T4b: exit 0 — cleanup не выполняется (rc=$rc)"
fi

# ============================================================ T5: санитизация
echo "== T5: санитизация значений (точные выражения из движка) =="
# Полный прогон движка до say-строки невозможен в песочнице:
# нет ни одного блочного устройства в /dev (mknod запрещён даже
# в userns на свежем tmpfs), а проверка [[ -b DISK ]] — ворота
# в run_install. Поэтому здесь — те же выражения, что в движке,
# один в один (контроль потока — статикой T0d/T0e + e2e-прогоном
# валидации выше: предупреждение о TIMEZONE реально печатается).
t5_fail=0
HOSTNAME=$(printf 'evil\n127.0.0.1 bank.example' | tr -cd 'a-zA-Z0-9.-')
[[ "$HOSTNAME" == "evil127.0.0.1bank.example" ]] || { echo "  HOSTNAME: [$HOSTNAME]"; t5_fail=1; }
USERNAME="9xros"
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_]*$ ]] || USERNAME="u$USERNAME"
[[ "$USERNAME" == "u9xros" ]] || { echo "  USERNAME: [$USERNAME]"; t5_fail=1; }
TIMEZONE='../../etc/passwd'
if [[ ! "${TIMEZONE:-}" =~ ^[A-Za-z0-9_+/-]+$ || "${TIMEZONE:-}" == *..* || ! -f "/usr/share/zoneinfo/${TIMEZONE:-}" ]]; then
  TIMEZONE="Europe/Astrakhan"
fi
[[ "$TIMEZONE" == "Europe/Astrakhan" ]] || { echo "  TIMEZONE: [$TIMEZONE]"; t5_fail=1; }
KEYMAP=$(printf 'ru\nEVIL=1')
[[ "${KEYMAP:-}" =~ ^[a-z0-9_-]+$ ]] || KEYMAP="ru"
[[ "$KEYMAP" == "ru" ]] || { echo "  KEYMAP: [$KEYMAP]"; t5_fail=1; }
# Легитимные значения не трогаются.
HOSTNAME="xros-os"; HOSTNAME=$(printf '%s' "$HOSTNAME" | tr -cd 'a-zA-Z0-9.-')
[[ "$HOSTNAME" == "xros-os" ]] || t5_fail=1
TIMEZONE="Europe/Astrakhan"
if [[ ! "${TIMEZONE:-}" =~ ^[A-Za-z0-9_+/-]+$ || "${TIMEZONE:-}" == *..* || ! -f "/usr/share/zoneinfo/${TIMEZONE:-}" ]]; then
  TIMEZONE="Europe/Astrakhan"
fi
[[ "$TIMEZONE" == "Europe/Astrakhan" ]] || t5_fail=1
[[ "$t5_fail" == "0" ]] \
  && ok "T5: санитизация HOSTNAME/USERNAME/TIMEZONE/KEYMAP (точные выражения)" \
  || bad "T5: санитизация HOSTNAME/USERNAME/TIMEZONE/KEYMAP (точные выражения)"

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPPED (упавшие:$FAILED_NAMES)"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
