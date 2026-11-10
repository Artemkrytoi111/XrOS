# Управление дочерним процессом установщика (задача 3, финальная доработка)

Дата: 2026-11-10. Проблема из AUDIT-REPORT.md §5.1 (C5): если GUI установщика
аварийно завершается, дочерний `xros-install` мог продолжить
форматирование/копирование системы без интерфейса. Исправлено.

## 0. Важное уточнение к исходной посылке задачи

В задаче сказано, что движок «уже имеет %q-экранирование паролей и ловушки
сигналов (проверь, что есть)». Проверка показала:

- `%q`-экранирование — **есть** (в `run_install`, `printf -v ... %q`).
- Ловушки сигналов — **НЕ БЫЛО вообще**: `grep trap src/xros-install`
  давал 0 совпадений, `xros_cleanup` не существовал. Ловушки, cleanup
  и сторож родителя написаны с нуля в этой задаче.
- Подтверждено проверкой кода: закрытие окна во время установки
  действительно было запрещено (`CancelClose` в `app.rs` + неактивная
  кнопка «Отмена»). Отмена из GUI была невозможна в принципе.

## 1. Что изменено

### 1.1 `src/xros-install-gui-rs/src/install.rs` — отслеживание и убийство дочернего процесса

- Новая структура **`InstallHandle`** (хранится в `App`, пока идёт установка):
  `child: Arc<Mutex<Child>>`, `pgid: i32`, `cancelled: Arc<AtomicBool>>`.
- `start_install` теперь возвращает `(Receiver<InstallEvent>, InstallHandle)`
  вместо одного `Receiver`.
- **`pre_exec` в `Command`** (до `exec`, в дочернем процессе между `fork`
  и `exec`), порядок операций:
  1. `prctl(PR_SET_PDEATHSIG, SIGTERM)` — ядро шлёт движку SIGTERM,
     как только умирает родитель (GUI). Работает, даже когда GUI уже не
     может выполнить ни одной инструкции (падение, `kill`, OOM).
  2. Проверка `getppid() == pid GUI` сразу после `prctl` — закрывает
     единственную гонку: родитель может умереть между `fork` и `prctl`,
     тогда дочерний уже переродительствован (init/sub-reaper), и PDEATHSIG
     относился бы к новому родителю, а не к GUI. Несовпадение —
     `Err(ESRCH)`, `spawn` возвращает ошибку, движок не запускается.
  3. `setsid()` — движок становится лидером своей группы процессов
     (`pgid == pid` движка). `kill(-pgid, SIGTERM)` при отмене гасит не
     только сам `xros-install`, но и `rsync` / `arch-chroot` / `mkfs`,
     которые обычный `Child::kill()` оставил бы сиротами дописывать
     систему в фоне. PDEATHSIG такого не даёт: он бьёт только в прямой
     дочерний процесс, а не в его детей.
- **Зачем два механизма** (задокументировано в комментарии к `InstallHandle`):
  PDEATHSIG — страховка от *аварийной* смерти GUI (ядро, без участия GUI);
  группа процессов — для *штатной* отмены из GUI и для внуков движка.
- `InstallHandle::cancel()`: флаг `cancelled`, `SIGTERM` всей группе,
  фоновый сторож: опрос `try_wait` каждые 100 мс, если за 5 с (`CANCEL_GRACE_MS`)
  движок не ушёл — `SIGKILL` группе. `cancel()` не делает `wait()`:
  единственный, кто ждёт движок и шлёт `Finished`, — поток чтения stdout
  (двойной `wait()` дал бы `ECHILD`).
- `Drop` для `InstallHandle`: если движок каким-то образом ещё жив при
  сбросе ручки — `SIGTERM` группе без ожидания (последняя страховка;
  при аварийном завершении самого GUI `Drop` не выполняется — там работает
  только PDEATHSIG).
- `pre_exec` в актуальном `std` — `unsafe fn` (E0133): вызов обёрнут в
  `unsafe` с `SAFETY`-комментарием. Замыкание делает только
  async-signal-safe вызовы без аллокаций (`prctl`/`getppid`/`setsid`,
  ошибки — `last_os_error` / `from_raw_os_error(ESRCH)`).
- `was_cancelled()` — флаг отмены для `App` (используется в `drain_events`).

### 1.2 `src/xros-install-gui-rs/src/app.rs` — отмена и сообщения

- Поля `App`: `child: Option<InstallHandle>`, `confirm_cancel: bool`
  (дублирующий флаг `cancel_requested` убран — его роль выполняет
  `InstallHandle::was_cancelled()`).
- `cancel_install()`: `SIGTERM` группе через ручку + статус
  «Остановка установки… Движок завершает работу и размонтирует диск.»
- `drain_events()` при `Finished(false)` различает отмену и ошибку:
  отмена — «Установка остановлена по вашему запросу… Разметка диска может
  быть незавершённой — повторите установку с начала» + хвост журнала;
  ошибка — прежний текст. Перед сбросом ручки `drain_events` дожидается
  реального выхода движка (опрос `is_running`, до ~2 с): движок печатает
  `INSTALL_DONE`/`INSTALL_FAILED` чуть раньше своего выхода, и без этого
  `Drop` ручки послал бы `SIGTERM` уже завершающемуся движку, а также
  остался бы зомби (его подбирает `try_wait` в `Drop`/`is_running`).
- Случайное закрытие окна (крестик/Alt+F4) во время установки **по-прежнему
  заблокировано** (`CancelClose`, комментарий обновлён): остановка — только
  осознанной кнопкой «Остановить установку» с подтверждением.
- Диалог подтверждения остановки (окно «Остановить установку»,
  «Да, остановить» / «Продолжить установку»).

### 1.3 `src/xros-install-gui-rs/src/steps.rs` — кнопка остановки

- На шаге Install во время установки — кнопка «Остановить установку»
  (открывает диалог подтверждения). `start_install` теперь сохраняет
  ручку в `app.child`. Отмена до начала установки — просто закрытие
  окна: движок ещё не запущен, разрушительных операций нет.

### 1.4 `src/xros-install` — ловушки, cleanup, сторож родителя (только этот блок!)

Добавлен блок между маркерами
`# --- XROS: защита дочернего процесса (начало) ---` /
`# --- XROS: защита дочернего процесса (конец) ---`
(строки ~60–160). Логика разметки, пакетов DE и GRUB **не менялась**.
Ловушки ставятся ПОСЛЕ перевыполнения через `sudo` (`exec` сбрасывает
ловушки, ставить раньше бессмысленно).

- `trap 'xros_on_signal HUP' HUP`, `TERM`, `INT`.
- `xros_on_signal`: первым делом `trap - HUP TERM INT` (повторный сигнал
  во время очистки не вызывает cleanup второй раз и не убивает процесс
  на середине `umount`); причина остановки в `XROS_STOP_REASON`
  (`SIGHUP`/`SIGTERM`/`SIGINT` с расшифровкой); `xros_cleanup`;
  в неинтерактивном режиме — `INSTALL_FAILED` в stdout (GUI ждёт маркер;
  в интерактивном режиме stdout — `dialog --gauge`, маркер туда нельзя);
  выход 129/143/130 (128+сигнал).
- `xros_cleanup()` — **идемпотентна**: флаг `XROS_CLEANUP_DONE` (повторный
  вызов — no-op), порядок: сначала `xros_kill_children`, потом
  `umount -R "$TARGET"`, удаление `/tmp/xros-de-result`
  и `/tmp/xros-install.conf`, `sync`, запись в журнал
  («Остановка установки (…) — очистка…» / «Очистка завершена:
  $TARGET размонтирован, временные файлы удалены»). Журнал `$LOG`
  намеренно НЕ удаляется — он нужен для диагностики.
- `xros_kill_children()` + `xros_descendants()`: гасит потомков движка
  рекурсивно по дереву (`ps --ppid`, дети/внуки — `arch-chroot` прячет
  за собой ещё один bash): сначала `SIGTERM`, через 2 с — `SIGKILL`
  выжившим. Порядок важен: если сначала размонтировать, `rsync`
  продолжит писать в `$TARGET` уже после `umount` — записи уйдут
  в живую систему вместо целевого диска.
- **Сторож родителя** (`xros_watchdog`, фоновая проверка «родитель жив»):
  раз в секунду сравнивает свой `PPID` с исходным; при смене (GUI умер,
  движок переродительствован) шлёт `SIGTERM` всей группе.
  Зачем он нужен, если есть PDEATHSIG — ключевая находка задачи:
  `bash` **откладывает выполнение ловушки, пока ждёт внешнюю команду
  на переднем плане** (`rsync`, `mkfs`, `pacman` в chroot — минуты).
  PDEATHSIG будит только сам движок, а его ловушка не выполнится,
  пока не кончится текущая внешняя команда. Сторож же шлёт `SIGTERM`
  всей группе: внешние команды умирают сразу, и ловушка выполняется.
  Запускается, только если движок — лидер своей группы (`pgid == $$`,
  так делает GUI через `setsid`); иначе `SIGTERM` группе мог бы задеть
  чужие процессы. При штатном выходе движка сторож глушится `EXIT`-ловушкой.

## 2. Тесты: `scripts/tests/test-child-process.sh` (новый файл)

Тест реально запускается (`bash scripts/tests/test-child-process.sh`),
даёт `PASS`/`FAIL` по каждому пункту, выход 0 — только если все `PASS`.
Без реального форматирования диска: `TARGET` — обычный каталог,
`umount`/`sync` подменены заглушками через `PATH`; временные файлы
движка — реальные (`/tmp/xros-de-result`, `/tmp/xros-install.conf`).

- **T0** (статика): `install.rs` — `PR_SET_PDEATHSIG` + `pre_exec` +
  `setsid` + `getppid`; `InstallHandle` + `kill` группы + эскалация
  `SIGKILL`; движок — `trap HUP/TERM/INT`, `cleanup`, флаг
  идемпотентности, сторож, `INSTALL_FAILED`. Блок защиты извлекается
  из `src/xros-install` между маркерами целиком — тесты гоняют
  **реальный код**, а не копию логики.
- **T1** (падение родителя): python-симулятор родителя (`ctypes`,
  `prctl`) делает ровно ту же последовательность, что `pre_exec` в Rust
  (`PDEATHSIG` → проверка `getppid` → `setsid`), затем умирает через
  `os._exit(1)` без очистки. Движок — реальный блок из движка +
  foreground-`sleep 30` (как `rsync`): должен завершить sleep, выполнить
  cleanup и выйти за ≤10 с; в журнале — причина и «Очистка завершена»,
  временные файлы удалены, `umount` вызван с `TARGET`, в stdout —
  `INSTALL_FAILED`, дети и внуки мертвы. **T1a** — с PDEATHSIG,
  **T1b** — без PDEATHSIG (работает только сторож родителя).
- **T2** (прямой `SIGTERM`): код выхода **143**, журнал, удаление
  временных файлов, `umount` с `TARGET`, `INSTALL_FAILED`, дети/внуки
  мертвы. **T2b**: два `SIGTERM` подряд — cleanup ровно один раз.
  **T2h**: два прямых вызова `xros_cleanup` — второй no-op, журнал
  не дублируется.
- **T3** (штатная отмена, как `InstallHandle::cancel`): `SIGTERM` всей
  группе — движок завершён за ≤5 с, cleanup выполнен, дети/внуки мертвы.
  **T3b**: движок, игнорирующий `SIGTERM`, — после паузы группа
  добивается `SIGKILL` (эскалация, как в Rust-сторожке).

### Результаты прогонов

| Прогон | Результат | Время |
|---|---|---|
| 1-й | **26 PASS / 5 FAIL** — все 5 FAIL были ошибками самого теста, а не кода: тест проверял удаление произвольного файла harness'а (а cleanup удаляет только свои реальные временные файлы) и слал прямой `SIGTERM` во время foreground-`sleep 30` (известное откладывание ловушки bash — см. §1.4). Тест исправлен, код не менялся. | ~32 с |
| 2-й | **33 PASS / 0 FAIL**, exit 0 | ~28 с |
| 3-й (на финальном коде, после правок по `cargo check`) | **33 PASS / 0 FAIL**, exit 0 | ~28 с |

## 3. Проверка кода

- `bash -n src/xros-install` — **OK**.
- `cargo check --offline` для `src/xros-install-gui-rs` — **PASS, 0 ошибок,
  0 warning'ов**. Выполнено в chroot `~/workspace/akvt-os/root.x86_64`
  (только для проверки, chroot не изменялся; bind-mount `~/workspace/xros`
  в `/xros` внутри chroot, `CARGO_HOME=/home/hatch/.cargo` — кэш cargo
  внутри chroot, `rustc 1.99.1`). На хосте `cargo` отсутствует.
  По ходу проверки `cargo check` нашёл 2 настоящие ошибки в моём коде,
  обе исправлены: `pre_exec` — `unsafe fn` (E0133) и `unused_mut`;
  затем 4 warning'а (лишние `unsafe`-блоки внутри замыкания и
  неиспользуемый `was_cancelled`) — тоже исправлены, `was_cancelled`
  задействован в `app.rs`, дублирующий флаг `cancel_requested` удалён.
  Артефакт проверки: `src/xros-install-gui-rs/target/` (~228 МБ кэша
  сборки; можно удалить, ускорит только повторные проверки).
- `cargo clippy --offline` — **честный SKIP, не выполнен**. Причина —
  окружение, а не код: пакет `rust` в chroot поставляет бинари
  `clippy-driver`/`cargo-clippy`, но в sysroot нет ни одной библиотеки
  линт-крейтов clippy (`/usr/lib/rustlib/x86_64-unknown-linux-gnu/lib/` —
  0 совпадений с `clippy`). Внутренний `rustc` падает с
  `package 'clippy' was not found`, а каскадные ошибки `<anon>`/E0554 —
  это переподача этого текста как исходника. `clippy-driver` на
  тривиальном файле работает, ручной probe проходит — ломается именно
  загрузка линт-крейтов. Исправление — вне моих полномочий здесь:
  нужен полный тулчейн с компонентом clippy (на хосте сборки, не в
  этом chroot: его изменять, кроме кэша cargo, запрещено).
  Где проверить: на машине с рабочим `cargo clippy` (rustup,
  компонент `clippy`), командой из §4.

## 4. Спецификация проверок для `scripts/xros-diagnose.sh`

Готовые shell-фрагменты (координатор вставляет в диагностику как есть;
пути — от корня репозитория):

```sh
# GUI: PDEATHSIG + pre_exec + setsid + проверка getppid (закрытие гонки)
grep -q "PR_SET_PDEATHSIG" src/xros-install-gui-rs/src/install.rs \
  && grep -q "pre_exec" src/xros-install-gui-rs/src/install.rs \
  && grep -q "setsid" src/xros-install-gui-rs/src/install.rs \
  && grep -q "getppid" src/xros-install-gui-rs/src/install.rs \
  && ok "gui: PDEATHSIG + pre_exec + setsid + getppid" \
  || bad "gui: PDEATHSIG + pre_exec + setsid + getppid"
# GUI: ручка дочернего процесса, убийство группы, эскалация SIGKILL
grep -q "InstallHandle" src/xros-install-gui-rs/src/install.rs \
  && grep -q "kill(-self.pgid" src/xros-install-gui-rs/src/install.rs \
  && grep -q "SIGKILL" src/xros-install-gui-rs/src/install.rs \
  && grep -q "was_cancelled" src/xros-install-gui-rs/src/install.rs \
  && ok "gui: InstallHandle + kill группы + SIGKILL" \
  || bad "gui: InstallHandle + kill группы + SIGKILL"
# GUI: кнопка остановки и её подтверждение
grep -q "Остановить установку" src/xros-install-gui-rs/src/steps.rs \
  && grep -q "confirm_cancel" src/xros-install-gui-rs/src/app.rs \
  && grep -q "cancel_install" src/xros-install-gui-rs/src/app.rs \
  && ok "gui: кнопка остановки установки" \
  || bad "gui: кнопка остановки установки"
# Движок: ловушки HUP/TERM/INT
grep -q "trap 'xros_on_signal HUP' HUP" src/xros-install \
  && grep -q "trap 'xros_on_signal TERM' TERM" src/xros-install \
  && grep -q "trap 'xros_on_signal INT' INT" src/xros-install \
  && ok "engine: trap HUP/TERM/INT" \
  || bad "engine: trap HUP/TERM/INT"
# Движок: идемпотентный cleanup + сторож родителя + маркер INSTALL_FAILED
grep -q "xros_cleanup()" src/xros-install \
  && grep -q "XROS_CLEANUP_DONE" src/xros-install \
  && grep -q "xros_watchdog" src/xros-install \
  && grep -q "INSTALL_FAILED" src/xros-install \
  && ok "engine: cleanup + сторож + INSTALL_FAILED" \
  || bad "engine: cleanup + сторож + INSTALL_FAILED"
# Движок: блок защиты не разрезан (маркеры начала и конца на месте)
grep -q "^# --- XROS: защита дочернего процесса (начало) ---" src/xros-install \
  && grep -q "^# --- XROS: защита дочернего процесса (конец) ---" src/xros-install \
  && ok "engine: блок защиты дочернего процесса цел" \
  || bad "engine: блок защиты дочернего процесса цел"
# Тест управления процессом существует и проходит
[[ -x scripts/tests/test-child-process.sh ]] \
  && bash scripts/tests/test-child-process.sh >/tmp/xros-child-test.log 2>&1 \
  && ok "test: test-child-process.sh PASS" \
  || bad "test: test-child-process.sh FAIL (см. /tmp/xros-child-test.log)"
# Rust: проверка без сети (только если cargo есть; иначе SKIP)
if command -v cargo >/dev/null 2>&1; then
  cargo check --offline --manifest-path src/xros-install-gui-rs/Cargo.toml \
    >/tmp/xros-cargo-check.log 2>&1 \
    && ok "rust: cargo check PASS" \
    || bad "rust: cargo check FAIL (см. /tmp/xros-cargo-check.log)"
else
  skip "rust: cargo check (нет cargo на хосте)"
fi
```

Замечание для диагностики: `cargo check` на этом хосте требует chroot
`~/workspace/akvt-os/root.x86_64` с bind-mount'ом репозитория
(см. §3); в чистой среде без cargo это `SKIP`, а не `FAIL`.

## 5. Что проверено, а что — нет (честно)

**Проверено тестом (без реального диска):**
- смерть родителя → движок завершается ≤10 с, cleanup выполняется,
  дети/внуки мертвы — в режимах с PDEATHSIG и без него (сторож);
- прямой `SIGTERM` → код 143, причина в журнале, `INSTALL_FAILED`;
- идемпотентность cleanup (двойной сигнал, двойной вызов);
- отмена через `SIGTERM` группе ≤5 с; эскалация `SIGKILL` для
  игнорирующего `SIGTERM` движка.
- `cargo check` — 0 ошибок/ warning'ов.

**НЕ проверено (требует живой системы / QEMU):**
- реальное аварийное завершение GUI во время установки в живой системе:
  падение/убийство настоящего `xros-install-gui` на полпути `rsync`,
  затем проверка, что диск размонтирован и ничего не дописывается.
  Эквивалент на уровне системных вызовов покрыт T1, но end-to-end
  путь GUI→движок→диск — только в QEMU.
- штатная отмена кнопкой «Остановить установку» в реальном GUI
  (клики мышью в QEMU; логика `cancel()` покрыта T3 на уровне
  механизма, но не через egui-события).
- поведение сторожа при переиспользовании PID родителя (узкий случай:
  GUI умер, и его PID за ~1 с занял другой процесс — сторож не
  сработает, но PDEATHSIG на уровне ядра сработает всегда).
- `cargo clippy` — см. §3 (окружение chroot).
- Полная установка до конца после этих правок (движок в успешном пути
  не менялся, но прогон установки целиком не делался — это зона
  другого этапа, не этой задачи).

## 6. Остающиеся проблемы и риски

1. **Откладывание ловушки bash** — фундаментальное ограничение: если
   движок убьют напрямую по PID (не группой) во время `rsync`/`mkfs`,
   cleanup выполнится только после конца текущей внешней команды.
   Закрыто для двух реальных путей (GUI отменяет группой, сторож
   шлёт группе), но прямой `kill <pid движка>` извне остаётся медленным.
   Полное закрытие потребовало бы переделки `run_install` на фоновые
   команды + `wait` — это вне зоны этой задачи.
2. **Внуки `arch-chroot`** — `xros_kill_children` гасит дерево
   потомков рекурсивно, но если внук сам сделал `setsid` (такого
   в цепочке установки нет — проверено по коду: `rsync`, `arch-chroot`,
   `mkfs`, `pacman` групп не меняют), он уйдёт из-под группового
   сигнала. Остаточный риск минимален.
3. **Сторож не стартует, если `pgid != $$`** — например, движок
   запущен из скрипта без job control. Тогда остаётся только PDEATHSIG
   (сам движок) без группового добивания внуков. В штатном пути
   (запуск из GUI через `setsid`) этого нет.
4. **Зомби при `saw_done`**: поток чтения stdout не делает `wait()`,
   если маркер `INSTALL_DONE`/`INSTALL_FAILED` уже получен, — зомби
   подбирает `App` через `try_wait` при сбросе ручки. Если GUI упадёт
   ровно между маркером и сбросом ручки — зомби подберёт init, это
   безвредно.
5. `clippy` недоступен в chroot (см. §3).

## 7. Файлы

- Изменены: `src/xros-install-gui-rs/src/install.rs`,
  `src/xros-install-gui-rs/src/app.rs`,
  `src/xros-install-gui-rs/src/steps.rs`, `src/xros-install`
  (только блок trap/cleanup/watchdog между маркерами).
- Созданы: `scripts/tests/test-child-process.sh`,
  `docs/final-refinement/child-process.md` (этот отчёт).
- НЕ тронуты: `~/workspace/akvt-os`, `ARCHITECTURE.md`,
  `AUDIT-REPORT.md`, `README.md`, `scripts/xros-diagnose.sh`,
  `scripts/build.sh` (не запускался), ISO не собирался.
