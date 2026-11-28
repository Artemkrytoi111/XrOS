#!/usr/bin/env bash
# XrOS — тесты RAID-блокировки установщика (A-38).
#
# Проверяется НАСТОЯЩИЙ код (не копии логики):
#   A. xros_disk_blocked из src/xros-install — с поддельными lsblk/blkid
#      (bash-функции), матрица кейсов: MD RAID, fakeraid (R-02),
#      LVM/LUKS, чистый диск, ошибки проверки (R-04: отсутствующие
#      утилиты, ошибки исполнения/доступа, пустой и некорректный вывод);
#   B. bridge.py — через scripts/tests/test-raid-bridge.py (Python);
#   C. system.rs — статические проверки (cargo check — если есть cargo);
#   D. РЕАЛЬНЫЙ движок в unshare -rm с LD_PRELOAD-шимом (как в
#      test-child-process-extended.sh): RAID-диск (lsblk и blkid-нога)
#      обязан остановиться ДО wipefs/sgdisk/mkfs, чистый диск — дойти
#      до них (позитивный контроль). Диск — только файл $T/fakedisk,
#      все разрушительные утилиты — заглушки, монтирования — внутри
#      unshare. Реальные диски не трогаются.
#   E. Статика: защита перед mkfs/wipefs, синхронность копий.
#
# Запуск: ./scripts/tests/test-raid-block.sh
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

# ================= A. xros_disk_blocked (настоящая функция) ================
awk '/^xros_disk_blocked\(\) \{/{f=1} f{print} f && /^}/{exit}' "$ENGINE" > "$T/blocked.sh"
if [[ -s "$T/blocked.sh" ]] && grep -q "linux_raid_member" "$T/blocked.sh"; then
  ok "A0 блок xros_disk_blocked извлечён из src/xros-install целиком"
else
  bad "A0 блок xros_disk_blocked извлечён из src/xros-install целиком"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  exit 1
fi
# R-18: настоящая xros_device_readable тоже извлекается (для A2 —
# unit-тестов реальной пробы чтения). В секции A она ПЕРЕОПРЕДЕЛЯЕТСЯ
# заглушкой (как lsblk/blkid ниже): секция A проверяет ЛОГИКУ
# РЕШЕНИЙ xros_disk_blocked, а не системные вызовы; реальная проба
# тестируется в A2 (негативные кейсы) и в D e2e (позитив — шим
# делает файл блочным устройством; негатив — файл отсутствует /
# head падает).
awk '/^xros_device_readable\(\) \{/{f=1} f{print} f && /^}/{exit}' "$ENGINE" > "$T/readable.sh"
if [[ -s "$T/readable.sh" ]] && grep -q "head -c 512" "$T/readable.sh"; then
  ok "A0 блок xros_device_readable извлечён из src/xros-install"
else
  bad "A0 блок xros_device_readable извлечён из src/xros-install"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
  exit 1
fi

say() { echo "SAY: $*" >> "$T/say.log"; }
# Поддельные lsblk/blkid: ответы задаются переменными кейса.
# LSBLK_RC / BLKID_RC — подмена кода возврата (пусто = 0/поведение
# по умолчанию). blkid возвращает 2, если устройства нет в таблице
# (как настоящий blkid -p: сигнатуры нет). LSBLK_PATH_RC — код
# только для перечисления потомков (lsblk -o PATH).
# R-18: UNREADABLE_DEVS — устройства, для которых заглушка пробы
# чтения возвращает «не читается» (список через пробел); пусто —
# все читаемы. BLKID_STDERR — текст в stderr поддельного blkid
# (как настоящий blkid при Permission denied).
LSBLK_FSTYPE=""; LSBLK_TYPE=""; LSBLK_PATH=""; BLKID_TABLE=""
LSBLK_RC=""; BLKID_RC=""; LSBLK_PATH_RC=""; UNREADABLE_DEVS=""; BLKID_STDERR=""
# Настоящая проба чтения — для A2; здесь же она переопределяется
# заглушкой ниже (порядок важен: source — до переопределения).
# shellcheck disable=SC1090
source "$T/readable.sh"
xros_device_readable() {
  local d="$1"
  [[ -n "$UNREADABLE_DEVS" ]] && printf '%s\n' $UNREADABLE_DEVS | grep -qxF -- "$d" && return 1
  return 0
}
lsblk() {
  echo "lsblk $*" >> "$T/lsblk.calls"
  case "$*" in
    *"-o PATH"*)
      [[ -n "$LSBLK_PATH_RC" ]] && return "$LSBLK_PATH_RC"
      printf '%s\n' "$LSBLK_PATH" ;;
    *"-o FSTYPE"*)
      [[ -n "$LSBLK_RC" ]] && return "$LSBLK_RC"
      printf '%s\n' "$LSBLK_FSTYPE" ;;
    *"-o TYPE"*)
      [[ -n "$LSBLK_RC" ]] && return "$LSBLK_RC"
      printf '%s\n' "$LSBLK_TYPE" ;;
    *) printf '' ;;
  esac
  return 0
}
blkid() {
  echo "blkid $*" >> "$T/blkid.calls"
  [[ -n "$BLKID_RC" ]] && return "$BLKID_RC"
  # R-18: настоящий blkid при ошибке доступа пишет в stderr
  # (проверено: 'blkid: error: ...: Permission denied', rc=2).
  [[ -n "$BLKID_STDERR" ]] && echo "$BLKID_STDERR" >&2
  local d="${!#}" _type
  _type="$(printf '%s\n' "$BLKID_TABLE" | awk -v dev="$d" '$1==dev {print $2; exit}')"
  if [[ -n "$_type" ]]; then printf '%s\n' "$_type"; return 0; fi
  return 2
}
# shellcheck disable=SC1090
source "$T/blocked.sh"

run_case() { # $1=имя $2=ожидаемое(blocked|free|error) $3=устройство
  local name="$1" want="$2" dev="$3"
  rm -f "$T/say.log" "$T/lsblk.calls" "$T/blkid.calls"
  LSBLK_RC=""; BLKID_RC=""; LSBLK_PATH_RC=""; UNREADABLE_DEVS=""; BLKID_STDERR=""
  local got _rc
  xros_disk_blocked "$dev"; _rc=$?
  case "$_rc" in 0) got="blocked" ;; 1) got="free" ;; 2) got="error" ;; *) got="rc$_rc" ;; esac
  if [[ "$got" == "$want" ]]; then ok "bash $name: $want"; else bad "bash $name: ожидалось $want, получено $got"; fi
}

# run_case_rc <имя> <ожидаемое> <устройство> — с заранее заданными
# LSBLK_RC/BLKID_RC/LSBLK_PATH_RC (не сбрасываются).
run_case_rc() {
  local name="$1" want="$2" dev="$3"
  rm -f "$T/say.log" "$T/lsblk.calls" "$T/blkid.calls"
  local got _rc
  xros_disk_blocked "$dev"; _rc=$?
  case "$_rc" in 0) got="blocked" ;; 1) got="free" ;; 2) got="error" ;; *) got="rc$_rc" ;; esac
  if [[ "$got" == "$want" ]]; then ok "bash $name: $want"; else bad "bash $name: ожидалось $want, получено $got"; fi
}

# 1. Несобранный член, TYPE=part (основной кейс A-38).
LSBLK_FSTYPE="linux_raid_member"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "член part linux_raid_member" blocked /dev/sda1
# 2. Несобранный член, TYPE=disk (целый диск-член).
LSBLK_FSTYPE="linux_raid_member"; LSBLK_TYPE="disk"; LSBLK_PATH="/dev/sda"; BLKID_TABLE=""
run_case "член whole-disk linux_raid_member" blocked /dev/sda
# 3. Собранный массив, TYPE=raid1 (префикс raid*, не точное "raid").
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="raid1"; LSBLK_PATH="/dev/md0"; BLKID_TABLE=""
run_case "собранный raid1" blocked /dev/md0
# 4. Остальные варианты MD: raid0/raid4/raid5/raid6/raid10.
for rt in raid0 raid4 raid5 raid6 raid10 raid; do
  LSBLK_FSTYPE="ext4"; LSBLK_TYPE="$rt"; LSBLK_PATH="/dev/md0"; BLKID_TABLE=""
  run_case "собранный $rt" blocked /dev/md0
done
# 5. Вложенное md-устройство в children (строки потомков lsblk).
LSBLK_FSTYPE=$'ext4\next4'; LSBLK_TYPE=$'disk\npart\nraid1'; LSBLK_PATH=$'/dev/sda\n/dev/sda1\n/dev/md0'; BLKID_TABLE=""
run_case "вложенное md в children" blocked /dev/sda
# 6. Член внутри родительского диска (FSTYPE потомка).
LSBLK_FSTYPE=$'\nlinux_raid_member'; LSBLK_TYPE=$'disk\npart'; LSBLK_PATH=$'/dev/sda\n/dev/sda1'; BLKID_TABLE=""
run_case "член внутри родительского диска" blocked /dev/sda
# 7. Чистый диск.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE=$'disk\npart'; LSBLK_PATH=$'/dev/sda\n/dev/sda1'; BLKID_TABLE=""
run_case "чистый диск" free /dev/sda
# 8. Обычный раздел ext4.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "обычный раздел ext4" free /dev/sda1
# 9. LVM.
LSBLK_FSTYPE="LVM2_member"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "LVM" blocked /dev/sda1
# 10. LUKS.
LSBLK_FSTYPE="crypto_LUKS"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "LUKS" blocked /dev/sda1
# 11. Вторая нога: lsblk чист, но blkid видит linux_raid_member.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"
BLKID_TABLE="/dev/sda1 linux_raid_member"
run_case "blkid-нога: член при чистом lsblk" blocked /dev/sda1
if grep -q "blkid.*-p -s TYPE.* /dev/sda1" "$T/blkid.calls" 2>/dev/null || grep -q "/dev/sda1" "$T/blkid.calls" 2>/dev/null; then
  ok "bash blkid-нога: blkid реально вызван для устройства"
else
  bad "bash blkid-нога: blkid реально вызван для устройства"
fi
# 12. blkid видит члена у потомка диска.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE=$'disk\npart'; LSBLK_PATH=$'/dev/sda\n/dev/sda1'
BLKID_TABLE="/dev/sda1 linux_raid_member"
run_case "blkid-нога: член у потомка диска" blocked /dev/sda
# 13. blkid чист — свободен (ложного срабатывания нет).
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE="/dev/sda1 ext4"
run_case "blkid чист: свободен" free /dev/sda1

# 14. R-02: все типы членов RAID/fakeraid из libblkid — lsblk-нога.
for ft in isw_raid_member ddf_raid_member promise_fasttrack_raid_member adaptec_raid_member hpt37x_raid_member hpt45x_raid_member jmicron_raid_member lsi_mega_raid_member nvidia_raid_member silicon_medley_raid_member via_raid_member; do
  LSBLK_FSTYPE="$ft"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
  run_case "fakeraid $ft (lsblk)" blocked /dev/sda1
done
# 15. R-02: fakeraid — blkid-нога (lsblk чист, blkid видит тип).
for ft in isw_raid_member ddf_raid_member promise_fasttrack_raid_member; do
  LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"
  BLKID_TABLE="/dev/sda1 $ft"
  run_case "fakeraid $ft (blkid)" blocked /dev/sda1
done
# 16. R-02: член fakeraid среди потомков диска (многострочный вывод).
LSBLK_FSTYPE=$'\nisw_raid_member'; LSBLK_TYPE=$'disk\npart'; LSBLK_PATH=$'/dev/sda\n/dev/sda1'; BLKID_TABLE=""
run_case "fakeraid isw_raid_member у потомка диска" blocked /dev/sda
# 17. R-02: LVM1_member — тот же класс, что и LVM2_member.
LSBLK_FSTYPE="LVM1_member"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "LVM1" blocked /dev/sda1

# 18. R-04: ошибка проверки — отдельный статус error, а не «свободен».
# 18а. Чистый диск с пустым выводом lsblk/blkid — свободен (норма:
#      неразмеченный диск без сигнатур; пустой вывод при rc=0 —
#      не ошибка).
LSBLK_FSTYPE=""; LSBLK_TYPE=""; LSBLK_PATH=""; BLKID_TABLE=""
run_case "пустой вывод: чистый диск свободен" free /dev/sda
# 18б. Некорректный вывод lsblk (мусор, не совпадающий с блоклистом)
#      при чистом blkid — свободен: мусор не блокирует, а blkid-нога
#      независимо подтверждает отсутствие сигнатур.
LSBLK_FSTYPE="not-a-real-fstype!!!"; LSBLK_TYPE="weird"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "некорректный вывод lsblk: свободен" free /dev/sda1
# 18в. Ошибка исполнения lsblk → error.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
LSBLK_RC=1; run_case_rc "lsblk: ошибка исполнения" error /dev/sda1; LSBLK_RC=""
# 18г. Ошибка исполнения blkid → error (rc=1, не 2).
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
BLKID_RC=1; run_case_rc "blkid: ошибка исполнения" error /dev/sda1; BLKID_RC=""
# 18д. Ошибка доступа (blkid не может прочитать устройство) → error.
#      blkid в таком случае возвращает ненулевой код, отличный от 2.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
BLKID_RC=1; run_case_rc "blkid: ошибка доступа" error /dev/sda1; BLKID_RC=""
# 18е. Не удалось перечислить потомков (lsblk -o PATH) → error.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
LSBLK_PATH_RC=1; run_case_rc "lsblk -o PATH: ошибка" error /dev/sda1; LSBLK_PATH_RC=""
# 18ж. Отсутствующий lsblk → error (подмена PATH + unset функции:
#      в подшелле функция lsblk удалена, а в PATH — только grep).
mkdir -p "$T/nobin"
ln -sf "$(command -v grep)" "$T/nobin/grep"
( unset -f lsblk; PATH="$T/nobin" xros_disk_blocked /dev/sda1 ); _rc=$?
if [[ "$_rc" -eq 2 ]]; then ok "bash нет lsblk: error"; else bad "bash нет lsblk: ожидалось error, получено rc=$_rc"; fi
# 18з. Отсутствующий blkid → error (lsblk-функция на месте).
( unset -f blkid; PATH="$T/nobin" xros_disk_blocked /dev/sda1 ); _rc=$?
if [[ "$_rc" -eq 2 ]]; then ok "bash нет blkid: error"; else bad "bash нет blkid: ожидалось error, получено rc=$_rc"; fi
# 18и. blkid rc=2 (сигнатуры нет) при чистом lsblk — свободен,
#      а не ошибка: это норма для чистого устройства.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "blkid rc=2: свободен" free /dev/sda1
# 18к. R-18: устройство не читается (проба) — error, а не free,
#      даже при чистом lsblk и rc=2 blkid.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
UNREADABLE_DEVS="/dev/sda1"; run_case_rc "R-18 устройство не читается" error /dev/sda1; UNREADABLE_DEVS=""
# 18л. R-18: потомок диска не читается — error (проба каждого
#      потомка в blkid-ноге, а не только самого устройства).
LSBLK_FSTYPE="ext4"; LSBLK_TYPE=$'disk\npart'; LSBLK_PATH=$'/dev/sda\n/dev/sda1'; BLKID_TABLE=""
UNREADABLE_DEVS="/dev/sda1"; run_case_rc "R-18 потомок не читается" error /dev/sda; UNREADABLE_DEVS=""
# 18м. R-18: blkid rc=2, но stderr непуст (Permission denied) —
#      error, а не free. Неоднозначность rc=2 раскрывается по stderr.
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
BLKID_STDERR="blkid: error: /dev/sda1: Permission denied"; run_case_rc "R-18 blkid stderr при rc=2" error /dev/sda1; BLKID_STDERR=""
# 18н. R-18: blkid rc=2, stderr пуст, устройство читаемо —
#      свободен (позитивный контроль: именно так выглядит чистый диск).
LSBLK_FSTYPE="ext4"; LSBLK_TYPE="part"; LSBLK_PATH="/dev/sda1"; BLKID_TABLE=""
run_case "R-18 rc=2 + пустой stderr + читаемо: свободен" free /dev/sda1

# ================= A2. R-18: реальная xros_device_readable ================
# Восстанавливаем настоящую функцию (переопределённую заглушкой
# в секции A) и тестируем её на реальных путях — без блочных
# устройств: все эти пути обязаны вернуть «не читается».
# Позитивный кейс (настоящее блочное устройство читается) здесь
# невозможен — он покрыт в D e2e: шим делает $T/fakedisk блочным,
# и чистый режим доходит до wipefs, т.е. проба прошла.
# shellcheck disable=SC1090
source "$T/readable.sh"
_probe() { # $1=имя $2=путь $3=ожидаемое(0|1)
  local name="$1" p="$2" want="$3" rc
  if xros_device_readable "$p" 2>/dev/null; then rc=0; else rc=1; fi
  if [[ "$rc" == "$want" ]]; then ok "probe $name"; else bad "probe $name (ожидалось rc $want, получено $rc)"; fi
}
_probe "несуществующий путь" /dev/nonexistent-xros-test 1
_probe "обычный файл" "$T/readable.sh" 1
_probe "каталог" "$T" 1
_probe "символьное устройство /dev/null" /dev/null 1
: > "$T/empty-file"
_probe "пустой обычный файл" "$T/empty-file" 1

# ================= B. bridge.py (Python) ====================================
if command -v python3 >/dev/null 2>&1; then
  if python3 "$ROOT/scripts/tests/test-raid-bridge.py" > "$T/bridge.out" 2>&1; then
    bsum="$(grep -oE 'PASS=[0-9]+ FAIL=0' "$T/bridge.out" | head -1)"
    ok "bridge test-raid-bridge.py пройден ($bsum)"
  else
    tail -5 "$T/bridge.out"; bad "bridge test-raid-bridge.py НЕ пройден"
  fi
else
  skip "bridge test-raid-bridge.py" "нет python3"
fi

# ================= C. system.rs (Rust) ======================================
RS="$ROOT/src/xros-install-gui-rs/src/system.rs"
grep -q 'linux_raid_member' "$RS" && ok "rust: linux_raid_member в system.rs" || bad "rust: linux_raid_member в system.rs"
grep -q 'starts_with("raid")' "$RS" && ok "rust: TYPE по префиксу raid* (starts_with)" || bad "rust: TYPE по префиксу raid* (starts_with)"
grep -q 'is_blocked_fstype(&fstype) || is_blocked_kind(kind)' "$RS" && ok "rust: list_partitions проверяет и FSTYPE, и TYPE" || bad "rust: list_partitions проверяет и FSTYPE, и TYPE"
if grep -q 'kind == "raid"' "$RS"; then bad "rust: нет точного kind == \"raid\" как единственной проверки"; else ok "rust: нет точного kind == \"raid\" как единственной проверки"; fi
# R-02: все типы fakeraid из libblkid — в is_blocked_fstype.
_RUST_FAKE_OK=1
for ft in isw_raid_member ddf_raid_member promise_fasttrack_raid_member adaptec_raid_member hpt37x_raid_member hpt45x_raid_member jmicron_raid_member lsi_mega_raid_member nvidia_raid_member silicon_medley_raid_member via_raid_member LVM1_member; do
  grep -q "\"$ft\"" "$RS" || _RUST_FAKE_OK=0
done
[[ "$_RUST_FAKE_OK" -eq 1 ]] && ok "rust: все типы fakeraid+LVM1 в system.rs" || bad "rust: все типы fakeraid+LVM1 в system.rs"
# R-03: независимая проверка blkid и трёхстатусный disk_check.
grep -q 'fn blkid_type' "$RS" && ok "rust: есть blkid_type (вторая нога)" || bad "rust: есть blkid_type (вторая нога)"
grep -q 'fn blkid_blocked' "$RS" && ok "rust: есть blkid_blocked (устройство + потомки)" || bad "rust: есть blkid_blocked (устройство + потомки)"
grep -q 'pub fn disk_check' "$RS" && ok "rust: есть disk_check (Result, а не bool)" || bad "rust: есть disk_check (Result, а не bool)"
if grep -q 'fn disk_blocked' "$RS"; then bad "rust: старый disk_blocked -> bool удалён"; else ok "rust: старый disk_blocked -> bool удалён"; fi
grep -q 'fn run_status' "$RS" && ok "rust: есть run_status (код возврата lsblk)" || bad "rust: есть run_status (код возврата lsblk)"
grep -q 'mod tests' "$RS" && ok "rust: unit-тесты в system.rs" || bad "rust: unit-тесты в system.rs"
# R-18: проба чтения в Rust — device_readable, вызов в начале disk_check
# и внутри blkid_type, непустой stderr blkid — Err.
grep -q 'fn device_readable' "$RS" && ok "rust R-18: есть device_readable" || bad "rust R-18: есть device_readable"
grep -q 'is_block_device()' "$RS" && ok "rust R-18: device_readable требует блочное устройство" || bad "rust R-18: device_readable требует блочное устройство"
if awk '/pub fn disk_check/,/^}/' "$RS" | grep -q 'device_readable(dev)'; then ok "rust R-18: disk_check начинается с пробы чтения"; else bad "rust R-18: disk_check начинается с пробы чтения"; fi
if awk '/fn blkid_type/,/^}/' "$RS" | grep -q 'device_readable(dev)'; then ok "rust R-18: blkid_type вызывает device_readable"; else bad "rust R-18: blkid_type вызывает device_readable"; fi
if awk '/fn blkid_type/,/^}/' "$RS" | grep -q 'output.stderr.is_empty()'; then ok "rust R-18: blkid_type проверяет stderr (rc=2 неоднозначен)"; else bad "rust R-18: blkid_type проверяет stderr (rc=2 неоднозначен)"; fi
grep -q 'fn device_readable_negative' "$RS" && ok "rust R-18: unit-тест device_readable_negative" || bad "rust R-18: unit-тест device_readable_negative"
grep -q 'fn disk_check_unreadable_is_error' "$RS" && ok "rust R-18: unit-тест disk_check_unreadable_is_error" || bad "rust R-18: unit-тест disk_check_unreadable_is_error"
if command -v cargo >/dev/null 2>&1; then
  if timeout 180 cargo check --offline --manifest-path "$ROOT/src/xros-install-gui-rs/Cargo.toml" > "$T/cargo.out" 2>&1; then
    ok "rust: cargo check --offline пройден"
  else
    tail -5 "$T/cargo.out"; bad "rust: cargo check --offline НЕ пройден"
  fi
  if timeout 300 cargo test --offline --manifest-path "$ROOT/src/xros-install-gui-rs/Cargo.toml" > "$T/cargo-test.out" 2>&1; then
    ok "rust: cargo test --offline пройден"
  else
    tail -5 "$T/cargo-test.out"; bad "rust: cargo test --offline НЕ пройден"
  fi
else
  skip "rust: cargo check" "cargo не установлен на этом хосте"
  skip "rust: cargo test" "cargo не установлен на этом хосте"
fi

# ================= D. РЕАЛЬНЫЙ движок в unshare ============================
REAL_ENGINE_E2E=1
ROOT_FS_TYPE="$(stat -f -c '%T' "$ROOT" 2>/dev/null || true)"
if [[ "$ROOT_FS_TYPE" == "9p" || "$ROOT_FS_TYPE" == "v9fs" ]]; then
  REAL_ENGINE_E2E=0
  for scenario in raid-lsblk raid-blkid clean lsblk-error blkid-error unreadable-missing unreadable-head; do
    skip "e2e $scenario" "тестовый checkout на $ROOT_FS_TYPE не поддерживает надёжный mount namespace"
  done
elif ! command -v gcc >/dev/null 2>&1 || ! command -v unshare >/dev/null 2>&1; then
  REAL_ENGINE_E2E=0
  skip "e2e реальный движок в unshare" "нет gcc или unshare на этом хосте"
elif ! unshare -rm sh -c 'set -e; mount -t tmpfs tmpfs /run; mountpoint -q /run; install -d -m 700 -o root -g root /run/xros-raid-probe; mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/xros-install/etc /mnt/xros-install/boot' >/dev/null 2>&1; then
  REAL_ENGINE_E2E=0
  skip "e2e реальный движок в unshare" "защищённый /run недоступен в текущем окружении"
fi
if [[ "$REAL_ENGINE_E2E" == "1" ]]; then
  # LD_PRELOAD-шим (та же идея, что в test-child-process-extended.sh).
  # XROS_FAKEBLK — список путей через ':' (диск + его разделы):
  # stat() подменяет их тип на блочное устройство, чтобы [[ -b ]]
  # и проба чтения R-18 работали на обычных файлах.
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
    ok "e2e LD_PRELOAD-шим собран (gcc)"
  else
    bad "e2e LD_PRELOAD-шим собран (gcc)"
    echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
    exit 1
  fi
  touch "$T/fakedisk"
  # R-18: узлы разделов тоже нужны как fake-блочные устройства:
  # после sgdisk движок ждёт ${DISK}1/${DISK}2 (или p1/p2) и вызывает
  # mkfs_root, а тот — пробу чтения xros_device_readable. Без узлов
  # чистый e2e-режим не доходил бы до mkfs (позитивный контроль).
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
  mkstub arch-chroot 'exit 0'
  mkstub dialog 'exit 0'
  mkstub rsync 'exit 1'
  cat > "$T/e2e/bin/blkid" <<EOF
#!/usr/bin/env bash
echo "blkid \$*" >> "$T/calls.log"
if [[ "\${LSBLK_MODE:-clean}" == "blkid-error" ]]; then exit 1; fi
case "\$*" in
  *"-p -s TYPE"*)
    if [[ "\${LSBLK_MODE:-clean}" == "raid-blkid" ]]; then echo "linux_raid_member"; fi
    ;;
esac
exit 0
EOF
  chmod +x "$T/e2e/bin/blkid"
  cat > "$T/e2e/bin/head" <<EOF
#!/usr/bin/env bash
# R-18: в режиме unreadable-head чтение fake-диска падает (как при
# исчезнувшем устройстве / ошибке ввода-вывода); остальные вызовы
# head — настоящий /usr/bin/head.
if [[ "\${XROS_HEAD_FAIL:-0}" == "1" && "\${@: -1}" == "$T/fakedisk" ]]; then exit 1; fi
exec /usr/bin/head "\$@"
EOF
  chmod +x "$T/e2e/bin/head"
  cat > "$T/e2e/bin/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$T/calls.log"
case "\$*" in
  *"-o FSTYPE"*)
    if [[ "\${LSBLK_MODE:-clean}" == "lsblk-error" ]]; then exit 1; fi
    if [[ "\${LSBLK_MODE:-clean}" == "raid-lsblk" ]]; then echo "linux_raid_member"; fi
    ;;
  *"-o TYPE"*)
    # R-04 e2e: в режиме lsblk-error падают только вызовы без -d
    # (ноги xros_disk_blocked); вызовы валидации конфига с -d
    # (lsblk -d -n -o TYPE) продолжают работать, чтобы движок дошёл
    # именно до проверки блокировки и выдал сообщение R-04.
    if [[ "\${LSBLK_MODE:-clean}" == "lsblk-error" && "\$*" != *"-d "* ]]; then exit 1; fi
    echo "disk" ;;
  *"-o PATH"*)
    if [[ "\${LSBLK_MODE:-clean}" == "lsblk-error" ]]; then exit 1; fi
    echo "\${@: -1}" ;;
  *"-o SIZE"*) echo "21474836480" ;;
  *) echo "" ;;
esac
exit 0
EOF
  chmod +x "$T/e2e/bin/lsblk"
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

  run_e2e() { # $1=имя $2=режим (raid-lsblk|raid-blkid|clean)
    local name="$1" mode="$2"
    local d="$T/e2e/$name"; mkdir -p "$d"
    # R-18: в режиме unreadable-head заглушка head падает на fake-диске.
    local head_fail=0
    [[ "$mode" == "unreadable-head" ]] && head_fail=1
    rm -f "$T/calls.log"
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
    case "$T/fakedisk" in
      "$T"/*) ;;
      *) echo "ОТКАЗ БЕЗОПАСНОСТИ: DISK вне $T" > "$d/result.txt"; return 1 ;;
    esac
    cat > "$d/inner.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
T="$T"; ENGINE="$ENGINE"
mount -t tmpfs tmpfs /run
mountpoint -q /run
mkdir -p /run/xros-install
chmod 700 /run/xros-install
mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/xros-install/etc /mnt/xros-install/boot
export XROS_FAKEBLK="$FAKEBLK_LIST"
export XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF=/run/xros-install/xros-install.conf
cp "$d/conf" "\$XROS_INSTALL_CONF"
chmod 600 "\$XROS_INSTALL_CONF"
export PATH="\$T/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LSBLK_MODE="$mode"
if setsid --wait env LD_PRELOAD="\$T/fakeblk.so" XROS_FAKEBLK="$FAKEBLK_LIST" XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF=/run/xros-install/xros-install.conf PATH="\$T/e2e/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" LSBLK_MODE="$mode" XROS_HEAD_FAIL="$head_fail" bash "\$ENGINE" > "$d/engine.out" 2>&1; then
  RC=0
else
  RC=\$?
fi
{
  echo "rc=\$RC"
  if grep -q "заблокирован" "$d/engine.out" /run/xros-install/xros-install.log 2>/dev/null; then echo "blocked_msg=yes"; else echo "blocked_msg=no"; fi
  if grep -q "не смог прочитать\|невозможно проверить" "$d/engine.out" /run/xros-install/xros-install.log 2>/dev/null; then echo "check_error=yes"; else echo "check_error=no"; fi
  # R-18 missing: движок останавливается ещё раньше — на собственной
  # проверке [[ -b \$DISK ]] («диск ... не найден»), до вызова
  # xros_disk_blocked. Это тоже безопасный стоп до wipefs, но с
  # другим сообщением — отдельный флаг, чтобы не смешивать.
  if grep -q "не найден" "$d/engine.out" /run/xros-install/xros-install.log 2>/dev/null; then echo "not_found_msg=yes"; else echo "not_found_msg=no"; fi
  grep -q "^wipefs" "\$T/calls.log" && echo "wipefs_called=yes" || echo "wipefs_called=no"
  grep -q "^sgdisk" "\$T/calls.log" && echo "sgdisk_called=yes" || echo "sgdisk_called=no"
  grep -q "^mkfs" "\$T/calls.log" && echo "mkfs_called=yes" || echo "mkfs_called=no"
  grep -q "^blkid" "\$T/calls.log" && echo "blkid_called=yes" || echo "blkid_called=no"
} > "$d/result.txt"
umount -R /mnt/xros-install 2>/dev/null || true
EOF
    chmod +x "$d/inner.sh"
    if ! unshare -rm bash "$d/inner.sh"; then
      for scenario in raid-lsblk raid-blkid clean lsblk-error blkid-error unreadable-missing unreadable-head; do
        skip "e2e $scenario" "внутренний namespace завершился с ошибкой"
      done
      echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
      [[ "$FAIL" -eq 0 ]] || exit 1
      exit 0
    fi
  }
  result_val() { grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- | head -1; }

  run_e2e "raid-lsblk" "raid-lsblk"
  R="$T/e2e/raid-lsblk/result.txt"
  [[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e raid-lsblk: движок остановился (rc!=0)" || bad "e2e raid-lsblk: движок остановился (rc!=0)"
  [[ "$(result_val "$R" blocked_msg)" == "yes" ]] && ok "e2e raid-lsblk: сообщение о блокировке" || bad "e2e raid-lsblk: сообщение о блокировке"
  [[ "$(result_val "$R" wipefs_called)" == "no" ]] && ok "e2e raid-lsblk: wipefs НЕ вызван" || bad "e2e raid-lsblk: wipefs НЕ вызван"
  [[ "$(result_val "$R" sgdisk_called)" == "no" ]] && ok "e2e raid-lsblk: sgdisk НЕ вызван" || bad "e2e raid-lsblk: sgdisk НЕ вызван"
  [[ "$(result_val "$R" mkfs_called)" == "no" ]] && ok "e2e raid-lsblk: mkfs НЕ вызван" || bad "e2e raid-lsblk: mkfs НЕ вызван"

  run_e2e "raid-blkid" "raid-blkid"
  R="$T/e2e/raid-blkid/result.txt"
  [[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e raid-blkid: движок остановился (rc!=0)" || bad "e2e raid-blkid: движок остановился (rc!=0)"
  [[ "$(result_val "$R" blocked_msg)" == "yes" ]] && ok "e2e raid-blkid: сообщение о блокировке" || bad "e2e raid-blkid: сообщение о блокировке"
  [[ "$(result_val "$R" blkid_called)" == "yes" ]] && ok "e2e raid-blkid: blkid-нога реально сработала" || bad "e2e raid-blkid: blkid-нога реально сработала"
  [[ "$(result_val "$R" wipefs_called)" == "no" ]] && ok "e2e raid-blkid: wipefs НЕ вызван" || bad "e2e raid-blkid: wipefs НЕ вызван"
  [[ "$(result_val "$R" sgdisk_called)" == "no" ]] && ok "e2e raid-blkid: sgdisk НЕ вызван" || bad "e2e raid-blkid: sgdisk НЕ вызван"
  [[ "$(result_val "$R" mkfs_called)" == "no" ]] && ok "e2e raid-blkid: mkfs НЕ вызван" || bad "e2e raid-blkid: mkfs НЕ вызван"

  run_e2e "clean" "clean"
  R="$T/e2e/clean/result.txt"
  [[ "$(result_val "$R" blocked_msg)" == "no" ]] && ok "e2e clean: блокировки нет" || bad "e2e clean: блокировки нет"
  [[ "$(result_val "$R" wipefs_called)" == "yes" ]] && ok "e2e clean: wipefs вызван (позитивный контроль)" || bad "e2e clean: wipefs вызван (позитивный контроль)"
  [[ "$(result_val "$R" sgdisk_called)" == "yes" ]] && ok "e2e clean: sgdisk вызван (позитивный контроль)" || bad "e2e clean: sgdisk вызван (позитивный контроль)"
  [[ "$(result_val "$R" mkfs_called)" == "yes" ]] && ok "e2e clean: mkfs вызван (позитивный контроль)" || bad "e2e clean: mkfs вызван (позитивный контроль)"

  # R-04: ошибка проверки lsblk/blkid — движок обязан остановиться
  # ДО разрушительных операций с понятным сообщением об ошибке.
  run_e2e "lsblk-error" "lsblk-error"
  R="$T/e2e/lsblk-error/result.txt"
  [[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e lsblk-error: движок остановился (rc!=0)" || bad "e2e lsblk-error: движок остановился (rc!=0)"
  [[ "$(result_val "$R" check_error)" == "yes" ]] && ok "e2e lsblk-error: сообщение об ошибке проверки" || bad "e2e lsblk-error: сообщение об ошибке проверки"
  [[ "$(result_val "$R" wipefs_called)" == "no" ]] && ok "e2e lsblk-error: wipefs НЕ вызван" || bad "e2e lsblk-error: wipefs НЕ вызван"
  [[ "$(result_val "$R" sgdisk_called)" == "no" ]] && ok "e2e lsblk-error: sgdisk НЕ вызван" || bad "e2e lsblk-error: sgdisk НЕ вызван"
  [[ "$(result_val "$R" mkfs_called)" == "no" ]] && ok "e2e lsblk-error: mkfs НЕ вызван" || bad "e2e lsblk-error: mkfs НЕ вызван"

  run_e2e "blkid-error" "blkid-error"
  R="$T/e2e/blkid-error/result.txt"
  [[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e blkid-error: движок остановился (rc!=0)" || bad "e2e blkid-error: движок остановился (rc!=0)"
  [[ "$(result_val "$R" check_error)" == "yes" ]] && ok "e2e blkid-error: сообщение об ошибке проверки" || bad "e2e blkid-error: сообщение об ошибке проверки"
  [[ "$(result_val "$R" wipefs_called)" == "no" ]] && ok "e2e blkid-error: wipefs НЕ вызван" || bad "e2e blkid-error: wipefs НЕ вызван"
  [[ "$(result_val "$R" sgdisk_called)" == "no" ]] && ok "e2e blkid-error: sgdisk НЕ вызван" || bad "e2e blkid-error: sgdisk НЕ вызван"
  [[ "$(result_val "$R" mkfs_called)" == "no" ]] && ok "e2e blkid-error: mkfs НЕ вызван" || bad "e2e blkid-error: mkfs НЕ вызван"

  # R-18: устройство не читается — движок обязан остановиться ДО
  # разрушительных операций (проба чтения в xros_disk_blocked).
  # (a) файл fake-диска отсутствует: [[ -b ]] не проходит.
  rm -f "$T/fakedisk"
  run_e2e "unreadable-missing" "clean"
  touch "$T/fakedisk"
  R="$T/e2e/unreadable-missing/result.txt"
  [[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e R-18 missing: движок остановился (rc!=0)" || bad "e2e R-18 missing: движок остановился (rc!=0)"
  # Движок останавливается на собственной проверке [[ -b $DISK ]]
  # («диск не найден») до xros_disk_blocked — сообщение другое,
  # но стоп до wipefs тот же. Принимается любой из двух.
  if [[ "$(result_val "$R" check_error)" == "yes" || "$(result_val "$R" not_found_msg)" == "yes" ]]; then ok "e2e R-18 missing: сообщение об ошибке проверки"; else bad "e2e R-18 missing: сообщение об ошибке проверки"; fi
  [[ "$(result_val "$R" wipefs_called)" == "no" ]] && ok "e2e R-18 missing: wipefs НЕ вызван" || bad "e2e R-18 missing: wipefs НЕ вызван"
  [[ "$(result_val "$R" sgdisk_called)" == "no" ]] && ok "e2e R-18 missing: sgdisk НЕ вызван" || bad "e2e R-18 missing: sgdisk НЕ вызван"
  [[ "$(result_val "$R" mkfs_called)" == "no" ]] && ok "e2e R-18 missing: mkfs НЕ вызван" || bad "e2e R-18 missing: mkfs НЕ вызван"
  # (b) узел есть (шим), но чтение сектора падает (заглушка head).
  run_e2e "unreadable-head" "unreadable-head"
  R="$T/e2e/unreadable-head/result.txt"
  [[ "$(result_val "$R" rc)" != "0" ]] && ok "e2e R-18 head-fail: движок остановился (rc!=0)" || bad "e2e R-18 head-fail: движок остановился (rc!=0)"
  [[ "$(result_val "$R" check_error)" == "yes" ]] && ok "e2e R-18 head-fail: сообщение об ошибке проверки" || bad "e2e R-18 head-fail: сообщение об ошибке проверки"
  [[ "$(result_val "$R" wipefs_called)" == "no" ]] && ok "e2e R-18 head-fail: wipefs НЕ вызван" || bad "e2e R-18 head-fail: wipefs НЕ вызван"
  [[ "$(result_val "$R" sgdisk_called)" == "no" ]] && ok "e2e R-18 head-fail: sgdisk НЕ вызван" || bad "e2e R-18 head-fail: sgdisk НЕ вызван"
  [[ "$(result_val "$R" mkfs_called)" == "no" ]] && ok "e2e R-18 head-fail: mkfs НЕ вызван" || bad "e2e R-18 head-fail: mkfs НЕ вызван"
fi

# ================= E. Статика: защита и синхронность =======================
# mkfs_root вызывает проверку блокировки (R-04: обёртка
# xros_require_disk_free) ДО первого mkfs.
MKFS_ROOT_START="$(grep -n '^mkfs_root() {' "$ENGINE" | cut -d: -f1)"
MKFS_ROOT_END="$(awk -v s="$MKFS_ROOT_START" 'NR>s && /^}/{print NR; exit}' "$ENGINE")"
GUARD_LINE="$(sed -n "${MKFS_ROOT_START},${MKFS_ROOT_END}p" "$ENGINE" | grep -n 'xros_require_disk_free' | head -1 | cut -d: -f1)"
FIRST_MKFS="$(sed -n "${MKFS_ROOT_START},${MKFS_ROOT_END}p" "$ENGINE" | grep -n 'mkfs\.' | head -1 | cut -d: -f1)"
if [[ -n "$GUARD_LINE" && -n "$FIRST_MKFS" && "$GUARD_LINE" -lt "$FIRST_MKFS" ]]; then
  ok "статика: mkfs_root проверяет блокировку до mkfs"
else
  bad "статика: mkfs_root проверяет блокировку до mkfs"
fi
# Повторная проверка перед wipefs (обёртка R-04).
WIPEFS_LINE="$(grep -n 'wipefs -a "\$DISK"' "$ENGINE" | head -1 | cut -d: -f1)"
RECHECK_LINE="$(grep -n 'if ! xros_require_disk_free "\$DISK"; then exit 1; fi' "$ENGINE" | tail -1 | cut -d: -f1)"
if [[ -n "$WIPEFS_LINE" && -n "$RECHECK_LINE" && "$RECHECK_LINE" -lt "$WIPEFS_LINE" ]]; then
  ok "статика: повторная проверка перед wipefs"
else
  bad "статика: повторная проверка перед wipefs"
fi
# R-04: прямых вызовов `if xros_disk_blocked` не осталось — все
# вызывающие места обязаны идти через обёртку (иначе код 2 ошибки
# трактовался бы как «свободен»).
if [[ "$(grep -c 'if xros_disk_blocked "\$' "$ENGINE")" -eq 0 ]]; then
  ok "статика: нет прямых if xros_disk_blocked (только обёртка)"
else
  bad "статика: нет прямых if xros_disk_blocked (только обёртка)"
fi
# R-18: проба чтения определена и вызывается в xros_disk_blocked
# ДО blkid-ноги; stderr blkid перехватывается, а не /dev/null.
grep -q '^xros_device_readable() {' "$ENGINE" && ok "статика R-18: xros_device_readable определена" || bad "статика R-18: xros_device_readable определена"
_BLK_START="$(grep -n '^xros_disk_blocked() {' "$ENGINE" | cut -d: -f1)"
_BLK_END="$(awk -v s="$_BLK_START" 'NR>s && /^}/{print NR; exit}' "$ENGINE")"
_PROBE_LINE="$(sed -n "${_BLK_START},${_BLK_END}p" "$ENGINE" | grep -n 'xros_device_readable "\$dev"' | head -1 | cut -d: -f1)"
_BLKID_LINE="$(sed -n "${_BLK_START},${_BLK_END}p" "$ENGINE" | grep -n 'blkid -p -s TYPE' | head -1 | cut -d: -f1)"
if [[ -n "$_PROBE_LINE" && -n "$_BLKID_LINE" && "$_PROBE_LINE" -lt "$_BLKID_LINE" ]]; then
  ok "статика R-18: проба чтения — до blkid"
else
  bad "статика R-18: проба чтения — до blkid"
fi
if grep -q 'blkid -p -s TYPE -o value "\$d" 2>"\$_blkid_err"' "$ENGINE"; then
  ok "статика R-18: stderr blkid перехватывается"
else
  bad "статика R-18: stderr blkid перехватывается"
fi
# R-02: все типы fakeraid из libblkid — в блоклисте движка.
_FAKERAID_OK=1
for ft in isw_raid_member ddf_raid_member promise_fasttrack_raid_member adaptec_raid_member hpt37x_raid_member hpt45x_raid_member jmicron_raid_member lsi_mega_raid_member nvidia_raid_member silicon_medley_raid_member via_raid_member LVM1_member; do
  grep -q "$ft" "$ENGINE" || _FAKERAID_OK=0
done
[[ "$_FAKERAID_OK" -eq 1 ]] && ok "статика: все типы fakeraid+LVM1 в блоклисте" || bad "статика: все типы fakeraid+LVM1 в блоклисте"
# Синхронность копий.
if cmp -s "$ENGINE" "$ROOT/packages/xros-installer/xros-install" \
   && cmp -s "$ENGINE" "$ROOT/profile/airootfs/usr/local/bin/xros-install"; then
  ok "статика: 3 копии xros-install идентичны"
else
  bad "статика: 3 копии xros-install идентичны"
fi
if cmp -s "$ROOT/src/xros-installer-diamond/bridge.py" \
          "$ROOT/profile/airootfs/usr/local/lib/xros-installer-diamond/bridge.py"; then
  ok "статика: 2 копии bridge.py идентичны"
else
  bad "статика: 2 копии bridge.py идентичны"
fi
# R-18 Python: проба чтения в bridge.py и её использование в disksJson.
_BR="$ROOT/src/xros-installer-diamond/bridge.py"
grep -q 'def _device_readable' "$_BR" && ok "статика R-18: _device_readable в bridge.py" || bad "статика R-18: _device_readable в bridge.py"
grep -q 'stat.S_ISBLK' "$_BR" && ok "статика R-18: bridge-проба требует блочное устройство" || bad "статика R-18: bridge-проба требует блочное устройство"
grep -q 'not _device_readable(' "$_BR" && ok "статика R-18: disksJson блокирует нечитаемые устройства" || bad "статика R-18: disksJson блокирует нечитаемые устройства"

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
if [[ $FAIL -gt 0 ]]; then
  echo "Не пройдено:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
