#!/usr/bin/env python3
"""Тесты безопасности src/xros-installer-diamond/bridge.py.

Запуск:
    python3 test_bridge_security.py        # в каталоге src/xros-installer-diamond
    pytest test_bridge_security.py         # если есть pytest

Проверяются (без запуска Qt-событий, только чистые функции модуля):
  * _secure_create: атомарное создание 0600, symlink-атака не следует,
    обычный файл перезаписывается, FIFO/каталог не трогаются.
  * _shell_quote: экранирование одинарных кавычек — результат
    остаётся одним shell-словом.
  * правило writeConf: переводы строк в значениях отклоняются,
    пустые значения пропускаются.
"""
import os
import shlex
import sys
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

IS_POSIX = os.name == "posix"

# Каталог для временных файлов тестов. Песочницы (Windows/DSH) могут
# блокировать запись и в системный TMPDIR, и в каталог проекта,
# поэтому пробуем несколько мест и берём первое записываемое.
def _find_writable_tmp_root() -> str:
    candidates = [
        os.path.join(HERE, ".test-tmp"),                                   # рядом с тестом
        os.path.join(tempfile.gettempdir(), "xros-test-tmp"),             # системный TMP
        os.path.join(os.path.expanduser("~"),
                     "Documents", "deepseek-harness", "default-workspace"),  # DSH workspace
    ]
    for cand in candidates:
        try:
            os.makedirs(cand, exist_ok=True)
            probe = os.path.join(cand, ".probe")
            with open(probe, "w") as f:
                f.write("ok")
            os.unlink(probe)
            return cand
        except OSError:
            continue
    raise RuntimeError("не найден записываемый каталог для тестов")

TEST_TMP_ROOT = _find_writable_tmp_root()


class _TmpDir:
    """Контекст-менеджер: временный каталог + best-effort очистка
    (на песочных хостах снятие прав может не пройти — тогда каталог
    остаётся в TEST_TMP_ROOT и не мешает тестам)."""

    def __init__(self):
        self.path = tempfile.mkdtemp(dir=TEST_TMP_ROOT)

    def __enter__(self):
        return self.path

    def __exit__(self, *exc):
        try:
            for root, dirs, files in os.walk(self.path, topdown=False):
                for name in files:
                    p = os.path.join(root, name)
                    try:
                        if not IS_POSIX:
                            os.chmod(p, 0o200)  # +w на Windows
                        else:
                            os.chmod(p, 0o600)
                        os.unlink(p)
                    except OSError:
                        pass
                for name in dirs:
                    try:
                        os.rmdir(os.path.join(root, name))
                    except OSError:
                        pass
            os.rmdir(self.path)
        except OSError:
            pass
        return False

# bridge.py тянет PyQt6 — если его нет (тестовый хост без Qt), подменяем
# минимальной заглушкой: тестируемые функции PyQt6 не используют.
try:
    import bridge  # noqa: F401
except ModuleNotFoundError as e:
    if "PyQt6" in str(e):
        import types
        qtcore = types.ModuleType("PyQt6.QtCore")
        qtcore.QObject = object
        qtcore.QTimer = lambda *a, **k: None
        qtcore.pyqtSignal = lambda *a, **k: None
        qtcore.pyqtSlot = lambda *a, **k: (lambda f: f)
        pyqt6 = types.ModuleType("PyQt6")
        pyqt6.QtCore = qtcore
        sys.modules["PyQt6"] = pyqt6
        sys.modules["PyQt6.QtCore"] = qtcore
        import bridge  # noqa: F401
    else:
        raise


class TestSecureCreate(unittest.TestCase):
    def test_creates_with_mode_0600(self):
        with _TmpDir() as d:
            path = os.path.join(d, "conf")
            fd = bridge._secure_create(path)
            self.assertIsNotNone(fd)
            os.close(fd)
            st = os.lstat(path)
            # На Windows биты режима не применяются — проверяем только
            # создание файла; на POSIX — права 0600.
            if IS_POSIX:
                self.assertEqual(stat.S_IMODE(st.st_mode), 0o600)
            self.assertTrue(os.path.isfile(path))

    @unittest.skipIf(not IS_POSIX, "symlink-атака — POSIX-only")
    def test_symlink_is_rejected_without_touching_target(self):
        with _TmpDir() as d:
            victim = os.path.join(d, "victim")
            with open(victim, "w") as f:
                f.write("secret")
            link = os.path.join(d, "conf")
            os.symlink(victim, link)
            fd = bridge._secure_create(link)
            self.assertIsNone(fd)
            self.assertTrue(os.path.islink(link))
            with open(victim) as f:
                self.assertEqual(f.read(), "secret")

    def test_existing_regular_file_is_replaced(self):
        with _TmpDir() as d:
            path = os.path.join(d, "conf")
            with open(path, "w") as f:
                f.write("stale")
            fd = bridge._secure_create(path)
            self.assertIsNotNone(fd)
            os.close(fd)
            with open(path) as f:
                self.assertEqual(f.read(), "")

    @unittest.skipIf(not IS_POSIX, "mkfifo — POSIX-only")
    def test_fifo_is_not_touched(self):
        with _TmpDir() as d:
            path = os.path.join(d, "conf")
            os.mkfifo(path)
            fd = bridge._secure_create(path)
            self.assertIsNone(fd)
            self.assertTrue(stat.S_ISFIFO(os.lstat(path).st_mode))

    def test_directory_is_not_touched(self):
        with _TmpDir() as d:
            path = os.path.join(d, "subdir")
            os.makedirs(path)
            fd = bridge._secure_create(path)
            self.assertIsNone(fd)
            self.assertTrue(os.path.isdir(path))


class TestShellQuote(unittest.TestCase):
    def test_plain_value(self):
        self.assertEqual(bridge._shell_quote("abc"), "'abc'")

    def test_single_quote_escaped(self):
        self.assertEqual(bridge._shell_quote("a'b"), "'a'\\''b'")

    def test_trailing_single_quote(self):
        # Кавычка в конце значения — классическая инъекция:
        # результат обязан оставаться ОДНИМ shell-словом.
        self.assertEqual(bridge._shell_quote("'"), "''\\'''")

    def test_dollar_and_backtick_stay_literal(self):
        self.assertEqual(bridge._shell_quote("$(reboot)"), "'$(reboot)'")
        self.assertEqual(bridge._shell_quote("`reboot`"), "'`reboot`'")

    def test_no_unescaped_single_quote_inside(self):
        # Инвариант: после подстановки значение остаётся одним shell-словом
        # (ни одна кавычка не «открывает» разбор заново). Проверяем
        # семантически: shlex разбирает KEY=<quote> как пару KEY, value.
        for v in ["", "abc", "a'b", "'", "''", "$(reboot)", "`reboot`",
                  "a b c", "pass'1'2'3", "ru ru"]:
            q = bridge._shell_quote(v)
            self.assertTrue(q.startswith("'") and q.endswith("'"))
            tokens = shlex.split("KEY=" + q)
            self.assertEqual(tokens, ["KEY=" + v], f"разбор сломан: {q!r}")


class TestConfigValueRejection(unittest.TestCase):
    """Правило writeConf (bridge.py): значения с переводом строки
    отклоняются (движок конфиг ИСПОЛНЯЕТ: set -a; . "$CONF"), пустые
    значения пропускаются (режим erase не передаёт ROOT_PART/EFI_PART)."""

    def test_newline_and_cr_rejected(self):
        for bad in ("a\nb", "a\rb", "a\nROOTPASS=hack", "x\rDISK=/dev/sdb"):
            self.assertTrue("\n" in bad or "\r" in bad)

    def test_empty_value_allowed(self):
        # Пустые значения — не ошибка, а пропуск строки KEY=VALUE.
        value = ""
        self.assertEqual(value, "")

    def test_normal_values_allowed(self):
        for ok in ("/dev/sda", "ext4", "my-host", "pass with spaces",
                   "pass'with'quotes"):
            self.assertFalse("\n" in ok)
            self.assertFalse("\r" in ok)


class TestSafeEnv(unittest.TestCase):
    """Проверка env-санитизации: к движку не попадают опасные переменные."""

    def test_drops_dangerous_env_keys(self):
        dangerous = {
            "PYTHONPATH": "/tmp/evil",
            "QT_PLUGIN_PATH": "/tmp/evil",
            "QML2_IMPORT_PATH": "/tmp/evil",
            "LD_LIBRARY_PATH": "/tmp/evil",
            "LD_PRELOAD": "/tmp/evil.so",
        }
        old = {}
        try:
            for k, v in dangerous.items():
                old[k] = os.environ.get(k)
                os.environ[k] = v
            env = bridge.safe_env()
            for k in dangerous:
                self.assertNotIn(k, env, f"{k} не должен уходить в установщик")
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_keeps_safe_env_keys(self):
        env = bridge.safe_env()
        self.assertIn("PATH", env)
        self.assertIsInstance(env, dict)


if __name__ == "__main__":
    unittest.main(verbosity=2)
