# Задача 6 — собственный build environment XrOS (убрать зависимость от чужого chroot)

Дата: 2026-11-10. Статус: **реализовано и ПРОВЕРЕНО вживую
(обновлено 2026-11-10 ~08:30)**: rootfs создан (`--init`), Rust собран,
все 4 PKGBUILD собраны от builder и установлены в rootfs, grub-check
пройден, повторяемость и очистка проверены. ISO не собирался
(отдельный этап, только после разрешения Мии).

Запреты соблюдены: `scripts/build.sh` и `mkarchiso` не запускались, ISO не
создавался, пакеты/репозитории не публиковались, `~/workspace/akvt-os` не
изменялся и не удалялся (только чтение `build-chroot.sh` и `root.x86_64`
для понимания), `ARCHITECTURE.md`, `AUDIT-REPORT.md`, `README.md`,
`scripts/xros-diagnose.sh` не редактировались.

## 1. Что проверено на хосте (2026-11-10)

Хост: **Ubuntu 24.04.5 LTS** (`/etc/os-release`), ядро 7.0.0-44-generic,
x86_64, EUID 0 (root), 4 CPU, ~7.7 ГБ RAM (свободно ~730 МБ на момент проверки),
свободно на диске 133 ГБ.

Инструменты хоста (`which`):

| Инструмент | Статус |
|---|---|
| `curl`, `tar`, `gpg`, `python3`, `apt-get` | есть |
| `systemd-nspawn` 255 (255.4-1ubuntu8.18) | есть |
| `unshare` (util-linux 2.39.3), `chroot`, `runuser`, `flock` | есть |
| `pacstrap`, `arch-chroot`, `mkarchiso` | **нет** (ожидаемо: хост не Arch) |
| `cargo`, `rustc`, `makepkg` | **нет** |
| `docker`, `podman` | нет |
| `zstd` | **установлен 1.5.5** через `apt-get install -y zstd` (2026-11-10) |
| `shellcheck` | нет (SKIP) |
| модуль `zstandard` для python3 | нет |

Сеть: `https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst`
отвечает на HEAD; `https://archlinux.org` доступен. URL bootstrap подтверждён
поиском по открытым источникам (официальный geo-mirror, путь `iso/latest/`;
пример: `curl -LO 'https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst'`,
подпись — `https://archlinux.org/iso/latest/archlinux-bootstrap-x86_64.tar.zst.sig`).

Проверки исполнителей (проверено вживую 2026-11-10 после `--init`):
- `systemd-nspawn` 255 **НЕ РАБОТАЕТ с реальным Arch-rootfs на этом
  хосте**: не может смонтировать sysfs в user namespace (EPERM, даже
  без `/sys`). Скрипт определяет это пробой `nspawn_usable()` и
  использует запасной путь `unshare --mount` + `chroot`.
- `unshare --mount --fork` + `chroot` — **работает** (все команды
  `--exec`, `--build-rust`, `--makepkg` выполнены именно этим путём).
- Rootfs: `build-env/root.x86_64`, **3.2 ГБ** после всех сборок
  (2.5 ГБ на момент `--init`, 117 пакетов: rust 1.99.1, grub 2.16,
  python-pyqt6 6.12.0, qt6-base 6.12.0...); bootstrap 127 575 204 Б,
  sha256 `655bc998…8339c`, подпись GPG проверена (Pierre Schmitz).
  Метки `state/init-done`, `state/deps-fetched` на месте.

Чужой chroot (только чтение, для понимания, что именно использовалось):
- `~/workspace/akvt-os/build-chroot.sh` — приватный mount namespace
  (`unshare --mount`), bind-монтирование proc/dev/pts/tmp, проброс
  egress-TLS хоста (`/run/hatch/egress-tls`, CA `hatch-egress-ca.crt`),
  `chroot $ROOT "$@"`. Механизм НЕ копировался: свой скрипт написан
  с нуля, с другим исполнителем (nspawn) и другой структурой каталогов.
- `~/workspace/akvt-os/root.x86_64` — 19 ГБ; внутри есть `cargo`, `rustc`,
  `pacman`, `makepkg`, `grub-script-check`, `unshare`; пользователь
  `builder` (uid 1000); `/home` содержит `builder`, `hatch`, `registry`.
- Что именно `build.sh` брал оттуда: **только** вызов
  `~/workspace/akvt-os/build-chroot.sh bash -c '... cargo build --release --offline'`
  для `src/xros-cli` и `src/xros-install-gui-rs` (одна строка-комментарий,
  CARGO_HOME `/home/hatch/.cargo`), плюс отсылка к `AUDIT-REPORT.md`
  («makepkg от пользователя hatch внутри chroot»). Никаких других
  зависимостей от чужого проекта в `build.sh` не было.

Что нужно для Rust-сборок (влияет на дизайн):
- `src/xros-cli`: только `libc 0.2` — лёгкий.
- `src/xros-install-gui-rs`: `eframe 0.32` + `egui 0.32` + `image 0.25` +
  `libc 0.2`, в `Cargo.lock` **304 пакета**. В свежем rootfs кэша cargo нет,
  vendor-каталога в проекте нет, на хосте нет cargo вообще — поэтому
  **первая сборка обязана быть онлайн** (`cargo fetch`), а `--offline`
  возможен только после неё. Скрипт это явно проверяет (метка
  `build-env/state/deps-fetched`) и отказывает в офлайне до первой
  онлайн-сборки, вместо молчаливого падения.

Попутное наблюдение (не моя правка, фиксирую для координатора):
на 2026-11-10 в `profile/airootfs/usr/local/bin/` уже лежат `xros` и
`xros-install-gui` (ELF, 06:11–06:37 сегодня), причём `xros` совпадает по
md5 со стейджингом в `packages/xros-cli/xros`. Старый комментарий в
`build.sh` («сейчас в airootfs их НЕТ») устарел — я обновил его до
фактического состояния с датой проверки. Кто/что их туда положило —
мне неизвестно (возможно, параллельная работа другого агента).

## 2. Выбранный механизм и почему

**Файл: `scripts/xros-build-env.sh`** (новый, ~600 строк, исполняемый).

Структура (всё внутри проекта, вне git — см. `.gitignore`):
```
~/workspace/xros/build-env/
  archlinux-bootstrap-x86_64.tar.zst(.sig)  # скачивается при --init
  root.x86_64/        # собственный Arch-rootfs XrOS (не чужой!)
  pkgcache/           # кэш pacman-пакетов (переиспользуется между --init)
  state/              # метки init-done, deps-fetched
  logs/               # (зарезервировано под логи --init)
  .lock               # flock от параллельных запусков
```

Почему не pacstrap/arch-chroot: их нет на хосте (не-Arch), и ставить
Arch-инструменты на Ubuntu нельзя. Поэтому rootfs создаётся из
**официального Arch bootstrap-тарболла** (~120 МБ, подпись `.sig`
проверяется по GPG с авто-получением ключа с keyserver.ubuntu.com),
а пакеты внутрь ставятся штатным `pacman -r <rootfs>` — тот же подход,
что Arch Wiki описывает для установки из-под другой системы. Если
скрипт однажды окажется на настоящем Arch-хосте, `--init` сам
переключится на `pacstrap` (проверка наличия в PATH).

Почему `systemd-nspawn` (основной путь): есть на хосте, даёт изоляцию
mount/net/pid-неймспейсов и сам чистит монтирования при выходе.
Запасной путь — `unshare --mount` + `chroot` с минимальным ручным
монтированием proc/dev (написан с нуля, не копия чужого скрипта).

Почему сборки идут через копию, а не напрямую в bind-монтированном
проекте: файлы проекта на хосте принадлежат root, а `cargo build` и
`makepkg` обязаны выполняться от непривилегированного пользователя
(`builder`, uid 1000 внутри rootfs — `makepkg` от root отказывается
работать). Поэтому исходники копируются в `/home/builder/xros-build/`
или `/home/builder/pkgbuild/` внутри rootfs (владелец `builder`),
а обратно от root возвращаются только артефакты: `Cargo.lock`,
готовые бинари (в стейджинг рядом с PKGBUILD) и `.pkg.tar.zst`.

Очистка: `trap cleanup EXIT` снимает bind-монтирования, созданные
в chroot-режиме (список в `build-env/.mounts`, снятие в обратном
порядке); nspawn чистит свои монтирования сам. `--clean` — ручное
снятие зависших монтирований; `--destroy`/`--reinit` — только с
`--confirm`. Параллельные запуски блокируются `flock`.

Защита от перекрёстных путей: скрипт проверяет, что запущен внутри
проекта XrOS (каталог `xros`, есть `profile/` и сам скрипт), и
работает только с путями внутри `$PROJECT/build-env`. В скрипте
и в `build.sh` **нет ни одного упоминания чужого проекта** —
ни путей, ни имени (проверено `grep -rni akvt` → 0 совпадений).

## 3. Режимы скрипта (как пользоваться)

```bash
scripts/xros-build-env.sh --check | --dry-run   # только аудит хоста и rootfs; ничего не скачивает и не создаёт
scripts/xros-build-env.sh --init                # создать rootfs (bootstrap ~120 МБ + пакеты ~2–3 ГБ)
scripts/xros-build-env.sh --reinit --confirm    # пересоздать rootfs с нуля
scripts/xros-build-env.sh --exec -- <команда...> # выполнить команду внутри rootfs от root
scripts/xros-build-env.sh --build-rust          # cargo build --release обоих крейтов (ПЕРВЫЙ раз — онлайн)
scripts/xros-build-env.sh --build-rust --offline # повторные сборки (только после первой онлайн)
scripts/xros-build-env.sh --makepkg packages/xros-cli   # makepkg от builder; .pkg.tar.zst возвращается в каталог пакета
scripts/xros-build-env.sh --grub-check [файлы...]       # grub-script-check (по умолчанию *.cfg из profile/)
scripts/xros-build-env.sh --clean               # снять зависшие монтирования, убрать временные файлы
scripts/xros-build-env.sh --destroy --confirm   # удалить весь build-env/
scripts/xros-build-env.sh --help                # полная справка (шапка скрипта)
```

`--build-rust` сам стейджит результаты: `Cargo.lock` → обратно в `src/`,
`xros` → `packages/xros-cli/xros`, `xros-install-gui` →
`packages/xros-installer/xros-install-gui` (ровно те пути, которые ждёт
этап 2 в `build.sh`).

## 4. Что изменено (файлы)

| Файл | Изменение |
|---|---|
| `scripts/xros-build-env.sh` | **новый** — собственный build environment (см. §2–3) |
| `scripts/build.sh` | этап 2 переписан: убрана строка `~/workspace/akvt-os/build-chroot.sh ...` и отсылка «своего у XrOS пока нет»; вместо неё — вызовы `scripts/xros-build-env.sh --build-rust [--offline]` и `--makepkg packages/...`; шаги 3–5 перенумерованы (3→репозиторий, 4→снимок, 5→бинари); комментарий про отсутствие бинарей в airootfs исправлен на фактическое состояние; **логика сборки ISO не тронута** (тот же `TODO`, `exit 3`, та же шапка про штатный mkarchiso и непроверенный обход) |
| `.gitignore` | **новый** — `build-env/` вне git |
| `docs/final-refinement/build-env.md` | этот отчёт |

Не тронуты: `~/workspace/akvt-os` (вообще), `ARCHITECTURE.md`,
`AUDIT-REPORT.md`, `README.md`, `scripts/xros-diagnose.sh`.
`build.sh` не запускался ни разу (даже без `--confirm`).

Примечание о параллельной правке: во время этой задачи `build.sh`
правился и другим агентом (блок стейджинга брендинга: источник
`banner.txt` и упоминание `scripts/make-branding.py`). Конфликта
с изменениями этой задачи нет: вызовы `xros-build-env.sh` в этапе 2
и примечание про бинари в airootfs на месте, логика ISO не тронута;
финальная проверка `bash -n` и `grep akvt` проведена уже после
той правки.

## 5. Результаты проверок (2026-11-10, вживую после --init)

- `bash -n scripts/xros-build-env.sh` — **OK** (после каждой правки).
- `bash -n scripts/build.sh` — **OK**.
- `shellcheck` — **SKIP**: на хосте отсутствует.
- `--help` — печатает полную справку из шапки скрипта (диапазон строк
  сверен с фактическим концом комментария).
- `--check` / `--dry-run` — **exit 0**: хост готов, rootfs существует,
  cargo/rustc/makepkg/grub-script-check и builder (uid 1000) внутри
  rootfs на месте, метки init-done и deps-fetched есть.
- `--init` (run4, ~07:49) — **УСПЕХ**: bootstrap + 117 пакетов,
  rootfs 2.5 ГБ, 0 ошибок (только неважные предупреждения хуков из-за
  запрета chown на overlayfs хоста). Повторный `--init` (run5) —
  **идемпотентен**: видит метку init-done, завершается за 0.018 с,
  rootfs не трогает.
- `--exec` — работает (chroot-путь): `cargo 1.99.1`, `rustc 1.99.1`,
  `/dev/null` — настоящее устройство, bind `/xros` виден.
- `--build-rust` (run3, ~08:08, 9 мин 38 с, `--jobs 1`) — **УСПЕХ**:
  оба крейта собраны онлайн от builder; `xros` 516 720 Б
  (sha256 `9c67cfdc…954e1aa`), `xros-install-gui` 11 268 248 Б
  (sha256 `f81a1b18…451ed254`); `xros --help` работает внутри rootfs.
  Повторный прогон `--build-rust --offline` (run4) — **2.2 с**,
  cargo: всё fresh, бинари байт-в-байт те же (sha совпали).
- `--makepkg` — **все 4 пакета собраны от builder (rc=0) и установлены
  в rootfs** (`pacman -Q`: xros-branding 1.0-2, xros-cli 1.0-1,
  xros-installer 1.0-2, xros-welcome 1.0-2):
  `xros-branding-1.0-2-any` 4 161 557 Б,
  `xros-cli-1.0-1-x86_64` 204 549 Б,
  `xros-installer-1.0-2-x86_64` 3 319 911 Б,
  `xros-welcome-1.0-2-any` 8 431 Б.
  Повторный прогон всех 4 — тоже rc=0 (с `--force`).
  Найденные и исправленные баги скрипта — см. §8.
- `--grub-check` — **OK**: `profile/grub/grub.cfg` и
  `profile/grub/loopback.cfg` проходят `grub-script-check`.
- `--clean` — **OK** (exit 0): `/proc/mounts` — 0 записей xros до
  и после, `.inner.*.sh` не остаётся, rootfs не трогается.
- `--destroy` / `--reinit` без `--confirm` — честно отказали, exit 1.
- Неизвестный режим — usage + exit 2.
- `grep -rni akvt scripts/xros-build-env.sh scripts/build.sh` — **0 совпадений**.
- `grep -rn 'akvt-os' scripts/` — 0 совпадений.
- **НЕ выполнялось** (вне этой задачи): сборка ISO (`scripts/build.sh`,
  `mkarchiso`), запуск в QEMU, публикация пакетов/репозитория.

## 6. Спецификация проверок для `xros-diagnose.sh` (готовые фрагменты)

Эти фрагменты — предложение координатору; в `xros-diagnose.sh`
я ничего не менял. Нумерация продолжает стиль существующих проверок
(см. раздел про `akvt` в diagnose, строка ~97).

```bash
# --- build-env: собственный build environment, без чужого chroot ---
# 6.1. Нет упоминаний чужого chroot в скриптах сборки.
#     (Проверяется именно путь/имя чужого скрипта, а не слово вообще.)
if grep -rIn --exclude-dir=.git -E 'akvt-os/build-chroot|/workspace/akvt-os|build-chroot\.sh' scripts/ 2>/dev/null | grep .; then
  fail "scripts/ ссылается на чужой chroot (akvt-os/build-chroot.sh)"
else
  pass "scripts/: нет ссылок на чужой chroot"
fi

# 6.2. Собственный скрипт окружения существует и исполняем.
if [[ -x scripts/xros-build-env.sh ]]; then
  pass "scripts/xros-build-env.sh: существует и исполняем"
else
  fail "scripts/xros-build-env.sh: отсутствует или не исполняем"
fi

# 6.3. Синтаксис собственного скрипта окружения.
if bash -n scripts/xros-build-env.sh; then
  pass "xros-build-env.sh: bash -n OK"
else
  fail "xros-build-env.sh: bash -n НЕ ПРОШЁЛ"
fi

# 6.4. Синтаксис build.sh (после правок этапа 2).
if bash -n scripts/build.sh; then
  pass "build.sh: bash -n OK"
else
  fail "build.sh: bash -n НЕ ПРОШЁЛ"
fi

# 6.5. build.sh не содержит путей вне проекта XrOS.
if grep -n 'workspace/akvt-os\|/home/[^ ]*akvt\|/root/xros-build' scripts/build.sh | grep .; then
  fail "build.sh: есть пути вне проекта XrOS"
else
  pass "build.sh: путей вне проекта XrOS нет"
fi

# 6.6. build.sh вызывает собственный скрипт окружения (этап 2).
if grep -q 'xros-build-env\.sh --build-rust' scripts/build.sh \
   && grep -q 'xros-build-env\.sh --makepkg' scripts/build.sh; then
  pass "build.sh: этап 2 вызывает scripts/xros-build-env.sh"
else
  fail "build.sh: этап 2 не вызывает собственный build-env"
fi

# 6.7. build-env/ исключён из git (если проект станет репозиторием).
if grep -q '^build-env/' .gitignore 2>/dev/null; then
  pass ".gitignore: build-env/ исключён"
else
  fail ".gitignore: build-env/ не исключён"
fi

# 6.8. Состояние собственного rootfs (информационно, не FAIL, пока нет --init):
#     PASS, если rootfs создан и внутри есть cargo+makepkg+grub-script-check;
#     SKIP с пояснением, если rootfs ещё не создан (это нормально до этапа 2).
if [[ -x build-env/root.x86_64/usr/bin/cargo \
   && -x build-env/root.x86_64/usr/bin/makepkg \
   && -x build-env/root.x86_64/usr/bin/grub-script-check ]]; then
  pass "build-env/rootfs: cargo+makepkg+grub-script-check на месте"
elif [[ -d build-env/root.x86_64 ]]; then
  fail "build-env/rootfs: создан, но нет cargo/makepkg/grub-script-check"
else
  echo "SKIP: build-env/rootfs ещё не создан (нужен scripts/xros-build-env.sh --init)"
fi
```

Замечание к существующей проверке diagnose (строка ~97): она уже
ищет `akvt|АКВТ|Территория успеха` по `profile src packages scripts
branding repo preview`, исключая `build.sh` и `xros-diagnose.sh`.
После этой задачи `build.sh` чист (0 совпадений `akvt`), поэтому
исключение `--exclude=build.sh` можно снять; `xros-build-env.sh`
тоже чист (0 совпадений), отдельных исключений для него не нужно.

## 7. Оставшиеся ограничения

1. **systemd-nspawn не работает на этом хосте** (sysfs EPERM в user
   namespace). Весь реальный путь — unshare+chroot; на хосте с
   настоящим systemd и правами nspawn может заработать сам
   (скрипт пробует его первым). Для сборки ISO это неважно:
   `mkarchiso` запускается отдельно, не через этот скрипт.
2. **Память хоста.** Свободно ~300–1200 МБ RAM (плавает), своп ~1 ГБ.
   Первая онлайн-сборка Rust шла с `--jobs 1` (иначе rustc упирается
   в RAM); переменная `XROS_CARGO_JOBS` (по умолчанию 1).
3. **Прокси/CA хоста.** Egress-прокси хоста (`hatch-egress-proxy`,
   пароль в env ротируется) и его CA пробрасываются в rootfs;
   `/etc/hosts` хоста копируется внутрь (иначе прокси резолвится
   в мёртвый адрес). На другом хосте без такого прокси эти шаги —
   no-op (файлов нет — не ошибка), но зеркало и ключи pacman могут
   потребовать ручной настройки.
4. **ISO не собран, QEMU не запускался** — это отдельные этапы
   (`scripts/build.sh`, только после разрешения Мии). Пакеты
   установлены в rootfs, но не опубликованы (нет репозитория).
5. **`--grub-check` по умолчанию** ищет `profile/grub/grub.cfg` и
   `*.cfg` в `profile/`; если grub-конфиг лежит в другом месте —
   передавать путь явно: `--grub-check <файл>`.
6. **Пакеты пересобираются недетерминированно по sha256**: `.BUILDINFO`
   содержит `builddate`, поэтому два прогона дают разные sha256
   (размеры почти совпадают: branding 4 161 555 → 4 161 557 Б).
   Содержимое пакетов идентично; для бит-в-бит воспроизводимости
   нужен фиксированный `SOURCE_DATE_EPOCH`.

## 8. Баги скрипта, найденные и исправленные при проверке (2026-11-10)

Все — в `scripts/xros-build-env.sh`, с комментариями в коде;
`bash -n` чист после каждой правки.

1. **`/dev/fd` отсутствовал в rootfs — makepkg падал (главный баг).**
   Симптомы: `makepkg` доходил до «Creating package», генерировал
   `.PKGINFO`/`.BUILDINFO` и умирал; в логе — второй «Making package»
   и `fakeroot: nested operation not yet supported`, пакета не было.
   Корень (доказано по `/tmp/inner-x.log:12554` и изолированным
   тестом): в `create_package()` (`/usr/sbin/makepkg`, строка 713)
   цикл `read ... < <(printf ...)` требует `/dev/fd/63`; без него
   `read` не получает данных, `orig=""`, а `[[ -n ${!orig} ]]`
   даёт `orig: invalid indirect expansion` — ошибка разматывает
   стек вызовов (create_package → run_single_packaging → ветка
   INFAKEROOT), и тот же процесс продолжает main flow как будто
   INFAKEROOT=0: второй «Making package» → повторный enter_fakeroot
   уже внутри fakeroot → nested error.
   Исправление: симлинки `/dev/fd → /proc/self/fd`,
   `/dev/stdin/stdout/stderr → /proc/self/fd/0|1|2` — в
   `prepare_rootfs_for_pacman` и защитно во внутреннем chroot-скрипте
   (`run_in_rootfs_chroot`), плюс созданы в текущем rootfs.
2. **Опечатка в возврате пакета (`do_makepkg`):** было
   `"$pkgdir#$PROJECT/"` — конкатенация с литеральным `#`
   (путь `/xros//home/.../packages/...#/home/...`), `cp` падал,
   хотя пакет уже был собран. Исправлено на уже вычисленный
   `relpkgdir` (`${pkgdir#$PROJECT/}`).
3. **`pacman -U` падал в chroot:** `could not determine root mount
   point /` — `/` внутри chroot не является точкой монтирования
   в `/proc/mounts`, проверка места невозможна. Исправление:
   `CheckSpace` отключён в `rootfs/etc/pacman.conf` (и в скрипте
   для свежих `--init`); место контролируется хостом (133 ГБ).
4. **Повторный `--makepkg` падал:** `A package has already been
   built` — копия с хоста приносила старый `.pkg.tar.zst` обратно
   в chroot, а makepkg без `-f` отказывается перезаписывать.
   Исправление: `--force` в вызове makepkg + исключение
   `*.pkg.tar.zst` из `copy_to_builder` для каталога пакета.
