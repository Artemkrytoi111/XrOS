#!/usr/bin/env bash
# Расширенный тест отмены установки XrOS (сценарии E1–E10).
#
# Дополняет scripts/tests/test-child-process.sh (T0–T3, 33 PASS).
# Каждый сценарий — отдельный тест с PASS/FAIL/SKIP.
#
# Соответствие сценариям из задания:
#  E1  кнопка отмены в GUI (реальный GUI не собирается: cargo нет на
#      хосте, готового бинаря нет — симуляция gui-sim.py, которая делает
#      ровно те же вызовы, что InstallHandle::cancel в install.rs:
#      SIGTERM группе + grace 5 с + SIGKILL; + статика проводки кнопки)
#  E2  SIGTERM GUI (gui-sim умирает от SIGTERM извне)
#  E3  SIGKILL GUI (gui-sim умирает от SIGKILL извне)
#  E4  потеря родителя (parent-sim умирает; PDEATHSIG и/или сторож)
#  E5  гибель дочернего движка (GUI-sim должен заметить Finished и не зависнуть)
#  E6  гибель потомка (rsync-заглушка убита извне) — РЕАЛЬНЫЙ движок
#  E7  двойная отмена (два cancel() подряд)
#  E8  ошибка копирования (rsync-заглушка -> ошибка) — РЕАЛЬНЫЙ движок
#  E9  ошибка подготовки разделов (mkfs-заглушка -> ошибка) — РЕАЛЬНЫЙ движок
#  E10 закрытие системы во время операции: статика обработчиков + честный
#      SKIP живого теста (нужна реальная перезагрузка)
#
# БЕЗОПАСНОСТЬ. Настоящие диски НЕ трогаются вообще:
#  * «диск» — обычный файл $T/fakedisk; LD_PRELOAD-шим подменяет только
#    бит типа файла для ЭТОГО пути (stat/lstat -> S_IFBLK), чтобы
#    [[ -b $DISK ]] в движке проходил; остальные файлы не меняются;
#  * все дисковые утилиты (sgdisk/mkfs/wipefs/partprobe/lsblk/blkid) —
#    заглушки из PATH, ничего не форматируют;
#  * mount/umount-заглушки делают НАСТОЯЩИЙ tmpfs-mount только на
#    $TARGET внутри `unshare -rm` (свой mount/user namespace, /mnt —
#    tmpfs); после теста пространство имён умирает вместе с mount'ами;
#  * DISK/ROOT_PART проверяются: цель обязана лежать в $T (mktemp),
#    иначе тест падает до запуска движка. /dev/sd*, /dev/nvme*,
#    /dev/vd*, /dev/hd* как цели запрещены и никогда не используются.
#
# Запуск: scripts/tests/test-child-process-extended.sh
# Выход 0 — все проверки PASS/SKIP, иначе FAIL и список упавших.
# Повторные запуски: каждый запуск использует свежий mktemp-каталог.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
GUI_INSTALL="$ROOT/src/xros-install-gui-rs/src/install.rs"
GUI_APP="$ROOT/src/xros-install-gui-rs/src/app.rs"
GUI_STEPS="$ROOT/src/xros-install-gui-rs/src/steps.rs"

PASS=0
FAIL=0
SKIPN=0
FAILED_NAMES=""

ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES $1"; echo "FAIL: $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP: $1"; }

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

# Строже wait_gone: pid должен полностью исчезнуть из /proc
# (не остаться зомби — systemd как PID 1 должен его подобрать).
wait_vanished() {
  local pid="$1" timeout="$2" i=0
  while [[ $i -lt $((timeout*10)) ]]; do
    [[ -d "/proc/$pid" ]] || return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

wait_file() {
  local f="$1" timeout="$2" i=0
  while [[ $i -lt $((timeout*10)) ]]; do
    [[ -f "$f" ]] && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

# 0 — процесс жив (не зомби), 1 — мёртв или зомби.
pid_alive() {
  local p="$1" st
  kill -0 "$p" 2>/dev/null || return 1
  st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null || true)
  [[ "$st" == "Z" ]] && return 1
  return 0
}

T="$(mktemp -d /tmp/xros-cancel-test.XXXXXX)"
echo "Рабочий каталог теста: $T"
cleanup_test() {
  for p in "$T"/*.pid "$T"/*/*.pid "$T"/*/rsync*.pid; do
    [[ -f "$p" ]] || continue
    while read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$pid" 2>/dev/null || true
      kill -KILL -"$pid" 2>/dev/null || true
    done < "$p" 2>/dev/null || true
  done
  rm -rf "$T"
}
trap cleanup_test EXIT

# --- Извлечь РЕАЛЬНЫЙ блок защиты из движка (между маркерами) ---
BLOCK="$T/engine-block.sh"
awk '/^# --- XROS: защита дочернего процесса \(начало\) ---/{f=1; next}
     /^# --- XROS: защита дочернего процесса \(конец\) ---/{f=0}
     f' "$ENGINE" > "$BLOCK"
if [[ -s "$BLOCK" ]] && grep -q "xros_on_signal" "$BLOCK" && grep -q "xros_watchdog" "$BLOCK"; then
  ok "E0a блок защиты извлечён из src/xros-install целиком"
else
  bad "E0a блок защиты извлечён из src/xros-install целиком"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN (упавшие:$FAILED_NAMES)"
  exit 1
fi

# --- LD_PRELOAD-шим: один тестовый файл выглядит блочным устройством ---
# Нужен только для [[ -b $DISK ]] в РЕАЛЬНОМ движке: mknod запрещён,
# /dev пуст, loop-устройств нет. Шим трогает только путь из
# $XROS_FAKEBLK, код движка не меняется.
cat > "$T/fakeblk.c" <<'C_EOF'
#define _GNU_SOURCE
#include <sys/stat.h>
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
static const char *tgt(void){ return getenv("XROS_FAKEBLK"); }
static void fake_mode(struct stat *st){
  if (S_ISREG(st->st_mode)) st->st_mode = (st->st_mode & ~S_IFMT) | S_IFBLK;
}
int stat(const char *p, struct stat *b){ static int (*r)(const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"stat"); int rc=r(p,b); const char *t=tgt(); if(rc==0&&t&&strcmp(p,t)==0) fake_mode(b); return rc; }
int lstat(const char *p, struct stat *b){ static int (*r)(const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"lstat"); int rc=r(p,b); const char *t=tgt(); if(rc==0&&t&&strcmp(p,t)==0) fake_mode(b); return rc; }
int __xstat(int v, const char *p, struct stat *b){ static int (*r)(int,const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"__xstat"); int rc=r(v,p,b); const char *t=tgt(); if(rc==0&&t&&strcmp(p,t)==0) fake_mode(b); return rc; }
int __lxstat(int v, const char *p, struct stat *b){ static int (*r)(int,const char*,struct stat*)=0; if(!r) r=dlsym(RTLD_NEXT,"__lxstat"); int rc=r(v,p,b); const char *t=tgt(); if(rc==0&&t&&strcmp(p,t)==0) fake_mode(b); return rc; }
C_EOF
if gcc -shared -fPIC -o "$T/fakeblk.so" "$T/fakeblk.c" -ldl 2>/dev/null; then
  ok "E0b LD_PRELOAD-шим собран (gcc)"
else
  bad "E0b LD_PRELOAD-шим собран (gcc)"
  echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN (упавшие:$FAILED_NAMES)"
  exit 1
fi
touch "$T/fakedisk"
if XROS_FAKEBLK="$T/fakedisk" LD_PRELOAD="$T/fakeblk.so" bash -c "test -b '$T/fakedisk'"; then
  ok "E0c шим: bash видит тестовый файл как блочное устройство"
else
  bad "E0c шим: bash видит тестовый файл как блочное устройство"
fi
if XROS_FAKEBLK="$T/fakedisk" LD_PRELOAD="$T/fakeblk.so" bash -c "test -b /etc/hostname" 2>/dev/null; then
  bad "E0d шим не трогает остальные файлы"
else
  ok "E0d шим не трогает остальные файлы"
fi

# --- Заглушки umount/sync для harness-тестов (только запись вызовов) ---
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

# --- Харнесс движка v2: реальный блок + писатель «копии» + сентинелы ---
# Аргументы: TARGET LOG TMPFILE PIDFILE CHILDRENFILE READYFILE FG_SLEEP STUBBIN BLOCK SENTINEL_SHA
cat > "$T/engine-harness2.sh" <<'HARNESS_EOF'
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
touch /tmp/xros-de-result /tmp/xros-install.conf
# Сентинелы «уже установленной системы»: cleanup не должен их трогать.
mkdir -p "$TARGET/etc" "$TARGET/boot"
echo "sentinel-passwd-content" > "$TARGET/etc/passwd-sentinel"
echo "sentinel-vmlinuz-content" > "$TARGET/boot/vmlinuz-sentinel"
sha256sum "$TARGET/etc/passwd-sentinel" "$TARGET/boot/vmlinuz-sentinel" > "${10}"
# «Копирование»: писатель дописывает в TARGET каждые 0.2 с (макс. 900
# итераций = 3 мин, чтобы не жить вечно при провале теста).
( for i in $(seq 1 900); do echo "$(date +%s%N) chunk-$i" >> "$TARGET/copy-progress.log"; sleep 0.2; done ) &
WRITER=$!
sleep 300 & CHILD1=$!
bash -c 'sleep 300' & CHILD2=$!
sleep 0.3
GRANDCHILD=$(ps -o pid= --ppid "$CHILD2" 2>/dev/null | tr -d ' ' | head -1)
printf '%s %s %s %s\n' "$CHILD1" "$CHILD2" "${GRANDCHILD:-0}" "$WRITER" > "$CHILDRENFILE"
echo ready > "$READYFILE"
# Внешняя команда на переднем плане — как rsync в run_install.
sleep "$FG_SLEEP"
HARNESS_EOF
chmod +x "$T/engine-harness2.sh"

# --- Фейковый движок для clean-exit: прогресс + INSTALL_DONE, код 0 ---
cat > "$T/fake-engine-done.sh" <<'FAKE_EOF'
#!/usr/bin/env bash
echo ready > "$1"
echo "10"; echo "XXX"; echo "Копирование..."; echo "XXX"
sleep 1
echo "INSTALL_DONE"
exit 0
FAKE_EOF
chmod +x "$T/fake-engine-done.sh"

# --- Симулятор родителя (python): как pre_exec в install.rs ---
cat > "$T/parent-sim2.py" <<'PY_EOF'
import ctypes, os, sys, time
libc = ctypes.CDLL("libc.so.6", use_errno=True)
PR_SET_PDEATHSIG = 1
mode, pidfile, readyfile, outfile = sys.argv[1:5]
cmd = sys.argv[6:]
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
for _ in range(100):
    if os.path.exists(readyfile):
        break
    time.sleep(0.1)
time.sleep(0.5)
os._exit(1)
PY_EOF

# --- Симулятор GUI (python): то же, что install.rs:start_install +
# InstallHandle::cancel + поток чтения stdout. НЕ настоящий egui-GUI
# (cargo нет на хосте, бинаря нет): те же системные вызовы в том же
# порядке — prctl PDEATHSIG, проверка getppid, setsid, pipe stdout,
# SIGTERM группе + grace 5 с + SIGKILL, wait() только в потоке чтения.
# Режимы: cancel | double-cancel | kill-engine | clean-exit | run-and-wait
#   GUI_SIM_OUT — файл результата, GUI_SIM_READY — файл готовности,
#   GUI_SIM_PIDFILE — pid симулятора (только run-and-wait),
#   GUI_KILL_GROUP_ON_CRASH=1 — гасить группу при неожиданной смерти
#     движка (в текущем коде Rust этого нет — см. E5).
cat > "$T/gui-sim.py" <<'PY_EOF'
import ctypes, os, sys, threading, time, subprocess, signal
libc = ctypes.CDLL("libc.so.6", use_errno=True)
PR_SET_PDEATHSIG = 1
MODE = sys.argv[1]
CMD = sys.argv[2:]
OUT = os.environ["GUI_SIM_OUT"]
READY = os.environ["GUI_SIM_READY"]
KILL_GROUP_ON_CRASH = os.environ.get("GUI_KILL_GROUP_ON_CRASH", "0") == "1"
CANCEL_GRACE_MS = int(os.environ.get("GUI_CANCEL_GRACE_MS", "5000"))
parent_pid = os.getpid()

def preexec():
    if libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM) != 0:
        os._exit(10)
    if os.getppid() != parent_pid:
        os._exit(11)
    if libc.setsid() == -1:
        os._exit(12)

proc = subprocess.Popen(CMD, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=preexec)
pgid = proc.pid  # после setsid pid == pgid
events = []
saw_done = False
finished = threading.Event()
cancelled = False

def reader():
    global saw_done
    try:
        for raw in proc.stdout:
            line = raw.decode(errors="replace").strip()
            if line == "INSTALL_DONE":
                saw_done = True
                events.append(("Finished", True))
                finished.set()
            elif line == "INSTALL_FAILED":
                saw_done = True
                events.append(("Finished", False))
                finished.set()
    except Exception as e:
        events.append(("reader_error", repr(e)))
    try:
        rc = proc.wait(timeout=10)
    except Exception:
        rc = None
    if not saw_done:
        ok = (rc == 0)
        if not ok and KILL_GROUP_ON_CRASH:
            try:
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            time.sleep(0.5)
            try:
                os.killpg(pgid, 0)
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
        events.append(("Finished", bool(ok)))
        finished.set()

def cancel():
    global cancelled
    cancelled = True
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    def grace():
        deadline = time.time() + CANCEL_GRACE_MS / 1000.0
        while time.time() < deadline:
            if proc.poll() is not None:
                return
            time.sleep(0.1)
        if proc.poll() is None:
            try:
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
    threading.Thread(target=grace, daemon=True).start()

def write_result(extra):
    # Маркер INSTALL_FAILED приходит чуть раньше выхода движка
    # (как и в настоящем GUI: drain_events ждёт is_running()==false
    # до 2 с). Дожидаемся реального выхода, иначе poll() вернёт None.
    try:
        proc.wait(timeout=10)
    except Exception:
        pass
    with open(OUT, "w") as f:
        f.write("returncode=%s\n" % (proc.poll(),))
        f.write("cancelled=%s\n" % (cancelled,))
        f.write("events=%s\n" % (events,))
        for k, v in extra.items():
            f.write("%s=%s\n" % (k, v))

t = threading.Thread(target=reader, daemon=True)
t.start()
te = threading.Thread(target=lambda: [l for l in proc.stderr], daemon=True)
te.start()
for _ in range(100):
    if os.path.exists(READY):
        break
    time.sleep(0.1)
time.sleep(0.5)
if MODE == "cancel":
    cancel()
    ok = finished.wait(timeout=15)
    write_result({"finished_seen": ok})
elif MODE == "double-cancel":
    th1 = threading.Thread(target=cancel)
    th2 = threading.Thread(target=lambda: (time.sleep(0.2), cancel()))
    th1.start(); th2.start(); th1.join(); th2.join()
    ok = finished.wait(timeout=15)
    write_result({"finished_seen": ok})
elif MODE == "kill-engine":
    os.kill(proc.pid, signal.SIGKILL)
    t0 = time.time()
    ok = finished.wait(timeout=10)
    write_result({"finished_seen": ok, "finished_secs": round(time.time() - t0, 2)})
elif MODE == "clean-exit":
    ok = finished.wait(timeout=10)
    write_result({"finished_seen": ok})
elif MODE == "run-and-wait":
    with open(os.environ["GUI_SIM_PIDFILE"], "w") as f:
        f.write(str(os.getpid()))
    while True:
        time.sleep(3600)
else:
    write_result({"error": "unknown mode %s" % MODE})
PY_EOF

# ================= E1: кнопка отмены в GUI =================
echo "== E1: кнопка отмены в GUI (симуляция InstallHandle::cancel) =="
# E1a: статика проводки кнопки (реальный GUI не собирается — cargo нет).
grep -q 'Остановить установку' "$GUI_STEPS" \
  && grep -q 'confirm_cancel = true' "$GUI_STEPS" \
  && ok "E1a steps.rs: кнопка «Остановить установку» -> confirm_cancel" \
  || bad "E1a steps.rs: кнопка «Остановить установку» -> confirm_cancel"
grep -q 'Да, остановить' "$GUI_APP" \
  && grep -q 'cancel_install()' "$GUI_APP" \
  && ok "E1b app.rs: диалог подтверждения -> cancel_install()" \
  || bad "E1b app.rs: диалог подтверждения -> cancel_install()"
grep -q 'h.cancel()' "$GUI_APP" \
  && grep -q 'fn cancel_install' "$GUI_APP" \
  && ok "E1c app.rs: cancel_install() -> InstallHandle::cancel()" \
  || bad "E1c app.rs: cancel_install() -> InstallHandle::cancel()"
grep -q 'signal_group(libc::SIGTERM)' "$GUI_INSTALL" \
  && grep -q 'CANCEL_GRACE_MS' "$GUI_INSTALL" \
  && grep -q 'libc::SIGKILL' "$GUI_INSTALL" \
  && ok "E1d install.rs: cancel = SIGTERM группе + grace + SIGKILL" \
  || bad "E1d install.rs: cancel = SIGTERM группе + grace + SIGKILL"
grep -q 'was_cancelled()' "$GUI_APP" \
  && grep -q 'остановлена по вашему запросу' "$GUI_APP" \
  && ok "E1e app.rs: Finished после отмены -> «остановлена по запросу», а не ошибка" \
  || bad "E1e app.rs: Finished после отмены -> «остановлена по запросу», а не ошибка"
grep -q 'CancelClose' "$GUI_APP" \
  && ok "E1f app.rs: случайное закрытие окна во время установки заблокировано" \
  || bad "E1f app.rs: случайное закрытие окна во время установки заблокировано"

# E1g: поведение — gui-sim в режиме cancel (тот же кодовый путь).
d="$T/e1"; mkdir -p "$d"
target="$d/target"; mkdir -p "$target"
log="$d/engine.log"; tmpfile="$d/tmpfile"; pidfile="$d/engine.pid"
children="$d/children.pid"; ready="$d/ready"; out="$d/engine.out"
rm -f "$T/umount.calls" "$T/sync.calls"
GUI_SIM_OUT="$d/gui.out" GUI_SIM_READY="$ready" GUI_KILL_GROUP_ON_CRASH=0 \
  python3 "$T/gui-sim.py" cancel /bin/bash "$T/engine-harness2.sh" \
  "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" "$d/sentinel.before" \
  > "$d/gui.stdout" 2>&1
sim_rc=$?
if [[ "$sim_rc" == "0" ]] && grep -q "finished_seen=True" "$d/gui.out" && grep -q "Finished.*False" "$d/gui.out"; then
  ok "E1g: cancel() -> Finished(false) за <=15 с, симулятор не завис"
else
  bad "E1g: cancel() -> Finished(false) за <=15 с, симулятор не завис (rc=$sim_rc)"
fi
grep -q "returncode=143" "$d/gui.out" \
  && ok "E1h: движок завершён с кодом 143 (SIGTERM), а не SIGKILL" \
  || bad "E1h: движок завершён с кодом 143 (SIGTERM), а не SIGKILL"
grep -q "Очистка завершена" "$log" 2>/dev/null \
  && grep -q "SIGTERM" "$log" 2>/dev/null \
  && ok "E1i: cleanup выполнен, причина в журнале" \
  || bad "E1i: cleanup выполнен, причина в журнале"
[[ ! -f /tmp/xros-de-result && ! -f /tmp/xros-install.conf ]] \
  && ok "E1j: временные файлы движка удалены" \
  || bad "E1j: временные файлы движка удалены"
grep -q "umount -R $target" "$T/umount.calls" 2>/dev/null \
  && ok "E1k: umount вызван с TARGET" \
  || bad "E1k: umount вызван с TARGET"
alive=0
for p in $(cat "$children" 2>/dev/null || true); do
  [[ "$p" == "0" ]] && continue
  pid_alive "$p" && alive=1
done
[[ "$alive" == "0" ]] \
  && ok "E1l: дети, внуки и писатель «копии» мертвы" \
  || bad "E1l: дети, внуки и писатель «копии» мертвы"
if [[ -f "$d/sentinel.before" ]] && (cd / && sha256sum -c "$d/sentinel.before" >/dev/null 2>&1); then
  ok "E1m: сентинелы «установленной системы» в TARGET целы"
else
  bad "E1m: сентинелы «установленной системы» в TARGET целы"
fi

# ================= E2/E3: SIGTERM / SIGKILL самому GUI =================
run_gui_death_test() {
  # $1 — имя, $2 — сигнал (TERM|KILL)
  local name="$1" sig="$2"
  local d="$T/$name"; mkdir -p "$d"
  local target="$d/target"; mkdir -p "$target"
  local log="$d/engine.log" tmpfile="$d/tmpfile" pidfile="$d/engine.pid"
  local children="$d/children.pid" ready="$d/ready"
  rm -f "$T/umount.calls" "$T/sync.calls"
  GUI_SIM_OUT="$d/gui.out" GUI_SIM_READY="$ready" GUI_SIM_PIDFILE="$d/sim.pid" \
    python3 "$T/gui-sim.py" run-and-wait /bin/bash "$T/engine-harness2.sh" \
    "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" "$d/sentinel.before" \
    > "$d/gui.stdout" 2>&1 &
  local sim=$!
  wait_file "$d/sim.pid" 5 || { bad "$name: симулятор GUI не запустился"; return; }
  local sim_pid; sim_pid=$(cat "$d/sim.pid")
  wait_file "$pidfile" 5 || { bad "$name: движок не запустился"; kill -KILL "$sim_pid" 2>/dev/null || true; return; }
  local engine_pid; engine_pid=$(cat "$pidfile")
  kill -"$sig" "$sim_pid"
  wait_gone "$sim_pid" 5 || { bad "$name: GUI не умер от SIG$sig"; }
  if wait_gone "$engine_pid" 10; then
    ok "$name: движок завершён за <=10 с после SIG$sig GUI (PDEATHSIG)"
  else
    bad "$name: движок завершён за <=10 с после SIG$sig GUI (PDEATHSIG)"
    kill -KILL -"$engine_pid" 2>/dev/null || true
    return
  fi
  grep -q "Очистка завершена" "$log" 2>/dev/null \
    && ok "$name: cleanup выполнен" \
    || bad "$name: cleanup выполнен"
  [[ ! -f /tmp/xros-de-result && ! -f /tmp/xros-install.conf ]] \
    && ok "$name: временные файлы удалены" \
    || bad "$name: временные файлы удалены"
  grep -q "umount -R $target" "$T/umount.calls" 2>/dev/null \
    && ok "$name: umount вызван с TARGET" \
    || bad "$name: umount вызван с TARGET"
  local alive=0
  for p in $(cat "$children" 2>/dev/null || true); do
    [[ "$p" == "0" ]] && continue
    pid_alive "$p" && alive=1
  done
  [[ "$alive" == "0" ]] \
    && ok "$name: дети, внуки и писатель «копии» мертвы" \
    || bad "$name: дети, внуки и писатель «копии» мертвы"
  if [[ -f "$d/sentinel.before" ]] && (cd / && sha256sum -c "$d/sentinel.before" >/dev/null 2>&1); then
    ok "$name: сентинелы TARGET целы"
  else
    bad "$name: сентинелы TARGET целы"
  fi
  # Писатель «копии» должен остановиться: размер лога стабилен 2 с.
  if [[ -f "$target/copy-progress.log" ]]; then
    local s1 s2
    s1=$(stat -c %s "$target/copy-progress.log"); sleep 2
    s2=$(stat -c %s "$target/copy-progress.log")
    [[ "$s1" == "$s2" ]] \
      && ok "$name: запись в TARGET остановилась (размер лога стабилен)" \
      || bad "$name: запись в TARGET остановилась (размер лога стабилен: $s1 -> $s2)"
  else
    ok "$name: запись в TARGET остановилась (лог копии не создавался)"
  fi
}

echo "== E2: SIGTERM GUI =="
run_gui_death_test "e2" "TERM"
echo "== E3: SIGKILL GUI =="
run_gui_death_test "e3" "KILL"

# ================= E4: потеря родителя =================
run_parent_loss_test() {
  # $1 — имя, $2 — режим (pdeath|nopdeath)
  local name="$1" mode="$2"
  local d="$T/$name"; mkdir -p "$d"
  local target="$d/target"; mkdir -p "$target"
  local log="$d/engine.log" tmpfile="$d/tmpfile" pidfile="$d/engine.pid"
  local children="$d/children.pid" ready="$d/ready" out="$d/engine.out"
  rm -f "$T/umount.calls" "$T/sync.calls"
  python3 "$T/parent-sim2.py" "$mode" "$pidfile" "$ready" "$out" -- \
    /bin/bash "$T/engine-harness2.sh" \
    "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" "$d/sentinel.before" &
  local sim=$!
  wait "$sim" 2>/dev/null || true
  if ! wait_file "$pidfile" 5; then
    bad "$name: движок не запустился (нет pid-файла)"
    return
  fi
  local engine_pid; engine_pid=$(cat "$pidfile")
  if wait_gone "$engine_pid" 10; then
    ok "$name: движок завершён за <=10 с после смерти родителя (режим $mode)"
  else
    bad "$name: движок завершён за <=10 с после смерти родителя (режим $mode)"
    kill -KILL -"$engine_pid" 2>/dev/null || true
    return
  fi
  if wait_vanished "$engine_pid" 5; then
    ok "$name: движок полностью исчез из /proc (без зомби)"
  else
    bad "$name: движок полностью исчез из /proc (без зомби)"
  fi
  grep -q "Очистка завершена" "$log" 2>/dev/null \
    && ok "$name: cleanup выполнен" \
    || bad "$name: cleanup выполнен"
  [[ ! -f /tmp/xros-de-result && ! -f /tmp/xros-install.conf ]] \
    && ok "$name: временные файлы удалены" \
    || bad "$name: временные файлы удалены"
  local alive=0
  for p in $(cat "$children" 2>/dev/null || true); do
    [[ "$p" == "0" ]] && continue
    pid_alive "$p" && alive=1
  done
  [[ "$alive" == "0" ]] \
    && ok "$name: дети, внуки и писатель «копии» мертвы" \
    || bad "$name: дети, внуки и писатель «копии» мертвы"
  if [[ -f "$target/copy-progress.log" ]]; then
    local s1 s2
    s1=$(stat -c %s "$target/copy-progress.log"); sleep 2
    s2=$(stat -c %s "$target/copy-progress.log")
    [[ "$s1" == "$s2" ]] \
      && ok "$name: запись в TARGET остановилась (размер лога стабилен)" \
      || bad "$name: запись в TARGET остановилась (размер лога стабилен: $s1 -> $s2)"
  else
    ok "$name: запись в TARGET остановилась (лог копии не создавался)"
  fi
  if [[ -f "$d/sentinel.before" ]] && (cd / && sha256sum -c "$d/sentinel.before" >/dev/null 2>&1); then
    ok "$name: сентинелы TARGET целы"
  else
    bad "$name: сентинелы TARGET целы"
  fi
}

echo "== E4: потеря родителя =="
run_parent_loss_test "e4a" "pdeath"
run_parent_loss_test "e4b" "nopdeath"

# ================= E5: гибель дочернего движка =================
echo "== E5: гибель движка (SIGKILL) — GUI должен заметить и не зависнуть =="
d="$T/e5"; mkdir -p "$d"
target="$d/target"; mkdir -p "$target"
log="$d/engine.log"; tmpfile="$d/tmpfile"; pidfile="$d/engine.pid"
children="$d/children.pid"; ready="$d/ready"
GUI_SIM_OUT="$d/gui.out" GUI_SIM_READY="$ready" GUI_KILL_GROUP_ON_CRASH=0 \
  python3 "$T/gui-sim.py" kill-engine /bin/bash "$T/engine-harness2.sh" \
  "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" "$d/sentinel.before" \
  > "$d/gui.stdout" 2>&1
sim_rc=$?
if [[ "$sim_rc" == "0" ]] && grep -q "finished_seen=True" "$d/gui.out" && grep -q "Finished.*False" "$d/gui.out"; then
  ok "E5a: GUI заметил гибель движка (Finished(false)), не завис"
else
  bad "E5a: GUI заметил гибель движка (Finished(false)), не завис (rc=$sim_rc)"
fi
fsecs=$(grep -o 'finished_secs=[0-9.]*' "$d/gui.out" | cut -d= -f2 || echo "?")
echo "E5a: время до Finished: ${fsecs} с (лимит 5 с)"
if [[ -n "$fsecs" && "$fsecs" != "?" ]]; then
  awk -v s="$fsecs" 'BEGIN { exit (s <= 5) ? 0 : 1 }' \
    && ok "E5b: Finished пришёл за <=5 с (сторож движка гасит группу)" \
    || bad "E5b: Finished пришёл за <=5 с (сторож движка гасит группу)"
else
  bad "E5b: Finished пришёл за <=5 с (сторож движка гасит группу)"
fi
engine_pid=$(cat "$pidfile" 2>/dev/null || echo 0)
if [[ "$engine_pid" != "0" ]] && wait_vanished "$engine_pid" 5; then
  ok "E5c: движок полностью исчез из /proc (без зомби — wait() в потоке чтения)"
else
  bad "E5c: движок полностью исчез из /proc (без зомби — wait() в потоке чтения)"
fi
alive=0
for p in $(cat "$children" 2>/dev/null || true); do
  [[ "$p" == "0" ]] && continue
  pid_alive "$p" && alive=1
done
[[ "$alive" == "0" ]] \
  && ok "E5d: дети и внуки движка мертвы (сторож + SIGTERM группе)" \
  || bad "E5d: дети и внуки движка мертвы (сторож + SIGTERM группе)"
# E5e: clean-exit — движок нормально завершается с INSTALL_DONE.
d="$T/e5e"; mkdir -p "$d"
GUI_SIM_OUT="$d/gui.out" GUI_SIM_READY="$d/ready" GUI_KILL_GROUP_ON_CRASH=0 \
  python3 "$T/gui-sim.py" clean-exit /bin/bash "$T/fake-engine-done.sh" "$d/ready" \
  > "$d/gui.stdout" 2>&1
sim_rc=$?
if [[ "$sim_rc" == "0" ]] && grep -q "finished_seen=True" "$d/gui.out" && grep -q "Finished.*True" "$d/gui.out"; then
  ok "E5e: штатный выход движка -> Finished(true), без зависания"
else
  bad "E5e: штатный выход движка -> Finished(true), без зависания (rc=$sim_rc)"
fi

# ================= E6/E8/E9: РЕАЛЬНЫЙ движок в unshare =================
# Заглушки внешних утилит для реального движка (общие на все запуски).
mkdir -p "$T/realbin"
mkstub() { # $1=имя, $2=тело
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\n%s\n' "$1" "$T" "$2" > "$T/realbin/$1"
  chmod +x "$T/realbin/$1"
}
mkstub sgdisk 'exit 0'
mkstub wipefs 'exit 0'
mkstub partprobe 'exit 0'
mkstub mkfs.ext4 'exit ${MKFS_FAIL:-0}'
mkstub mkfs.fat 'exit 0'
mkstub mkfs.btrfs 'exit ${MKFS_FAIL:-0}'
mkstub mkfs.xfs 'exit ${MKFS_FAIL:-0}'
mkstub blkid 'exit 0'
mkstub findmnt 'exit 1'
mkstub genfstab 'exit 0'
mkstub arch-chroot 'exit 0'
mkstub dialog 'exit 0'
cat > "$T/realbin/lsblk" <<EOF
#!/usr/bin/env bash
echo "lsblk \$*" >> "$T/calls.log"
case "\$*" in *"-o TYPE"*) echo "disk";; *) echo "";; esac
exit 0
EOF
chmod +x "$T/realbin/lsblk"
# mount: записать вызов и сделать НАСТОЯЩИЙ tmpfs-mount на TARGET
# (внутри unshare — приватно пространству имён).
cat > "$T/realbin/mount" <<EOF
#!/usr/bin/env bash
echo "mount \$*" >> "$T/calls.log"
tgt="\${@: -1}"
/bin/mount -t tmpfs tmpfs "\$tgt"
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
# rsync: fail — сразу ошибка; slow — «долгое копирование» (writer +
# exec sleep 60, чтобы kill pid'а заглушки убивал именно копирование).
# mkstub печёт путь $T/calls.log в файл (quoted heredoc оставил бы
# литеральный $T, и вызовы писались бы в /calls.log).
mkstub rsync $'if [[ "${RSYNC_MODE:-fail}" == "fail" ]]; then\n  exit 1\nfi\ntgt="${@: -1}"\n( for i in $(seq 1 600); do echo "$(date +%s%N) chunk-$i" >> "$tgt/copy.log"; sleep 0.2; done ) &\necho $! > "${RSYNC_WRITER_PID:-/tmp/xros-no-writer.pid}"\necho "$$" > "${RSYNC_PIDFILE:-/tmp/xros-no-rsync.pid}"\nexec sleep 60'

# Запустить РЕАЛЬНЫЙ src/xros-install в unshare -rm.
# $1=name $2=rsync_mode(fail|slow) $3=mkfs_fail(0|1) $4=kill_rsync(0|1)
# Результат — файл $T/$1/result.txt (ключи key=value).
run_real_engine() {
  local name="$1" rsync_mode="$2" mkfs_fail="$3" kill_rsync="$4"
  local d="$T/$name"; mkdir -p "$d"
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
  # Защита: цель — только наш тестовый файл внутри $T.
  case "$T/fakedisk" in
    "$T"/*) ;;
    *) echo "ОТКАЗ БЕЗОПАСНОСТИ: DISK вне $T" > "$d/result.txt"; return 1 ;;
  esac
  cat > "$d/inner.sh" <<EOF
#!/usr/bin/env bash
set -u
T="$T"; ENGINE="$ENGINE"
mount -t tmpfs tmpfs /mnt
mkdir -p /mnt/xros-install/etc /mnt/xros-install/boot
echo "sentinel-passwd-content" > /mnt/xros-install/etc/passwd-sentinel
echo "sentinel-vmlinuz-content" > /mnt/xros-install/boot/vmlinuz-sentinel
sha256sum /mnt/xros-install/etc/passwd-sentinel /mnt/xros-install/boot/vmlinuz-sentinel > "$d/sentinel.before"
export XROS_FAKEBLK="\$T/fakedisk"
export XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf"
export PATH="\$T/realbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export RSYNC_MODE="$rsync_mode" MKFS_FAIL="$mkfs_fail"
export RSYNC_PIDFILE="$d/rsync.pid" RSYNC_WRITER_PID="$d/rsync-writer.pid"
ENG_CMD=(setsid --wait env LD_PRELOAD="\$T/fakeblk.so" XROS_FAKEBLK="\$T/fakedisk" XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF="$d/conf" PATH="\$T/realbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" RSYNC_MODE="$rsync_mode" MKFS_FAIL="$mkfs_fail" RSYNC_PIDFILE="$d/rsync.pid" RSYNC_WRITER_PID="$d/rsync-writer.pid" bash "\$ENGINE")
if [[ "$kill_rsync" == "1" ]]; then
  "\${ENG_CMD[@]}" > "$d/engine.out" 2>&1 &
  ENG=\$!
  for i in \$(seq 1 50); do [[ -f "$d/rsync.pid" ]] && break; sleep 0.1; done
  if [[ -f "$d/rsync.pid" ]]; then
    kill -KILL "\$(cat "$d/rsync.pid")" 2>/dev/null || true
  else
    echo "rsync pidfile MISSING" >> "$d/inner.log"
  fi
  wait "\$ENG"; RC=\$?
else
  "\${ENG_CMD[@]}" > "$d/engine.out" 2>&1
  RC=\$?
fi
{
  echo "rc=\$RC"
  grep -q "INSTALL_FAILED" "$d/engine.out" && echo "stdout_install_failed=yes" || echo "stdout_install_failed=no"
  grep -q "INSTALL_DONE" "$d/engine.out" && echo "stdout_install_done=yes" || echo "stdout_install_done=no"
  grep -q "Очистка завершена" /tmp/xros-install.log && echo "log_cleanup=yes" || echo "log_cleanup=no"
  grep -q "TestPass123" /tmp/xros-install.log && echo "log_password_leak=yes" || echo "log_password_leak=no"
  grep -q "/mnt/xros-install" /proc/mounts && echo "target_mounted=yes" || echo "target_mounted=no"
  if [[ -f /mnt/xros-install/etc/passwd-sentinel ]]; then (cd / && sha256sum -c "$d/sentinel.before" >/dev/null 2>&1 && echo "sentinel=ok" || echo "sentinel=CHANGED"); else echo "sentinel=HIDDEN"; fi
  test -f "$d/conf" && echo "conf=exists" || echo "conf=removed"
  echo "umount_calls=\$(grep -c '^umount' "\$T/calls.log" 2>/dev/null || true)"
  grep -q "^rsync" "\$T/calls.log" && echo "rsync_called=yes" || echo "rsync_called=no"
  grep -q "mkfs.ext4" "\$T/calls.log" && echo "mkfs_called=yes" || echo "mkfs_called=no"
  if [[ -f "$d/rsync-writer.pid" ]]; then WPID=\$(cat "$d/rsync-writer.pid"); kill -0 "\$WPID" 2>/dev/null && echo "writer=ALIVE" || echo "writer=dead"; else echo "writer=n/a"; fi
  if [[ -f "$d/rsync.pid" ]]; then RPID=\$(cat "$d/rsync.pid"); kill -0 "\$RPID" 2>/dev/null && echo "rsync=ALIVE" || echo "rsync=dead"; else echo "rsync=n/a"; fi
} > "$d/result.txt"
umount -R /mnt/xros-install 2>/dev/null || true
EOF
  chmod +x "$d/inner.sh"
  unshare -rm bash "$d/inner.sh"
}

result_val() { # $1=result.txt $2=ключ
  grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- | head -1
}

# ================= E8: ошибка копирования (rsync -> 1) =================
echo "== E8: ошибка во время копирования (реальный движок, rsync=1) =="
run_real_engine "e8" "fail" 0 0
R="$T/e8/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "E8a: движок вышел с кодом 1" \
  || bad "E8a: движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "E8b: в stdout INSTALL_FAILED" \
  || bad "E8b: в stdout INSTALL_FAILED"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "E8c: cleanup выполнен (в журнале «Очистка завершена»)" \
  || bad "E8c: cleanup выполнен (в журнале «Очистка завершена»)"
[[ "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "E8d: TARGET размонтирован (настоящий tmpfs-mount снят)" \
  || bad "E8d: TARGET размонтирован (настоящий tmpfs-mount снят)"
[[ "$(result_val "$R" sentinel)" == "ok" ]] \
  && ok "E8e: сентинелы «установленной системы» целы" \
  || bad "E8e: сентинелы «установленной системы» целы ($(result_val "$R" sentinel))"
[[ "$(result_val "$R" conf)" == "removed" ]] \
  && ok "E8f: конфиг с паролями удалён" \
  || bad "E8f: конфиг с паролями удалён"
[[ "$(result_val "$R" log_password_leak)" == "no" ]] \
  && ok "E8g: пароль не утёк в журнал установки" \
  || bad "E8g: пароль не утёк в журнал установки"
uc=$(result_val "$R" umount_calls); uc=${uc:-0}
[[ "$uc" -ge 2 ]] \
  && ok "E8h: umount вызван >=2 раз (до разметки + cleanup), вызовов: $uc" \
  || bad "E8h: umount вызван >=2 раз (до разметки + cleanup), вызовов: $uc"

# ================= E9: ошибка подготовки разделов (mkfs -> 1) =================
echo "== E9: ошибка во время подготовки разделов (реальный движок, mkfs=1) =="
run_real_engine "e9" "fail" 1 0
R="$T/e9/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "E9a: движок вышел с кодом 1" \
  || bad "E9a: движок вышел с кодом 1 (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "E9b: в stdout INSTALL_FAILED" \
  || bad "E9b: в stdout INSTALL_FAILED"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "E9c: cleanup выполнен (в журнале «Очистка завершена»)" \
  || bad "E9c: cleanup выполнен (в журнале «Очистка завершена»)"
[[ "$(result_val "$R" rsync_called)" == "no" ]] \
  && ok "E9d: копирование не началось после ошибки mkfs" \
  || bad "E9d: копирование не началось после ошибки mkfs"
[[ "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "E9e: TARGET не смонтирован" \
  || bad "E9e: TARGET не смонтирован"
[[ "$(result_val "$R" sentinel)" == "ok" ]] \
  && ok "E9f: сентинелы «установленной системы» целы" \
  || bad "E9f: сентинелы «установленной системы» целы ($(result_val "$R" sentinel))"
[[ "$(result_val "$R" conf)" == "removed" ]] \
  && ok "E9g: конфиг с паролями удалён" \
  || bad "E9g: конфиг с паролями удалён"
uc=$(result_val "$R" umount_calls); uc=${uc:-0}
[[ "$uc" -ge 2 ]] \
  && ok "E9h: umount вызван >=2 раз (до разметки + cleanup), вызовов: $uc" \
  || bad "E9h: umount вызван >=2 раз (до разметки + cleanup), вызовов: $uc"

# ================= E6: гибель потомка (rsync убит извне) =================
echo "== E6: гибель процесса-потомка (реальный движок, rsync SIGKILL) =="
run_real_engine "e6" "slow" 0 1
R="$T/e6/result.txt"
[[ "$(result_val "$R" rc)" == "1" ]] \
  && ok "E6a: движок вышел с кодом 1 после гибели rsync" \
  || bad "E6a: движок вышел с кодом 1 после гибели rsync (получено: $(result_val "$R" rc))"
[[ "$(result_val "$R" stdout_install_failed)" == "yes" ]] \
  && ok "E6b: в stdout INSTALL_FAILED" \
  || bad "E6b: в stdout INSTALL_FAILED"
[[ "$(result_val "$R" log_cleanup)" == "yes" ]] \
  && ok "E6c: cleanup выполнен" \
  || bad "E6c: cleanup выполнен"
[[ "$(result_val "$R" rsync)" == "dead" ]] \
  && ok "E6d: процесс rsync мёртв" \
  || bad "E6d: процесс rsync мёртв ($(result_val "$R" rsync))"
[[ "$(result_val "$R" writer)" == "dead" ]] \
  && ok "E6e: внук rsync (писатель «копии») мёртв — не продолжает писать" \
  || bad "E6e: внук rsync (писатель «копии») мёртв — не продолжает писать ($(result_val "$R" writer))"
[[ "$(result_val "$R" target_mounted)" == "no" ]] \
  && ok "E6f: TARGET размонтирован" \
  || bad "E6f: TARGET размонтирован"
[[ "$(result_val "$R" sentinel)" == "ok" ]] \
  && ok "E6g: сентинелы «установленной системы» целы" \
  || bad "E6g: сентинелы «установленной системы» целы ($(result_val "$R" sentinel))"

# ================= E7: повторная отмена =================
echo "== E7: двойная отмена (два cancel() подряд) =="
d="$T/e7"; mkdir -p "$d"
target="$d/target"; mkdir -p "$target"
log="$d/engine.log"; tmpfile="$d/tmpfile"; pidfile="$d/engine.pid"
children="$d/children.pid"; ready="$d/ready"
rm -f "$T/umount.calls" "$T/sync.calls"
GUI_SIM_OUT="$d/gui.out" GUI_SIM_READY="$ready" GUI_KILL_GROUP_ON_CRASH=0 \
  python3 "$T/gui-sim.py" double-cancel /bin/bash "$T/engine-harness2.sh" \
  "$target" "$log" "$tmpfile" "$pidfile" "$children" "$ready" 30 "$T/bin" "$BLOCK" "$d/sentinel.before" \
  > "$d/gui.stdout" 2>&1
sim_rc=$?
if [[ "$sim_rc" == "0" ]] && grep -q "finished_seen=True" "$d/gui.out" && grep -q "Finished.*False" "$d/gui.out"; then
  ok "E7a: двойной cancel() -> Finished(false), симулятор не завис и не упал"
else
  bad "E7a: двойной cancel() -> Finished(false), симулятор не завис и не упал (rc=$sim_rc)"
fi
grep -q "returncode=143" "$d/gui.out" \
  && ok "E7b: движок завершён с кодом 143 (SIGTERM), второй cancel НЕ дал SIGKILL" \
  || bad "E7b: движок завершён с кодом 143 (SIGTERM), второй cancel НЕ дал SIGKILL"
n=$(grep -c "Очистка завершена" "$log" 2>/dev/null || true)
[[ "$n" == "1" ]] \
  && ok "E7c: cleanup выполнен ровно один раз (без двойного завершения)" \
  || bad "E7c: cleanup выполнен ровно один раз (без двойного завершения; строк: $n)"
nfin=$(grep -o "Finished" "$d/gui.out" | wc -l)
[[ "$nfin" == "1" ]] \
  && ok "E7d: событие Finished отправлено ровно один раз" \
  || bad "E7d: событие Finished отправлено ровно один раз (получено: $nfin)"
grep -q "cancelled=True" "$d/gui.out" \
  && ok "E7e: флаг отмены установлен (идемпотентный AtomicBool)" \
  || bad "E7e: флаг отмены установлен (идемпотентный AtomicBool)"

# ================= E10: закрытие системы во время операции =================
echo "== E10: закрытие системы во время операции =="
grep -q "trap 'xros_on_signal HUP' HUP" "$ENGINE" \
  && grep -q "trap 'xros_on_signal TERM' TERM" "$ENGINE" \
  && grep -q "trap 'xros_on_signal INT' INT" "$ENGINE" \
  && ok "E10a движок: ловушки HUP/TERM/INT вооружены (systemd при выключении шлёт SIGTERM)" \
  || bad "E10a движок: ловушки HUP/TERM/INT вооружены (systemd при выключении шлёт SIGTERM)"
grep -q "xros_cleanup" "$ENGINE" \
  && grep -q "umount -R \"\$TARGET\"" "$ENGINE" \
  && ok "E10b движок: обработчик делает cleanup с размонтированием TARGET" \
  || bad "E10b движок: обработчик делает cleanup с размонтированием TARGET"
if grep -rq "ctrlc\|signal-hook\|nix::sys::signal\|libc::signal" "$ROOT/src/xros-install-gui-rs/src/" 2>/dev/null; then
  bad "E10c GUI: нет своих обработчиков сигналов (SIGTERM по умолчанию убивает GUI -> PDEATHSIG гасит движок)"
else
  ok "E10c GUI: нет своих обработчиков сигналов (SIGTERM по умолчанию убивает GUI -> PDEATHSIG гасит движок)"
fi
grep -q "PR_SET_PDEATHSIG" "$GUI_INSTALL" \
  && ok "E10d GUI: PDEATHSIG страхует движок при гибели GUI на выключении" \
  || bad "E10d GUI: PDEATHSIG страхует движок при гибели GUI на выключении"
skip "E10e живой тест выключения/перезагрузки во время установки: нужна реальная перезагрузка живой системы — в этом окружении недоступна (контейнер, нет ISO/ВМ). Проверены только обработчики и cleanup-логика (E10a–E10d)."

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN (упавшие:$FAILED_NAMES)"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
