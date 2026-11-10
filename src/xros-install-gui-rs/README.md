# XrOS — графический установщик (Rust, egui).
# Свой дизайн: тёмная тема, фирменная система 10.11.2026 — фон #08080D,
# акцент #8B00FF, второй акцент #B66AFF (см. branding/design-tokens.css).
# По качеству и удобству ориентир — Calamares/EndeavourOS,
# но один в один не копируем: свои шаги, свои тексты, своя палитра.
#
# Шаги: Welcome, Location, Keyboard, Desktop, Partitions, Users,
# Office Suite, Summary, Install, Finish.
# Движок установки — консольный xros-install (см. ../xros-install):
# GUI только собирает выборы и показывает прогресс.
# Сборка: cargo build --release (в среде сборки с Rust).
# Бинарь ставится в /usr/local/bin/xros-install-gui (пакет xros-installer).
