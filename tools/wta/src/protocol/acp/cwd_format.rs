//! Resolve the working directory for ACP `session/new` / `session/load`
//! in the **agent's own path namespace**.
//!
//! ## Why this exists
//!
//! The ACP `cwd` field must be a valid absolute path *in the agent
//! process's namespace*. An agent launched inside WSL validates against the
//! Linux filesystem, so a Windows path like `C:\WINDOWS\system32` (what
//! `std::env::current_dir()` returns for the packaged helper) is rejected
//! with `Directory path must be absolute`. A Windows-native agent, by
//! contrast, happily accepts that same Windows path — which is why the bug
//! only ever reproduced with WSL agents.
//!
//! ## Approach (no launcher/profile parsing — wrapper-proof)
//!
//! 1. **Target format** — which namespace the agent expects — is learned
//!    from the agent itself via `session/list`: each prior session reports
//!    its `cwd`, and a leading `/` means POSIX, a drive-letter means
//!    Windows. This is authoritative regardless of how the agent was
//!    launched (`wsl.exe …`, a `.cmd` wrapper, `cmd /c …`, etc.). When the
//!    list is empty or unsupported the target is unknown and the caller
//!    tries both formats.
//!
//! 2. **Source value** — the cwd we start from ([`pick_value`]) preserves
//!    every captured pane cwd, including a legitimate `System32`; only an
//!    absent value falls back to `%USERPROFILE%`.
//!
//! 3. **Conversion** is done by two *idempotent* converters,
//!    [`to_windows_format`] / [`to_linux_format`]: passing a path that is
//!    already in the requested format is a no-op, so the caller just calls
//!    the one matching the target and never has to reason about the source
//!    format.

use std::path::{Path, PathBuf};
use std::time::Duration;
use std::{future::Future, time::Instant};

use agent_client_protocol as acp;

use super::conn;

/// A path's namespace.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PathFormat {
    Windows,
    Posix,
}

/// Confidence and namespace of the agent receiving the ACP request.
///
/// An explicit source comes from the profile-selected backend and is
/// authoritative. A detected source comes from historical `session/list`
/// rows, which can be stale, so its candidate ladder keeps the opposite
/// namespace available after a proven cwd rejection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CwdTarget {
    Explicit(PathFormat),
    Detected(PathFormat),
    Unknown,
}

/// Classify a path's namespace: POSIX if it starts with `/`, Windows
/// otherwise (drive-letter `C:\…`, UNC `\\server\share`, extended-length
/// `\\?\C:\…`, etc.). It's a strict binary — there are only two namespaces
/// an agent can want, and callers always start from a real cwd, so there's
/// no third "indeterminate" case to reason about.
pub fn classify(path: &Path) -> PathFormat {
    if path.to_string_lossy().trim_start().starts_with('/') {
        PathFormat::Posix
    } else {
        PathFormat::Windows
    }
}

/// Learn the agent's namespace from `session/list` cwd values.
///
/// Every non-empty row must be an unambiguous absolute path in the same
/// namespace. Mixed histories and UNC/relative values return `None` so the
/// caller keeps both namespace candidates available.
pub fn detect_format<'a>(
    session_cwd_values: impl IntoIterator<Item = &'a str>,
) -> Option<PathFormat> {
    let mut detected = None;
    for cwd in session_cwd_values {
        let cwd = cwd.trim();
        if cwd.is_empty() {
            continue;
        }
        let format = classify_session_cwd(cwd)?;
        if detected.is_some_and(|previous| previous != format) {
            return None;
        }
        detected = Some(format);
    }
    detected
}

fn classify_session_cwd(cwd: &str) -> Option<PathFormat> {
    // `//server/share` is ambiguous between a POSIX implementation-defined
    // path and a forward-slash Windows UNC spelling. `\\server\share` and
    // WSL UNC paths likewise identify a host-side transport, not the
    // namespace an ACP agent accepts. Do not let any of them lock in a target.
    if cwd.starts_with("//") || cwd.starts_with(r"\\") {
        return None;
    }
    if cwd.starts_with('/') {
        return Some(PathFormat::Posix);
    }
    let bytes = cwd.as_bytes();
    (bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'\\' | b'/'))
    .then_some(PathFormat::Windows)
}

/// Ask a connected agent which cwd namespace it uses, when it advertises
/// `session/list`. An empty list and an unsupported/failed call are both
/// deliberately unknown; callers retain their retry fallback in either case.
pub(crate) async fn detect_agent_format(
    conn: &conn::ClientLink,
    init: &acp::schema::v1::InitializeResponse,
    timeout: Duration,
) -> Option<PathFormat> {
    if init.agent_capabilities.session_capabilities.list.is_none() {
        return None;
    }
    let response = match tokio::time::timeout(
        timeout,
        conn.list_sessions(acp::schema::v1::ListSessionsRequest::new()),
    )
    .await
    {
        Ok(Ok(response)) => response,
        Ok(Err(error)) => {
            tracing::debug!(
                target: "acp_cwd",
                %error,
                "agent session/list unavailable while detecting cwd namespace"
            );
            return None;
        }
        Err(_) => {
            tracing::warn!(
                target: "acp_cwd",
                "agent session/list timed out while detecting cwd namespace"
            );
            return None;
        }
    };
    let cwd_values: Vec<String> = response
        .sessions
        .iter()
        .map(|session| session.cwd.to_string_lossy().into_owned())
        .collect();
    detect_format(cwd_values.iter().map(String::as_str))
}

/// Choose the source cwd value, preserving every non-empty reported path.
///
/// `C:\Windows\System32` is a legitimate user-selected cwd; C++ now supplies
/// the source pane's cwd explicitly, so treating it as junk would corrupt a
/// real session. Empty remains the only fallback case.
pub fn pick_value(candidate: Option<&Path>) -> PathBuf {
    if let Some(p) = candidate {
        if !p.as_os_str().is_empty() {
            return p.to_path_buf();
        }
    }
    user_profile_dir()
}

/// Idempotent conversion to a Windows path:
/// * already Windows → unchanged;
/// * `/mnt/<drive>/…` → `<Drive>:\…`;
/// * any other POSIX path (e.g. `/home/user`) → `%USERPROFILE%` (a faithful
///   conversion would need the source distro's `\\wsl$` root, which we
///   don't know here — this is the rare WSL-pane→native-agent corner).
pub fn to_windows_format(path: &Path) -> PathBuf {
    match classify(path) {
        PathFormat::Windows => path.to_path_buf(),
        PathFormat::Posix => {
            mnt_to_windows(&path.to_string_lossy()).unwrap_or_else(user_profile_dir)
        }
    }
}

/// Idempotent conversion to a POSIX path:
/// * already POSIX → unchanged;
/// * Windows drive path `C:\a\b` → `/mnt/c/a/b` (standard WSL auto-mount,
///   distro-independent — no shell-out needed);
/// * non-drive Windows path (true UNC) → `/tmp` (via `windows_to_mnt`).
pub fn to_linux_format(path: &Path) -> PathBuf {
    match classify(path) {
        PathFormat::Posix => path.to_path_buf(),
        PathFormat::Windows => PathBuf::from(windows_to_mnt(&path.to_string_lossy())),
    }
}

/// Convert a Terminal-reported path to the POSIX namespace of `distro`.
///
/// Unlike [`to_linux_format`], this recognizes the UNC forms Terminal reports
/// for a WSL pane and validates that they belong to the selected distro before
/// stripping their Windows-side namespace. Relative paths deliberately return
/// `None`: the caller resolves them against the distro's real `$HOME`.
pub(crate) fn to_wsl_format(distro: &str, path: &Path) -> Option<PathBuf> {
    let raw = path.to_string_lossy();
    let raw = raw.trim();
    if raw == "~" || raw.starts_with("~/") {
        return None;
    }

    let normalized = raw.replace('\\', "/");
    for root in [
        format!("//wsl.localhost/{distro}"),
        format!("//wsl$/{distro}"),
        format!("//?/UNC/wsl.localhost/{distro}"),
        format!("//?/UNC/wsl$/{distro}"),
    ] {
        if normalized.eq_ignore_ascii_case(&root) {
            return Some(PathBuf::from("/"));
        }
        let prefix = format!("{root}/");
        if normalized.len() >= prefix.len()
            && normalized[..prefix.len()].eq_ignore_ascii_case(&prefix)
        {
            return Some(PathBuf::from(format!("/{}", &normalized[prefix.len()..])));
        }
    }
    if raw.starts_with('/') {
        return Some(PathBuf::from(raw));
    }

    let bytes = normalized.as_bytes();
    (bytes.len() >= 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && bytes[2] == b'/')
        .then(|| to_linux_format(Path::new(raw)))
}

/// Ordered, bounded cwd candidates. The list is capped at two entries:
/// compatibility fallback must not turn a single ACP request into an
/// unbounded sequence of potentially side-effecting `session/new` calls.
pub fn build_attempts(value: &Path, target: CwdTarget) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    let mut push = |p: PathBuf| {
        if out.len() < 2 && !out.contains(&p) {
            out.push(p);
        }
    };
    match target {
        CwdTarget::Explicit(PathFormat::Windows) => push(to_windows_format(value)),
        CwdTarget::Explicit(PathFormat::Posix) => {
            push(to_linux_format(value));
            push(PathBuf::from("/tmp"));
        }
        CwdTarget::Detected(PathFormat::Windows) => {
            push(to_windows_format(value));
            push(to_linux_format(value));
        }
        CwdTarget::Detected(PathFormat::Posix) => {
            push(to_linux_format(value));
            push(to_windows_format(value));
        }
        CwdTarget::Unknown => {
            match classify(value) {
                PathFormat::Posix => {
                    push(to_linux_format(value));
                    push(to_windows_format(value));
                }
                PathFormat::Windows => {
                    push(to_windows_format(value));
                    push(to_linux_format(value));
                }
            }
        }
    }
    out
}

/// Failure from a bounded [`run_cwd_attempts`] operation.
#[derive(Debug)]
pub enum CwdAttemptFailure {
    Agent(acp::Error),
    Timeout,
}

/// Run one ACP operation against the cwd candidate ladder under one absolute
/// deadline. A retry is allowed only for a deterministic preflight cwd
/// rejection tied to the attempted path or an explicit cwd/directory field.
pub async fn run_cwd_attempts<T, F, Fut>(
    attempts: &[PathBuf],
    deadline: Instant,
    mut operation: F,
) -> Result<(T, PathBuf), CwdAttemptFailure>
where
    F: FnMut(PathBuf) -> Fut,
    Fut: Future<Output = acp::Result<T>>,
{
    for (index, cwd) in attempts.iter().enumerate() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .ok_or(CwdAttemptFailure::Timeout)?;
        match tokio::time::timeout(remaining, operation(cwd.clone())).await {
            Ok(Ok(value)) => return Ok((value, cwd.clone())),
            Ok(Err(error))
                if index + 1 < attempts.len() && is_retryable_cwd_rejection(&error, cwd) =>
            {
                continue;
            }
            Ok(Err(error)) => return Err(CwdAttemptFailure::Agent(error)),
            Err(_) => return Err(CwdAttemptFailure::Timeout),
        }
    }
    unreachable!("cwd candidate builder always returns at least one path")
}

fn is_retryable_cwd_rejection(error: &acp::Error, attempted: &Path) -> bool {
    let data = error.data.as_ref().map(ToString::to_string).unwrap_or_default();
    let evidence = format!("{} {data}", error.message).to_ascii_lowercase();
    let attempted = attempted.to_string_lossy().replace('\\', "/").to_ascii_lowercase();
    let normalized_evidence = evidence.replace('\\', "/");
    let references_attempt = !attempted.is_empty() && normalized_evidence.contains(&attempted);
    let declares_cwd = evidence.contains("cwd")
        || evidence.contains("working directory")
        || evidence.contains("current directory")
        || evidence.contains("directory path");
    let deterministic_rejection = evidence.contains("must be absolute")
        || evidence.contains("not absolute")
        || evidence.contains("not a directory")
        || evidence.contains("no such file or directory")
        || evidence.contains("does not exist")
        || evidence.contains("cannot be accessed")
        || evidence.contains("invalid working directory")
        || evidence.contains("failed to set current directory");
    deterministic_rejection && (references_attempt || declares_cwd)
}

// --- internals ---------------------------------------------------------

/// `C:\Users\me` → `/mnt/c/Users/me`; bare `C:` → `/mnt/c`. Verbatim/device
/// prefixes (`\\?\C:\…`, `\\.\C:\…`) are stripped first. A non-drive Windows
/// path (true UNC like `\\server\share`) has no `/mnt` equivalent, so it
/// defers to the safe POSIX floor `/tmp` rather than emitting a nonsense
/// path like `/?/C:/foo`.
fn windows_to_mnt(win: &str) -> String {
    let win = win.trim();
    // Strip extended-length / device prefixes before drive parsing.
    let win = win
        .strip_prefix(r"\\?\")
        .or_else(|| win.strip_prefix(r"\\.\"))
        .unwrap_or(win);
    let bytes = win.as_bytes();
    if bytes.len() < 2 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' {
        // True UNC / non-drive Windows path — no drive to map onto /mnt.
        return "/tmp".to_string();
    }
    let drive = (bytes[0] as char).to_ascii_lowercase();
    let rest = &win[2..]; // after `C:`
    let rest = rest.replace('\\', "/");
    let rest = rest.trim_start_matches('/');
    if rest.is_empty() {
        format!("/mnt/{drive}")
    } else {
        format!("/mnt/{drive}/{rest}")
    }
}

/// `/mnt/c/Users/me` → `Some(C:\Users\me)`; non-`/mnt` POSIX → `None`.
fn mnt_to_windows(posix: &str) -> Option<PathBuf> {
    let posix = posix.trim();
    let rest = posix.strip_prefix("/mnt/")?;
    let mut chars = rest.chars();
    let drive = chars.next()?;
    if !drive.is_ascii_alphabetic() {
        return None;
    }
    // After the drive letter we require a mountpoint boundary: either
    // end-of-string (`/mnt/c`) or a `/` (`/mnt/c/...`). Reject things like
    // `/mnt/cUsers`, which is an unrelated POSIX path, not a WSL mountpoint.
    let after = &rest[1..];
    if !after.is_empty() && !after.starts_with('/') {
        return None;
    }
    let after = after.strip_prefix('/').unwrap_or(after);
    let drive_up = drive.to_ascii_uppercase();
    if after.is_empty() {
        Some(PathBuf::from(format!("{drive_up}:\\")))
    } else {
        Some(PathBuf::from(format!(
            "{drive_up}:\\{}",
            after.replace('/', "\\")
        )))
    }
}

/// Junk launcher dirs WT/Windows hand back when there's no real cwd:
/// `C:\Windows\System32` and `C:\Windows`. Deliberately small — drive roots
/// and `%USERPROFILE%` are legitimate and must not be treated as junk.
fn is_junk(path: &Path) -> bool {
    let system_root = std::env::var_os("SystemRoot")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    let system32 = system_root.join("System32");
    path_eq_ci(path, &system_root) || path_eq_ci(path, &system32)
}

fn user_profile_dir() -> PathBuf {
    // This helper is the *Windows-namespace* fallback, so it must always
    // return a Windows path and never the junk launcher dir. Resolution:
    //   1. USERPROFILE, but only if it's Windows-looking AND not a junk
    //      launcher dir — some MSYS/Git-Bash setups export a POSIX-style
    //      USERPROFILE (e.g. `/c/Users/u`), and a misconfigured one could even
    //      point at `C:\Windows\System32` (the very junk `pick_value` avoids),
    //      so both are skipped.
    //   2. HOME, with the same Windows-looking + non-junk guard — a POSIX HOME
    //      (e.g. Git Bash's `/home/u`) or a junk HOME is likewise skipped.
    //   3. %SystemDrive%\ (e.g. `C:\`) — a guaranteed-valid Windows dir.
    //      Deliberately NOT `current_dir()`, which can be C:\WINDOWS\system32
    //      for the packaged helper (the very junk we're avoiding).
    if let Some(p) = std::env::var_os("USERPROFILE").filter(|v| !v.is_empty()) {
        let profile = PathBuf::from(p);
        if classify(&profile) == PathFormat::Windows && !is_junk(&profile) {
            return profile;
        }
    }
    if let Some(h) = std::env::var_os("HOME").filter(|v| !v.is_empty()) {
        let home = PathBuf::from(h);
        if classify(&home) == PathFormat::Windows && !is_junk(&home) {
            return home;
        }
    }
    let drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".to_string());
    PathBuf::from(format!("{drive}\\"))
}

fn path_eq_ci(a: &Path, b: &Path) -> bool {
    fn norm(p: &Path) -> String {
        let s = p.to_string_lossy();
        // Strip verbatim / device prefixes so `\\?\C:\Windows\System32`
        // normalizes the same as `C:\Windows\System32` — otherwise a
        // verbatim junk path would slip past `is_junk`.
        let s: &str = s
            .strip_prefix(r"\\?\")
            .or_else(|| s.strip_prefix(r"\\.\"))
            .unwrap_or(&s);
        s.trim_end_matches(['\\', '/'])
            .to_ascii_lowercase()
            .replace('/', "\\")
    }
    norm(a) == norm(b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    // Serializes + restores process-wide env mutations so parallel tests
    // don't clobber each other's USERPROFILE/SystemRoot. Uses the CRATE-WIDE
    // env lock (`test_support::lock_env`) so these tests serialize against
    // every other env-mutating test in the crate, not just this module's — a
    // module-local lock would still race `std::env` (a process global) against
    // tests elsewhere. The guard restores prior values on drop (incl. during
    // panic-unwind from a failed assert), while still holding the lock.
    struct EnvGuard {
        saved: Vec<(String, Option<OsString>)>,
        _lock: crate::test_support::EnvGuard,
    }
    impl Drop for EnvGuard {
        fn drop(&mut self) {
            for (k, old) in &self.saved {
                match old {
                    Some(v) => std::env::set_var(k, v),
                    None => std::env::remove_var(k),
                }
            }
        }
    }
    fn scoped_env(vars: &[(&str, &str)]) -> EnvGuard {
        let lock = crate::test_support::lock_env();
        let saved = vars
            .iter()
            .map(|(k, _)| (k.to_string(), std::env::var_os(k)))
            .collect();
        for (k, v) in vars {
            std::env::set_var(k, v);
        }
        EnvGuard { saved, _lock: lock }
    }

    #[test]
    fn classify_basic() {
        // POSIX = leading '/' (after trimming leading whitespace).
        assert_eq!(classify(Path::new("/home/u")), PathFormat::Posix);
        assert_eq!(classify(Path::new("/mnt/c/foo")), PathFormat::Posix);
        assert_eq!(classify(Path::new("  /leading/space")), PathFormat::Posix);
        // Everything else is Windows: drive (back- or forward-slash), bare
        // drive, UNC, extended-length, even a bare relative fragment.
        assert_eq!(classify(Path::new(r"C:\foo")), PathFormat::Windows);
        assert_eq!(classify(Path::new("C:/foo")), PathFormat::Windows);
        assert_eq!(classify(Path::new("C:")), PathFormat::Windows);
        assert_eq!(classify(Path::new(r"\\server\share")), PathFormat::Windows);
        assert_eq!(classify(Path::new(r"\\?\C:\foo")), PathFormat::Windows);
        assert_eq!(
            classify(Path::new(r"\\wsl$\Ubuntu\home\u")),
            PathFormat::Windows
        );
        assert_eq!(classify(Path::new(r"relative\path")), PathFormat::Windows);
    }

    #[test]
    fn detect_format_from_session_cwd_values() {
        assert_eq!(
            detect_format(["/home/yeelam", "/mnt/c/x"]),
            Some(PathFormat::Posix)
        );
        assert_eq!(
            detect_format([r"Q:\official", r"C:\Users\me"]),
            Some(PathFormat::Windows)
        );
        // Leading empty/blank entries are skipped; first real one decides.
        assert_eq!(
            detect_format(["", "   ", "/home/u"]),
            Some(PathFormat::Posix)
        );
        // Empty list / all-blank → unknown.
        assert_eq!(detect_format(Vec::<&str>::new()), None);
        assert_eq!(detect_format(["", "  "]), None);
    }

    #[test]
    fn windows_linux_round_trips() {
        // A real drive path survives a round trip through both converters.
        let win = Path::new(r"C:\Users\me");
        let posix = to_linux_format(win);
        assert_eq!(posix, PathBuf::from("/mnt/c/Users/me"));
        assert_eq!(to_windows_format(&posix), PathBuf::from(r"C:\Users\me"));
        // bare drive
        assert_eq!(to_linux_format(Path::new("C:")), PathBuf::from("/mnt/c"));
    }

    #[test]
    fn to_linux_is_idempotent_and_converts() {
        // already posix → unchanged
        assert_eq!(
            to_linux_format(Path::new("/home/u")),
            PathBuf::from("/home/u")
        );
        // windows drive → /mnt
        assert_eq!(
            to_linux_format(Path::new(r"C:\Users\me")),
            PathBuf::from("/mnt/c/Users/me")
        );
        assert_eq!(
            to_linux_format(Path::new(r"Q:\official\repo")),
            PathBuf::from("/mnt/q/official/repo")
        );
        assert_eq!(to_linux_format(Path::new(r"C:\")), PathBuf::from("/mnt/c"));
        // extended-length \\?\C:\foo → /mnt/c/foo (prefix stripped)
        assert_eq!(
            to_linux_format(Path::new(r"\\?\C:\foo")),
            PathBuf::from("/mnt/c/foo")
        );
        // true UNC has no /mnt mapping → safe POSIX floor
        assert_eq!(
            to_linux_format(Path::new(r"\\server\share")),
            PathBuf::from("/tmp")
        );
    }

    #[test]
    fn to_wsl_format_converts_generic_wsl_unc_forms_for_selected_distro() {
        for source in [
            r"\\wsl.localhost\Fedora-40\home\me\project",
            r"\\wsl$\Fedora-40\home\me\project",
            r"\\?\UNC\wsl.localhost\Fedora-40\home\me\project",
            r"\\?\UNC\wsl$\Fedora-40\home\me\project",
        ] {
            assert_eq!(
                to_wsl_format("Fedora-40", Path::new(source)),
                Some(PathBuf::from("/home/me/project")),
                "must convert generic WSL UNC cwd `{source}`"
            );
        }
        assert_eq!(
            to_wsl_format("Fedora-40", Path::new(r"\\wsl$\Ubuntu\home\me")),
            None,
            "a different distro's cwd must not cross into the selected agent"
        );
    }

    #[test]
    fn to_windows_is_idempotent_and_converts() {
        let _g = scoped_env(&[("USERPROFILE", r"C:\Users\tester")]);
        // already windows → unchanged
        assert_eq!(
            to_windows_format(Path::new(r"Q:\official")),
            PathBuf::from(r"Q:\official")
        );
        // /mnt → drive
        assert_eq!(
            to_windows_format(Path::new("/mnt/c/Users/me")),
            PathBuf::from(r"C:\Users\me")
        );
        assert_eq!(
            to_windows_format(Path::new("/mnt/q")),
            PathBuf::from(r"Q:\")
        );
        // non-/mnt posix → %USERPROFILE%
        assert_eq!(
            to_windows_format(Path::new("/home/yeelam")),
            PathBuf::from(r"C:\Users\tester")
        );
        // malformed /mnt (no boundary after drive) is NOT a mountpoint → %USERPROFILE%
        assert_eq!(
            to_windows_format(Path::new("/mnt/cUsers")),
            PathBuf::from(r"C:\Users\tester")
        );
    }

    #[test]
    fn pick_value_preserves_legitimate_system32() {
        let _g = scoped_env(&[
            ("SystemRoot", r"C:\Windows"),
            ("USERPROFILE", r"C:\Users\tester"),
        ]);
        assert_eq!(
            pick_value(Some(Path::new(r"C:\WINDOWS\system32"))),
            PathBuf::from(r"C:\WINDOWS\system32")
        );
        assert_eq!(
            pick_value(Some(Path::new(r"C:\Windows"))),
            PathBuf::from(r"C:\Windows")
        );
        assert_eq!(pick_value(None), PathBuf::from(r"C:\Users\tester"));
        assert_eq!(
            pick_value(Some(Path::new(r"\\?\C:\WINDOWS\system32"))),
            PathBuf::from(r"\\?\C:\WINDOWS\system32")
        );
        // real paths pass through (windows or posix)
        assert_eq!(
            pick_value(Some(Path::new(r"Q:\repo"))),
            PathBuf::from(r"Q:\repo")
        );
        assert_eq!(
            pick_value(Some(Path::new("/home/yeelam"))),
            PathBuf::from("/home/yeelam")
        );
    }

    #[test]
    fn user_profile_dir_always_returns_windows_path() {
        // USERPROFILE empty + a POSIX HOME must NOT yield the POSIX HOME or a
        // junk current_dir; it falls back to %SystemDrive%\ (a Windows path).
        let _g = scoped_env(&[
            ("USERPROFILE", ""),
            ("HOME", "/home/u"),
            ("SystemDrive", "C:"),
        ]);
        let got = user_profile_dir();
        assert_eq!(classify(&got), PathFormat::Windows);
        assert_eq!(got, PathBuf::from(r"C:\"));
    }

    #[test]
    fn user_profile_dir_skips_posix_userprofile() {
        // A POSIX-style USERPROFILE (some MSYS/Git-Bash setups) must be
        // skipped, not returned verbatim, so the Windows-namespace contract
        // holds. With a Windows HOME available, that HOME wins.
        let _g = scoped_env(&[
            ("USERPROFILE", "/c/Users/u"),
            ("HOME", r"D:\home\u"),
            ("SystemDrive", "C:"),
        ]);
        let got = user_profile_dir();
        assert_eq!(classify(&got), PathFormat::Windows);
        assert_eq!(got, PathBuf::from(r"D:\home\u"));
    }

    #[test]
    fn user_profile_dir_posix_userprofile_and_home_falls_back_to_drive() {
        // Both USERPROFILE and HOME POSIX-style → neither is usable, so we
        // land on %SystemDrive%\ rather than emitting a POSIX path.
        let _g = scoped_env(&[
            ("USERPROFILE", "/c/Users/u"),
            ("HOME", "/home/u"),
            ("SystemDrive", "C:"),
        ]);
        let got = user_profile_dir();
        assert_eq!(classify(&got), PathFormat::Windows);
        assert_eq!(got, PathBuf::from(r"C:\"));
    }

    #[test]
    fn user_profile_dir_skips_junk_userprofile() {
        // A misconfigured USERPROFILE pointing at the junk launcher dir must be
        // skipped (honoring the "never return junk" contract); with no usable
        // HOME it falls back to %SystemDrive%\.
        let _g = scoped_env(&[
            ("USERPROFILE", r"C:\Windows\System32"),
            ("HOME", ""),
            ("SystemRoot", r"C:\Windows"),
            ("SystemDrive", "C:"),
        ]);
        let got = user_profile_dir();
        assert_eq!(classify(&got), PathFormat::Windows);
        assert!(!is_junk(&got));
        assert_eq!(got, PathBuf::from(r"C:\"));
    }

    #[test]
    fn session_history_requires_unambiguous_consensus() {
        assert_eq!(
            detect_format([r"C:\repo", r"D:\work"]),
            Some(PathFormat::Windows)
        );
        assert_eq!(
            detect_format(["/home/me", "/mnt/c/repo"]),
            Some(PathFormat::Posix)
        );
        assert_eq!(detect_format([r"C:\repo", "/home/me"]), None);
        assert_eq!(detect_format(["//server/share", "/home/me"]), None);
        assert_eq!(detect_format([r"\\server\share", r"C:\repo"]), None);
        assert_eq!(detect_format(["relative/path"]), None);
    }

    #[test]
    fn cwd_retry_requires_preflight_evidence_for_attempted_path() {
        let attempted = Path::new(r"C:\WINDOWS\system32");
        assert!(is_retryable_cwd_rejection(
            &acp::Error::new(-32603, "Directory path must be absolute: C:\\WINDOWS\\system32"),
            attempted,
        ));
        assert!(is_retryable_cwd_rejection(
            &acp::Error::new(-32603, "Invalid working directory"),
            attempted,
        ));
        assert!(is_retryable_cwd_rejection(
            &acp::Error::new(-32603, "ENOENT: no such file or directory, chdir 'C:\\WINDOWS\\system32'"),
            attempted,
        ));
        assert!(!is_retryable_cwd_rejection(
            &acp::Error::new(-32603, "The requested model does not exist"),
            attempted,
        ));
        assert!(!is_retryable_cwd_rejection(
            &acp::Error::new(-32603, "absolute URL required for endpoint"),
            attempted,
        ));
    }

    #[test]
    fn build_attempts_linux_target() {
        // windows value, linux agent → /mnt then /tmp
        assert_eq!(
            build_attempts(
                Path::new(r"Q:\repo"),
                CwdTarget::Explicit(PathFormat::Posix),
            ),
            vec![PathBuf::from("/mnt/q/repo"), PathBuf::from("/tmp")]
        );
        // posix value, linux agent → as-is then /tmp
        assert_eq!(
            build_attempts(
                Path::new("/home/u"),
                CwdTarget::Explicit(PathFormat::Posix),
            ),
            vec![PathBuf::from("/home/u"), PathBuf::from("/tmp")]
        );
    }

    #[test]
    fn build_attempts_windows_target() {
        let _g = scoped_env(&[("USERPROFILE", r"C:\Users\tester")]);
        assert_eq!(
            build_attempts(
                Path::new(r"Q:\repo"),
                CwdTarget::Explicit(PathFormat::Windows),
            ),
            vec![PathBuf::from(r"Q:\repo")]
        );
        // posix value, windows agent → converts (/mnt) or USERPROFILE
        assert_eq!(
            build_attempts(
                Path::new("/mnt/c/x"),
                CwdTarget::Explicit(PathFormat::Windows),
            ),
            vec![PathBuf::from(r"C:\x")]
        );
    }

    #[test]
    fn build_attempts_unknown_target_tries_both() {
        let _g = scoped_env(&[("USERPROFILE", r"C:\Users\tester")]);
        // Unknown remains bounded to the original and opposite namespace.
        let got = build_attempts(Path::new(r"Q:\repo"), CwdTarget::Unknown);
        assert_eq!(
            got,
            vec![
                PathBuf::from(r"Q:\repo"),
                PathBuf::from("/mnt/q/repo"),
            ]
        );
        let got2 = build_attempts(Path::new("/home/u"), CwdTarget::Unknown);
        assert_eq!(
            got2,
            vec![
                PathBuf::from("/home/u"),
                PathBuf::from(r"C:\Users\tester"),
            ]
        );
    }

    #[test]
    fn detected_target_keeps_opposite_namespace_as_fallback() {
        assert_eq!(
            build_attempts(
                Path::new(r"C:\repo"),
                CwdTarget::Detected(PathFormat::Windows),
            ),
            vec![PathBuf::from(r"C:\repo"), PathBuf::from("/mnt/c/repo")]
        );
    }

    #[tokio::test]
    async fn attempts_share_one_deadline_and_stop_on_timeout() {
        let attempts = vec![PathBuf::from(r"C:\repo"), PathBuf::from("/mnt/c/repo")];
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls_for_operation = std::sync::Arc::clone(&calls);
        let deadline = Instant::now() + Duration::from_millis(250);
        let result = run_cwd_attempts(&attempts, deadline, move |_cwd| {
            let calls = std::sync::Arc::clone(&calls_for_operation);
            async move {
                calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(150)).await;
                Err::<(), _>(acp::Error::new(-32603, "Invalid working directory"))
            }
        })
        .await;

        assert!(matches!(result, Err(CwdAttemptFailure::Timeout)));
        assert_eq!(
            calls.load(std::sync::atomic::Ordering::SeqCst),
            2,
            "the second candidate receives only the first candidate's remaining budget"
        );
    }

    #[tokio::test]
    async fn non_cwd_errors_are_never_retried() {
        let attempts = vec![PathBuf::from(r"C:\repo"), PathBuf::from("/mnt/c/repo")];
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let calls_for_operation = std::sync::Arc::clone(&calls);
        let result = run_cwd_attempts(
            &attempts,
            Instant::now() + Duration::from_secs(1),
            move |_cwd| {
                let calls = std::sync::Arc::clone(&calls_for_operation);
                async move {
                    calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    Err::<(), _>(acp::Error::new(-32603, "agent is temporarily unavailable"))
                }
            },
        )
        .await;

        assert!(matches!(result, Err(CwdAttemptFailure::Agent(_))));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1);
    }
}
