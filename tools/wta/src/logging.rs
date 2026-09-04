use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_appender::rolling;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

/// Per-PID helper log file prefix. The `main_helper-{pid}` process label
/// (see `main::process_label`) lands here, e.g.
/// `wta-main_helper-12345.<date>.log`.
const HELPER_LOG_PREFIX: &str = "wta-main_helper-";
/// Per-PID helper logs older than this are reclaimed by [`housekeeping`].
const HELPER_RETENTION_DAYS: u64 = 3;
/// Daily files kept for each Rust WTA log stream. Older matching files are
/// pruned when the appender is opened or rolls over. This is a best-effort
/// bound if concurrent writers race or filesystem deletion fails.
const LOG_MAX_FILES: usize = 3;

/// Holds the non-blocking appender's `WorkerGuard` for the whole process.
///
/// Stored in a global (not a `main()` local) so [`shutdown_flush`] can drop it
/// — flushing the appender — before any `std::process::exit`, which would
/// otherwise skip the `Drop` and lose the final buffered log records.
static GUARD: OnceLock<Mutex<Option<WorkerGuard>>> = OnceLock::new();
/// The normal file destination selected by [`init`], including the temporary
/// fallback directory (package-versioned when package identity is available).
/// When both normal destinations fail, this becomes the known-usable bootstrap
/// parent directory for legacy hook bundles.
///
/// [`log_dir`] feeds legacy hook compatibility. The synchronous panic backstop
/// writes to the bootstrap stream when normal appenders are unavailable.
static EFFECTIVE_LOG_DIR: OnceLock<PathBuf> = OnceLock::new();
/// Whether normal appenders failed and logging is using the bootstrap stream.
static USING_BOOTSTRAP_LOG: OnceLock<bool> = OnceLock::new();

/// Returns the default `EnvFilter` directive to use when neither `WTA_LOG` nor
/// `RUST_LOG` is set.
///
/// `debug_assertions` is passed in (rather than read from `cfg!`) so that the
/// release-build branch can be unit-tested even when the test binary itself is
/// compiled in debug mode.
pub(crate) fn default_filter_directive(debug_assertions: bool) -> &'static str {
    if debug_assertions {
        // Verbose for developers iterating on *our* code, but cap the
        // `agent_client_protocol` crate at `info`. At `debug` that crate dumps
        // every JSON-RPC message body verbatim — and logs each outgoing
        // response twice via its actor spans (`send_raw_message` +
        // `outgoing_protocol_actor`). For the `sessions/list` poll that
        // response is the whole session-registry snapshot (~27 KB), so a
        // routine debug session bloats `wta-main_master.<date>.log` to multiple
        // GB, of
        // which ~99% is this one crate's wire trace. Capping at `info` drops
        // that debug/trace flood while still surfacing anything the crate logs
        // at info and above. Today the crate emits only `trace!`/`debug!` (no
        // info/warn/error), so this is behaviorally identical to `warn` but
        // reads as the minimal cap and is forward-safe if the crate later adds
        // info-level logs. WTA keeps its own dedicated ACP wire log
        // (`wta-acp-debug.log`) for deep debugging; opt the crate's trace back
        // in explicitly with `WTA_LOG=debug,agent_client_protocol=debug`.
        "debug,agent_client_protocol=info"
    } else {
        // Shipping release binaries log at info: enough to follow lifecycle
        // and connection flow out of the box, without the noisy debug traces.
        // Users can still opt into more via `WTA_LOG=debug|trace` / `RUST_LOG`.
        "info"
    }
}

fn effective_destination(destination: Option<&Path>, bootstrap_dir: &Path) -> (PathBuf, bool) {
    match destination {
        Some(destination) => (destination.to_path_buf(), false),
        None => (bootstrap_dir.to_path_buf(), true),
    }
}

/// Root of the WTA log tree: `<local_root>/logs` (or a temp-dir fallback).
fn logs_root() -> std::path::PathBuf {
    crate::runtime_paths::intelligent_terminal_local_root()
        .map(|r| r.join("logs"))
        .unwrap_or_else(|| {
            std::env::temp_dir()
                .join("IntelligentTerminal")
                .join("logs")
        })
}

/// The directory log files are written to: `<root>/logs/<pkgver>` when
/// packaged, `<root>/logs` when unpackaged.
///
/// Shared so every Rust process agrees on the package-private log directory.
/// `spawn.rs` also hands it to pre-0.1.5 hook bundles during auto-upgrade.
pub(crate) fn log_dir() -> std::path::PathBuf {
    if let Some(dir) = EFFECTIVE_LOG_DIR.get() {
        return dir.clone();
    }

    let root = logs_root();
    match package_version() {
        Some(v) => root.join(v),
        None => root,
    }
}

/// A writer that treats last-resort diagnostics as best effort.
struct BestEffortWriter<W> {
    inner: W,
}

impl<W: Write> Write for BestEffortWriter<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let _ = self.inner.write_all(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        let _ = self.inner.flush();
        Ok(())
    }
}

fn bootstrap_log_dir() -> PathBuf {
    std::env::temp_dir()
}

fn best_effort_bootstrap_writer(log_dir: &Path) -> Box<dyn Write + Send> {
    match build_log_writer("bootstrap", log_dir) {
        Ok(writer) => Box::new(BestEffortWriter { inner: writer }),
        Err(_) => Box::new(io::sink()),
    }
}

fn write_bootstrap_diagnostic_to<W: Write>(writer: &mut W, args: std::fmt::Arguments<'_>) {
    let line = format!("{args}\n");
    let _ = writer.write_all(line.as_bytes());
}

fn write_bootstrap_diagnostic_at(log_dir: &Path, args: std::fmt::Arguments<'_>) {
    let mut writer = best_effort_bootstrap_writer(log_dir);
    write_bootstrap_diagnostic_to(&mut writer, args);
}

fn write_panic_record_at(
    log_dir: &Path,
    bootstrap_dir: &Path,
    using_bootstrap_log: bool,
    args: std::fmt::Arguments<'_>,
) {
    if !using_bootstrap_log {
        if let Ok(mut writer) = build_log_writer("panic", log_dir) {
            write_bootstrap_diagnostic_to(&mut writer, args);
            let _ = writer.flush();
            return;
        }
    }

    write_bootstrap_diagnostic_at(bootstrap_dir, args);
}

/// Build the writer for a process without panicking when the log directory is
/// unavailable. Use the fallible builder so appender initialization errors can
/// proceed through the fallback chain instead of panicking.
fn build_log_writer(process: &str, log_dir: &Path) -> Result<Box<dyn Write + Send>, String> {
    let appender = rolling::Builder::new()
        .rotation(rolling::Rotation::DAILY)
        .filename_prefix(format!("wta-{process}"))
        .filename_suffix("log")
        .max_log_files(LOG_MAX_FILES)
        .build(log_dir);

    appender
        .map(|appender| Box::new(appender) as Box<dyn Write + Send>)
        .map_err(|err| err.to_string())
}

struct PreparedLogWriter {
    writer: Box<dyn Write + Send>,
    destination: Option<PathBuf>,
    fallback_reason: Option<String>,
}

fn try_log_destination(
    process: &str,
    logs_root: &Path,
    log_dir: &Path,
    current_version: Option<&str>,
) -> Result<Box<dyn Write + Send>, String> {
    // Old version directories remain reclaimable even when a file or ACL
    // blocks creation of the current version directory.
    housekeeping(logs_root, log_dir, current_version, process);

    std::fs::create_dir_all(log_dir).map_err(|err| {
        format!(
            "failed to create WTA log directory {}: {err}",
            log_dir.display()
        )
    })?;

    build_log_writer(process, log_dir).map_err(|err| {
        format!(
            "failed to initialize WTA {process} log writer in {}: {err}",
            log_dir.display()
        )
    })
}

fn prepare_log_writer(
    process: &str,
    primary_root: &Path,
    primary_dir: &Path,
    fallback_root: &Path,
    fallback_dir: &Path,
    bootstrap_dir: &Path,
    current_version: Option<&str>,
) -> PreparedLogWriter {
    // A recovered primary directory must still prune obsolete package-version
    // directories left by earlier degraded runs in the fallback tree. The
    // current version remains eligible for concurrent fallback writers.
    if primary_root != fallback_root {
        housekeeping(fallback_root, fallback_dir, current_version, process);
    }

    match try_log_destination(process, primary_root, primary_dir, current_version) {
        Ok(writer) => PreparedLogWriter {
            writer,
            destination: Some(primary_dir.to_path_buf()),
            fallback_reason: None,
        },
        Err(primary_error) => {
            if primary_dir != fallback_dir {
                write_bootstrap_diagnostic_at(
                    bootstrap_dir,
                    format_args!(
                        "{primary_error}; trying fallback directory {}",
                        fallback_dir.display()
                    ),
                );

                match try_log_destination(process, fallback_root, fallback_dir, current_version) {
                    Ok(writer) => {
                        return PreparedLogWriter {
                            writer,
                            destination: Some(fallback_dir.to_path_buf()),
                            fallback_reason: Some(primary_error),
                        };
                    }
                    Err(fallback_error) => {
                        let reason = format!("{primary_error}; {fallback_error}");
                        write_bootstrap_diagnostic_at(
                            bootstrap_dir,
                            format_args!(
                                "{reason}; falling back to daily bootstrap logs in {}",
                                bootstrap_dir.display()
                            ),
                        );
                        return PreparedLogWriter {
                            writer: best_effort_bootstrap_writer(bootstrap_dir),
                            destination: None,
                            fallback_reason: Some(reason),
                        };
                    }
                }
            }

            write_bootstrap_diagnostic_at(
                bootstrap_dir,
                format_args!(
                    "{primary_error}; falling back to daily bootstrap logs in {}",
                    bootstrap_dir.display()
                ),
            );
            PreparedLogWriter {
                writer: best_effort_bootstrap_writer(bootstrap_dir),
                destination: None,
                fallback_reason: Some(primary_error),
            }
        }
    }
}

pub fn init(process: &str) {
    let logs_root = logs_root();
    let fallback_root = std::env::temp_dir()
        .join("IntelligentTerminal")
        .join("logs");

    // Per-version subdirectory: each build's logs are stored separately so an
    // upgrade can drop the prior version's logs wholesale — we keep only the
    // current version's dir (see `prune_old_version_dirs`). This is also what
    // makes cleanup lock-free: the live (current-version) dir is never a
    // deletion target, so no process can delete a file another is still writing.
    //
    // The version key is the *package* version (GetCurrentPackageId), shared at
    // runtime with the C++ agent-pane logger so both writers land in the same
    // `logs\<pkgver>\` folder. Unpackaged
    // (dev-from-cargo / tests) has no package identity → logs go flat.
    let version_dir = package_version();
    let log_dir = match &version_dir {
        Some(v) => logs_root.join(v),
        None => logs_root.clone(),
    };
    let fallback_dir = match &version_dir {
        Some(v) => fallback_root.join(v),
        None => fallback_root.clone(),
    };
    let bootstrap_dir = bootstrap_log_dir();

    // Every Rust WTA log stream rotates daily with the same bounded retention,
    // so long-running installations cannot retain any stream indefinitely.
    let prepared = prepare_log_writer(
        process,
        &logs_root,
        &log_dir,
        &fallback_root,
        &fallback_dir,
        &bootstrap_dir,
        version_dir.as_deref(),
    );
    let (effective_log_dir, using_bootstrap_log) =
        effective_destination(prepared.destination.as_deref(), &bootstrap_dir);
    let _ = EFFECTIVE_LOG_DIR.set(effective_log_dir);
    let _ = USING_BOOTSTRAP_LOG.set(using_bootstrap_log);
    let (non_blocking, guard) = tracing_appender::non_blocking(prepared.writer);

    let default_level = default_filter_directive(cfg!(debug_assertions));

    let filter = EnvFilter::try_from_env("WTA_LOG")
        .or_else(|_| EnvFilter::try_from_default_env())
        .unwrap_or_else(|_| EnvFilter::new(default_level));

    tracing_subscriber::registry()
        .with(filter)
        .with(
            fmt::layer()
                .with_writer(non_blocking)
                .with_ansi(false)
                .with_target(true)
                .with_timer(fmt::time::SystemTime),
        )
        .init();

    if let Some(reason) = prepared.fallback_reason {
        if let Some(destination) = prepared.destination {
            tracing::warn!(
                target: "logging",
                reason = %reason,
                fallback_log_dir = %destination.display(),
                "primary WTA log directory unavailable; using fallback directory"
            );
        } else {
            tracing::warn!(
                target: "logging",
                reason = %reason,
                bootstrap_log_dir = %bootstrap_dir.display(),
                "WTA log directories unavailable; using daily bootstrap log"
            );
        }
    }

    // Stash the guard globally so `shutdown_flush` can drop it on exit.
    let _ = GUARD.set(Mutex::new(Some(guard)));
}

/// The current process's package version as `"Major.Minor.Build.Revision"`
/// (e.g. `"0.8.0.2"`), or `None` when the process has no package identity
/// (unpackaged dev runs / tests).
///
/// This is the shared per-version-dir key: the C++ side reads the same value
/// via `GetCurrentPackageId` in `IntelligentTerminalPaths.h`, so the Rust
/// processes and the C++ agent-pane logger resolve to the same
/// `logs\<pkgver>\` folder.
pub(crate) fn package_version() -> Option<String> {
    use windows_sys::Win32::Foundation::ERROR_INSUFFICIENT_BUFFER;
    use windows_sys::Win32::Storage::Packaging::Appx::{GetCurrentPackageId, PACKAGE_ID};

    unsafe {
        // First call sizes the buffer. A packaged process returns
        // ERROR_INSUFFICIENT_BUFFER and fills `len`; unpackaged returns
        // APPMODEL_ERROR_NO_PACKAGE (any other rc means "no usable identity").
        let mut len: u32 = 0;
        if GetCurrentPackageId(&mut len, std::ptr::null_mut()) != ERROR_INSUFFICIENT_BUFFER
            || len == 0
        {
            return None;
        }
        // PACKAGE_ID holds a u64 + pointers, so back it with `u64` storage to
        // guarantee 8-byte alignment (a `Vec<u8>` is only 1-aligned).
        let words = (len as usize + 7) / 8;
        let mut buf = vec![0u64; words.max(1)];
        if GetCurrentPackageId(&mut len, buf.as_mut_ptr() as *mut u8) != 0 {
            return None; // not ERROR_SUCCESS
        }
        let id = &*(buf.as_ptr() as *const PACKAGE_ID);
        // PACKAGE_VERSION { Anonymous: union { Version: u64, Anonymous: { Revision, Build, Minor, Major } } }
        let v = id.version.Anonymous.Anonymous;
        Some(format!(
            "{}.{}.{}.{}",
            v.Major, v.Minor, v.Build, v.Revision
        ))
    }
}

/// Flush and release the file appender. Must be called once before any
/// `std::process::exit` and at the end of `main()`.
///
/// The non-blocking appender only flushes its buffered records when its
/// `WorkerGuard` is dropped. The guard lives in a `static` ([`GUARD`]) — and
/// `static`s never run `Drop` at process teardown — so this explicit
/// take-and-drop is the single flush point for *every* exit path, including
/// the `process::exit` calls that bypass normal stack unwinding. Idempotent:
/// a second call finds the guard already taken and is a no-op.
pub fn shutdown_flush() {
    if let Some(slot) = GUARD.get() {
        if let Ok(mut guard) = slot.lock() {
            guard.take(); // drop the WorkerGuard -> blocks until appender drains
        }
    }
}

/// Install a Windows console control handler that records the teardown
/// signal and drains the log appender before the OS terminates us.
///
/// The wta-**helper** runs as a ConPTY child of Windows Terminal (it's the
/// process rendered in the agent pane). When its pane/tab/window closes — or
/// the user logs off / shuts down — the OS delivers a control event
/// (`CTRL_CLOSE`/`CTRL_LOGOFF`/`CTRL_SHUTDOWN`) and then terminates it at the
/// end of a short grace window. Without a handler those deaths are invisible:
/// the process vanishes mid-stream and the non-blocking appender's last
/// buffered records are lost, because [`shutdown_flush`] never runs (the
/// `WorkerGuard` lives in a `static` and `static`s don't `Drop` at teardown).
/// That is exactly the "helper just stopped responding" signature where the
/// success path is logged exhaustively but the teardown path is silent and
/// the incident is undiagnosable.
///
/// This closes that gap for the helper: it logs WHICH control event tore the
/// process down and flushes so the final records (e.g. the transport-lost
/// WARN in `run_acp_client_over_pipe`) reach disk. The handler returns FALSE
/// so the default handler still runs and the process terminates as before —
/// we only ADD a log line + flush, never changing termination behavior. It's
/// installed process-wide (cheap and harmless), so any wta process that does
/// receive a console control event benefits.
///
/// Coverage limits — what this does NOT catch:
///   * The wta-**master** is spawned `CREATE_NO_WINDOW` and contained in a
///     Job Object with `KILL_ON_JOB_CLOSE` (see C++ `SharedWta`). Its normal
///     teardown is the parent dropping that job, which reaps the master like
///     a `TerminateProcess` — NO control event — so *this handler* does not
///     trace routine master teardown. That teardown is not unlogged overall,
///     though: the C++ parent (`SharedWta`) records both the deliberate
///     job-close and an unexpected exit to `terminal-agent-pane.log`. This
///     handler fires for the master only on genuine console signals
///     (logoff/shutdown), if delivered at all.
///   * A hard `TerminateProcess` (Task Manager "End task", `taskkill /F`, an
///     OS resource kill, or the Job-Object reap above) delivers no control
///     event and stays untraceable from inside the process.
///   * While the Ratatui TUI holds the console in raw mode, Ctrl+C arrives as
///     a key event (not `CTRL_C_EVENT`), so this handler doesn't normally see
///     it and doesn't alter the TUI's Ctrl+C behavior.
pub fn install_ctrl_handler() {
    use windows_sys::Win32::Foundation::{GetLastError, ERROR_INVALID_HANDLE};
    use windows_sys::Win32::System::Console::{
        SetConsoleCtrlHandler, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_C_EVENT, CTRL_LOGOFF_EVENT,
        CTRL_SHUTDOWN_EVENT,
    };

    // Returns `windows_sys`' `BOOL` (an `i32` alias) to match the
    // PHANDLER_ROUTINE signature: 0 == FALSE (fall through to default).
    unsafe extern "system" fn handler(ctrl_type: u32) -> i32 {
        let event = match ctrl_type {
            CTRL_C_EVENT => "CTRL_C",
            CTRL_BREAK_EVENT => "CTRL_BREAK",
            CTRL_CLOSE_EVENT => "CTRL_CLOSE",
            CTRL_LOGOFF_EVENT => "CTRL_LOGOFF",
            CTRL_SHUTDOWN_EVENT => "CTRL_SHUTDOWN",
            _ => "UNKNOWN",
        };
        tracing::warn!(
            target: "lifecycle",
            ctrl_type,
            event,
            "console control event received — process being torn down; flushing logs"
        );
        // Drain the appender so the line above (and any earlier buffered
        // records) hit disk before the grace window ends and we're killed.
        shutdown_flush();
        // FALSE → fall through to the default handler (terminate). We only
        // add logging + flush; termination behavior is unchanged.
        0
    }

    // SAFETY: `handler` is a valid `extern "system"` routine matching the
    // PHANDLER_ROUTINE signature; registering a control handler is a
    // process-global, thread-safe Win32 operation.
    unsafe {
        if SetConsoleCtrlHandler(Some(handler), 1) == 0 {
            // Capture the Win32 error immediately, before any other call (incl.
            // the logging macro's own work) can reset thread-last-error.
            let error_code = GetLastError();
            if error_code == ERROR_INVALID_HANDLE {
                // Expected for a windowless wta process (the CREATE_NO_WINDOW
                // master, a detached CLI invocation): there's no console to
                // signal, and teardown for those is covered elsewhere (the C++
                // side observes the master via its wait callback). Benign —
                // debug only, so it never spams release logs.
                tracing::debug!(
                    target: "lifecycle",
                    error_code,
                    "SetConsoleCtrlHandler: no console attached (expected for windowless process)"
                );
            } else {
                // Any other failure is the diagnostic feature itself failing to
                // arm where we DID expect a console (e.g. the helper) — warn so
                // release (info) logs explain why later teardown signals are
                // absent rather than leaving it a silent mystery.
                tracing::warn!(
                    target: "lifecycle",
                    error_code,
                    "SetConsoleCtrlHandler failed — teardown signals will not be logged"
                );
            }
        }
    }
}

/// Install a panic hook that records the panic to disk, then chains to the
/// previous hook.
///
/// A Rust panic otherwise writes only to stderr — invisible for a ConPTY-
/// hosted helper or a `CREATE_NO_WINDOW` master — and the non-blocking
/// appender's buffered tail is lost when a *fatal* panic kills the process
/// before the background worker drains it. So a panic is a "died for no
/// logged reason" blind spot. This closes it WITHOUT changing panic semantics
/// (it chains the previous hook, so unwind/abort and backtraces are
/// unchanged):
///   * a `tracing::error!` so the panic correlates in the normal log (this
///     drains fine for a *recovered* panic, e.g. behind a `catch_unwind`), and
///   * a synchronous append to `wta-panic.log`, independent of the async
///     appender, so the record reaches disk even when a fatal panic kills us.
///
/// It deliberately does NOT call [`shutdown_flush`]: that drops the appender
/// guard and would permanently kill logging after a recoverable panic. The
/// synchronous file write is the durable path instead.
pub fn install_panic_hook() {
    let prev = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        // Same payload extraction the rest of the codebase uses.
        let msg = info
            .payload()
            .downcast_ref::<&'static str>()
            .copied()
            .or_else(|| info.payload().downcast_ref::<String>().map(|s| s.as_str()))
            .unwrap_or("<non-string panic payload>");
        let location = info
            .location()
            .map(|l| format!("{}:{}:{}", l.file(), l.line(), l.column()))
            .unwrap_or_else(|| "<unknown>".to_string());
        let thread_name = std::thread::current()
            .name()
            .unwrap_or("<unnamed>")
            .to_string();

        tracing::error!(
            target: "panic",
            message = %msg,
            location = %location,
            thread = %thread_name,
            "thread panicked"
        );

        // Guaranteed-on-disk backstop: a fatal main-thread panic unwinds past
        // main() without reaching any `shutdown_flush`, so the appender's
        // buffered tail (incl. the error above) can be lost. A synchronous
        // write here does not depend on the normal appender being alive.
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let panic_record = format!(
            "[{millis}ms] pid={} thread={thread_name} panicked at {location}: {msg}",
            std::process::id()
        );
        write_panic_record_at(
            &log_dir(),
            &bootstrap_log_dir(),
            USING_BOOTSTRAP_LOG.get().copied().unwrap_or(false),
            format_args!("{panic_record}"),
        );

        prev(info);
    }));
}

/// Filesystem upkeep run once per process at logging init, before our own
/// appender opens.
///
/// 1. Cap the number of retained per-version log dirs (drops older builds'
///    logs after an upgrade).
/// 2. Reclaim per-PID helper logs older than [`HELPER_RETENTION_DAYS`] within
///    the current version's dir.
fn housekeeping(logs_root: &Path, log_dir: &Path, current_version: Option<&str>, process: &str) {
    // Only meaningful when packaged (there are per-version subdirs to cap);
    // unpackaged dev/tests write flat and have nothing to prune here.
    if let Some(current) = current_version {
        prune_old_version_dirs(logs_root, current);
    }
    // Only long-lived / relevant processes scan for stale helper files; the
    // high-frequency `cli` path must not pay a directory scan on every call.
    if process == "main_master" || process.starts_with("main_helper") {
        prune_stale_helper_logs(log_dir);
    }
}

/// Delete every per-version log subdir under `logs/` except the current
/// build's — we keep only the current version's logs, so on any start after an
/// upgrade the prior versions' dirs are removed wholesale.
///
/// The current dir is never a deletion target, so this needs no inter-process
/// lock even when several upgraded processes start at once: they only ever race
/// to delete the same *dead* (old-version) dirs, and `remove_dir_all` is
/// idempotent.
fn prune_old_version_dirs(logs_root: &Path, current: &str) {
    let Ok(entries) = std::fs::read_dir(logs_root) else {
        return;
    };
    for entry in entries.flatten() {
        if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            // Leave any flat files alone — only version subdirs are pruned.
            // (Post-unification all writers use the versioned dir, but a stray
            // pre-upgrade flat log must never be a deletion target here.)
            continue;
        }
        if entry.file_name().to_string_lossy() == current {
            continue; // never delete the live dir
        }
        let _ = std::fs::remove_dir_all(entry.path());
    }
}

/// Delete per-PID helper logs whose mtime is older than
/// [`HELPER_RETENTION_DAYS`]. Each PID has its own daily-rotated
/// `wta-main_helper-{pid}.<date>.log` stream, so appender retention cannot
/// reclaim streams abandoned when helper processes exit.
///
/// Mtime is an activity heuristic, not a liveness check. A helper that stays
/// idle beyond the retention window can match; removal failures are ignored.
/// A liveness-aware policy belongs in a separate audit.
fn prune_stale_helper_logs(log_dir: &Path) {
    let Some(cutoff) = std::time::SystemTime::now().checked_sub(std::time::Duration::from_secs(
        HELPER_RETENTION_DAYS * 24 * 60 * 60,
    )) else {
        return;
    };

    if let Ok(entries) = std::fs::read_dir(log_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.starts_with(HELPER_LOG_PREFIX) {
                continue;
            }
            let stale = entry
                .metadata()
                .and_then(|m| m.modified())
                .map(|mtime| mtime < cutoff)
                .unwrap_or(false);
            if stale {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::filter::LevelFilter;

    struct TestScratchDir(std::path::PathBuf);

    impl TestScratchDir {
        fn new(label: &str) -> Self {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!("{label}-{}-{nonce}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TestScratchDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    struct FailingWriter;

    impl Write for FailingWriter {
        fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
            Err(std::io::Error::other("diagnostic write failed"))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Err(std::io::Error::other("diagnostic flush failed"))
        }
    }

    #[derive(Default)]
    struct RecordingWriter {
        writes: Vec<Vec<u8>>,
    }

    impl Write for RecordingWriter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.writes.push(buf.to_vec());
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn matching_daily_logs(root: &Path, prefix: &str) -> Vec<PathBuf> {
        std::fs::read_dir(root)
            .unwrap()
            .flatten()
            .filter_map(|entry| {
                let name = entry.file_name();
                let name = name.to_string_lossy();
                if name.starts_with(&format!("{prefix}.")) && name.ends_with(".log") {
                    Some(entry.path())
                } else {
                    None
                }
            })
            .collect()
    }

    #[test]
    fn debug_build_default_is_debug() {
        assert_eq!(
            default_filter_directive(true),
            "debug,agent_client_protocol=info"
        );
    }

    #[test]
    fn debug_build_default_caps_acp_crate_at_info() {
        // The debug default keeps our own code at `debug` but must cap the
        // noisy `agent_client_protocol` wire trace, or a routine debug run
        // balloons wta-main_master.<date>.log to multiple GB (see the directive doc).
        let directive = default_filter_directive(true);
        assert!(directive.starts_with("debug"));
        assert!(directive.contains("agent_client_protocol=info"));
    }

    #[test]
    fn release_build_default_is_info() {
        assert_eq!(default_filter_directive(false), "info");
    }

    #[test]
    fn release_default_filter_enables_info() {
        // The EnvFilter built from the release default must enable info (and
        // warn/error), so shipping builds have useful logs without WTA_LOG.
        let filter = EnvFilter::new(default_filter_directive(false));
        assert_eq!(filter.max_level_hint(), Some(LevelFilter::INFO));
    }

    #[test]
    fn debug_default_filter_enables_debug() {
        let filter = EnvFilter::new(default_filter_directive(true));
        assert_eq!(filter.max_level_hint(), Some(LevelFilter::DEBUG));
    }

    #[test]
    fn prune_keeps_only_current_version() {
        let root = std::env::temp_dir().join(format!("wta-version-prune-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        let current = "9.9.9.9";
        std::fs::create_dir_all(root.join(current)).unwrap();
        // Several older version dirs, each with a log file inside.
        for v in ["0.0.1", "0.0.2", "0.0.3", "0.0.4", "0.0.5"] {
            let d = root.join(v);
            std::fs::create_dir_all(&d).unwrap();
            std::fs::write(d.join("wta-main.log"), "x").unwrap();
        }
        // A flat non-dir file must be left untouched.
        std::fs::write(root.join("terminal-agent-pane.log"), "cpp").unwrap();

        prune_old_version_dirs(&root, current);

        // Current version survives; flat file untouched; every older version gone.
        assert!(root.join(current).exists());
        assert!(root.join("terminal-agent-pane.log").exists());
        for v in ["0.0.1", "0.0.2", "0.0.3", "0.0.4", "0.0.5"] {
            assert!(
                !root.join(v).exists(),
                "old version dir {v} must be deleted"
            );
        }
        let dir_count = std::fs::read_dir(&root)
            .unwrap()
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .count();
        assert_eq!(dir_count, 1);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn prune_stale_helper_logs_keeps_recent_and_non_helper_files() {
        let scratch = TestScratchDir::new("wta-helper-prune");
        let root = scratch.path();

        let stale_helper = root.join("wta-main_helper-123.2000-01-01.log");
        std::fs::write(&stale_helper, "stale").unwrap();
        let stale_time = std::time::SystemTime::now()
            .checked_sub(std::time::Duration::from_secs(
                (HELPER_RETENTION_DAYS + 1) * 24 * 60 * 60,
            ))
            .unwrap();
        std::fs::OpenOptions::new()
            .write(true)
            .open(&stale_helper)
            .unwrap()
            .set_modified(stale_time)
            .unwrap();

        let recent_helper = root.join("wta-main_helper-456.2000-01-01.log");
        std::fs::write(&recent_helper, "recent").unwrap();
        let non_helper = root.join("wta-main_master.2000-01-01.log");
        std::fs::write(&non_helper, "keep").unwrap();
        std::fs::OpenOptions::new()
            .write(true)
            .open(&non_helper)
            .unwrap()
            .set_modified(stale_time)
            .unwrap();
        let cpp_log = root.join("terminal-agent-pane.log");
        std::fs::write(&cpp_log, "keep").unwrap();
        std::fs::OpenOptions::new()
            .write(true)
            .open(&cpp_log)
            .unwrap()
            .set_modified(stale_time)
            .unwrap();

        prune_stale_helper_logs(root);

        assert!(!stale_helper.exists());
        assert!(recent_helper.exists());
        assert!(non_helper.exists());
        assert!(cpp_log.exists());
    }

    #[test]
    fn housekeeping_skips_helper_scan_for_cli() {
        let scratch = TestScratchDir::new("wta-helper-housekeeping");
        let stale_helper = scratch.path().join("wta-main_helper-123.2000-01-01.log");
        std::fs::write(&stale_helper, "stale").unwrap();
        let stale_time = std::time::SystemTime::now()
            .checked_sub(std::time::Duration::from_secs(
                (HELPER_RETENTION_DAYS + 1) * 24 * 60 * 60,
            ))
            .unwrap();
        std::fs::OpenOptions::new()
            .write(true)
            .open(&stale_helper)
            .unwrap()
            .set_modified(stale_time)
            .unwrap();

        housekeeping(scratch.path(), scratch.path(), None, "cli");
        assert!(stale_helper.exists());

        housekeeping(scratch.path(), scratch.path(), None, "main_master");
        assert!(!stale_helper.exists());
    }

    #[test]
    fn log_writer_returns_errors_for_unusable_directory() {
        let scratch = TestScratchDir::new("wta-log-writer-fallback");
        let blocker = scratch.path().join("not-a-directory");
        std::fs::write(&blocker, "blocker").unwrap();
        let unusable_dir = blocker.join("logs");

        assert!(build_log_writer("cli", &unusable_dir).is_err());
        assert!(build_log_writer("main_master", &unusable_dir).is_err());
    }

    #[test]
    fn log_writer_uses_daily_file_name() {
        let scratch = TestScratchDir::new("wta-log-writer-name");
        let writer = build_log_writer("main_master", scratch.path()).unwrap();
        drop(writer);

        assert_eq!(
            matching_daily_logs(scratch.path(), "wta-main_master").len(),
            1
        );
    }

    #[test]
    fn healthy_primary_directory_does_not_use_fallback() {
        let scratch = TestScratchDir::new("wta-log-primary");
        let primary_root = scratch.path().join("primary-root");
        let primary_dir = primary_root.join("logs");
        let fallback_root = scratch.path().join("fallback-root");
        let fallback_dir = fallback_root.join("logs");

        let prepared = prepare_log_writer(
            "main_master",
            &primary_root,
            &primary_dir,
            &fallback_root,
            &fallback_dir,
            scratch.path(),
            None,
        );
        drop(prepared.writer);

        assert_eq!(prepared.destination.as_deref(), Some(primary_dir.as_path()));
        assert!(prepared.fallback_reason.is_none());
        assert_eq!(
            matching_daily_logs(&primary_dir, "wta-main_master").len(),
            1
        );
        assert!(!fallback_dir.exists());
    }

    #[test]
    fn healthy_primary_prunes_stale_fallback_versions() {
        let scratch = TestScratchDir::new("wta-log-fallback-prune");
        let current = "9.9.9.9";
        let primary_root = scratch.path().join("primary-root");
        let primary_dir = primary_root.join(current);
        let fallback_root = scratch.path().join("fallback-root");
        let fallback_dir = fallback_root.join(current);
        let stale_fallback = fallback_root.join("0.0.0.1");
        std::fs::create_dir_all(&stale_fallback).unwrap();
        std::fs::write(
            stale_fallback.join("wta-main_master.2000-01-01.log"),
            "stale",
        )
        .unwrap();

        let prepared = prepare_log_writer(
            "main_master",
            &primary_root,
            &primary_dir,
            &fallback_root,
            &fallback_dir,
            scratch.path(),
            Some(current),
        );
        drop(prepared.writer);

        assert_eq!(prepared.destination.as_deref(), Some(primary_dir.as_path()));
        assert!(!stale_fallback.exists());
        assert!(!fallback_dir.exists());
    }

    #[test]
    fn blocked_current_directory_does_not_block_version_pruning() {
        let scratch = TestScratchDir::new("wta-log-blocked-version-prune");
        let current = "9.9.9.9";
        let primary_root = scratch.path().join("primary-root");
        let primary_dir = primary_root.join(current);
        let stale_primary = primary_root.join("0.0.0.1");
        std::fs::create_dir_all(&stale_primary).unwrap();
        std::fs::write(
            stale_primary.join("wta-main_master.2000-01-01.log"),
            "stale",
        )
        .unwrap();
        std::fs::write(&primary_dir, "blocker").unwrap();
        let fallback_root = scratch.path().join("fallback-root");
        let fallback_dir = fallback_root.join(current);

        let prepared = prepare_log_writer(
            "main_master",
            &primary_root,
            &primary_dir,
            &fallback_root,
            &fallback_dir,
            scratch.path(),
            Some(current),
        );
        drop(prepared.writer);

        assert_eq!(
            prepared.destination.as_deref(),
            Some(fallback_dir.as_path())
        );
        assert!(!stale_primary.exists());
    }

    #[test]
    fn all_log_writers_use_daily_names_and_enforce_retention() {
        for process in [
            "cli",
            "main_master",
            "delegate",
            "probe",
            "install-hooks",
            "panic",
            "bootstrap",
        ] {
            let scratch = TestScratchDir::new(&format!("wta-{process}-retention"));
            let prefix = format!("wta-{process}");
            let seeded_logs: Vec<_> = (1..=LOG_MAX_FILES + 2)
                .map(|day| {
                    scratch
                        .path()
                        .join(format!("{prefix}.2000-01-{day:02}.log"))
                })
                .collect();
            for path in &seeded_logs {
                std::fs::write(path, "old").unwrap();
            }

            let writer = build_log_writer(process, scratch.path()).unwrap();
            drop(writer);

            let date_format = time::format_description::parse("[year]-[month]-[day]").unwrap();
            let logs: Vec<_> = matching_daily_logs(scratch.path(), &prefix)
                .into_iter()
                .filter(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .and_then(|name| name.strip_prefix(&format!("{prefix}.")))
                        .and_then(|name| name.strip_suffix(".log"))
                        .is_some_and(|date| time::Date::parse(date, &date_format).is_ok())
                })
                .collect();
            assert_eq!(logs.len(), LOG_MAX_FILES, "{process}");
            assert_eq!(
                seeded_logs.iter().filter(|path| !path.exists()).count(),
                3,
                "{process}"
            );
        }
    }

    #[test]
    fn create_directory_failure_uses_fallback_directory() {
        let scratch = TestScratchDir::new("wta-log-create-fallback");
        let blocker = scratch.path().join("not-a-directory");
        std::fs::write(&blocker, "blocker").unwrap();
        let primary_dir = blocker.join("logs");
        let fallback_root = scratch.path().join("fallback-root");
        let fallback_dir = fallback_root.join("logs");

        let prepared = prepare_log_writer(
            "main_master",
            &blocker,
            &primary_dir,
            &fallback_root,
            &fallback_dir,
            scratch.path(),
            None,
        );
        drop(prepared.writer);

        assert_eq!(
            prepared.destination.as_deref(),
            Some(fallback_dir.as_path())
        );
        assert!(prepared
            .fallback_reason
            .as_deref()
            .unwrap()
            .contains("failed to create WTA log directory"));
        assert_eq!(
            matching_daily_logs(&fallback_dir, "wta-main_master").len(),
            1
        );
    }

    #[test]
    fn appender_failure_uses_fallback_directory() {
        let scratch = TestScratchDir::new("wta-log-appender-fallback");
        let primary_root = scratch.path().join("primary-root");
        let primary_dir = primary_root.join("logs");
        let probe_dir = scratch.path().join("probe");
        std::fs::create_dir_all(&probe_dir).unwrap();
        let probe_writer = build_log_writer("main_master", &probe_dir).unwrap();
        drop(probe_writer);
        let generated_name = matching_daily_logs(&probe_dir, "wta-main_master")
            .into_iter()
            .next()
            .unwrap()
            .file_name()
            .unwrap()
            .to_owned();
        std::fs::create_dir_all(primary_dir.join(generated_name)).unwrap();
        let fallback_root = scratch.path().join("fallback-root");
        let fallback_dir = fallback_root.join("logs");

        let prepared = prepare_log_writer(
            "main_master",
            &primary_root,
            &primary_dir,
            &fallback_root,
            &fallback_dir,
            scratch.path(),
            None,
        );
        drop(prepared.writer);

        assert_eq!(
            prepared.destination.as_deref(),
            Some(fallback_dir.as_path())
        );
        assert!(prepared
            .fallback_reason
            .as_deref()
            .unwrap()
            .contains("failed to initialize WTA main_master log writer"));
        assert_eq!(
            matching_daily_logs(&fallback_dir, "wta-main_master").len(),
            1
        );
    }

    #[test]
    fn unusable_primary_and_fallback_use_bootstrap_log() {
        let scratch = TestScratchDir::new("wta-log-bootstrap-fallback");
        let primary_blocker = scratch.path().join("primary-blocker");
        let fallback_blocker = scratch.path().join("fallback-blocker");
        std::fs::write(&primary_blocker, "blocker").unwrap();
        std::fs::write(&fallback_blocker, "blocker").unwrap();

        let prepared = prepare_log_writer(
            "main_master",
            &primary_blocker,
            &primary_blocker.join("logs"),
            &fallback_blocker,
            &fallback_blocker.join("logs"),
            scratch.path(),
            None,
        );

        assert!(prepared.destination.is_none());
        let reason = prepared.fallback_reason.as_deref().unwrap();
        assert_eq!(
            reason
                .match_indices("failed to create WTA log directory")
                .count(),
            2
        );
        let bootstrap_path = matching_daily_logs(scratch.path(), "wta-bootstrap")
            .into_iter()
            .next()
            .unwrap();
        let bootstrap = std::fs::read_to_string(&bootstrap_path).unwrap();
        assert!(bootstrap.contains(reason));
        assert!(bootstrap.contains(&fallback_blocker.join("logs").display().to_string()));

        let mut writer = prepared.writer;
        writer.write_all(b"degraded-record\n").unwrap();
        writer.flush().unwrap();
        drop(writer);
        let bootstrap = std::fs::read_to_string(bootstrap_path).unwrap();
        assert!(bootstrap.contains("degraded-record"));
    }

    #[test]
    fn identical_primary_and_fallback_are_attempted_once() {
        let scratch = TestScratchDir::new("wta-log-identical-fallback");
        let blocker = scratch.path().join("blocker");
        std::fs::write(&blocker, "blocker").unwrap();
        let unusable_dir = blocker.join("logs");

        let prepared = prepare_log_writer(
            "main_master",
            &blocker,
            &unusable_dir,
            &blocker,
            &unusable_dir,
            scratch.path(),
            None,
        );

        assert!(prepared.destination.is_none());
        assert_eq!(
            prepared
                .fallback_reason
                .as_deref()
                .unwrap()
                .match_indices("failed to create WTA log directory")
                .count(),
            1
        );
    }

    #[test]
    fn bootstrap_diagnostics_ignore_write_failures() {
        let mut writer = FailingWriter;
        write_bootstrap_diagnostic_to(&mut writer, format_args!("diagnostic"));
    }

    #[test]
    fn panic_record_falls_back_when_normal_log_writer_fails() {
        let scratch = TestScratchDir::new("wta-panic-bootstrap-fallback");
        let blocker = scratch.path().join("blocker");
        std::fs::write(&blocker, "blocker").unwrap();

        write_panic_record_at(
            &blocker.join("logs"),
            scratch.path(),
            false,
            format_args!("panic breadcrumb"),
        );

        let bootstrap_path = matching_daily_logs(scratch.path(), "wta-bootstrap")
            .into_iter()
            .next()
            .unwrap();
        assert!(std::fs::read_to_string(bootstrap_path)
            .unwrap()
            .contains("panic breadcrumb"));
    }

    #[test]
    fn effective_destination_uses_bootstrap_parent_when_normal_paths_fail() {
        let primary = Path::new(r"C:\package-private\logs\1.2.3.4");
        let bootstrap = Path::new(r"C:\temp");

        assert_eq!(
            effective_destination(Some(primary), bootstrap),
            (primary.to_path_buf(), false)
        );
        assert_eq!(
            effective_destination(None, bootstrap),
            (bootstrap.to_path_buf(), true)
        );
    }

    #[test]
    fn bootstrap_diagnostic_is_appended_in_one_write() {
        let mut writer = RecordingWriter::default();
        write_bootstrap_diagnostic_to(
            &mut writer,
            format_args!("diagnostic {} {}", "with", "fragments"),
        );

        assert_eq!(writer.writes, [b"diagnostic with fragments\n".to_vec()]);
    }

    #[test]
    fn best_effort_fallback_writer_ignores_write_failures() {
        let mut writer = BestEffortWriter {
            inner: FailingWriter,
        };
        assert_eq!(writer.write(b"diagnostic").unwrap(), 10);
        writer.flush().unwrap();
    }

    #[test]
    fn best_effort_fallback_writer_forwards_the_complete_record() {
        let mut writer = BestEffortWriter {
            inner: std::io::Cursor::new(Vec::new()),
        };

        assert_eq!(writer.write(b"diagnostic").unwrap(), 10);
        assert_eq!(writer.inner.into_inner(), b"diagnostic");
    }

    #[test]
    fn bootstrap_writer_uses_daily_rotation_and_retention() {
        let scratch = TestScratchDir::new("wta-bootstrap-retention");
        for day in 1..=LOG_MAX_FILES + 2 {
            std::fs::write(
                scratch
                    .path()
                    .join(format!("wta-bootstrap.2000-01-{day:02}.log")),
                "old",
            )
            .unwrap();
        }

        let mut writer = best_effort_bootstrap_writer(scratch.path());
        writer.write_all(b"diagnostic").unwrap();
        writer.flush().unwrap();
        drop(writer);

        assert_eq!(
            matching_daily_logs(scratch.path(), "wta-bootstrap").len(),
            LOG_MAX_FILES
        );
    }
}
