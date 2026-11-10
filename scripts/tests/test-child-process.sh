#!/usr/bin/env bash
# Тест управления дочерним процессом установщика XrOS.
#
# Что проверяется (БЕЗ реального форматирования диска — TARGET здесь
# обычный каталог, а umount/sync подменены заглушками через PATH):
#  T0  статика: в install.rs есть PDEATHSIG/pre_exec/setsid/getppid,
#      в src/xros-install есть trap HUP/TERM/INT + cleanup + сторож.
#  T1  падение родителя: python-симулятор родителя делает ровно то же,
#      что pre_exec в install.rs (prctl PDEATHSIG, проверка getppid,
#      setsid), затем умирает через os._exit(1) без всякой очистки.
#      Движок (РЕАЛЬНЫЙ блок из src/xros-install, извлечённый между
#      маркерами) должен завершить sleep на переднем плане, выполнить
#      cleanup и выйти за <=10 с. T1b — то же без PDEATHSIG: работает
#      только фоновый сторож родителя (проверка PPID).
#  T2  прямой SIGTERM движку: код выхода 143, в журнале причина
#      остановки + «Очистка завершена», временный файл удалён,
#      заглушка umount вызвана с TARGET, дети и внуки мертвы,
#      в stdout — INSTALL_FAILED.
#  T2b идемпотентность: два SIGTERM подряд и два прямых вызова
#      xros_cleanup — «Очистка завершена» в журнале ровно один раз.
#  T3  штатная отмена как в InstallHandle::cancel: SIGTERM всей группе
#      процессов; T3b: движок, игнорирующий SIGTERM, — после паузы
#      группа добивается SIGKILL (эскалация, как в Rust-сторожке).
#
# Запуск: scripts/tests/test-child-process.sh
# Выход 0 — все тесты PASS, иначе FAIL и список упавших.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
GUI_INSTALL="$ROOT/src/xros-install-gui-rs/src/install.rs"

PASS=0
FAIL=0
FAILED_NAMES=""

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "FAIL: $1"; }

# Ждать, пока pid исчезнет (kill -0), не дольше $2 секунд. 0 — исчез.
# Зомби (state Z) тоже считается исчезнувшим: процесс уже мёртв,
# просто родитель его ещё не подобрал wait() — а kill -0 на зомби
# всё ещё отвечает успехом.
wait_gone() {
  local pid="$1" timeout="$2" i=0 st
  while [[ $i -lt $((timeout*10)) ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    st=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
    [[ "$st" == "Z" ]] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

# Ждать появления файла, не дольше $2 секунд. 0 — появился.
wait_file() {
  local f="$1" timeout="$2" i=0
  while [[ $i -lt $((timeout*10)) ]]; do
    [[ -f "$f" ]] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

T="$(mktemp -d /tmp/xros-child-test.XXXXXX)"
echo "Рабочий каталог теста: $T"
cleanup_test() {
  # Добить всё, что могло остаться от теста (только наши pid).
  for p in "$T"/*.pid; do
    [[ -f "$p" ]] || continue
    while read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
    done < "$p"
  done
  for p in "$T"/engine-*.pid "$T"/cancel-*.pid; do
    [[ -f "$p" ]] || continue
    while read -r pid; do
      kill -KILL "$pid" 2>/dev/null || true
      kill -KILL -"$pid" 2>/dev/null || true
    done < "$p"
  done
  rm -rf "$T"
}
trap cleanup_test EXIT

# --- Заглушки umount/sync: пишут вызовы в файл, ничего не монтируют ---
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
chmod +x "$T/bin/umount" "$T/bin/sync"

# --- T0: статические проверки механизма ---
echo "== T0: статика =="
grep -q "PR_SET_PDEATHSIG" "$GUI_INSTALL" \
  && grep -q "pre_exec" "$GUI_INSTALL" \
  && grep -q "setsid" "$GUI_INSTALL" \
  && grep -q "getppid" "$GUI_INSTALL" \
  && ok "T0a install.rs: PDEATHSIG + pre_exec + setsid + getppid" \
  || bad "T0a install.rs: PDEATHSIG + pre_exec + setsid + getppid"
grep -q "InstallHandle" "$GUI_INSTALL" \
  && grep -q "kill(-self.pgid" "$GUI_INSTALL" \
  && grep -q "SIGKILL" "$GUI_INSTALL" \
  && ok "T0b install.rs: InstallHandle + kill группы + эскалация SIGKILL" \
  || bad "T0b install.rs: InstallHandle + kill группы + эскалация SIGKILL"
grep -q "trap 'xros_on_signal HUP' HUP" "$ENGINE" \
  && grep -q "trap 'xros_on_signal TERM' TERM" "$ENGINE" \
  && grep -q "trap 'xros_on_signal INT' INT" "$ENGINE" \
  && ok "T0c xros-install: trap HUP/TERM/INT" \
  || bad "T0c xros-install: trap HUP/TERM/INT"
grep -q "xros_cleanup()" "$ENGINE" \
  && grep -q "XROS_CLEANUP_DONE" "$ENGINE" \
  && grep -q "xros_watchdog" "$ENGINE" \
  && grep -q "INSTALL_FAILED" "$ENGINE" \
  && ok "T0d xros-install: cleanup + флаг идемпотентности + сторож + INSTALL_FAILED" \
  || bad "T0d xros-install: cleanup + флаг идемпотентности + сторож + INSTALL_FAILED"

# --- Извлечь РЕАЛЬНЫЙ блок защиты из движка (между маркерами) ---
BLOCK="$T/engine-block.sh"
awk '/^# --- XROS: защита дочернего процесса \(начало\) ---/{f=1; next}
     /^# --- XROS: защита дочернего процесса \(конец\) ---/{f=0}
     f' "$ENGINE" > "$BLOCK"
if [[ -s "$BLOCK" ]] && grep -q "xros_on_signal" "$BLOCK" && grep -q "xros_watchdog" "$BLOCK"; then
  ok "T0e блок защиты извлечён из src/xros-install целиком"
else
  bad "T0e блок защиты извлечён из src/xros-install целиком"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL (упавшие:$FAILED_NAMES)"
  exit 1
fi

# --- Фальшивый «движок»: реальный блок + foreground-sleep (как rsync) ---
# Аргументы: TARGET LOG TMPFILE PIDFILE CHILDRENFILE READYFILE FG_SLEEP
cat > "$T/engine-harness.sh" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -u
TARGET="$1"; LOG="$2"; TMPFILE="$3"; PIDFILE="$4"; CHILDRENFILE="$5"; READYFILE="$6"; FG_SLEEP="$7"
export PATH="$8:$PATH"
NONINTERACTIVE=1
say() { printf '%s\n' "[harness] $*" >> "$LOG"; }
# shellcheck disable=SC1090
source "$9"
echo "$$" > "$PIDFILE"
touch "$TMPFILE"
# Файлы, которые реально удаляет cleanup движка (см. xros_cleanup):
# создаём их здесь, чтобы проверить удаление. TMPFILE при этом
# cleanup удалять НЕ должен — это проверка границ очистки.
touch /tmp/xros-de-result /tmp/xros-install.conf
sleep 300 & CHILD1=$!
bash -c 'sleep 300' & CHILD2=$!
sleep 0.3
GRANDCHILD=$(ps -o pid= --ppid "$CHILD2" 2>/dev/null | tr -d ' ' | head -1)
printf '%s %s %s\n' "$CHILD1" "$CHILD2" "${GRANDCHILD:-0}" > "$CHILDRENFILE"
echo ready > "$READYFILE"
# Внешняя команда на переднем плане — как rsync в run_install:
# ловушка bash во время неё откладывается, поэтому быстрый выход
# здесь возможен только если команду убьют (группа / сторож).
sleep "$FG_SLEEP"
HARNESS_EOF
chmod +x "$T/engine-harness.sh"

# --- Симулятор родителя (python): та же последовательность, что pre_exec ---
# Аргументы: MODE(pdeath|nopdeath) PIDFILE READYFILE OUTFILE -- <команда...>
cat > "$T/parent-sim.py" <<'PY_EOF'
import ctypes, os, sys, time
libc = ctypes.CDLL("libc.so.6", use_errno=True)
PR_SET_PDEATHSIG = 1
mode, pidfile, readyfile, outfile = sys.argv[1:5]
cmd = sys.argv[6:]  # sys.argv[5] == "--"
parent_pid = os.getpid()
pid = os.fork()
if pid == 0:
    try:
        if mode == "pdeath":
            if libc.prctl(PR_SET_PDEATHSIG, 15) != 0:
                os._exit(10)
            if os.getppid() != parent_pid:
                os._exit(11)
        os.setsid()
        fd = os.open(outfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.dup2(fd, 1)
        os.dup2(fd, 2)
        os.execv(cmd[0], cmd)
    except Exception:
        os._exit(12)
    os._exit(13)
with open(pidfile, "w") as f:
    f.write(str(pid))
# Ждём, пока движок встанет (ловушки вооружены, сторож запущен,
# foreground-команда идёт), и умираем без всякой очистки — как при падении.
for _ in range(100):
    if os.path.exists(readyfile):
        break
    time.sleep(0.1)
time.sleep(0.5)
os._exit(1)  # симуляция аварийного завершения родителя
PY_EOF

run_crash_test() {
  # $1 — имя теста, $2 — режим parent-sim (pdeath|nopdeath)
  local name="$1" mode="$2"
  local d="$T/$name"; mkdir -p "$d"
  local target="$d/target"; mkdir -p "$target"
  local log="$d/engine.log" tmpfile="$d/tmpfile" pidfile="$d/engine.pid"
  local children="$d/children.pid" ready="$d/ready" out="$d/engine.out"
  rm -f "$T/umount.calls" "$T/sync.calls"
  python3 "$T/parent-sim.py" "$mode" "$pidfile" "$ready" "$out" -- \
    /bin/bash "$T/engine-harness.sh" \
    "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" &
  local sim=$!
  wait "$sim" 2>/dev/null || true  # parent-sim умирает сам через _exit(1)
  if ! wait_file "$pidfile" 5; then
    bad "$name: движок не запустился (нет pid-файла)"
    return
  fi
  local engine_pid; engine_pid=$(cat "$pidfile")
  if wait_gone "$engine_pid" 10; then
    ok "$name: движок завершён за <=10 с после смерти родителя (режим $mode)"
  else
    bad "$name: движок НЕ завершён за 10 с после смерти родителя (режим $mode)"
    kill -KILL -"$engine_pid" 2>/dev/null || true
    return
  fi
  grep -q "SIGTERM" "$log" 2>/dev/null \
    && grep -q "Очистка завершена" "$log" 2>/dev/null \
    && ok "$name: в журнале причина остановки и «Очистка завершена»" \
    || bad "$name: в журнале причина остановки и «Очистка завершена»"
  [[ ! -f /tmp/xros-de-result && ! -f /tmp/xros-install.conf ]] \
    && ok "$name: временные файлы движка удалены cleanup" \
    || bad "$name: временные файлы движка удалены cleanup"
  [[ -f "$tmpfile" ]] \
    && ok "$name: cleanup не трогает чужие файлы" \
    || bad "$name: cleanup не трогает чужие файлы"
  grep -q "umount -R $target" "$T/umount.calls" 2>/dev/null \
    && ok "$name: заглушка umount вызвана с TARGET" \
    || bad "$name: заглушка umount вызвана с TARGET"
  grep -q "INSTALL_FAILED" "$out" 2>/dev/null \
    && ok "$name: в stdout движка INSTALL_FAILED" \
    || bad "$name: в stdout движка INSTALL_FAILED"
  local alive=0
  if [[ -f "$children" ]]; then
    for p in $(cat "$children"); do
      [[ "$p" == "0" ]] && continue
      kill -0 "$p" 2>/dev/null && alive=1
    done
  fi
  [[ "$alive" == "0" ]] \
    && ok "$name: дети и внуки движка мертвы" \
    || bad "$name: дети и внуки движка мертвы"
}

echo "== T1: аварийное завершение родителя =="
run_crash_test "t1a" "pdeath"
run_crash_test "t1b" "nopdeath"

# --- T2: прямой SIGTERM движку (код выхода наблюдаем — мы его родитель) ---
echo "== T2: прямой SIGTERM + идемпотентность =="
d="$T/t2"; mkdir -p "$d"
target="$d/target"; mkdir -p "$target"
log="$d/engine.log"; tmpfile="$d/tmpfile"; pidfile="$d/engine.pid"
children="$d/children.pid"; ready="$d/ready"; out="$d/engine.out"
rm -f "$T/umount.calls" "$T/sync.calls"
# Без setsid: harness — прямой ребёнок этого скрипта, поэтому wait
# вернёт его код выхода. Сторож при этом не стартует (pgid != $$),
# но в T2 проверяется ловушка, а не сторож (он — в T1).
/bin/bash "$T/engine-harness.sh" \
  "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 5 "$T/bin" "$BLOCK" \
  > "$out" 2>&1 &
engine_pid=$!
wait_file "$ready" 5 || { bad "T2: движок не запустился"; }
kill -TERM "$engine_pid"
# wait именно движка: код выхода должен быть 143 (128+SIGTERM).
# Сначала дождаться исчезновения (ловушка откладывается до конца
# foreground-sleep, <=5 с + cleanup), потом wait вернёт код сразу.
wait_gone "$engine_pid" 15 || { bad "T2: движок не завершён после SIGTERM"; }
wait "$engine_pid" 2>/dev/null; rc=$?
if [[ "$rc" == "143" ]]; then
  ok "T2a: код выхода движка 143 после SIGTERM"
else
  bad "T2a: код выхода движка 143 после SIGTERM (получено $rc)"
fi
grep -q "SIGTERM" "$log" 2>/dev/null && grep -q "Очистка завершена" "$log" 2>/dev/null \
  && ok "T2b: в журнале причина остановки и «Очистка завершена»" \
  || bad "T2b: в журнале причина остановки и «Очистка завершена»"
[[ ! -f /tmp/xros-de-result && ! -f /tmp/xros-install.conf ]] \
  && ok "T2c: временные файлы движка удалены cleanup" \
  || bad "T2c: временные файлы движка удалены cleanup"
[[ -f "$tmpfile" ]] \
  && ok "T2c2: cleanup не трогает чужие файлы" \
  || bad "T2c2: cleanup не трогает чужие файлы"
grep -q "umount -R $target" "$T/umount.calls" 2>/dev/null \
  && ok "T2d: заглушка umount вызвана с TARGET" \
  || bad "T2d: заглушка umount вызвана с TARGET"
grep -q "INSTALL_FAILED" "$out" 2>/dev/null \
  && ok "T2e: в stdout движка INSTALL_FAILED" \
  || bad "T2e: в stdout движка INSTALL_FAILED"
alive=0
for p in $(cat "$children" 2>/dev/null || true); do
  [[ "$p" == "0" ]] && continue
  kill -0 "$p" 2>/dev/null && alive=1
done
[[ "$alive" == "0" ]] \
  && ok "T2f: дети и внуки движка мертвы" \
  || bad "T2f: дети и внуки движка мертвы"

# T2b: два SIGTERM подряд — cleanup ровно один раз
d="$T/t2b"; mkdir -p "$d"
target="$d/target"; mkdir -p "$target"
log="$d/engine.log"; tmpfile="$d/tmpfile"; pidfile="$d/engine.pid"
children="$d/children.pid"; ready="$d/ready"; out="$d/engine.out"
/bin/bash "$T/engine-harness.sh" \
  "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 5 "$T/bin" "$BLOCK" \
  > "$out" 2>&1 &
engine_pid=$!
wait_file "$ready" 5 || { bad "T2g: движок не запустился"; }
# Прямой SIGTERM одному движку во время foreground-команды: ловушка
# bash выполняется только после её конца (<=5 с). Второй TERM шлём,
# пока первая ловушка ещё висит в ожидании, — cleanup всё равно
# должен выполниться ровно один раз (флаг + снятие ловушек).
kill -TERM "$engine_pid"; sleep 0.3; kill -TERM "$engine_pid" 2>/dev/null || true
wait_gone "$engine_pid" 15 || { bad "T2g: движок не завершён после двойного SIGTERM"; }
n=$(grep -c "Очистка завершена" "$log" 2>/dev/null || true)
[[ "$n" == "1" ]] \
  && ok "T2g: двойной SIGTERM — cleanup выполнен ровно один раз" \
  || bad "T2g: двойной SIGTERM — cleanup выполнен ровно один раз (строк: $n)"

# T2h: два прямых вызова xros_cleanup — второй no-op
d="$T/t2h"; mkdir -p "$d"
cat > "$d/idem.sh" <<EOF
#!/usr/bin/env bash
set -u
TARGET="$d/target"; LOG="$d/engine.log"; NONINTERACTIVE=1
mkdir -p "\$TARGET"
export PATH="$T/bin:\$PATH"
say() { printf '%s\n' "[harness] \$*" >> "\$LOG"; }
source "$BLOCK"
xros_cleanup
xros_cleanup
echo "second call rc=\$?"
EOF
mkdir -p "$d/target"
bash "$d/idem.sh" > "$d/out" 2>&1; rc=$?
n=$(grep -c "Очистка завершена" "$d/engine.log" 2>/dev/null || true)
if [[ "$rc" == "0" && "$n" == "1" ]] && grep -q "second call rc=0" "$d/out"; then
  ok "T2h: повторный xros_cleanup — no-op, журнал не дублируется"
else
  bad "T2h: повторный xros_cleanup — no-op, журнал не дублируется (rc=$rc, строк: $n)"
fi

# --- T3: штатная отмена — SIGTERM всей группе (как InstallHandle::cancel) ---
echo "== T3: отмена через убийство группы =="
d="$T/t3"; mkdir -p "$d"
target="$d/target"; mkdir -p "$target"
log="$d/engine.log"; tmpfile="$d/tmpfile"; pidfile="$d/engine.pid"
children="$d/children.pid"; ready="$d/ready"; out="$d/engine.out"
rm -f "$T/umount.calls"
setsid /bin/bash "$T/engine-harness.sh" \
  "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" \
  > "$out" 2>&1 &
wait_file "$ready" 5 || { bad "T3: движок не запустился"; }
engine_pid=$(cat "$pidfile")
# SIGTERM группе (минус перед pgid; движок — лидер группы после setsid)
kill -TERM -"$engine_pid"
if wait_gone "$engine_pid" 5; then
  ok "T3a: SIGTERM группе — движок завершён за <=5 с"
else
  bad "T3a: SIGTERM группе — движок завершён за <=5 с"
  kill -KILL -"$engine_pid" 2>/dev/null || true
fi
grep -q "Очистка завершена" "$log" 2>/dev/null \
  && ok "T3b: cleanup выполнен при отмене группой" \
  || bad "T3b: cleanup выполнен при отмене группой"
alive=0
for p in $(cat "$children" 2>/dev/null || true); do
  [[ "$p" == "0" ]] && continue
  kill -0 "$p" 2>/dev/null && alive=1
done
[[ "$alive" == "0" ]] \
  && ok "T3c: дети и внуки мертвы после SIGTERM группе" \
  || bad "T3c: дети и внуки мертвы после SIGTERM группе"

# T3b: движок, игнорирующий SIGTERM, — эскалация SIGKILL группе
cat > "$d/stubborn.sh" <<'STUB_EOF'
#!/usr/bin/env bash
trap '' TERM
echo "$$" > "$1"
echo ready > "$2"
sleep 300
STUB_EOF
chmod +x "$d/stubborn.sh"
setsid /bin/bash "$d/stubborn.sh" "$d/stubborn.pid" "$d/stubborn.ready" &
disown 2>/dev/null || true
wait_file "$d/stubborn.ready" 5 || { bad "T3d: упрямый движок не запустился"; }
stub_pid=$(cat "$d/stubborn.pid")
kill -TERM -"$stub_pid"
sleep 2
if kill -0 "$stub_pid" 2>/dev/null; then
  ok "T3d: упрямый движок пережил SIGTERM группе (эскалация нужна)"
  kill -KILL -"$stub_pid"
  if wait_gone "$stub_pid" 5; then
    ok "T3e: SIGKILL группе добивает упрямый движок за <=5 с"
  else
    bad "T3e: SIGKILL группе добивает упрямый движок за <=5 с"
  fi
else
  bad "T3d: упрямый движок пережил SIGTERM группе (эскалация нужна)"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL (упавшие:$FAILED_NAMES)"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
