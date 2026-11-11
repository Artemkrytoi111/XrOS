#!/usr/bin/env python3
"""XrOS 1.0 Diamond — точка входа установщика (PyQt6 + QML).

Запуск из окна приветствия (src/xros-welcome):
    sudo /usr/local/bin/xros-installer-diamond
Закрытие установщика НЕ завершает Live-сессию: приложение просто
выходит, окно приветствия остаётся.
"""
import os
import sys

# Самоповышение прав (найдено в Live UEFI build3, 11.11.2026): окно
# приветствия запускает установщик БЕЗ sudo (Popen([INSTALLER])), а мост
# вызывает движок напрямую, без sudo. Без этого блока Diamond работал бы
# от пользователя xros, и движок падал бы на разметке/монтировании.
# Паттерн — как в старом Rust GUI (main.rs): если не root, перевыполняем
# себя через sudo (у живого пользователя xros sudo без пароля).
# Wayland-переменные (WAYLAND_DISPLAY, XDG_RUNTIME_DIR) sudo сохраняет,
# поэтому окно открывается в той же сессии.
if os.geteuid() != 0:
    os.execvp("sudo", ["sudo", sys.executable, os.path.abspath(__file__), *sys.argv[1:]])

from PyQt6.QtCore import QUrl
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlApplicationEngine

from bridge import InstallerBridge

HERE = os.path.dirname(os.path.abspath(__file__))


def main() -> int:
    app = QGuiApplication(sys.argv)
    app.setApplicationName("XrOS 1.0 Diamond")
    app.setOrganizationName("XrOS")

    engine = QQmlApplicationEngine()
    bridge = InstallerBridge()
    engine.rootContext().setContextProperty("bridge", bridge)
    # Палитра — singleton из qml/Theme.qml.
    engine.addImportPath(os.path.join(HERE, "qml"))
    qml_file = os.path.join(HERE, "qml", "Main.qml")
    engine.load(QUrl.fromLocalFile(qml_file))
    if not engine.rootObjects():
        print("ОШИБКА: не удалось загрузить QML", file=sys.stderr)
        return 1
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
