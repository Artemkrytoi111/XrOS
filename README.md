<p align="center">
  <img src="packages/xros-branding/xros-logo-small.png" width="300" alt="XrOS">
</p>

<h1 align="center">XrOS</h1>

<p align="center">
  <b>Дистрибутив Linux на базе Arch Linux: живая система с KDE Plasma, графический установщик собственного дизайна и подписанный репозиторий пакетов.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-dev_1.2beta-8B00FF" alt="Version dev 1.2beta">
  <img src="https://img.shields.io/badge/based_on-Arch_Linux-1793D1?logo=archlinux&logoColor=white" alt="Based on Arch Linux">
  <img src="https://img.shields.io/badge/license-GPLv3-blue.svg" alt="License: GPLv3">
  <a href="https://artemkrytoi111.github.io/XrOS/"><img src="https://img.shields.io/badge/website-artemkrytoi111.github.io%2FXrOS-8B00FF" alt="Website"></a>
</p>

> [!NOTE]
> **Статус:** DEV ISO собран 14.11.2026 и проверен (`check-iso` 12/12 PASS). Security-hardening commit от 20.11.2026 (см. раздел Security Hardening). Публичный релиз пока не опубликован — подробности на [странице загрузки](https://artemkrytoi111.github.io/XrOS/download.html).

## О проекте

XrOS — настольный дистрибутив на базе Arch Linux. Живая система с KDE Plasma, графический установщик Diamond с собственным дизайном, тема GRUB Sapphire, экран завершения с безопасной перезагрузкой, диагностика и автотесты. Обновления — из подписанного репозитория `[xros]` с проверкой подписей GPG.

Текущая версия в разработке — **1.2beta** (dev); последний собранный образ — 1.0 Diamond (DEV ISO 14.11.2026).

Оформление: чёрный металлический X с фиолетовым неоном, акцент `#8B00FF`, второй акцент `#B66AFF`, фон `#08080D` / `#111018`.

## Возможности

- **Живая система** — KDE Plasma, работает с USB без установки
- **Графический установщик** — собственный дизайн, разметка диска, пользователи, LUKS как опция
- **Подписанные пакеты** — `SigLevel = Required`, подписи GPG для пакетов, баз репозитория и манифеста исходников
- **Автообновления** — репозиторий `[xros]`, таймер обновлений, переходный пакет `xros-keyring`
- **Диагностика и тесты** — `./scripts/xros-diagnose.sh` (PASS=309 FAIL=0 SKIP=14)
- **Свой build-env** — изолированная среда сборки на базе Arch

## Загрузка

Публичный релиз пока не опубликован. DEV ISO (собран 14.11.2026):

| Файл | Размер | SHA-256 |
|---|---|---|
| `xros-1.0-x86_64.iso` (гибридный, BIOS+UEFI) | 1 823 131 648 Б | `fa867b6409277b42ddd1289465c7181c959dbf678ec212af8a9b0e5c25030445` |
| `xros-1.0-x86_64.iso` (базовый) | 1 822 580 736 Б | см. [страницу загрузки](https://artemkrytoi111.github.io/XrOS/download.html) |

Проверка: `sha256sum xros-1.0-x86_64.iso`, `check-iso` 12/12 PASS.

## Установка

1. Запишите ISO на USB (например, `dd` или Rufus) и загрузитесь с него
2. В живой системе запустите установщик **XrOS Install**
3. Выберите разметку диска, пользователей и опции (LUKS — по желанию)
4. Дождитесь завершения и перезагрузитесь

Подробно — на [странице установки](https://artemkrytoi111.github.io/XrOS/install.html).

## Security Hardening (2026-11-20)

Следующие критические проблемы безопасности были устранены в коммите *security-hardening*:

| # | Проблема | Исправление |
|---|----------|-------------|
| 1 | **PKGBUILD — `sha256sums=('SKIP')`** — отсутствие проверки целостности исходных файлов | Все 5 пакетов (`xros-installer`, `xros-cli`, `xros-welcome`, `xros-branding`, `xros-keyring`) получили реальные SHA-256 хеши файлов `source=`. |
| 2 | **TOCTOU в `bridge.py:_secure_create`** — `unlink` → `open` даёт окно для подмены symlink | Реализовано атомарное `O_CREAT|O_EXCL` + безопасная очистка через `lstat` (учитываются только обычные файлы и symlink-и). |
| 3 | **Инъекция строк в конфиг установщика** — GUI мог передать `\n` в значение, движок `. "$CONF"` исполнял лишнюю команду | Добавлена валидация в `bridge.py:writeConf` (Python) и `install.rs:validate_conf_value` (Rust) — значения с `\n`/`\r` отклоняются. |
| 4 | **Слишком широкие `sudo` права** — `xros ALL=(ALL) NOPASSWD: ALL` | Сужены до `xros ALL=(root) NOPASSWD: /usr/local/bin/xros-install`. |
| 5 | **Автообновление без проверки подписей** — таймер мог поставить неподписанные пакеты | В `xros-auto-update` добавлена fail-closed проверка `SigLevel = Required` для `[xros]` перед каждым запуском. |
| 6 | **Опасные `rm -rf` без проверки пути** — подмена переменной могла удалить произвольный каталог | Все `rm -rf` в `scripts/build.sh` защищены `case`-проверкой: удаляется только строго ожидаемый каталог внутри проекта. |
| 7 | **Тесты безопасности** | Добавлены unit-тесты для `bridge.py` (`test_bridge_security.py`) и `install.rs` (`#[cfg(test)]` модуль) — проверяют атомарность, экранирование и инъекции. |

> [!NOTE]
> Изменения носят **оборонительный характер** — функционал (сборка ISO, установка, автообновления) не изменялся. Все патчи прошли ручной аудит кода и работают в POSIX-окружении сборки.

## Безопасность

- Установка только подписанных пакетов: `SigLevel = Required`
- Подписи GPG: пакеты, базы репозитория (`xros.db`, `xros.files`), манифест исходников
- Production GPG-ключ: `52F96353…`, бессрочный; online-подписание выполняется subkey `6393D0F5…`, приватные части хранятся отдельно
- Переходный пакет `xros-keyring 1.0-1` — доверие новому ключу на существующих системах
- Публичный ключ: [`xros-gpg-prod/xros-public.key`](xros-gpg-prod/xros-public.key)

Подробно — на [странице безопасности](https://artemkrytoi111.github.io/XrOS/security.html).

## Пакеты

| Пакет | Версия | Назначение |
|---|---|---|
| `xros-installer` | 1.0-6 | Графический установщик Diamond |
| `xros-welcome` | 1.0-3 | Приветствие (PyQt6) |
| `xros-branding` | 1.0-2 | Тема, обои, GRUB Sapphire |
| `xros-cli` | 1.0-2 | Команда `xros` |
| `xros-keyring` | 1.0-1 | Переходный пакет доверия новому ключу |

## Сборка из исходников

Требуется Arch Linux (или собственный build-env из репозитория).

```bash
git clone https://github.com/Artemkrytoi111/XrOS.git
cd XrOS
./scripts/build.sh --confirm
```

Быстрая проверка окружения:

```bash
./scripts/xros-diagnose.sh
```

## Структура репозитория

- `profile/` — профиль mkarchiso (live-система, загрузчик — только GRUB, UEFI)
- `src/` — установщик (bash-движок + Rust GUI), приветствие (PyQt6), команда `xros`
- `packages/` — PKGBUILD и собранные пакеты проекта
- `scripts/` — диагностика, сборка (`build.sh`), собственный build-env, тесты (`scripts/tests/`)
- `repo/` — локальный репозиторий пакетов `[xros]`
- `branding/` — логотипы, обои, фон GRUB, `banner.txt`
- `preview/` — дизайн-превью для согласования
- `xros-gpg-prod/` — подтверждённый публичный ключ
- `index.html`, `download.html`, … — сайт проекта (GitHub Pages)

## Ссылки

- Сайт проекта: https://artemkrytoi111.github.io/XrOS/
- Репозиторий обновлений: https://github.com/Artemkrytoi111/XrOS-Security-Updates
- Arch Linux: https://archlinux.org

## Лицензия

GPLv3 — см. [LICENSE](LICENSE).
