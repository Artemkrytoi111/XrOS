// GUI тут только собирает выборы и запускает проверенный
// консольный установщик. Саму установку не изобретаем:
// /usr/local/bin/xros-install в неинтерактивном режиме делает
// разметку, копирование, ядро, GRUB, пользователя и всё остальное.

use crate::app::{Choices, PartMode};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};

pub const INSTALLER: &str = "/usr/local/bin/xros-install";
pub const CONF: &str = "/tmp/xros-install.conf";
pub const LOGFILE: &str = "/tmp/xros-install.log";

// Сколько ждём, пока движок сам завершится после SIGTERM группе,
// прежде чем добить группу SIGKILL (cleanup: размонтирование и т.п.).
const CANCEL_GRACE_MS: u64 = 5_000;

// Ручка запущенного движка установки. Хранится в App, пока идёт
// установка: GUI отслеживает дочерний процесс и может его остановить.
//
// Почему два механизма сразу, а не один:
//  * PR_SET_PDEATHSIG (SIGTERM) — страховка от АВАРИЙНОГО завершения
//    GUI (падение, kill извне, OOM): ядро само шлёт движку SIGTERM,
//    как только родитель умирает. Работает, даже когда GUI уже не
//    может выполнить ни одной инструкции. Ловушка в xros-install
//    по SIGTERM делает cleanup и выходит с кодом 143.
//  * Отдельная группа процессов (setsid) — для ШТАТНОЙ отмены из GUI
//    и для внуков движка: kill(-pgid, SIGTERM) гасит не только сам
//    xros-install, но и rsync / arch-chroot / mkfs, которые обычный
//    Child::kill() оставил бы сиротами дописывать систему в фоне.
//    PDEATHSIG такого не даёт: он бьёт только в прямой дочерний
//    процесс, а не в его детей.
// pre_exec выполняется в дочернем процессе МЕЖДУ fork и exec —
// PDEATHSIG ставится ДО первой инструкции движка, поэтому окна,
// в котором родитель умер, а сигнал ещё не вооружён, нет. Остаётся
// одна микро-гонка: родитель может умереть между fork и самим prctl —
// тогда дочерний уже переродительствован (init/sub-reaper), и
// PDEATHSIG относился бы к новому родителю, а не к GUI. Закрываем её
// проверкой getppid() сразу после prctl: ppid не равен pid GUI —
// значит, родитель уже мёртв, и мы выходим до exec (spawn вернёт Err).
pub struct InstallHandle {
    child: Arc<Mutex<Child>>,
    pgid: i32,
    cancelled: Arc<AtomicBool>,
}

impl InstallHandle {
    pub fn was_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    pub fn is_running(&self) -> bool {
        match self.child.lock() {
            Ok(mut c) => matches!(c.try_wait(), Ok(None)),
            Err(_) => false,
        }
    }

    fn signal_group(&self, sig: libc::c_int) {
        // минус перед pgid = сигнал всей группе, а не одному процессу
        unsafe {
            libc::kill(-self.pgid, sig);
        }
    }

    // Штатная отмена: SIGTERM всей группе, затем, если движок не ушёл
    // сам (cleanup занимает секунды: размонтирование и т.п.), —
    // SIGKILL группе. Не ждём завершения здесь: единственный, кто
    // делает wait() и шлёт InstallEvent::Finished, — поток чтения
    // stdout (см. start_install). Двойной wait дал бы ECHILD.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.signal_group(libc::SIGTERM);
        let child = Arc::clone(&self.child);
        let pgid = self.pgid;
        std::thread::spawn(move || {
            let deadline =
                std::time::Instant::now() + std::time::Duration::from_millis(CANCEL_GRACE_MS);
            loop {
                let gone = match child.lock() {
                    Ok(mut c) => !matches!(c.try_wait(), Ok(None)),
                    Err(_) => true,
                };
                if gone || std::time::Instant::now() >= deadline {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            if std::time::Instant::now() >= deadline {
                let still_running = match child.lock() {
                    Ok(mut c) => matches!(c.try_wait(), Ok(None)),
                    Err(_) => false,
                };
                if still_running {
                    unsafe {
                        libc::kill(-pgid, libc::SIGKILL);
                    }
                }
            }
        });
    }
}

impl Drop for InstallHandle {
    fn drop(&mut self) {
        // Последняя страховка на путях, где App просто выбрасывает
        // ручку (например, окно закрыли после Finished): если движок
        // каким-то образом ещё жив — SIGTERM группе, без ожидания.
        // При аварийном завершении самого GUI (SIGKILL/падение) Drop
        // не выполняется — там работает только PDEATHSIG.
        if self.is_running() {
            self.signal_group(libc::SIGTERM);
        }
    }
}

#[derive(Debug)]
pub enum InstallEvent {
    Progress(u8),
    Status(String),
    Log(String),
    Finished(bool),
}

// кавычки, иначе пароль с пробелом всё сломает
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

pub fn write_conf(sel: &Choices) -> std::io::Result<()> {
    let rootpass = if sel.same_admin_pass {
        sel.userpass.clone()
    } else {
        sel.rootpass.clone()
    };
    let partmode = match sel.partmode {
        PartMode::Erase => "erase",
        PartMode::Manual => "manual",
    };
    let vals: [(&str, String); 15] = [
        ("DISK", sel.disk.clone()),
        ("PARTMODE", partmode.to_string()),
        ("ROOT_PART", sel.root_part.clone()),
        ("EFI_PART", sel.efi_part.clone()),
        ("FS", sel.fs.clone()),
        ("HOSTNAME", sel.hostname.clone()),
        ("FULLNAME", sel.fullname.clone()),
        ("USERNAME", sel.username.clone()),
        ("USERPASS", sel.userpass.clone()),
        ("ROOTPASS", rootpass),
        ("AUTOLOGIN", if sel.autologin { "1" } else { "0" }.to_string()),
        ("TIMEZONE", sel.timezone.clone()),
        ("KEYMAP", sel.keymap.clone()),
        ("DE", sel.de.clone()),
        ("OFFICE", sel.office.clone()),
    ];
    // 600 — с момента создания: File::create дал бы 644 на время записи,
    // а в конфиге — оба пароля. OpenOptionsExt::mode действует только
    // при создании, поэтому set_permissions оставляем для уже
    // существующего файла с чужими правами.
    // Убираем заранее созданный файл/симлинк: иначе OpenOptions
    // пошёл бы по симлинку (чужие права/цель), а leftover от прошлого
    // упавшего запуска содержал бы старые пароли.
    let _ = std::fs::remove_file(CONF);
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(CONF)?;
    for (k, v) in vals {
        writeln!(f, "{k}={}", shell_quote(&v))?;
    }
    drop(f);
    std::fs::set_permissions(CONF, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

pub fn start_install(
    sel: &Choices,
) -> std::io::Result<(mpsc::Receiver<InstallEvent>, InstallHandle)> {
    write_conf(sel)?;
    let parent_pid = std::process::id() as libc::pid_t;
    let mut cmd = Command::new(INSTALLER);
    cmd.env("XROS_NONINTERACTIVE", "1")
        .env("XROS_INSTALL_CONF", CONF)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    // SAFETY: pre_exec — unsafe fn, потому что замыкание выполняется
    // в дочернем процессе после fork, до exec: там разрешены только
    // async-signal-safe операции без аллокаций и блокировок. Наше
    // замыкание делает только prctl/getppid/setsid и возвращает
    // ошибки без аллокаций (last_os_error / from_raw_os_error).
    unsafe {
        cmd.pre_exec(move || {
            // Порядок важен: сначала PDEATHSIG, потом проверка ppid
            // (см. комментарий к InstallHandle), потом setsid.
            // setsid после prctl безопасен: смена группы не трогает
            // PDEATHSIG, а pid дочернего при этом не меняется.
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent_pid {
                // Родитель уже мёртв (переродительствование).
                // ESRCH — без аллокаций; текст ошибки не важен,
                // spawn всё равно вернёт Err, а движок не запустится.
                return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
            }
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    // Конфиг с паролями уже записан. Если spawn не удался, движок
    // его не прочитает и не удалит — стираем сами, чтобы пароли
    // не остались в /tmp.
    let child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) => {
            let _ = std::fs::remove_file(CONF);
            return Err(e);
        }
    };
    let pgid = child.id() as i32;
    // после setsid pid дочернего == pgid его новой группы
    let child = Arc::new(Mutex::new(child));
    let handle = InstallHandle {
        child: Arc::clone(&child),
        pgid,
        cancelled: Arc::new(AtomicBool::new(false)),
    };
    let (tx, rx) = mpsc::channel();
    let stdout = child
        .lock()
        .map_err(|_| std::io::Error::other("child mutex poisoned"))?
        .stdout
        .take()
        .expect("stdout перехвачен");
    let stderr = child
        .lock()
        .map_err(|_| std::io::Error::other("child mutex poisoned"))?
        .stderr
        .take()
        .expect("stderr перехвачен");

    // stderr — отдельным потоком, чтобы не забить буфер
    let tx_err = tx.clone();
    std::thread::spawn(move || {
        let reader = BufReader::new(stderr);
        for line in reader.lines() {
            let Ok(line) = line else { break };
            if !line.trim().is_empty() {
                let _ = tx_err.send(InstallEvent::Log(line));
            }
        }
    });

    let child_for_wait = Arc::clone(&child);
    std::thread::spawn(move || {
        let reader = BufReader::new(stdout);
        let mut in_xxx = false;
        let mut saw_done = false;
        for line in reader.lines() {
            let Ok(line) = line else { break };
            let line = line.trim_end().to_string();
            if line.is_empty() {
                continue;
            }
            // dialog шлёт XXX до и после статуса, так что флаг туда-сюда
            if line == "XXX" {
                in_xxx = !in_xxx;
                continue;
            }
            if in_xxx {
                let _ = tx.send(InstallEvent::Status(line));
                continue;
            }
            if line.chars().all(|c| c.is_ascii_digit()) {
                if let Ok(n) = line.parse::<u8>() {
                    let _ = tx.send(InstallEvent::Progress(n));
                }
                continue;
            }
            match line.as_str() {
                "INSTALL_DONE" => {
                    saw_done = true;
                    let _ = tx.send(InstallEvent::Finished(true));
                }
                "INSTALL_FAILED" => {
                    saw_done = true;
                    let _ = tx.send(InstallEvent::Finished(false));
                }
                _ => {
                    let _ = tx.send(InstallEvent::Log(line));
                }
            }
        }
        if !saw_done {
            // Единственное место, где делается wait(): поток-отменщик
            // (InstallHandle::cancel) только сигналит группе и проверяет
            // try_wait, но не ждёт — иначе два wait() дали бы ECHILD.
            // К этому моменту stdout закрыт, т.е. движок уже вышел
            // (или был убит) — wait() здесь не висит.
            let ok = child_for_wait
                .lock()
                .map(|mut c| c.wait().map(|s| s.success()).unwrap_or(false))
                .unwrap_or(false);
            let _ = tx.send(InstallEvent::Finished(ok));
        }
    });
    Ok((rx, handle))
}

// хвост журнала — для диалога об ошибке
pub fn log_tail(n: usize) -> String {
    let Ok(text) = std::fs::read_to_string(LOGFILE) else {
        return String::new();
    };
    let lines: Vec<&str> = text.lines().rev().take(n).collect();
    lines.into_iter().rev().collect::<Vec<_>>().join("\n")
}
