<p align="center">
  <img src="packages/xros-branding/xros-logo-small.png" width="300" alt="XrOS">
</p>

<h1 align="center">XrOS</h1>

<p align="center">
  <b>Дистрибутив Linux на базе Arch Linux: живая система с KDE Plasma, графический установщик собственного дизайна и подписанный репозиторий пакетов.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-dev_1.1beta-8B00FF" alt="Version dev 1.1beta">
  <img src="https://img.shields.io/badge/based_on-Arch_Linux-1793D1?logo=archlinux&logoColor=white" alt="Based on Arch Linux">
  <img src="https://img.shields.io/badge/license-GPLv3-blue.svg" alt="License: GPLv3">
  <a href="https://artemkrytoi111.github.io/XrOS/"><img src="https://img.shields.io/badge/website-artemkrytoi111.github.io%2FXrOS-8B00FF" alt="Website"></a>
</p>

> [!NOTE]
> **Статус:** DEV ISO собран 14.11.2026 и проверен (`check-iso` 12/12 PASS). Публичный релиз пока не опубликован — подробности на [странице загрузки](https://artemkrytoi111.github.io/XrOS/download.html).

## О проекте

XrOS — настольный дистрибутив на базе Arch Linux. Живая система с KDE Plasma, графический установщик Diamond с собственным дизайном, тема GRUB Sapphire, экран завершения с безопасной перезагрузкой, диагностика и автотесты. Обновления — из подписанного репозитория `[xros]` с проверкой подписей GPG.

Текущая версия в разработке — **1.1beta** (dev); последний собранный образ — 1.0 Diamond (DEV ISO 14.11.2026).

Оформление: чёрный металлический X с фиолетовым неоном, акцент `#8B00FF`, второй акцент `#B66AFF`, фон `#08080D` / `#111018`.

## Возможности

- **Живая система** — KDE Plasma, работает с USB без установки
- **Графический установщик** — собственный дизайн, разметка диска, пользователи, LUKS как опция
- **Подписанные пакеты** — `SigLevel = Required`, подписи GPG для пакетов, баз репозитория и манифеста исходников
- **Автообновления** — репозиторий `[xros]`, таймер обновлений, переходный пакет `xros-keyring`
- **Диагностика и тесты** — `./scripts/xros-diagnose.sh` (PASS=307 FAIL=0 SKIP=18), полный набор тестов 919/0/7
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

## Безопасность

- Установка только подписанных пакетов: `SigLevel = Required`
- Подписи GPG: пакеты, базы репозитория (`xros.db`, `xros.files`), манифест исходников
- Ротация production-ключа: `B16629E8…` → `9E71EDB1…`, переходный период до 13.12.2026
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
