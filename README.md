# XrOS

Профессиональный дистрибутив Linux на базе Arch Linux: живая система
с KDE Plasma, графический установщик своего дизайна, красивый GRUB,
экран завершения с безопасной перезагрузкой, диагностика и автотесты.

> **Статус: архитектура готова, аудит, финальная доработка и финальный
> этап подготовки пройдены (диагностика PASS=214 FAIL=0 SKIP=11,
> перепроверка этапа 1а 10.11.2026, см. AUDIT-REPORT.md §9.8;
> два прогона идентичны, 10.11.2026). Собственный build-env готов
> (rootfs 3.2 ГБ). BIOS-GRUB проверен загрузкой в QEMU (в сборку
> не внедрён). Дефект UEFI `test`-модуля в GRUB исправлен и проверен
> в QEMU на настоящем `grub.cfg`. ISO пока не собран —
> сборка только с явного разрешения Мии.**
> Полная архитектура, решения и план — в [ARCHITECTURE.md](ARCHITECTURE.md).
> Отчёт аудита, доработки и финального этапа — в [AUDIT-REPORT.md](AUDIT-REPORT.md) (§9).
> Дизайн-превью для согласования — в [preview/index.html](preview/index.html).

## Брендинг

чёрный металлический X
с фиолетовым неоном, акцент `#8B00FF`, второй акцент `#B66AFF`,
фон `#08080D`, доп. фон `#111018`.
Подробности: [branding/README.md](branding/README.md).

## Структура

- `profile/` — профиль mkarchiso (live-система, загрузчик — только GRUB, UEFI)
- `src/` — установщик (bash-движок + Rust GUI), приветствие (PyQt6), команда `xros`
- `packages/` — PKGBUILD пакетов проекта
- `scripts/` — диагностика (`xros-diagnose.sh`), сборка (`build.sh`), генерация брендинга, собственный build environment (`xros-build-env.sh`), тесты (`scripts/tests/`)
- `repo/` — локальный репозиторий пакетов (4 пакета; сервер `xros.example` — PLACEHOLDER)
- `branding/` — логотипы, обои, фон GRUB, banner.txt (канонические исходники)
- `preview/` — дизайн-превью для согласования
- `docs/` — исследование BIOS-GRUB (`boot-bios-grub.md`), план публикации репозитория (`REPO-PUBLISHING.md`), отчёты финальной доработки (`docs/final-refinement/`, включая `security-audit-2.md` — повторный аудит безопасности установщика, `de-none-package-lists.md` — состав KDE/DE=none, `build-env.md` — собственный build environment)
- `experiments/` — QEMU-эксперименты: `bios-grub-test/` (BIOS-GRUB: BIOS CD/USB + UEFI-регрессия, все PASS) и `uefi-test-module/` (дефект UEFI `test`-модуля: исправление `grub.cfg`, доказательства ДО/ПОСЛЕ)

## Быстрые проверки этапа 1

```bash
./scripts/xros-diagnose.sh
```
