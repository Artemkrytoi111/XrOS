#!/usr/bin/env python3
"""XrOS 1.0 Diamond — точка входа установщика (PyQt6 + QML).

Запуск из окна приветствия (src/xros-welcome):
    sudo /usr/local/bin/xros-installer-diamond
Закрытие установщика НЕ завершает Live-сессию: приложение просто
выходит, окно приветствия остаётся.
"""
import ctypes
import os
import signal
import sys


def _arm_parent_death():
    if os.geteuid() != 0:
        return
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM) != 0:
        raise OSError(ctypes.get_errno(), "prctl(PR_SET_PDEATHSIG) failed")
    if os.getppid() == 1:
        raise RuntimeError("parent exited before Diamond was armed")

if os.geteuid() != 0:
    print("xros-installer-diamond должен запускаться через xros-installer-launcher", file=sys.stderr)
    sys.exit(1)
_arm_parent_death()

from PyQt6.QtCore import QUrl, QTimer
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

    # D14 (12.11.2026): принудительная активация окна и захват фокуса.
    # В UEFI Live клавиатура не доходила до QML (печать/Tab/Enter игнорировались).
    # После загрузки просим активацию корневого окна.
    def activate_window():
        roots = engine.rootObjects()
        if roots:
            win = roots[0]
            win.requestActivate()
            win.raise_()
    QTimer.singleShot(300, activate_window)

    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
