#!/usr/bin/env bash
# XrOS — тест P4-AUD-02: fail-closed отключение конкурирующих DM.
#
# Проверяет исправление: `systemctl disable <dm>` для существующих
# конкурирующих менеджеров входа больше не подавляется `|| true`,
# а прерывает установку с понятной ошибкой (exit 1, INSTALL_FAILED,
# без INSTALL_DONE). Отсутствующий юнит — безопасно пропускается
# (проверка файла юнита в целевой системе, без вызова systemctl).
# Выбранный DM не отключается (пропускается в цикле), а включается
# следующей командой (P4-AUD-01, fail-closed).
#
# Слои:
#   S — статика: helper + цикл во всех 3 копиях движка, нет `|| true`
#       на disable, P4-AUD-01 не тронут, set-default multi-user.target
#       (вне объёма) не тронут, 3 копии байт-в-байт.
#   R — рантайм: РЕАЛЬНЫЙ движок в `unshare -rm` с фиктивным диском
#       (файл + LD_PRELOAD-шим, как в test-sddm-failclosed.sh):
#       unit-файлы DM создаются заглушкой rsync в фиктивной цели
#       (DM_UNITS — /usr/lib, DM_UNITS_ETC — /etc,
#       DM_UNITS_LOCAL — /usr/local/lib; DM_MASKED — симлинк на
#       /dev/null, DM_DANGLING — висячий симлинк, DM_CORRUPT —
#       мусор без [Unit], DM_DIR — каталог вместо файла;
#       DM_ENABLED — предвключённые; DM_ALIAS_FILE — alias как
#       обычный файл; DM_ALIAS_DANGLING — alias как висячий
#       симлинк), заглушка arch-chroot моделирует systemctl
#       disable/enable/set-default с флагами отказа
#       (FAIL_DISABLE — список юнитов, SYSTEMD_UNAVAILABLE — все
#       вызовы systemctl падают).
#
# Модель заглушки systemctl (V-02/V-03, усилена по аудиту):
#   состояние юнита выводится из ФАЙЛОВОЙ СИСТЕМЫ цели (тип, цель
#   симлинка, содержимое файла — unit_state()), а не из переменных
#   окружения и не копированием предиката движка ([ -e ]). Переменные
#   DM_* используются ТОЛЬКО заглушкой rsync для СОЗДАНИЯ начального
#   состояния; заглушка arch-chroot их не читает и определяет
#   состояние самостоятельно — расхождение предикатов ловится.
#   Поведение enable/disable сверено с настоящим systemctl 255
#   (--root на временных целях, аудит E1–E19 + проверка A1/B1/B2
#   этого этапа): absent/dangling/corrupt/directory — rc 1,
#   masked — disable rc 0 / enable rc 1, повторный enable того же
#   DM — rc 0; alias на другой юнит или обычный файл/каталог —
#   rc 1, alias НЕ перезаписывается, но wants-симлинк СОЗДАЁТСЯ
#   (частичное изменение, как у реального systemctl — не скрываем);
#   висячий alias — реальный systemctl УДАЛЯЕТ его и создаёт
#   заново (rc 0). Общая ошибка FAIL_* — без частичных изменений.
#
# Сценарии (нумерация — по заданию; R16–R23 — усиление по аудиту
# P4-AUD-02-INDEPENDENT-REPORT, V-02/V-03):
#   R1  kde + sddm: успех (конкуренты отсутствуют — пропуск).
#   R2  kde + конкурирующий gdm: успешное отключение.
#   R3  gnome + gdm: успех.
#   R4  gnome + конкурирующий sddm: успешное отключение.
#   R5  lightdm как конкурирующий: успешное отключение (kde).
#   R6  несуществующий сервис: disable не вызывается вообще (xfce).
#   R7  уже отключённый сервис: disable rc=0, успех.
#   R8  уже замаскированный сервис: disable rc=0, успех.
#   R9  ошибка systemctl disable: exit 1, INSTALL_FAILED.
#   R10 ошибка systemctl enable: exit 1 (P4-AUD-01 сохранён).
#   R11 ошибка systemctl set-default: exit 1 (P4-AUD-01 сохранён).
#   R12 недоступный systemd: disable падает, exit 1.
#   R13 ненулевой exit code при обязательной ошибке (R9–R12).
#   R14 нет ложного успеха (R9–R12: нет INSTALL_DONE, нет de-result).
#   R15 cleanup/EXIT trap (R9, R12).
#   R16 неизвестный DM xdm удерживает alias: V-01 pre-check отказывает
#       ДО enable (понятная ошибка, alias не тронут, частичного
#       состояния нет), нет INSTALL_DONE, cleanup.
#   R17 alias — обычный файл: V-01 pre-check отказывает ДО enable,
#       нет INSTALL_DONE, cleanup.
#   R18 конкурент только в /etc/systemd/system: helper находит его,
#       disable успешен, установка успешна.
#   R19 конкурент только в /usr/local/lib/systemd/system: аналогично.
#   R20 конкурент — повреждённый unit-файл: disable падает, отказ.
#   R21 путь gdm.service — каталог: disable падает, отказ.
#   R22 конкурент — висячий симлинк: helper пропускает (как реальный
#       systemctl), установка успешна, disable не вызывается (V-03).
#   R23 alias — висячий симлинк: реальный systemctl удаляет его и
#       создаёт заново, enable успешен (проверено --root, A1).
#   R24 alias — каталог: V-01 pre-check отказывает ДО enable,
#       нет INSTALL_DONE, cleanup.
#   R25 юнит только в /run/systemd/system: helper его НЕ ищет
#       (V-05 — /run пуст при установке по механизму), установка
#       успешна; alias не затронут.
#   R26 юнит только в /run удерживает alias (предвключён): установка
#       честно прерывается fail-closed на enable (V-05, граничный
#       случай — по механизму не возникает, но отказ безопасен).
#   R27 финальная проверка (V-07): юнит удалён после enable (гонка
#       TOCTOU) — проверка ловит висячий alias, отказ, нет INSTALL_DONE.
#   R28 финальная проверка (V-07): alias переставлен на sddm-foo.service
#       после enable — проверка ловит неточное имя, отказ.
#   R29 финальная проверка (V-07): юнит замаскирован после enable —
#       проверка ловит маску, отказ.
#   R30 финальная проверка (V-07): юнит заменён каталогом после
#       enable — проверка ловит неверный тип, отказ.
#   Дополнительно: DE=none успех и DE=none + ошибка disable;
#   замаскированный ВЫБРАННЫЙ DM (enable падает, P4-AUD-01).
#
# Безопасность: только фиктивные файлы внутри $T, никаких физических
# дисков, ISO, QEMU, коммитов. /run/archiso/bootmnt — фиктивный
# источник ядра, создаётся внутри mount namespace (tmpfs + make-rprivate),
# на хост не протекает (проверяется в R0).
#
# Запуск: ./scripts/tests/test-display-manager-failclosed.sh
# Выход: 0 — все проверки PASS; 1 — есть FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
ENGINE_PROFILE="$ROOT/profile/airootfs/usr/local/bin/xros-install"
ENGINE_PKG="$ROOT/packages/xros-installer/xros-install"
T="$(mktemp -d /tmp/xros-dm-test.XXXXXX)"
PASS=0; FAIL=0; SKIP=0; FAILED_NAMES=""
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "SKIP: $1 ($2)"; }
trap 'rm -rf "$T"; umount -R /mnt/xros-install 2>/dev/null || true' EXIT

# ================= S. Статика ==============================
# S1: нет `|| true` на systemctl disable ни в одной копии движка.
s1_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  if grep -q 'systemctl disable.*|| true' "$f"; then s1_fail=1; fi
done
[[ "$s1_fail" == "0" ]] \
  && ok "S1: нет '|| true' на 'systemctl disable' (3 копии)" \
  || bad "S1: нет '|| true' на 'systemctl disable' (3 копии)"
# S2: helper xros_disable_dm есть во всех 3 копиях, с fail-closed.
s2_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q '^xros_disable_dm() {' "$f" || s2_fail=1
  grep -q 'не удалось отключить \$unit в установленной системе' "$f" || s2_fail=1
  grep -A3 'systemctl disable "\$unit"' "$f" | grep -q 'exit 1' || s2_fail=1
  grep -q 'Пропуск: \$unit отсутствует в установленной системе' "$f" || s2_fail=1
done
[[ "$s2_fail" == "0" ]] \
  && ok "S2: helper xros_disable_dm с fail-closed и веткой 'отсутствует' (3 копии)" \
  || bad "S2: helper xros_disable_dm с fail-closed и веткой 'отсутствует' (3 копии)"
# S3: цикл отключения перечисляет все три DM в каждой из трёх веток
# (KDE, none, другие DE) — ровно 3 цикла на копию.
s3_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  [[ "$(grep -c 'for dm in sddm lightdm gdm; do' "$f")" == "3" ]] || s3_fail=1
  [[ "$(grep -c 'xros_disable_dm "\$dm.service"' "$f")" == "3" ]] || s3_fail=1
done
[[ "$s3_fail" == "0" ]] \
  && ok "S3: цикл 'for dm in sddm lightdm gdm' + xros_disable_dm — в 3 ветках (3 копии)" \
  || bad "S3: цикл 'for dm in sddm lightdm gdm' + xros_disable_dm — в 3 ветках (3 копии)"
# S4: P4-AUD-04 FIX-B (V-09): set-default multi-user.target — fail-closed,
# проглатывание (|| true) убрано; ошибка с понятным сообщением.
s4_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q 'systemctl set-default multi-user.target.*|| true' "$f" && s4_fail=1
  grep -q 'не удалось установить multi-user.target как цель по умолчанию' "$f" || s4_fail=1
  grep -A1 'systemctl set-default multi-user.target' "$f" | grep -q 'exit 1' || s4_fail=1
done
[[ "$s4_fail" == "0" ]] \
  && ok "S4: 'set-default multi-user.target' fail-closed, '|| true' убрано (FIX-B V-09, 3 копии)" \
  || bad "S4: 'set-default multi-user.target' fail-closed, '|| true' убрано (FIX-B V-09, 3 копии)"
# S5: P4-AUD-01 не тронут (enable sddm / enable $DE_DM / set-default
# graphical.target — fail-closed во всех 3 копиях).
s5_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q 'не удалось включить SDDM в установленной системе' "$f" || s5_fail=1
  grep -q 'не удалось задать graphical.target по умолчанию' "$f" || s5_fail=1
  grep -q 'не удалось включить менеджер входа \$DE_DM' "$f" || s5_fail=1
  grep -A1 'systemctl enable sddm.service' "$f" | grep -q 'exit 1' || s5_fail=1
  grep -A1 'systemctl set-default graphical.target' "$f" | grep -q 'exit 1' || s5_fail=1
  grep -A1 'systemctl enable "\$DE_DM.service"' "$f" | grep -q 'exit 1' || s5_fail=1
done
[[ "$s5_fail" == "0" ]] \
  && ok "S5: P4-AUD-01 intact (fail-closed enable/set-default, 3 копии)" \
  || bad "S5: P4-AUD-01 intact (fail-closed enable/set-default, 3 копии)"
# S6: три копии движка байт-в-байт (R16 по заданию).
if cmp -s "$ENGINE" "$ENGINE_PROFILE" && cmp -s "$ENGINE" "$ENGINE_PKG" \
   && [[ "$(sha256sum "$ENGINE" | cut -d' ' -f1)" == "$(sha256sum "$ENGINE_PROFILE" | cut -d' ' -f1)" ]] \
   && [[ "$(sha256sum "$ENGINE" | cut -d' ' -f1)" == "$(sha256sum "$ENGINE_PKG" | cut -d' ' -f1)" ]]; then
  ok "S6: три копии движка байт-в-байт (cmp + sha256)"
else
  bad "S6: три копии движка байт-в-байт (cmp + sha256)"
fi
# S7: выбранный DM пропускается в цикле отключения.
s7_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q '\[ "\$dm" = "\$DE_DM" \] && continue' "$f" || s7_fail=1
done
[[ "$s7_fail" == "0" ]] \
  && ok "S7: выбранный DM пропускается в цикле ('[ \$dm = \$DE_DM ] && continue', 3 копии)" \
  || bad "S7: выбранный DM пропускается в цикле ('[ \$dm = \$DE_DM ] && continue', 3 копии)"

# S8/S9: проверяем секцию заглушки arch-chroot (между heredoc-маркерами),
# а не весь файл — иначе текст самой проверки и шапка файла удовлетворили
# бы grep. Номера строк берутся по маркерам; маркер начала собирается
# через переменную, чтобы сама проверка не попала в диапазон.
_m="STUB_EOF"
_s1="$(grep -n -F "<<'$_m'" "$0" | head -1 | cut -d: -f1)"
_s2="$(grep -n '^STUB_EOF$' "$0" | head -1 | cut -d: -f1)"
STUB_SECT="$(sed -n "${_s1},${_s2}p" "$0")"
# S8: заглушка enable моделирует alias-конфликты (V-02): чужой alias
# не перезаписывается (stub-alias-conflict), обычный файл/каталог
# отклоняется (stub-alias-regular), висячий alias удаляется и
# пересоздаётся (stub-alias-dangling), wants создаётся даже при отказе.
{ echo "$STUB_SECT" | grep -q 'stub-alias-conflict'; } \
  && { echo "$STUB_SECT" | grep -q 'stub-alias-regular'; } \
  && { echo "$STUB_SECT" | grep -q 'stub-alias-dangling'; } \
  && { echo "$STUB_SECT" | grep -q 'cur.*upath'; } \
  && ok "S8: заглушка enable моделирует alias-конфликты (чужой alias / обычный файл / висячий alias, wants при отказе)" \
  || bad "S8: заглушка enable моделирует alias-конфликты (чужой alias / обычный файл / висячий alias, wants при отказе)"
# S9: независимая модель состояния юнита (V-03): заглушка arch-chroot
# выводит состояние из файловой системы (unit_state: absent/valid/
# masked/dangling/directory/corrupt) и НЕ читает переменные DM_*
# (DM_UNITS/DM_MASKED/DM_CORRUPT/DM_DIR/DM_DANGLING/DM_ENABLED/...) —
# они используются только заглушкой rsync для СОЗДАНИЯ состояния.
# Примечание: проверяются именно переменные СОЗДАНИЯ состояния, а не
# подстрока 'DM_' — флаги отказа FAIL_SDDM_ENABLE/FAIL_DM_ENABLE
# заглушка читать обязана, и 'DM_' в них — ложное срабатывание.
# DM_RACE в список НЕ входит: её читает обработчик set-default (для
# инъекции гонки TOCTOU, V-07), а не unit_state().
{ echo "$STUB_SECT" | grep -q 'unit_state()'; } \
  && { echo "$STUB_SECT" | grep -q '"dangling"'; } \
  && { echo "$STUB_SECT" | grep -q '"corrupt"'; } \
  && { echo "$STUB_SECT" | grep -q '"directory"'; } \
  && ! { echo "$STUB_SECT" | grep -qE 'DM_UNITS|DM_MASKED|DM_DANGLING|DM_CORRUPT|DM_DIR|DM_ENABLED|DM_ALIAS'; } \
  && ok "S9: заглушка arch-chroot определяет состояние юнита независимо (unit_state, без DM_*)" \
  || bad "S9: заглушка arch-chroot определяет состояние юнита независимо (unit_state, без DM_*)"
# S10: механизм V-05 — rsync копирования живой системы исключает
# /run/*, поэтому юнит DM не может попасть в цель из живой системы
# через /run (проверяется движок, 3 копии).
s10_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q "exclude='/run/\*'" "$f" || s10_fail=1
done
[[ "$s10_fail" == "0" ]] \
  && ok "S10: rsync исключает '/run/*' — /run-юниты не копируются в цель (V-05, 3 копии)" \
  || bad "S10: rsync исключает '/run/*' — /run-юниты не копируются в цель (V-05, 3 копии)"
# S11: V-01 — helper xros_check_dm_alias есть во всех 3 копиях и
# вызывается в графических ветках (KDE и другие DE) ДО цикла отключения.
s11_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q '^xros_check_dm_alias() {' "$f" || s11_fail=1
  grep -q 'неизвестному менеджеру входа' "$f" || s11_fail=1
  [[ "$(grep -c 'xros_check_dm_alias$' "$f")" == "2" ]] || s11_fail=1
done
[[ "$s11_fail" == "0" ]] \
  && ok "S11: helper xros_check_dm_alias есть и вызывается в 2 графических ветках (V-01, 3 копии)" \
  || bad "S11: helper xros_check_dm_alias есть и вызывается в 2 графических ветках (V-01, 3 копии)"
# S12: V-07 — финальная проверка использует xros_verify_dm (точное
# имя, существование, тип, маска, [Unit]); старый подстановочный
# match '*"$DE_DM"*' отсутствует.
s12_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q '^xros_verify_dm() {' "$f" || s12_fail=1
  grep -q 'xros_verify_dm$' "$f" || s12_fail=1
  grep -q '"\$name" == "\$DE_DM.service"' "$f" || s12_fail=1
  if grep -q '\*"\$DE_DM"\*' "$f"; then s12_fail=1; fi
done
[[ "$s12_fail" == "0" ]] \
  && ok "S12: финальная проверка — xros_verify_dm (точное имя, без подстановочного match) (V-07, 3 копии)" \
  || bad "S12: финальная проверка — xros_verify_dm (точное имя, без подстановочного match) (V-07, 3 копии)"
# S13: R-22 — xros_disable_dm разрешает путь через xros_resolve_in_target
# (chroot-семантика); прямые [ -e ] и readlink на абсолютные симлинки
# относительно хоста убраны; висячий симлинк по-прежнему пропуск.
s13_fail=0
for f in "$ENGINE" "$ENGINE_PROFILE" "$ENGINE_PKG"; do
  grep -q '^xros_resolve_in_target() {' "$f" || s13_fail=1
  grep -q 'xros_resolve_in_target "${f#$TARGET}"' "$f" || s13_fail=1
  grep -q 'R-22' "$f" || s13_fail=1
done
[[ "$s13_fail" == "0" ]] \
  && ok "S13: xros_disable_dm разрешает путь через xros_resolve_in_target (R-22, 3 копии)" \
  || bad "S13: xros_disable_dm разрешает путь через xros_resolve_in_target (R-22, 3 копии)"

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
  skip "рантайм R1–R12" "gcc недоступен — нет fakeblk.so"
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
  skip "рантайм R1–R12" "unshare -rm недоступен"
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
# файлы, которые проверяет финальная проверка движка, плюс unit-файлы
# DM из окружения (только СОЗДАНИЕ начального состояния; заглушка
# arch-chroot эти переменные не читает — см. V-03):
#   DM_UNITS / DM_UNITS_ETC / DM_UNITS_LOCAL — юниты в /usr/lib,
#   /etc, /usr/local/lib соответственно;
#   DM_MASKED — симлинк на /dev/null (замаскирован);
#   DM_DANGLING — висячий симлинк (цель не существует);
#   DM_CORRUPT — мусор без [Unit] (повреждённый файл);
#   DM_DIR — каталог вместо файла юнита;
#   DM_ENABLED — предвключённые (wants + alias);
#   DM_ALIAS_FILE=1 — alias как обычный файл;
#   DM_ALIAS_DIR=1 — alias как каталог;
#   DM_ALIAS_DANGLING=1 — alias как висячий симлинк;
#   DM_UNITS_RUN — юниты только в /run/systemd/system (V-05);
#   DM_RACE — гонка TOCTOU после enable (V-07): delete-unit /
#   alias-wrong / alias-mask / alias-dir (применяется заглушкой
#   arch-chroot в обработчике set-default, ДО финальной проверки).
cat > "$T/realbin/rsync" <<EOF
#!/usr/bin/env bash
echo "rsync \$*" >> "$T/calls.log"
tgt="\${@: -1}"
mkdir -p "\$tgt/boot/grub" "\$tgt/etc" "\$tgt/usr/share/xros/grub-theme" "\$tgt/usr/lib/systemd/system" "\$tgt/usr/local/lib/systemd/system" "\$tgt/etc/systemd/system" "\$tgt/etc/systemd/system/graphical.target.wants" "\$tgt/run/systemd/system"
printf 'fake-vmlinuz' > "\$tgt/boot/vmlinuz-linux"
printf 'fake-initramfs' > "\$tgt/boot/initramfs-linux.img"
printf 'fake-grub.cfg' > "\$tgt/boot/grub/grub.cfg"
printf 'UUID=fake / ext4 defaults 0 1\n' > "\$tgt/etc/fstab"
printf 'root:x:0:0:root:/root:/bin/bash\ntestuser:x:1000:1000:Test User:/home/testuser:/bin/bash\n' > "\$tgt/etc/passwd"
printf 'xros-test\n' > "\$tgt/etc/hostname"
printf 'fake-theme' > "\$tgt/usr/share/xros/grub-theme/theme.txt"
# P4-AUD-04 FIX-B: базовые цели systemd в фейковой живой системе
# (как в настоящей Arch): multi-user.target и graphical.target.
# Финальная проверка default target (DE=none) читает их из ФС.
printf '[Unit]\nDescription=Multi-User System\nRequires=basic.target\nAfter=basic.target\nAllowIsolate=yes\n' > "\$tgt/usr/lib/systemd/system/multi-user.target"
printf '[Unit]\nDescription=Graphical Interface\nRequires=multi-user.target\nAfter=multi-user.target\nAllowIsolate=yes\n' > "\$tgt/usr/lib/systemd/system/graphical.target"
# Путь к файлу юнита ВНУТРИ цели (без префикса каталога цели):
# симлинки alias/wants указывают на путь, видимый изнутри системы
# (как у реального systemctl); сравнение с ним в заглушке arch-chroot —
# по той же форме, без префикса и без двойных слешей.
# Порядок — приоритет поиска systemd: /etc, /run, /usr/local/lib, /usr/lib.
# /run включён сюда, потому что alias предвключённого юнита указывает
# туда, где systemctl его нашёл (нужно для R26); helper движка /run
# НЕ проверяет (V-05) — это разные места (создание alias vs disable).
unit_path() { # \$1=имя DM
  local u="\$1" d
  for d in "/etc/systemd/system" "/run/systemd/system" "/usr/local/lib/systemd/system" "/usr/lib/systemd/system"; do
    if [[ -L "\$tgt\$d/\$u.service" || -e "\$tgt\$d/\$u.service" ]]; then echo "\$d/\$u.service"; return 0; fi
  done
  echo "/usr/lib/systemd/system/\$u.service"; return 1
}
mk_dm_unit() { # \$1=каталог \$2=имя DM
  local dir="\$1" u="\$2"
  if [[ " \$DM_MASKED " == *" \$u "* ]]; then
    ln -sf /dev/null "\$dir/\$u.service"
  elif [[ " \$DM_DANGLING " == *" \$u "* ]]; then
    ln -sf /nonexistent-unit-file "\$dir/\$u.service"
  elif [[ " \$DM_CORRUPT " == *" \$u "* ]]; then
    printf 'this is not a unit file\n[Broken\n' > "\$dir/\$u.service"
  elif [[ " \$DM_DIR " == *" \$u "* ]]; then
    mkdir "\$dir/\$u.service"
  else
    printf '[Unit]\nDescription=Fake %s\n\n[Service]\nExecStart=/usr/bin/%s\n\n[Install]\nWantedBy=graphical.target\nAlias=display-manager.service\n' "\$u" "\$u" > "\$dir/\$u.service"
  fi
}
for u in \$DM_UNITS; do mk_dm_unit "\$tgt/usr/lib/systemd/system" "\$u"; done
for u in \$DM_UNITS_ETC; do mk_dm_unit "\$tgt/etc/systemd/system" "\$u"; done
for u in \$DM_UNITS_LOCAL; do mk_dm_unit "\$tgt/usr/local/lib/systemd/system" "\$u"; done
for u in \$DM_UNITS_RUN; do mk_dm_unit "\$tgt/run/systemd/system" "\$u"; done
for u in \$DM_ABSOLUTE; do
  # P4-AUD-04 FIX-A: юнит как АБСОЛЮТНЫЙ симлинк на реальный файл
  # внутри цели (в /usr/lib). Старый helper пропускал его ([ -e ]
  # разрешается по хосту); новый обязан обнаружить и отключить.
  printf '[Unit]\nDescription=Fake %s\n\n[Service]\nExecStart=/usr/bin/%s\n\n[Install]\nWantedBy=graphical.target\nAlias=display-manager.service\n' "\$u" "\$u" > "\$tgt/usr/lib/systemd/system/\$u-real.service"
  ln -sf "/usr/lib/systemd/system/\$u-real.service" "\$tgt/usr/lib/systemd/system/\$u.service"
done
for u in \$DM_ENABLED; do
  ln -sf "\$(unit_path "\$u")" "\$tgt/etc/systemd/system/graphical.target.wants/\$u.service"
done
if [[ "\$DM_ALIAS_FILE" == "1" ]]; then
  printf 'junk-not-a-symlink' > "\$tgt/etc/systemd/system/display-manager.service"
elif [[ "\$DM_ALIAS_DIR" == "1" ]]; then
  mkdir "\$tgt/etc/systemd/system/display-manager.service"
elif [[ "\$DM_ALIAS_DANGLING" == "1" ]]; then
  ln -sf /nonexistent-unit "\$tgt/etc/systemd/system/display-manager.service"
elif [[ -n "\$DM_ENABLED" ]]; then
  first="\${DM_ENABLED%% *}"
  ln -sf "\$(unit_path "\$first")" "\$tgt/etc/systemd/system/display-manager.service"
fi
exit 0
EOF
chmod +x "$T/realbin/rsync"
# arch-chroot: симулирует ЭФФЕКТЫ команд в цели (симлинки DM,
# default target, grub-загрузчик), остальные команды — exit 0.
# Флаги отказа — из окружения: FAIL_SDDM_ENABLE, FAIL_SET_DEFAULT,
# FAIL_DM_ENABLE (как в test-sddm-failclosed.sh) плюс новые:
# FAIL_DISABLE — список юнитов, чей disable падает (через пробел);
# SYSTEMD_UNAVAILABLE=1 — все вызовы systemctl падают.
# Честность заглушки (модель реального systemctl, V-02/V-03):
#   unit_state() выводит состояние юнита из ФАЙЛОВОЙ СИСТЕМЫ цели
#   (тип, цель симлинка, содержимое) — независимо от движка и от
#   переменных DM_* (их эта заглушка не читает).
#   Сверено с настоящим systemctl 255 (--root, аудит E1–E19 + A1/B1/B2):
#   absent/dangling/corrupt/directory — disable/enable rc 1;
#   masked — disable rc 0, enable rc 1; повторный enable — rc 0;
#   alias на другой юнит или обычный файл/каталог — enable rc 1,
#   alias НЕ перезаписывается, но wants-симлинк СОЗДАЁТСЯ (частичное
#   изменение, как у реального systemctl — не скрываем, логируем
#   stub-wants-partial); висячий alias — реальный systemctl удаляет
#   его и создаёт заново (rc 0). Общая ошибка FAIL_* — без частичных
#   изменений.
cat > "$T/realbin/arch-chroot" <<'STUB_EOF'
#!/usr/bin/env bash
echo "arch-chroot $*" >> "${XROS_TEST_T}/calls.log"
tgt="$1"; shift
cmd="$*"
# Независимая модель состояния юнита (V-03): состояние выводится из
# файловой системы цели, а не из переменных окружения и не копированием
# предиката движка ([ -e ]). Возврат: absent | valid | masked |
# dangling | directory | corrupt. Порядок каталогов — приоритет
# поиска systemd: /etc, /usr/local/lib, /usr/lib.
unit_state() { # $1=имя DM (без .service)
  local u="$1" f
  for f in "$tgt/etc/systemd/system/$u.service" \
           "$tgt/usr/local/lib/systemd/system/$u.service" \
           "$tgt/usr/lib/systemd/system/$u.service"; do
    if [[ -L "$f" ]]; then
      if [[ "$(readlink "$f")" == "/dev/null" ]]; then echo "masked"; return 0; fi
      # P4-AUD-04 FIX-A: абсолютный симлинк разрешается внутри цели,
      # а не по хосту (та же ошибка, что была в движке до FIX-A).
      # Относительный симлинк [ -e ] уже видит корректно (внутри цели).
      local _tgt _res
      _tgt="$(readlink "$f")"
      case "$_tgt" in
        /*) _res="$tgt$_tgt" ;;
        *)  _res="$f" ;;
      esac
      if [[ ! -e "$_res" ]]; then echo "dangling"; return 0; fi
      if [[ -d "$_res" ]]; then echo "directory"; return 0; fi
      if grep -q '^\[Unit\]' "$_res" 2>/dev/null; then echo "valid"; else echo "corrupt"; fi
      return 0
    fi
    if [[ -d "$f" ]]; then echo "directory"; return 0; fi
    if [[ -e "$f" ]]; then
      if grep -q '^\[Unit\]' "$f" 2>/dev/null; then echo "valid"; else echo "corrupt"; fi
      return 0
    fi
  done
  echo "absent"; return 0
}
# Путь к файлу юнита ВНУТРИ цели (без $tgt) — та же форма, что и
# в заглушке rsync (unit_path): симлинки и сравнение — по
# внутрицелевому пути, как у реального systemctl.
unit_file_path() { # $1=имя DM: путь к файлу юнита (первый найденный)
  local u="$1" f
  for f in "/etc/systemd/system/$u.service" \
           "/usr/local/lib/systemd/system/$u.service" \
           "/usr/lib/systemd/system/$u.service"; do
    if [[ -L "$tgt$f" || -e "$tgt$f" ]]; then echo "$f"; return 0; fi
  done
  echo ""; return 1
}
if [[ "$cmd" =~ systemctl\ enable\ ([a-z0-9-]+)\.service ]]; then
  dm="${BASH_REMATCH[1]}"
  if [[ "${SYSTEMD_UNAVAILABLE:-0}" == "1" ]]; then
    echo "stub-systemctl: FAILED (systemd unavailable)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  st="$(unit_state "$dm")"
  case "$st" in
    absent|dangling)
      echo "stub-dm-enable: FAILED ($dm not found)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
    directory)
      echo "stub-dm-enable: FAILED ($dm is a directory)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
    corrupt)
      echo "stub-dm-enable: FAILED ($dm corrupt unit file)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
    masked)
      echo "stub-dm-enable: FAILED ($dm masked)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
  esac
  if [[ "$dm" == "sddm" && "${FAIL_SDDM_ENABLE:-0}" == "1" ]]; then
    echo "stub-sddm-enable: FAILED" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  if [[ "$dm" != "sddm" && "${FAIL_DM_ENABLE:-0}" == "1" ]]; then
    echo "stub-dm-enable: FAILED ($dm)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  upath="$(unit_file_path "$dm")"
  mkdir -p "$tgt/etc/systemd/system" "$tgt/etc/systemd/system/graphical.target.wants"
  alias_path="$tgt/etc/systemd/system/display-manager.service"
  if [[ -L "$alias_path" ]]; then
    cur="$(readlink "$alias_path")"
    # Существует ли цель alias ВНУТРИ цели? Alias указывает на
    # внутрицелевой путь (например, /usr/lib/...), поэтому проверять
    # его надо через $tgt, а не через корень хоста: прямой
    # [ -e "$alias_path" ] разрешил бы симлинк относительно хоста
    # и счёл бы живой alias висячим.
    if [[ "$cur" == /* ]]; then alias_target_exists="$tgt$cur"; else alias_target_exists="$tgt/etc/systemd/system/$cur"; fi
    if [[ ! -e "$alias_target_exists" ]]; then
      # Висячий alias (A1): реальный systemctl удаляет его и создаёт
      # заново — rc 0.
      rm -f "$alias_path"
      echo "stub-alias-dangling: removed dangling alias, recreating for $dm" >> "${XROS_TEST_T}/calls.log"
      ln -sf "$upath" "$alias_path"
      ln -sf "$upath" "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
      echo "stub-dm-link: $dm" >> "${XROS_TEST_T}/calls.log"
      exit 0
    fi
    if [[ "$cur" == "$upath" ]]; then
      # Повторный enable того же DM (E15): rc 0, wants обеспечивается.
      ln -sf "$upath" "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
      echo "stub-dm-link: $dm" >> "${XROS_TEST_T}/calls.log"
      exit 0
    fi
    # Alias указывает на другой юнит (E16/E19): отказ, alias НЕ
    # перезаписывается, но wants-симлинк СОЗДАЁТСЯ (частично).
    ln -sf "$upath" "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
    echo "stub-wants-partial: $dm (wants created, alias untouched)" >> "${XROS_TEST_T}/calls.log"
    echo "stub-alias-conflict: $alias_path -> $cur (enable $dm refused)" >> "${XROS_TEST_T}/calls.log"
    exit 1
  elif [[ -e "$alias_path" ]]; then
    # Alias — обычный файл или каталог (E14/B1/B2): отказ, wants создаётся.
    ln -sf "$upath" "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
    echo "stub-wants-partial: $dm (wants created, alias untouched)" >> "${XROS_TEST_T}/calls.log"
    echo "stub-alias-regular: $alias_path exists, not a symlink (enable $dm refused)" >> "${XROS_TEST_T}/calls.log"
    exit 1
  else
    # Alias отсутствует (E3): создаём alias + wants.
    ln -sf "$upath" "$alias_path"
    ln -sf "$upath" "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
    echo "stub-dm-link: $dm" >> "${XROS_TEST_T}/calls.log"
    exit 0
  fi
fi
if [[ "$cmd" =~ systemctl\ disable\ ([a-z0-9-]+)\.service ]]; then
  dm="${BASH_REMATCH[1]}"
  if [[ "${SYSTEMD_UNAVAILABLE:-0}" == "1" ]]; then
    echo "stub-systemctl: FAILED (systemd unavailable)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  st="$(unit_state "$dm")"
  case "$st" in
    absent|dangling)
      echo "stub-dm-disable: FAILED ($dm $st — engine called disable for absent unit)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
    directory)
      echo "stub-dm-disable: FAILED ($dm is a directory)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
    corrupt)
      echo "stub-dm-disable: FAILED ($dm corrupt unit file)" >> "${XROS_TEST_T}/calls.log"; exit 1 ;;
  esac
  if [[ " ${FAIL_DISABLE:-} " == *" $dm "* ]]; then
    echo "stub-dm-disable: FAILED ($dm)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  upath="$(unit_file_path "$dm")"
  link="$tgt/etc/systemd/system/display-manager.service"
  if [[ "$(readlink "$link" 2>/dev/null)" == "$upath" ]]; then rm -f "$link"; fi
  rm -f "$tgt/etc/systemd/system/graphical.target.wants/$dm.service"
  echo "stub-dm-disable: $dm" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" == *"systemctl set-default graphical.target"* ]]; then
  if [[ "${SYSTEMD_UNAVAILABLE:-0}" == "1" ]]; then
    echo "stub-systemctl: FAILED (systemd unavailable)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  if [[ "${FAIL_SET_DEFAULT:-0}" == "1" ]]; then
    echo "stub-set-default: FAILED" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  # DM_RACE (V-07): симуляция гонки TOCTOU между enable и финальной
  # проверкой движка. Мутация применяется ПОСЛЕ успешного enable и
  # set-default, но ДО финальной проверки — финальная проверка
  # обязана её поймать. Только для тестов V-07; в штатном потоке
  # DM_RACE пуст и ничего не меняется.
  if [[ -n "${DM_RACE:-}" ]]; then
    _race_link="$tgt/etc/systemd/system/display-manager.service"
    _race_tgt="$(readlink "$_race_link" 2>/dev/null || true)"
    if [[ -n "$_race_tgt" ]]; then
      case "$DM_RACE" in
        delete-unit)
          rm -f "$tgt$_race_tgt"
          echo "stub-race: deleted unit $_race_tgt" >> "${XROS_TEST_T}/calls.log"
          ;;
        alias-wrong)
          _race_name="${_race_tgt##*/}"; _race_name="${_race_name%.service}-foo.service"
          printf '[Unit]\nDescription=Fake wrong DM\n\n[Service]\nExecStart=/usr/bin/wrong\n' > "$tgt/usr/lib/systemd/system/$_race_name"
          ln -sf "/usr/lib/systemd/system/$_race_name" "$_race_link"
          echo "stub-race: alias repointed to $_race_name" >> "${XROS_TEST_T}/calls.log"
          ;;
        alias-mask)
          rm -f "$tgt$_race_tgt"; ln -sf /dev/null "$tgt$_race_tgt"
          echo "stub-race: unit $_race_tgt masked" >> "${XROS_TEST_T}/calls.log"
          ;;
        alias-dir)
          rm -f "$tgt$_race_tgt"; mkdir -p "$tgt$_race_tgt"
          echo "stub-race: unit $_race_tgt replaced by directory" >> "${XROS_TEST_T}/calls.log"
          ;;
      esac
    fi
  fi
  echo "stub-default-target: graphical.target" >> "${XROS_TEST_T}/calls.log"
  exit 0
fi
if [[ "$cmd" == *"systemctl set-default multi-user.target"* ]]; then
  if [[ "${SYSTEMD_UNAVAILABLE:-0}" == "1" ]]; then
    echo "stub-systemctl: FAILED (systemd unavailable)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  if [[ "${FAIL_SET_DEFAULT:-0}" == "1" ]]; then
    echo "stub-set-default: FAILED" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  # P4-AUD-04 FIX-B: как настоящий systemctl — реально создаём симлинк
  # default.target (финальная проверка движка читает его из ФС цели).
  if [[ ! -e "$tgt/usr/lib/systemd/system/multi-user.target" ]]; then
    echo "stub-set-default: FAILED (multi-user.target not found)" >> "${XROS_TEST_T}/calls.log"; exit 1
  fi
  ln -sf /usr/lib/systemd/system/multi-user.target "$tgt/etc/systemd/system/default.target"
  echo "stub-default-target: multi-user.target" >> "${XROS_TEST_T}/calls.log"
  # DEFAULT_RACE (P4-AUD-04 FIX-B): гонка TOCTOU между set-default и
  # финальной проверкой движка. Мутация применяется ПОСЛЕ создания
  # симлинка, но ДО финальной проверки — финальная проверка обязана
  # её поймать. Только для тестов FIX-B; в штатном потоке пусто.
  if [[ -n "${DEFAULT_RACE:-}" ]]; then
    _drace_link="$tgt/etc/systemd/system/default.target"
    case "$DEFAULT_RACE" in
      default-wrong)
        ln -sf /usr/lib/systemd/system/graphical.target "$_drace_link"
        echo "stub-default-race: default.target repointed to graphical.target" >> "${XROS_TEST_T}/calls.log"
        ;;
      default-delete)
        rm -f "$_drace_link"
        echo "stub-default-race: default.target deleted" >> "${XROS_TEST_T}/calls.log"
        ;;
      default-mask)
        rm -f "$tgt/usr/lib/systemd/system/multi-user.target"; ln -sf /dev/null "$tgt/usr/lib/systemd/system/multi-user.target"
        echo "stub-default-race: multi-user.target masked" >> "${XROS_TEST_T}/calls.log"
        ;;
      default-dangling)
        ln -sf /usr/lib/systemd/system/nonexistent.target "$_drace_link"
        echo "stub-default-race: default.target repointed to nonexistent target" >> "${XROS_TEST_T}/calls.log"
        ;;
    esac
  fi
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
# $1=name $2=DE $3=DM_UNITS $4=DM_MASKED $5=DM_ENABLED $6=FAIL_DISABLE
# $7=FAIL_SDDM_ENABLE $8=FAIL_SET_DEFAULT $9=FAIL_DM_ENABLE ${10}=SYSTEMD_UNAVAILABLE
# ${11}=DM_UNITS_ETC ${12}=DM_UNITS_LOCAL ${13}=DM_CORRUPT ${14}=DM_DIR
# ${15}=DM_DANGLING ${16}=DM_ALIAS_FILE(1) ${17}=DM_ALIAS_DANGLING(1)
# ${18}=DM_UNITS_RUN ${19}=DM_ALIAS_DIR(1) ${20}=DM_RACE
# ${21}=DM_ABSOLUTE (P4-AUD-04 FIX-A: юнит как абсолютный симлинк)
# ${22}=DEFAULT_RACE (P4-AUD-04 FIX-B: гонка default.target)
# (позиции 11–22 необязательны: ${11:-} по умолчанию пусто)
run_scenario() {
  local name="$1" de="$2" dm_units="$3" dm_masked="$4" dm_enabled="$5" fail_disable="$6"
  local fail_sddm="$7" fail_setdefault="$8" fail_dm="$9" sys_unavail="${10}"
  local units_etc="${11:-}" units_local="${12:-}" dm_corrupt="${13:-}" dm_dir="${14:-}" dm_dangling="${15:-}" alias_file="${16:-}" alias_dangling="${17:-}"
  local units_run="${18:-}" alias_dir="${19:-}" dm_race="${20:-}"
  local dm_absolute="${21:-}" default_race="${22:-}"
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
export DM_UNITS="$dm_units" DM_MASKED="$dm_masked" DM_ENABLED="$dm_enabled"
export DM_UNITS_ETC="$units_etc" DM_UNITS_LOCAL="$units_local" DM_CORRUPT="$dm_corrupt" DM_DIR="$dm_dir" DM_DANGLING="$dm_dangling" DM_ALIAS_FILE="$alias_file" DM_ALIAS_DANGLING="$alias_dangling" DM_UNITS_RUN="$units_run" DM_ALIAS_DIR="$alias_dir" DM_RACE="$dm_race" DM_ABSOLUTE="$dm_absolute" DEFAULT_RACE="$default_race"
export FAIL_DISABLE="$fail_disable" FAIL_SDDM_ENABLE="$fail_sddm" FAIL_SET_DEFAULT="$fail_setdefault" FAIL_DM_ENABLE="$fail_dm" SYSTEMD_UNAVAILABLE="$sys_unavail"
ENG_CMD=(setsid --wait env LD_PRELOAD="\$T/fakeblk.so" XROS_FAKEBLK="$FAKEBLK_LIST" XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf" PATH="\$T/realbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" XROS_TEST_T="\$T" XROS_TEST_FAKEDISK="\$T/fakedisk" DM_UNITS="$dm_units" DM_MASKED="$dm_masked" DM_ENABLED="$dm_enabled" DM_UNITS_ETC="$units_etc" DM_UNITS_LOCAL="$units_local" DM_CORRUPT="$dm_corrupt" DM_DIR="$dm_dir" DM_DANGLING="$dm_dangling" DM_ALIAS_FILE="$alias_file" DM_ALIAS_DANGLING="$alias_dangling" DM_UNITS_RUN="$units_run" DM_ALIAS_DIR="$alias_dir" DM_RACE="$dm_race" DM_ABSOLUTE="$dm_absolute" DEFAULT_RACE="$default_race" FAIL_DISABLE="$fail_disable" FAIL_SDDM_ENABLE="$fail_sddm" FAIL_SET_DEFAULT="$fail_setdefault" FAIL_DM_ENABLE="$fail_dm" SYSTEMD_UNAVAILABLE="$sys_unavail" bash "\$ENGINE")
"\${ENG_CMD[@]}" > "$d/engine.out" 2>&1
RC=\$?
{
  echo "rc=\$RC"
  grep -q "INSTALL_FAILED" "$d/engine.out" && echo "stdout_install_failed=yes" || echo "stdout_install_failed=no"
  grep -q "INSTALL_DONE" "$d/engine.out" && echo "stdout_install_done=yes" || echo "stdout_install_done=no"
  grep -q "Очистка завершена" /tmp/xros-install.log && echo "log_cleanup=yes" || echo "log_cleanup=no"
  grep -q "не удалось включить SDDM" /tmp/xros-install.log && echo "log_sddm_error=yes" || echo "log_sddm_error=no"
  grep -q "не удалось задать graphical.target" /tmp/xros-install.log && echo "log_setdefault_error=yes" || echo "log_setdefault_error=no"
  grep -q "не удалось установить multi-user.target" /tmp/xros-install.log && echo "log_setdefault_multiuser_error=yes" || echo "log_setdefault_multiuser_error=no"
  grep -q "default target" /tmp/xros-install.log && echo "log_default_target_error=yes" || echo "log_default_target_error=no"
  grep -q "не удалось включить менеджер входа" /tmp/xros-install.log && echo "log_dm_error=yes" || echo "log_dm_error=no"
  grep -q "не удалось отключить" /tmp/xros-install.log && echo "log_disable_error=yes" || echo "log_disable_error=no"
  grep -q "Пропуск: sddm.service отсутствует" /tmp/xros-install.log && echo "log_skip_sddm=yes" || echo "log_skip_sddm=no"
  grep -q "Пропуск: gdm.service отсутствует" /tmp/xros-install.log && echo "log_skip_gdm=yes" || echo "log_skip_gdm=no"
  grep -q "Пропуск: lightdm.service отсутствует" /tmp/xros-install.log && echo "log_skip_lightdm=yes" || echo "log_skip_lightdm=no"
  grep -q "ядро не найдено" /tmp/xros-install.log && echo "log_kernel_missing=yes" || echo "log_kernel_missing=no"
  grep -q "менеджер входа .* не включён" /tmp/xros-install.log && echo "log_dm_not_enabled=yes" || echo "log_dm_not_enabled=no"
  grep -q "/mnt/xros-install" /proc/mounts && echo "target_mounted=yes" || echo "target_mounted=no"
  if [[ -f /tmp/xros-de-result ]]; then echo "de_result=\$(cat /tmp/xros-de-result)"; else echo "de_result=MISSING"; fi
  grep -q "stub-dm-link: sddm" "\$T/calls.log" && echo "dm_link=sddm" || echo "dm_link=not-sddm"
  grep -q "stub-dm-link: gdm" "\$T/calls.log" && echo "dm_link_gdm=yes" || echo "dm_link_gdm=no"
  grep -q "stub-dm-link: lightdm" "\$T/calls.log" && echo "dm_link_lightdm=yes" || echo "dm_link_lightdm=no"
  grep -q "stub-default-target: graphical.target" "\$T/calls.log" && echo "default_target=graphical" || echo "default_target=not-graphical"
  grep -q "stub-default-target: multi-user.target" "\$T/calls.log" && echo "default_target_multiuser=yes" || echo "default_target_multiuser=no"
  grep -q "stub-dm-disable: sddm" "\$T/calls.log" && echo "disable_sddm=yes" || echo "disable_sddm=no"
  grep -q "stub-dm-disable: gdm" "\$T/calls.log" && echo "disable_gdm=yes" || echo "disable_gdm=no"
  grep -q "stub-dm-disable: lightdm" "\$T/calls.log" && echo "disable_lightdm=yes" || echo "disable_lightdm=no"
  grep -q "stub-dm-disable: FAILED" "\$T/calls.log" && echo "stub_disable_failed=yes" || echo "stub_disable_failed=no"
  grep -q "stub-systemctl: FAILED (systemd unavailable)" "\$T/calls.log" && echo "stub_systemd_unavail=yes" || echo "stub_systemd_unavail=no"
  grep -q "stub-sddm-enable: FAILED" "\$T/calls.log" && echo "stub_sddm_failed=yes" || echo "stub_sddm_failed=no"
  grep -q "stub-set-default: FAILED" "\$T/calls.log" && echo "stub_setdefault_failed=yes" || echo "stub_setdefault_failed=no"
  grep -q "stub-dm-enable: FAILED" "\$T/calls.log" && echo "stub_dm_failed=yes" || echo "stub_dm_failed=no"
  grep -q "stub-alias-conflict" "\$T/calls.log" && echo "alias_conflict=yes" || echo "alias_conflict=no"
  grep -q "stub-alias-conflict:.*xdm.service" "\$T/calls.log" && echo "alias_conflict_xdm=yes" || echo "alias_conflict_xdm=no"
  grep -q "stub-alias-regular" "\$T/calls.log" && echo "alias_regular=yes" || echo "alias_regular=no"
  grep -q "stub-alias-dangling" "\$T/calls.log" && echo "alias_dangling=yes" || echo "alias_dangling=no"
  grep -q "stub-wants-partial:" "\$T/calls.log" && echo "wants_partial=yes" || echo "wants_partial=no"
  grep -q "corrupt unit file" "\$T/calls.log" && echo "stub_disable_corrupt=yes" || echo "stub_disable_corrupt=no"
  grep -q "is a directory" "\$T/calls.log" && echo "stub_disable_dir=yes" || echo "stub_disable_dir=no"
  grep -q "неизвестному менеджеру входа" /tmp/xros-install.log && echo "log_v01_unknown=yes" || echo "log_v01_unknown=no"
  grep -q "а не симлинк" /tmp/xros-install.log && echo "log_v01_notsymlink=yes" || echo "log_v01_notsymlink=no"
  grep -q "stub-race:" "\$T/calls.log" && echo "stub_race=yes" || echo "stub_race=no"
  grep -q "stub-default-race:" "\$T/calls.log" && echo "stub_default_race=yes" || echo "stub_default_race=no"
  grep -q "systemctl enable" "\$T/calls.log" && echo "enable_attempted=yes" || echo "enable_attempted=no"
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

# ================= R1. KDE + SDDM, успех (конкуренты отсутствуют) ==============================
run_scenario "r1-kde-ok" "kde" "sddm" "" "" "" 0 0 0 0
R="$T/r1-kde-ok/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R1a: kde успех — движок вышел с кодом 0" \
  || bad "R1a: kde успех — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R1b: kde успех — в stdout INSTALL_DONE" \
  || bad "R1b: kde успех — в stdout INSTALL_DONE"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R1c: kde успех — display-manager.service указывает на sddm" \
  || bad "R1c: kde успех — display-manager.service указывает на sddm"
[[ "$(result_val "$R" default_target)" == "graphical" ]] \
  && ok "R1d: kde успех — default target = graphical.target" \
  || bad "R1d: kde успех — default target = graphical.target"
[[ "$(result_val "$R" disable_gdm)" == "no" && "$(result_val "$R" disable_lightdm)" == "no" ]] \
  && ok "R1e: kde успех — disable НЕ вызывался для отсутствующих gdm/lightdm" \
  || bad "R1e: kde успех — disable НЕ вызывался для отсутствующих gdm/lightdm"
[[ "$(result_val "$R" log_skip_gdm)" == "yes" && "$(result_val "$R" log_skip_lightdm)" == "yes" ]] \
  && ok "R1f: kde успех — в журнале 'Пропуск: gdm/lightdm отсутствует'" \
  || bad "R1f: kde успех — в журнале 'Пропуск: gdm/lightdm отсутствует'"
[[ "$(result_val "$R" disable_sddm)" == "no" ]] \
  && ok "R1g: kde успех — выбранный sddm НЕ отключался" \
  || bad "R1g: kde успех — выбранный sddm НЕ отключался"

# ================= R2. KDE + конкурирующий GDM ==============================
run_scenario "r2-kde-gdm" "kde" "sddm gdm" "" "gdm" "" 0 0 0 0
R="$T/r2-kde-gdm/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R2a: kde+gdm — движок вышел с кодом 0" \
  || bad "R2a: kde+gdm — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R2b: kde+gdm — в stdout INSTALL_DONE" \
  || bad "R2b: kde+gdm — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_gdm)" == "yes" ]] \
  && ok "R2c: kde+gdm — disable вызван для конкурирующего gdm" \
  || bad "R2c: kde+gdm — disable вызван для конкурирующего gdm"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R2d: kde+gdm — display-manager.service указывает на sddm (gdm отключён)" \
  || bad "R2d: kde+gdm — display-manager.service указывает на sddm (gdm отключён)"
[[ "$(result_val "$R" disable_sddm)" == "no" ]] \
  && ok "R2e: kde+gdm — выбранный sddm НЕ отключался" \
  || bad "R2e: kde+gdm — выбранный sddm НЕ отключался"

# ================= R3. GNOME + GDM, успех ==============================
run_scenario "r3-gnome-ok" "gnome" "gdm" "" "" "" 0 0 0 0
R="$T/r3-gnome-ok/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R3a: gnome успех — движок вышел с кодом 0" \
  || bad "R3a: gnome успех — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R3b: gnome успех — в stdout INSTALL_DONE" \
  || bad "R3b: gnome успех — в stdout INSTALL_DONE"
[[ "$(result_val "$R" dm_link_gdm)" == "yes" ]] \
  && ok "R3c: gnome успех — display-manager.service указывает на gdm" \
  || bad "R3c: gnome успех — display-manager.service указывает на gdm"
[[ "$(result_val "$R" default_target)" == "graphical" ]] \
  && ok "R3d: gnome успех — default target = graphical.target" \
  || bad "R3d: gnome успех — default target = graphical.target"
[[ "$(result_val "$R" disable_sddm)" == "no" && "$(result_val "$R" disable_lightdm)" == "no" ]] \
  && ok "R3e: gnome успех — disable НЕ вызывался для отсутствующих sddm/lightdm" \
  || bad "R3e: gnome успех — disable НЕ вызывался для отсутствующих sddm/lightdm"

# ================= R4. GNOME + конкурирующий SDDM ==============================
run_scenario "r4-gnome-sddm" "gnome" "gdm sddm" "" "sddm" "" 0 0 0 0
R="$T/r4-gnome-sddm/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R4a: gnome+sddm — движок вышел с кодом 0" \
  || bad "R4a: gnome+sddm — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" disable_sddm)" == "yes" ]] \
  && ok "R4b: gnome+sddm — disable вызван для конкурирующего sddm" \
  || bad "R4b: gnome+sddm — disable вызван для конкурирующего sddm"
[[ "$(result_val "$R" dm_link_gdm)" == "yes" ]] \
  && ok "R4c: gnome+sddm — display-manager.service указывает на gdm (sddm отключён)" \
  || bad "R4c: gnome+sddm — display-manager.service указывает на gdm (sddm отключён)"
[[ "$(result_val "$R" disable_gdm)" == "no" ]] \
  && ok "R4d: gnome+sddm — выбранный gdm НЕ отключался" \
  || bad "R4d: gnome+sddm — выбранный gdm НЕ отключался"

# ================= R5. LightDM как конкурирующий (KDE) ==============================
run_scenario "r5-kde-lightdm" "kde" "sddm lightdm" "" "lightdm" "" 0 0 0 0
R="$T/r5-kde-lightdm/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R5a: kde+lightdm — движок вышел с кодом 0" \
  || bad "R5a: kde+lightdm — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" disable_lightdm)" == "yes" ]] \
  && ok "R5b: kde+lightdm — disable вызван для конкурирующего lightdm" \
  || bad "R5b: kde+lightdm — disable вызван для конкурирующего lightdm"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R5c: kde+lightdm — display-manager.service указывает на sddm" \
  || bad "R5c: kde+lightdm — display-manager.service указывает на sddm"

# ================= R6. Несуществующий сервис (XFCE, только lightdm) ==============================
run_scenario "r6-xfce-only" "xfce" "lightdm" "" "" "" 0 0 0 0
R="$T/r6-xfce-only/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R6a: xfce — движок вышел с кодом 0" \
  || bad "R6a: xfce — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" disable_sddm)" == "no" && "$(result_val "$R" disable_gdm)" == "no" ]] \
  && ok "R6b: xfce — disable НЕ вызывался ни для sddm, ни для gdm (их нет)" \
  || bad "R6b: xfce — disable НЕ вызывался ни для sddm, ни для gdm (их нет)"
[[ "$(result_val "$R" dm_link_lightdm)" == "yes" ]] \
  && ok "R6c: xfce — display-manager.service указывает на lightdm" \
  || bad "R6c: xfce — display-manager.service указывает на lightdm"
[[ "$(result_val "$R" log_skip_sddm)" == "yes" && "$(result_val "$R" log_skip_gdm)" == "yes" ]] \
  && ok "R6d: xfce — в журнале 'Пропуск' для отсутствующих sddm/gdm" \
  || bad "R6d: xfce — в журнале 'Пропуск' для отсутствующих sddm/gdm"

# ================= R7. Уже отключённый сервис (GNOME, sddm есть, не включён) ==============================
run_scenario "r7-gnome-disabled" "gnome" "gdm sddm" "" "" "" 0 0 0 0
R="$T/r7-gnome-disabled/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R7a: уже отключён — движок вышел с кодом 0" \
  || bad "R7a: уже отключён — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" disable_sddm)" == "yes" ]] \
  && ok "R7b: уже отключён — disable вызван для существующего sddm (rc=0)" \
  || bad "R7b: уже отключён — disable вызван для существующего sddm (rc=0)"
[[ "$(result_val "$R" dm_link_gdm)" == "yes" ]] \
  && ok "R7c: уже отключён — display-manager.service указывает на gdm" \
  || bad "R7c: уже отключён — display-manager.service указывает на gdm"

# ================= R8. Уже замаскированный сервис (GNOME, sddm masked) ==============================
run_scenario "r8-gnome-masked" "gnome" "gdm sddm" "sddm" "" "" 0 0 0 0
R="$T/r8-gnome-masked/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R8a: замаскирован — движок вышел с кодом 0" \
  || bad "R8a: замаскирован — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" disable_sddm)" == "yes" ]] \
  && ok "R8b: замаскирован — disable вызван для замаскированного sddm (rc=0)" \
  || bad "R8b: замаскирован — disable вызван для замаскированного sddm (rc=0)"
[[ "$(result_val "$R" dm_link_gdm)" == "yes" ]] \
  && ok "R8c: замаскирован — display-manager.service указывает на gdm" \
  || bad "R8c: замаскирован — display-manager.service указывает на gdm"

# ================= R9. Ошибка systemctl disable ==============================
run_scenario "r9-gnome-disable-fail" "gnome" "gdm sddm" "" "sddm" "sddm" 0 0 0 0
R="$T/r9-gnome-disable-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R9a: disable fail — движок вышел с кодом 1" \
  || bad "R9a: disable fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R9b: disable fail — в stdout INSTALL_FAILED" \
  || bad "R9b: disable fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R9c: disable fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R9c: disable fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_disable_error)" == "yes" ]] \
  && ok "R9d: disable fail — в журнале понятная ошибка 'не удалось отключить sddm.service'" \
  || bad "R9d: disable fail — в журнале понятная ошибка 'не удалось отключить sddm.service'"
[[ "$(result_val "$R" stub_disable_failed)" == "yes" ]] \
  && ok "R9e: disable fail — заглушка зафиксировала падение disable" \
  || bad "R9e: disable fail — заглушка зафиксировала падение disable"
[[ "$(result_val "$R" de_result)" == "MISSING" ]] \
  && ok "R9f: disable fail — /tmp/xros-de-result не записан (нет ложного итога)" \
  || bad "R9f: disable fail — /tmp/xros-de-result не записан (получено: $(result_val "$R" de_result))"
[[ "$(result_val "$R" log_cleanup)" == "yes" && "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "R9g: disable fail — cleanup выполнен, TARGET размонтирован" \
  || bad "R9g: disable fail — cleanup выполнен, TARGET размонтирован"
[[ "$(result_val "$R" dm_link_gdm)" == "no" ]] \
  && ok "R9h: disable fail — gdm НЕ включён (остановка до enable)" \
  || bad "R9h: disable fail — gdm НЕ включён (остановка до enable)"

# ================= R10. Ошибка systemctl enable (P4-AUD-01 сохранён) ==============================
run_scenario "r10-gnome-enable-fail" "gnome" "gdm sddm" "" "sddm" "" 0 0 1 0
R="$T/r10-gnome-enable-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R10a: enable fail — движок вышел с кодом 1" \
  || bad "R10a: enable fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R10b: enable fail — в stdout INSTALL_FAILED" \
  || bad "R10b: enable fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R10c: enable fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R10c: enable fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_dm_error)" == "yes" ]] \
  && ok "R10d: enable fail — в журнале понятная ошибка 'не удалось включить менеджер входа'" \
  || bad "R10d: enable fail — в журнале понятная ошибка 'не удалось включить менеджер входа'"
[[ "$(result_val "$R" disable_sddm)" == "yes" ]] \
  && ok "R10e: enable fail — disable конкурента прошёл ДО падения enable (порядок верный)" \
  || bad "R10e: enable fail — disable конкурента прошёл ДО падения enable (порядок верный)"

# ================= R11. Ошибка systemctl set-default (P4-AUD-01 сохранён) ==============================
run_scenario "r11-kde-setdefault-fail" "kde" "sddm" "" "" "" 0 1 0 0
R="$T/r11-kde-setdefault-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R11a: set-default fail — движок вышел с кодом 1" \
  || bad "R11a: set-default fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R11b: set-default fail — в stdout INSTALL_FAILED" \
  || bad "R11b: set-default fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R11c: set-default fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R11c: set-default fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_setdefault_error)" == "yes" ]] \
  && ok "R11d: set-default fail — в журнале понятная ошибка 'не удалось задать graphical.target'" \
  || bad "R11d: set-default fail — в журнале понятная ошибка 'не удалось задать graphical.target'"

# ================= R12. Недоступный systemd ==============================
run_scenario "r12-kde-systemd-down" "kde" "sddm gdm" "" "gdm" "" 0 0 0 1
R="$T/r12-kde-systemd-down/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R12a: systemd down — движок вышел с кодом 1" \
  || bad "R12a: systemd down — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R12b: systemd down — в stdout INSTALL_FAILED" \
  || bad "R12b: systemd down — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R12c: systemd down — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R12c: systemd down — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" stub_systemd_unavail)" == "yes" ]] \
  && ok "R12d: systemd down — заглушка зафиксировала недоступность systemd" \
  || bad "R12d: systemd down — заглушка зафиксировала недоступность systemd"
[[ "$(result_val "$R" log_disable_error)" == "yes" ]] \
  && ok "R12e: systemd down — в журнале понятная ошибка отключения DM" \
  || bad "R12e: systemd down — в журнале понятная ошибка отключения DM"
[[ "$(result_val "$R" log_cleanup)" == "yes" && "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "R12f: systemd down — cleanup выполнен, TARGET размонтирован" \
  || bad "R12f: systemd down — cleanup выполнен, TARGET размонтирован"

# ================= R13. DE=none, успех (все DM отключаются) ==============================
run_scenario "r13-none-ok" "none" "sddm gdm lightdm" "" "sddm" "" 0 0 0 0
R="$T/r13-none-ok/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R13a: none успех — движок вышел с кодом 0" \
  || bad "R13a: none успех — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R13b: none успех — в stdout INSTALL_DONE" \
  || bad "R13b: none успех — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_sddm)" == "yes" && "$(result_val "$R" disable_gdm)" == "yes" && "$(result_val "$R" disable_lightdm)" == "yes" ]] \
  && ok "R13c: none успех — disable вызван для всех трёх DM" \
  || bad "R13c: none успех — disable вызван для всех трёх DM"
[[ "$(result_val "$R" default_target_multiuser)" == "yes" ]] \
  && ok "R13d: none успех — default target = multi-user.target" \
  || bad "R13d: none успех — default target = multi-user.target"

# ================= R14. DE=none + ошибка disable ==============================
run_scenario "r14-none-disable-fail" "none" "sddm gdm lightdm" "" "" "sddm" 0 0 0 0
R="$T/r14-none-disable-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R14a: none disable fail — движок вышел с кодом 1" \
  || bad "R14a: none disable fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R14b: none disable fail — в stdout INSTALL_FAILED" \
  || bad "R14b: none disable fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R14c: none disable fail — нет INSTALL_DONE (успех не сообщён)" \
  || bad "R14c: none disable fail — нет INSTALL_DONE (успех не сообщён)"
[[ "$(result_val "$R" log_disable_error)" == "yes" ]] \
  && ok "R14d: none disable fail — в журнале понятная ошибка 'не удалось отключить sddm.service'" \
  || bad "R14d: none disable fail — в журнале понятная ошибка 'не удалось отключить sddm.service'"
[[ "$(result_val "$R" de_result)" == "MISSING" ]] \
  && ok "R14e: none disable fail — /tmp/xros-de-result не записан" \
  || bad "R14e: none disable fail — /tmp/xros-de-result не записан (получено: $(result_val "$R" de_result))"

# ================= R15. Замаскированный ВЫБРАННЫЙ DM (GNOME, gdm masked) ==============================
run_scenario "r15-gnome-masked-selected" "gnome" "gdm" "gdm" "" "" 0 0 0 0
R="$T/r15-gnome-masked-selected/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R15a: masked selected — движок вышел с кодом 1" \
  || bad "R15a: masked selected — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R15b: masked selected — в stdout INSTALL_FAILED" \
  || bad "R15b: masked selected — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" log_dm_error)" == "yes" ]] \
  && ok "R15c: masked selected — в журнале понятная ошибка включения менеджера входа" \
  || bad "R15c: masked selected — в журнале понятная ошибка включения менеджера входа"
[[ "$(result_val "$R" disable_gdm)" == "no" ]] \
  && ok "R15d: masked selected — выбранный gdm НЕ отключался (пропущен в цикле)" \
  || bad "R15d: masked selected — выбранный gdm НЕ отключался (пропущен в цикле)"

# ================= R16. Неизвестный DM xdm удерживает alias (V-01) ==============================
# xdm.service существует, display-manager.service -> xdm.service,
# выбранный DM — SDDM. V-01 pre-check отказывает ДО enable: понятная
# ошибка с именем неизвестного DM, alias НЕ тронут (enable не
# вызывался — частичного wants-симлинка нет, в отличие от старого
# поведения, когда отказ был на enable).
run_scenario "r16-xdm" "kde" "sddm xdm" "" "xdm" "" 0 0 0 0 "" "" "" "" "" "" ""
R="$T/r16-xdm/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R16a: xdm — движок вышел с кодом 1" \
  || bad "R16a: xdm — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R16b: xdm — в stdout INSTALL_FAILED" \
  || bad "R16b: xdm — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R16c: xdm — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R16c: xdm — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_v01_unknown)" == "yes" ]] \
  && ok "R16d: xdm — в журнале ошибка V-01 (неизвестный менеджер входа назван)" \
  || bad "R16d: xdm — в журнале ошибка V-01 (неизвестный менеджер входа назван)"
[[ "$(result_val "$R" enable_attempted)" == "no" ]] \
  && ok "R16e: xdm — pre-check отказал ДО enable (enable не вызывался)" \
  || bad "R16e: xdm — pre-check отказал ДО enable (enable не вызывался)"
[[ "$(result_val "$R" alias_conflict)" == "no" ]] \
  && ok "R16f: xdm — нет alias-конфликта в заглушке (enable не вызывался)" \
  || bad "R16f: xdm — нет alias-конфликта в заглушке (enable не вызывался)"
[[ "$(result_val "$R" wants_partial)" == "no" ]] \
  && ok "R16g: xdm — частичного состояния нет (pre-check не создаёт wants)" \
  || bad "R16g: xdm — частичного состояния нет (pre-check не создаёт wants)"
[[ "$(result_val "$R" dm_link)" == "not-sddm" ]] \
  && ok "R16h: xdm — sddm не был включён (нет stub-dm-link: sddm)" \
  || bad "R16h: xdm — sddm не был включён (нет stub-dm-link: sddm)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R16i: xdm — cleanup выполнен (EXIT trap)" \
  || bad "R16i: xdm — cleanup выполнен (EXIT trap)"
[[ "$(result_val "$R" log_sddm_error)" == "no" ]] \
  && ok "R16j: xdm — старой ошибки enable ('не удалось включить SDDM') нет (отказ на pre-check)" \
  || bad "R16j: xdm — старой ошибки enable ('не удалось включить SDDM') нет (отказ на pre-check)"

# ================= R17. Alias — обычный файл (V-01) ==============================
# display-manager.service существует как обычный файл, выбранный DM — GDM.
# V-01 pre-check отказывает ДО enable (понятная ошибка «не симлинк»),
# частичного wants-симлинка нет.
run_scenario "r17-alias-regular" "gnome" "gdm" "" "" "" 0 0 0 0 "" "" "" "" "" "1" ""
R="$T/r17-alias-regular/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R17a: alias-файл — движок вышел с кодом 1" \
  || bad "R17a: alias-файл — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R17b: alias-файл — в stdout INSTALL_FAILED" \
  || bad "R17b: alias-файл — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R17c: alias-файл — нет INSTALL_DONE" \
  || bad "R17c: alias-файл — нет INSTALL_DONE"
[[ "$(result_val "$R" log_v01_notsymlink)" == "yes" ]] \
  && ok "R17d: alias-файл — в журнале ошибка V-01 (alias — не симлинк)" \
  || bad "R17d: alias-файл — в журнале ошибка V-01 (alias — не симлинк)"
[[ "$(result_val "$R" enable_attempted)" == "no" ]] \
  && ok "R17e: alias-файл — pre-check отказал ДО enable (enable не вызывался)" \
  || bad "R17e: alias-файл — pre-check отказал ДО enable (enable не вызывался)"
[[ "$(result_val "$R" alias_regular)" == "no" ]] \
  && ok "R17f: alias-файл — заглушка не фиксировала отказ enable (enable не вызывался)" \
  || bad "R17f: alias-файл — заглушка не фиксировала отказ enable (enable не вызывался)"
[[ "$(result_val "$R" wants_partial)" == "no" ]] \
  && ok "R17g: alias-файл — частичного состояния нет (pre-check не создаёт wants)" \
  || bad "R17g: alias-файл — частичного состояния нет (pre-check не создаёт wants)"
[[ "$(result_val "$R" dm_link_gdm)" == "no" ]] \
  && ok "R17h: alias-файл — gdm не был включён" \
  || bad "R17h: alias-файл — gdm не был включён"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R17i: alias-файл — cleanup выполнен (EXIT trap)" \
  || bad "R17i: alias-файл — cleanup выполнен (EXIT trap)"
[[ "$(result_val "$R" log_dm_error)" == "no" ]] \
  && ok "R17j: alias-файл — старой ошибки enable ('не удалось включить менеджер входа') нет (отказ на pre-check)" \
  || bad "R17j: alias-файл — старой ошибки enable ('не удалось включить менеджер входа') нет (отказ на pre-check)"

# ================= R18. Конкурент только в /etc/systemd/system (V-03) ==============================
# gdm существует только в /etc/systemd/system (и предвключён),
# sddm — в /usr/lib/systemd/system. Helper должен найти конкурента.
run_scenario "r18-etc-unit" "kde" "sddm" "" "gdm" "" 0 0 0 0 "gdm" "" "" "" "" "" ""
R="$T/r18-etc-unit/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R18a: /etc-юнит — движок вышел с кодом 0" \
  || bad "R18a: /etc-юнит — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R18b: /etc-юнит — в stdout INSTALL_DONE" \
  || bad "R18b: /etc-юнит — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_gdm)" == "yes" ]] \
  && ok "R18c: /etc-юнит — helper обнаружил конкурента в /etc и вызвал disable" \
  || bad "R18c: /etc-юнит — helper обнаружил конкурента в /etc и вызвал disable"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R18d: /etc-юнит — display-manager.service указывает на sddm" \
  || bad "R18d: /etc-юнит — display-manager.service указывает на sddm"
# Примечание: на успешном пути движок НЕ вызывает xros_cleanup
# («Очистка завершена» логируется только при отказе через EXIT trap),
# поэтому log_cleanup здесь не проверяется.

# ================= R19. Конкурент только в /usr/local/lib/systemd/system (V-03) ==============================
run_scenario "r19-local-unit" "kde" "sddm" "" "gdm" "" 0 0 0 0 "" "gdm" "" "" "" "" ""
R="$T/r19-local-unit/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R19a: /usr/local/lib-юнит — движок вышел с кодом 0" \
  || bad "R19a: /usr/local/lib-юнит — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R19b: /usr/local/lib-юнит — в stdout INSTALL_DONE" \
  || bad "R19b: /usr/local/lib-юнит — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_gdm)" == "yes" ]] \
  && ok "R19c: /usr/local/lib-юнит — helper обнаружил конкурента и вызвал disable" \
  || bad "R19c: /usr/local/lib-юнит — helper обнаружил конкурента и вызвал disable"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R19d: /usr/local/lib-юнит — display-manager.service указывает на sddm" \
  || bad "R19d: /usr/local/lib-юнит — display-manager.service указывает на sddm"
# Примечание: на успешном пути движок НЕ вызывает xros_cleanup
# («Очистка завершена» логируется только при отказе через EXIT trap),
# поэтому log_cleanup здесь не проверяется.

# ================= R20. Конкурент — повреждённый unit-файл (V-03/V-04) ==============================
# gdm.service существует, но содержимое — мусор без [Unit].
# Заглушка моделирует отказ реального systemctl (E9).
run_scenario "r20-corrupt-unit" "kde" "sddm gdm" "" "" "" 0 0 0 0 "" "" "gdm" "" "" "" ""
R="$T/r20-corrupt-unit/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R20a: corrupt-юнит — движок вышел с кодом 1" \
  || bad "R20a: corrupt-юнит — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R20b: corrupt-юнит — в stdout INSTALL_FAILED" \
  || bad "R20b: corrupt-юнит — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R20c: corrupt-юнит — нет INSTALL_DONE" \
  || bad "R20c: corrupt-юнит — нет INSTALL_DONE"
[[ "$(result_val "$R" log_disable_error)" == "yes" ]] \
  && ok "R20d: corrupt-юнит — в журнале понятная ошибка отключения" \
  || bad "R20d: corrupt-юнит — в журнале понятная ошибка отключения"
[[ "$(result_val "$R" stub_disable_corrupt)" == "yes" ]] \
  && ok "R20e: corrupt-юнит — заглушка зафиксировала отказ (повреждённый файл)" \
  || bad "R20e: corrupt-юнит — заглушка зафиксировала отказ (повреждённый файл)"
[[ "$(result_val "$R" dm_link)" == "not-sddm" ]] \
  && ok "R20f: corrupt-юнит — sddm не был включён" \
  || bad "R20f: corrupt-юнит — sddm не был включён"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R20g: corrupt-юнит — cleanup выполнен (EXIT trap)" \
  || bad "R20g: corrupt-юнит — cleanup выполнен (EXIT trap)"

# ================= R21. Каталог вместо unit-файла (V-03/V-04) ==============================
# gdm.service — каталог. Заглушка моделирует отказ реального systemctl (E8).
run_scenario "r21-dir-unit" "kde" "sddm gdm" "" "" "" 0 0 0 0 "" "" "" "gdm" "" "" ""
R="$T/r21-dir-unit/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R21a: каталог-юнит — движок вышел с кодом 1" \
  || bad "R21a: каталог-юнит — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R21b: каталог-юнит — в stdout INSTALL_FAILED" \
  || bad "R21b: каталог-юнит — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R21c: каталог-юнит — нет INSTALL_DONE" \
  || bad "R21c: каталог-юнит — нет INSTALL_DONE"
[[ "$(result_val "$R" log_disable_error)" == "yes" ]] \
  && ok "R21d: каталог-юнит — в журнале понятная ошибка отключения" \
  || bad "R21d: каталог-юнит — в журнале понятная ошибка отключения"
[[ "$(result_val "$R" stub_disable_dir)" == "yes" ]] \
  && ok "R21e: каталог-юнит — заглушка зафиксировала отказ (каталог вместо файла)" \
  || bad "R21e: каталог-юнит — заглушка зафиксировала отказ (каталог вместо файла)"
[[ "$(result_val "$R" dm_link)" == "not-sddm" ]] \
  && ok "R21f: каталог-юнит — sddm не был включён" \
  || bad "R21f: каталог-юнит — sddm не был включён"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R21g: каталог-юнит — cleanup выполнен (EXIT trap)" \
  || bad "R21g: каталог-юнит — cleanup выполнен (EXIT trap)"

# ================= R22. Конкурент — висячий симлинк (V-03) ==============================
# gdm.service — симлинк на несуществующий файл. Ожидаемое поведение
# зафиксировано аудитом systemd (E7): движок ([ -e ] — false) и
# реальный systemctl (rc 1 «does not exist») согласны — юнит
# отсутствует; helper пропускает его, disable НЕ вызывается,
# установка успешна.
run_scenario "r22-dangling-unit" "kde" "sddm gdm" "" "" "" 0 0 0 0 "" "" "" "" "gdm" "" ""
R="$T/r22-dangling-unit/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R22a: висячий юнит — движок вышел с кодом 0" \
  || bad "R22a: висячий юнит — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R22b: висячий юнит — в stdout INSTALL_DONE" \
  || bad "R22b: висячий юнит — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_gdm)" == "no" ]] \
  && ok "R22c: висячий юнит — helper пропустил его, disable не вызывался" \
  || bad "R22c: висячий юнит — helper пропустил его, disable не вызывался"
[[ "$(result_val "$R" log_skip_gdm)" == "yes" ]] \
  && ok "R22d: висячий юнит — в журнале пропуск (gdm.service отсутствует)" \
  || bad "R22d: висячий юнит — в журнале пропуск (gdm.service отсутствует)"
[[ "$(result_val "$R" stub_disable_failed)" == "no" ]] \
  && ok "R22e: висячий юнит — заглушка не зафиксировала отказа disable" \
  || bad "R22e: висячий юнит — заглушка не зафиксировала отказа disable"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R22f: висячий юнит — display-manager.service указывает на sddm" \
  || bad "R22f: висячий юнит — display-manager.service указывает на sddm"
# Примечание: на успешном пути движок НЕ вызывает xros_cleanup
# («Очистка завершена» логируется только при отказе через EXIT trap),
# поэтому log_cleanup здесь не проверяется.

# ================= R23. Alias — висячий симлинк (V-02, A1) ==============================
# display-manager.service — симлинк на несуществующий файл.
# Проверено реальным systemctl 255 (--root, A1): он УДАЛЯЕТ висячий
# alias и создаёт его заново — enable успешен (rc 0).
run_scenario "r23-dangling-alias" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "1"
R="$T/r23-dangling-alias/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R23a: висячий alias — движок вышел с кодом 0" \
  || bad "R23a: висячий alias — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R23b: висячий alias — в stdout INSTALL_DONE" \
  || bad "R23b: висячий alias — в stdout INSTALL_DONE"
[[ "$(result_val "$R" alias_dangling)" == "yes" ]] \
  && ok "R23c: висячий alias — заглушка зафиксировала удаление и пересоздание alias" \
  || bad "R23c: висячий alias — заглушка зафиксировала удаление и пересоздание alias"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R23d: висячий alias — display-manager.service указывает на sddm" \
  || bad "R23d: висячий alias — display-manager.service указывает на sddm"
# Примечание: на успешном пути движок НЕ вызывает xros_cleanup
# («Очистка завершена» логируется только при отказе через EXIT trap),
# поэтому log_cleanup здесь не проверяется.

# ================= R24. Alias — каталог (V-01) ==============================
# display-manager.service — каталог, выбранный DM — GDM.
# V-01 pre-check отказывает ДО enable (понятная ошибка «каталог,
# а не симлинк»), частичного wants-симлинка нет.
run_scenario "r24-alias-dir" "gnome" "gdm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "" "1" ""
R="$T/r24-alias-dir/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R24a: alias-каталог — движок вышел с кодом 1" \
  || bad "R24a: alias-каталог — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R24b: alias-каталог — в stdout INSTALL_FAILED" \
  || bad "R24b: alias-каталог — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R24c: alias-каталог — нет INSTALL_DONE" \
  || bad "R24c: alias-каталог — нет INSTALL_DONE"
[[ "$(result_val "$R" log_v01_notsymlink)" == "yes" ]] \
  && ok "R24d: alias-каталог — в журнале ошибка V-01 (alias — не симлинк)" \
  || bad "R24d: alias-каталог — в журнале ошибка V-01 (alias — не симлинк)"
[[ "$(result_val "$R" enable_attempted)" == "no" ]] \
  && ok "R24e: alias-каталог — pre-check отказал ДО enable (enable не вызывался)" \
  || bad "R24e: alias-каталог — pre-check отказал ДО enable (enable не вызывался)"
[[ "$(result_val "$R" wants_partial)" == "no" ]] \
  && ok "R24f: alias-каталог — частичного состояния нет (pre-check не создаёт wants)" \
  || bad "R24f: alias-каталог — частичного состояния нет (pre-check не создаёт wants)"
[[ "$(result_val "$R" dm_link_gdm)" == "no" ]] \
  && ok "R24g: alias-каталог — gdm не был включён" \
  || bad "R24g: alias-каталог — gdm не был включён"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R24h: alias-каталог — cleanup выполнен (EXIT trap)" \
  || bad "R24h: alias-каталог — cleanup выполнен (EXIT trap)"

# ================= R25. Юнит только в /run/systemd/system (V-05) ==============================
# gdm существует ТОЛЬКО в /run/systemd/system, alias не удерживает.
# Helper движка /run не проверяет (V-05 — по механизму /run пуст при
# установке: rsync исключает /run/*, S10). Ожидается: helper пропускает
# его как отсутствующий, установка успешна. /run-юнит — временный,
# на загрузку установленной системы он не влияет (tmpfs).
run_scenario "r25-run-unit" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "gdm" "" ""
R="$T/r25-run-unit/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R25a: /run-юнит — движок вышел с кодом 0" \
  || bad "R25a: /run-юнит — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R25b: /run-юнит — в stdout INSTALL_DONE" \
  || bad "R25b: /run-юнит — в stdout INSTALL_DONE"
[[ "$(result_val "$R" log_skip_gdm)" == "yes" ]] \
  && ok "R25c: /run-юнит — helper пропустил его (gdm.service отсутствует в 3 каталогах)" \
  || bad "R25c: /run-юнит — helper пропустил его (gdm.service отсутствует в 3 каталогах)"
[[ "$(result_val "$R" disable_gdm)" == "no" ]] \
  && ok "R25d: /run-юнит — disable не вызывался (юнит не найден helper)" \
  || bad "R25d: /run-юнит — disable не вызывался (юнит не найден helper)"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R25e: /run-юнит — display-manager.service указывает на sddm" \
  || bad "R25e: /run-юнит — display-manager.service указывает на sddm"
[[ "$(result_val "$R" enable_attempted)" == "yes" ]] \
  && ok "R25f: /run-юнит — enable sddm вызывался (успешная настройка)" \
  || bad "R25f: /run-юнит — enable sddm вызывался (успешная настройка)"
# Примечание: на успешном пути движок НЕ вызывает xros_cleanup,
# поэтому log_cleanup здесь не проверяется.

# ================= R26. /run-юнит удерживает alias (V-05, граничный случай) ==============================
# gdm существует ТОЛЬКО в /run/systemd/system и предвключён (alias ->
# /run/.../gdm.service). По механизму такой случай при установке не
# возникает (S10), но если бы возник — отказ обязан быть fail-closed,
# а не молчаливым. Ожидается: pre-check пропускает (имя gdm известно),
# helper пропускает gdm (не в 3 каталогах), enable sddm падает на
# конфликте alias (как реальный systemctl), установка прерывается.
run_scenario "r26-run-alias" "kde" "sddm" "" "gdm" "" 0 0 0 0 "" "" "" "" "" "" "" "gdm" "" ""
R="$T/r26-run-alias/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R26a: /run-alias — движок вышел с кодом 1" \
  || bad "R26a: /run-alias — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R26b: /run-alias — в stdout INSTALL_FAILED" \
  || bad "R26b: /run-alias — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R26c: /run-alias — нет INSTALL_DONE" \
  || bad "R26c: /run-alias — нет INSTALL_DONE"
[[ "$(result_val "$R" log_sddm_error)" == "yes" ]] \
  && ok "R26d: /run-alias — в журнале ошибка включения SDDM (отказ на enable)" \
  || bad "R26d: /run-alias — в журнале ошибка включения SDDM (отказ на enable)"
[[ "$(result_val "$R" alias_conflict)" == "yes" ]] \
  && ok "R26e: /run-alias — заглушка зафиксировала alias-конфликт" \
  || bad "R26e: /run-alias — заглушка зафиксировала alias-конфликт"
[[ "$(result_val "$R" wants_partial)" == "yes" ]] \
  && ok "R26f: /run-alias — частичное изменение не скрыто (wants создан при отказе)" \
  || bad "R26f: /run-alias — частичное изменение не скрыто (wants создан при отказе)"
[[ "$(result_val "$R" dm_link)" == "not-sddm" ]] \
  && ok "R26g: /run-alias — sddm не был включён" \
  || bad "R26g: /run-alias — sddm не был включён"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R26h: /run-alias — cleanup выполнен (EXIT trap)" \
  || bad "R26h: /run-alias — cleanup выполнен (EXIT trap)"

# ================= R27. Финальная проверка: юнит удалён после enable (V-07) ==============================
# DM_RACE=delete-unit: заглушка set-default удаляет файл юнита ПОСЛЕ
# успешного enable. Финальная проверка (xros_verify_dm) обязана
# поймать висячий alias и прервать установку (без INSTALL_DONE).
run_scenario "r27-final-missing" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "delete-unit"
R="$T/r27-final-missing/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R27a: final-missing — движок вышел с кодом 1" \
  || bad "R27a: final-missing — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R27b: final-missing — в stdout INSTALL_FAILED" \
  || bad "R27b: final-missing — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R27c: final-missing — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R27c: final-missing — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_dm_not_enabled)" == "yes" ]] \
  && ok "R27d: final-missing — в журнале ошибка финальной проверки ('менеджер входа не включён')" \
  || bad "R27d: final-missing — в журнале ошибка финальной проверки ('менеджер входа не включён')"
[[ "$(result_val "$R" stub_race)" == "yes" ]] \
  && ok "R27e: final-missing — гонка TOCTOU применена (заглушка удалила юнит)" \
  || bad "R27e: final-missing — гонка TOCTOU применена (заглушка удалила юнит)"
[[ "$(result_val "$R" enable_attempted)" == "yes" ]] \
  && ok "R27f: final-missing — enable выполнялся (отказ именно на финальной проверке)" \
  || bad "R27f: final-missing — enable выполнялся (отказ именно на финальной проверке)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R27g: final-missing — cleanup выполнен (EXIT trap)" \
  || bad "R27g: final-missing — cleanup выполнен (EXIT trap)"

# ================= R28. Финальная проверка: alias на sddm-foo.service (V-07) ==============================
# DM_RACE=alias-wrong: alias переставлен на sddm-foo.service ПОСЛЕ
# enable. Старая проверка по подстроке (*sddm*) пропустила бы это;
# новая (точное имя) обязана отказать.
run_scenario "r28-final-wrongname" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "alias-wrong"
R="$T/r28-final-wrongname/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R28a: final-wrongname — движок вышел с кодом 1" \
  || bad "R28a: final-wrongname — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R28b: final-wrongname — в stdout INSTALL_FAILED" \
  || bad "R28b: final-wrongname — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R28c: final-wrongname — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R28c: final-wrongname — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_dm_not_enabled)" == "yes" ]] \
  && ok "R28d: final-wrongname — в журнале ошибка финальной проверки" \
  || bad "R28d: final-wrongname — в журнале ошибка финальной проверки"
[[ "$(result_val "$R" stub_race)" == "yes" ]] \
  && ok "R28e: final-wrongname — гонка TOCTOU применена (alias переставлен)" \
  || bad "R28e: final-wrongname — гонка TOCTOU применена (alias переставлен)"
[[ "$(result_val "$R" enable_attempted)" == "yes" ]] \
  && ok "R28f: final-wrongname — enable выполнялся (отказ именно на финальной проверке)" \
  || bad "R28f: final-wrongname — enable выполнялся (отказ именно на финальной проверке)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R28g: final-wrongname — cleanup выполнен (EXIT trap)" \
  || bad "R28g: final-wrongname — cleanup выполнен (EXIT trap)"

# ================= R29. Финальная проверка: юнит замаскирован после enable (V-07) ==============================
# DM_RACE=alias-mask: файл юнита заменён симлинком на /dev/null ПОСЛЕ
# enable. Финальная проверка обязана поймать маску.
run_scenario "r29-final-masked" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "alias-mask"
R="$T/r29-final-masked/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R29a: final-masked — движок вышел с кодом 1" \
  || bad "R29a: final-masked — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R29b: final-masked — в stdout INSTALL_FAILED" \
  || bad "R29b: final-masked — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R29c: final-masked — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R29c: final-masked — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_dm_not_enabled)" == "yes" ]] \
  && ok "R29d: final-masked — в журнале ошибка финальной проверки" \
  || bad "R29d: final-masked — в журнале ошибка финальной проверки"
[[ "$(result_val "$R" stub_race)" == "yes" ]] \
  && ok "R29e: final-masked — гонка TOCTOU применена (юнит замаскирован)" \
  || bad "R29e: final-masked — гонка TOCTOU применена (юнит замаскирован)"
[[ "$(result_val "$R" enable_attempted)" == "yes" ]] \
  && ok "R29f: final-masked — enable выполнялся (отказ именно на финальной проверке)" \
  || bad "R29f: final-masked — enable выполнялся (отказ именно на финальной проверке)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R29g: final-masked — cleanup выполнен (EXIT trap)" \
  || bad "R29g: final-masked — cleanup выполнен (EXIT trap)"

# ================= R30. Финальная проверка: юнит заменён каталогом после enable (V-07) ==============================
# DM_RACE=alias-dir: файл юнита заменён каталогом ПОСЛЕ enable.
# Финальная проверка обязана поймать неверный тип объекта.
run_scenario "r30-final-dir" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "alias-dir"
R="$T/r30-final-dir/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R30a: final-dir — движок вышел с кодом 1" \
  || bad "R30a: final-dir — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R30b: final-dir — в stdout INSTALL_FAILED" \
  || bad "R30b: final-dir — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R30c: final-dir — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R30c: final-dir — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_dm_not_enabled)" == "yes" ]] \
  && ok "R30d: final-dir — в журнале ошибка финальной проверки" \
  || bad "R30d: final-dir — в журнале ошибка финальной проверки"
[[ "$(result_val "$R" stub_race)" == "yes" ]] \
  && ok "R30e: final-dir — гонка TOCTOU применена (юнит заменён каталогом)" \
  || bad "R30e: final-dir — гонка TOCTOU применена (юнит заменён каталогом)"
[[ "$(result_val "$R" enable_attempted)" == "yes" ]] \
  && ok "R30f: final-dir — enable выполнялся (отказ именно на финальной проверке)" \
  || bad "R30f: final-dir — enable выполнялся (отказ именно на финальной проверке)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R30g: final-dir — cleanup выполнен (EXIT trap)" \
  || bad "R30g: final-dir — cleanup выполнен (EXIT trap)"

# ================= R31. Конкурент — АБСОЛЮТНЫЙ симлинк, включён (FIX-A) ==============================
# gdm.service — абсолютный симлинк на реальный файл внутри цели
# (/usr/lib/systemd/system/gdm-real.service), предвключён (alias +
# wants). Старый helper ([ -e ] — разрешается по хосту) пропускал его
# как «отсутствующий»; новый обязан обнаружить и отключить.
run_scenario "r31-absolute-unit" "kde" "sddm" "" "gdm" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "" "gdm"
R="$T/r31-absolute-unit/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R31a: absolute-symlink unit — движок вышел с кодом 0" \
  || bad "R31a: absolute-symlink unit — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R31b: absolute-symlink unit — в stdout INSTALL_DONE" \
  || bad "R31b: absolute-symlink unit — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_gdm)" == "yes" ]] \
  && ok "R31c: absolute-symlink unit — helper ОБНАРУЖИЛ и отключил gdm (FIX-A)" \
  || bad "R31c: absolute-symlink unit — helper ОБНАРУЖИЛ и отключил gdm (FIX-A)"
[[ "$(result_val "$R" log_skip_gdm)" == "no" ]] \
  && ok "R31d: absolute-symlink unit — в журнале НЕТ пропуска gdm (не «отсутствует»)" \
  || bad "R31d: absolute-symlink unit — в журнале НЕТ пропуска gdm (не «отсутствует»)"
[[ "$(result_val "$R" stub_disable_failed)" == "no" ]] \
  && ok "R31e: absolute-symlink unit — заглушка не зафиксировала отказа disable" \
  || bad "R31e: absolute-symlink unit — заглушка не зафиксировала отказа disable"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R31f: absolute-symlink unit — display-manager.service указывает на sddm" \
  || bad "R31f: absolute-symlink unit — display-manager.service указывает на sddm"

# ================= R32. Конкурент — АБСОЛЮТНЫЙ симлинк, не включён (FIX-A) ==============================
# gdm.service — абсолютный симлинк на реальный файл внутри цели,
# не предвключён. Helper обязан обнаружить и отключить его.
run_scenario "r32-absolute-unit-notenabled" "kde" "sddm" "" "" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "" "gdm"
R="$T/r32-absolute-unit-notenabled/result.txt"
[[ "$(result_val "$R" rc)" == "0" ]] \
  && ok "R32a: absolute-symlink unit (not enabled) — движок вышел с кодом 0" \
  || bad "R32a: absolute-symlink unit (not enabled) — движок вышел с кодом 0 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_done)" == "yes" ]] \
  && ok "R32b: absolute-symlink unit (not enabled) — в stdout INSTALL_DONE" \
  || bad "R32b: absolute-symlink unit (not enabled) — в stdout INSTALL_DONE"
[[ "$(result_val "$R" disable_gdm)" == "yes" ]] \
  && ok "R32c: absolute-symlink unit (not enabled) — helper отключил gdm (FIX-A)" \
  || bad "R32c: absolute-symlink unit (not enabled) — helper отключил gdm (FIX-A)"
[[ "$(result_val "$R" log_skip_gdm)" == "no" ]] \
  && ok "R32d: absolute-symlink unit (not enabled) — в журнале НЕТ пропуска gdm" \
  || bad "R32d: absolute-symlink unit (not enabled) — в журнале НЕТ пропуска gdm"
[[ "$(result_val "$R" dm_link)" == "sddm" ]] \
  && ok "R32e: absolute-symlink unit (not enabled) — display-manager.service указывает на sddm" \
  || bad "R32e: absolute-symlink unit (not enabled) — display-manager.service указывает на sddm"

# Примечание (P4-AUD-04): сценарий «выбранный DM — абсолютный симлинк»
# НЕ добавлен: он упирается в известное ограничение V-07-INFO-2
# (xros_verify_dm трактует абсолютный симлинк как висячий, т.к.
# [ -e ] разрешается по хосту) — это вне объёма FIX-A/FIX-B
# (V-07 закрыт, xros_verify_dm не меняется). FIX-A покрывает
# конкурирующие DM (R31, R32); выбранный DM как абсолютный симлинк
# на практике не встречается (DM-юниты — обычные файлы).

# ================= R34. DE=none, set-default падает (FIX-B, V-09) ==============================
# set-default multi-user.target возвращает ошибку. Раньше (|| true)
# установка молча продолжалась и рапортовала INSTALL_DONE; теперь —
# fail-closed: код 1, INSTALL_FAILED, нет INSTALL_DONE, cleanup.
run_scenario "r34-none-setdefault-fail" "none" "sddm gdm lightdm" "" "sddm" "" 0 1 0 0
R="$T/r34-none-setdefault-fail/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R34a: none set-default-fail — движок вышел с кодом 1" \
  || bad "R34a: none set-default-fail — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R34b: none set-default-fail — в stdout INSTALL_FAILED" \
  || bad "R34b: none set-default-fail — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R34c: none set-default-fail — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R34c: none set-default-fail — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_setdefault_multiuser_error)" == "yes" ]] \
  && ok "R34d: none set-default-fail — в журнале ошибка set-default multi-user.target" \
  || bad "R34d: none set-default-fail — в журнале ошибка set-default multi-user.target"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R34e: none set-default-fail — cleanup выполнен (EXIT trap)" \
  || bad "R34e: none set-default-fail — cleanup выполнен (EXIT trap)"
[[ "$(result_val "$R" default_target_multiuser)" == "no" ]] \
  && ok "R34f: none set-default-fail — default target не установлен (заглушка отказала)" \
  || bad "R34f: none set-default-fail — default target не установлен (заглушка отказала)"

# ================= R35. DE=none, гонка: default.target переназначен (FIX-B) ==============================
# Между set-default и финальной проверкой default.target переназначен
# на graphical.target. Финальная проверка обязана поймать подмену.
run_scenario "r35-none-default-race-wrong" "none" "sddm gdm lightdm" "" "sddm" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "" "" "default-wrong"
R="$T/r35-none-default-race-wrong/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R35a: default-race-wrong — движок вышел с кодом 1" \
  || bad "R35a: default-race-wrong — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R35b: default-race-wrong — в stdout INSTALL_FAILED" \
  || bad "R35b: default-race-wrong — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R35c: default-race-wrong — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R35c: default-race-wrong — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_default_target_error)" == "yes" ]] \
  && ok "R35d: default-race-wrong — в журнале ошибка проверки default target" \
  || bad "R35d: default-race-wrong — в журнале ошибка проверки default target"
[[ "$(result_val "$R" stub_default_race)" == "yes" ]] \
  && ok "R35e: default-race-wrong — гонка TOCTOU применена (default.target переназначен)" \
  || bad "R35e: default-race-wrong — гонка TOCTOU применена (default.target переназначен)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R35f: default-race-wrong — cleanup выполнен (EXIT trap)" \
  || bad "R35f: default-race-wrong — cleanup выполнен (EXIT trap)"

# ================= R36. DE=none, гонка: default.target удалён (FIX-B) ==============================
# Между set-default и финальной проверкой default.target удалён.
# Финальная проверка обязана поймать отсутствие симлинка.
run_scenario "r36-none-default-race-delete" "none" "sddm gdm lightdm" "" "sddm" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "" "" "default-delete"
R="$T/r36-none-default-race-delete/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R36a: default-race-delete — движок вышел с кодом 1" \
  || bad "R36a: default-race-delete — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R36b: default-race-delete — в stdout INSTALL_FAILED" \
  || bad "R36b: default-race-delete — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R36c: default-race-delete — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R36c: default-race-delete — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_default_target_error)" == "yes" ]] \
  && ok "R36d: default-race-delete — в журнале ошибка проверки default target" \
  || bad "R36d: default-race-delete — в журнале ошибка проверки default target"
[[ "$(result_val "$R" stub_default_race)" == "yes" ]] \
  && ok "R36e: default-race-delete — гонка TOCTOU применена (default.target удалён)" \
  || bad "R36e: default-race-delete — гонка TOCTOU применена (default.target удалён)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R36f: default-race-delete — cleanup выполнен (EXIT trap)" \
  || bad "R36f: default-race-delete — cleanup выполнен (EXIT trap)"

# ================= R37. DE=none, гонка: multi-user.target замаскирован (R-22) ==============================
# Между set-default и финальной проверкой юнит multi-user.target заменён
# симлинком на /dev/null. Финальная проверка обязана поймать маску.
run_scenario "r37-none-default-race-mask" "none" "sddm gdm lightdm" "" "sddm" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "" "" "default-mask"
R="$T/r37-none-default-race-mask/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R37a: default-race-mask — движок вышел с кодом 1" \
  || bad "R37a: default-race-mask — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R37b: default-race-mask — в stdout INSTALL_FAILED" \
  || bad "R37b: default-race-mask — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R37c: default-race-mask — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R37c: default-race-mask — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_default_target_error)" == "yes" ]] \
  && ok "R37d: default-race-mask — в журнале ошибка проверки default target" \
  || bad "R37d: default-race-mask — в журнале ошибка проверки default target"
[[ "$(result_val "$R" stub_default_race)" == "yes" ]] \
  && ok "R37e: default-race-mask — гонка TOCTOU применена (multi-user.target замаскирован)" \
  || bad "R37e: default-race-mask — гонка TOCTOU применена (multi-user.target замаскирован)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R37f: default-race-mask — cleanup выполнен (EXIT trap)" \
  || bad "R37f: default-race-mask — cleanup выполнен (EXIT trap)"

# ================= R38. DE=none, гонка: default.target висячий (R-22) ==============================
# Между set-default и финальной проверкой default.target переназначен
# на несуществующий юнит. Финальная проверка обязана поймать висячий симлинк.
run_scenario "r38-none-default-race-dangling" "none" "sddm gdm lightdm" "" "sddm" "" 0 0 0 0 "" "" "" "" "" "" "" "" "" "" "" "default-dangling"
R="$T/r38-none-default-race-dangling/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "R38a: default-race-dangling — движок вышел с кодом 1" \
  || bad "R38a: default-race-dangling — движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "R38b: default-race-dangling — в stdout INSTALL_FAILED" \
  || bad "R38b: default-race-dangling — в stdout INSTALL_FAILED"
[[ "$(result_val "$R" stdout_install_done)" == "no" ]] \
  && ok "R38c: default-race-dangling — нет INSTALL_DONE (нет ложного успеха)" \
  || bad "R38c: default-race-dangling — нет INSTALL_DONE (нет ложного успеха)"
[[ "$(result_val "$R" log_default_target_error)" == "yes" ]] \
  && ok "R38d: default-race-dangling — в журнале ошибка проверки default target" \
  || bad "R38d: default-race-dangling — в журнале ошибка проверки default target"
[[ "$(result_val "$R" stub_default_race)" == "yes" ]] \
  && ok "R38e: default-race-dangling — гонка TOCTOU применена (default.target висячий)" \
  || bad "R38e: default-race-dangling — гонка TOCTOU применена (default.target висячий)"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "R38f: default-race-dangling — cleanup выполнен (EXIT trap)" \
  || bad "R38f: default-race-dangling — cleanup выполнен (EXIT trap)"

# ================= R0d. Проверка отсутствия протечки на хост ==============================
if [[ -e /run/archiso/bootmnt/xros/boot/x86_64/vmlinuz-linux ]]; then
  bad "R0d: фиктивное ядро НЕ должно быть видно на хосте (/run/archiso)"
else
  ok "R0d: фиктивный /run/archiso не потёк на хост"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIP (упавшие:$FAILED_NAMES)"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
