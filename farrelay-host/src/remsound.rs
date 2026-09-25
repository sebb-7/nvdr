use serde::Serialize;
#[cfg(any(test, target_os = "windows"))]
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RemSoundLifecycleState {
    Unsupported,
    #[cfg(any(test, target_os = "windows"))]
    NotInstalled,
    #[cfg(any(test, target_os = "windows"))]
    Stopped,
    #[cfg(any(test, target_os = "windows"))]
    Running,
    #[cfg(any(test, target_os = "windows"))]
    Starting,
    #[cfg(any(test, target_os = "windows"))]
    Stopping,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RemSoundExecutableSource {
    #[cfg(any(test, target_os = "windows"))]
    Bundled,
    #[cfg(any(test, target_os = "windows"))]
    Installed,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RemSoundStatus {
    pub platform_supported: bool,
    pub installed: bool,
    pub running: bool,
    pub manageable: bool,
    pub state: RemSoundLifecycleState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub executable_source: Option<RemSoundExecutableSource>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct RemSoundActionResult {
    pub requested: bool,
    pub state: RemSoundLifecycleState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemSoundError {
    UnsupportedPlatform,
    #[cfg(any(test, target_os = "windows"))]
    NotInstalled,
    #[cfg(any(test, target_os = "windows"))]
    NotManaged,
    #[cfg(any(test, target_os = "windows"))]
    ProbeFailed,
    #[cfg(any(test, target_os = "windows"))]
    StartFailed,
    #[cfg(any(test, target_os = "windows"))]
    StopFailed,
    #[cfg(any(test, target_os = "windows"))]
    StopTimeout,
}

impl RemSoundError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnsupportedPlatform => "unsupported_platform",
            #[cfg(any(test, target_os = "windows"))]
            Self::NotInstalled => "remsound_not_installed",
            #[cfg(any(test, target_os = "windows"))]
            Self::NotManaged => "remsound_not_managed",
            #[cfg(any(test, target_os = "windows"))]
            Self::ProbeFailed => "remsound_probe_failed",
            #[cfg(any(test, target_os = "windows"))]
            Self::StartFailed => "remsound_start_failed",
            #[cfg(any(test, target_os = "windows"))]
            Self::StopFailed => "remsound_stop_failed",
            #[cfg(any(test, target_os = "windows"))]
            Self::StopTimeout => "remsound_stop_timeout",
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            Self::UnsupportedPlatform => {
                "RemSound process orchestration is supported only on Windows."
            }
            #[cfg(any(test, target_os = "windows"))]
            Self::NotInstalled => {
                "RemSound was not found in a FarRelay-managed or standard installed location."
            }
            #[cfg(any(test, target_os = "windows"))]
            Self::NotManaged => {
                "RemSound is running, but FarRelay cannot safely identify a managed executable to control."
            }
            #[cfg(any(test, target_os = "windows"))]
            Self::ProbeFailed => "FarRelay could not inspect the RemSound process state.",
            #[cfg(any(test, target_os = "windows"))]
            Self::StartFailed => "FarRelay could not start RemSound.",
            #[cfg(any(test, target_os = "windows"))]
            Self::StopFailed => "FarRelay could not request RemSound to close.",
            #[cfg(any(test, target_os = "windows"))]
            Self::StopTimeout => "RemSound did not stop within the bounded restart window.",
        }
    }
}

pub trait RemSoundProvider {
    fn status(&self) -> Result<RemSoundStatus, RemSoundError>;
    fn start(&self) -> Result<RemSoundActionResult, RemSoundError>;
    fn stop(&self) -> Result<RemSoundActionResult, RemSoundError>;
    fn restart(&self) -> Result<RemSoundActionResult, RemSoundError>;
}

#[cfg(any(test, target_os = "windows"))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct ResolvedRemSoundExecutable {
    path: PathBuf,
    source: RemSoundExecutableSource,
}

#[cfg(any(test, target_os = "windows"))]
trait RemSoundRuntime {
    fn platform_supported(&self) -> bool;
    fn resolve_executable(&self) -> Result<Option<ResolvedRemSoundExecutable>, String>;
    fn running_process_ids(&self) -> Result<Vec<u32>, String>;
    fn version(&self, executable: &Path) -> Result<Option<String>, String>;
    fn launch_minimized(&self, executable: &Path) -> Result<(), String>;
    fn request_close(&self, executable: &Path) -> Result<(), String>;
    fn wait_until_stopped(&self, timeout: Duration) -> Result<bool, String>;
}

#[cfg(any(test, target_os = "windows"))]
struct ManagedRemSoundProvider<R> {
    runtime: R,
}

#[cfg(any(test, target_os = "windows"))]
impl<R> ManagedRemSoundProvider<R> {
    fn new(runtime: R) -> Self {
        Self { runtime }
    }
}

#[cfg(any(test, target_os = "windows"))]
impl<R: RemSoundRuntime> ManagedRemSoundProvider<R> {
    fn resolved_executable(&self) -> Result<Option<ResolvedRemSoundExecutable>, RemSoundError> {
        self.runtime
            .resolve_executable()
            .map_err(|_| RemSoundError::ProbeFailed)
    }

    fn running_process_ids(&self) -> Result<Vec<u32>, RemSoundError> {
        self.runtime
            .running_process_ids()
            .map_err(|_| RemSoundError::ProbeFailed)
    }

    fn require_executable(
        &self,
        running: bool,
    ) -> Result<ResolvedRemSoundExecutable, RemSoundError> {
        match self.resolved_executable()? {
            Some(executable) => Ok(executable),
            None if running => Err(RemSoundError::NotManaged),
            None => Err(RemSoundError::NotInstalled),
        }
    }
}

#[cfg(any(test, target_os = "windows"))]
impl<R: RemSoundRuntime> RemSoundProvider for ManagedRemSoundProvider<R> {
    fn status(&self) -> Result<RemSoundStatus, RemSoundError> {
        if !self.runtime.platform_supported() {
            return Ok(RemSoundStatus {
                platform_supported: false,
                installed: false,
                running: false,
                manageable: false,
                state: RemSoundLifecycleState::Unsupported,
                version: None,
                executable_source: None,
            });
        }

        let executable = self.resolved_executable()?;
        let running = !self.running_process_ids()?.is_empty();
        let installed = executable.is_some();
        let version = executable
            .as_ref()
            .and_then(|resolved| self.runtime.version(&resolved.path).ok().flatten());
        let executable_source = executable.as_ref().map(|resolved| resolved.source.clone());

        Ok(RemSoundStatus {
            platform_supported: true,
            installed,
            running,
            manageable: installed,
            state: if running {
                RemSoundLifecycleState::Running
            } else if installed {
                RemSoundLifecycleState::Stopped
            } else {
                RemSoundLifecycleState::NotInstalled
            },
            version,
            executable_source,
        })
    }

    fn start(&self) -> Result<RemSoundActionResult, RemSoundError> {
        if !self.runtime.platform_supported() {
            return Err(RemSoundError::UnsupportedPlatform);
        }

        let running = !self.running_process_ids()?.is_empty();
        if running {
            return Ok(RemSoundActionResult {
                requested: false,
                state: RemSoundLifecycleState::Running,
            });
        }

        let executable = self.require_executable(false)?;
        self.runtime
            .launch_minimized(&executable.path)
            .map_err(|_| RemSoundError::StartFailed)?;

        Ok(RemSoundActionResult {
            requested: true,
            state: RemSoundLifecycleState::Starting,
        })
    }

    fn stop(&self) -> Result<RemSoundActionResult, RemSoundError> {
        if !self.runtime.platform_supported() {
            return Err(RemSoundError::UnsupportedPlatform);
        }

        let running = !self.running_process_ids()?.is_empty();
        if !running {
            return Ok(RemSoundActionResult {
                requested: false,
                state: RemSoundLifecycleState::Stopped,
            });
        }

        let executable = self.require_executable(true)?;
        self.runtime
            .request_close(&executable.path)
            .map_err(|_| RemSoundError::StopFailed)?;

        Ok(RemSoundActionResult {
            requested: true,
            state: RemSoundLifecycleState::Stopping,
        })
    }

    fn restart(&self) -> Result<RemSoundActionResult, RemSoundError> {
        if !self.runtime.platform_supported() {
            return Err(RemSoundError::UnsupportedPlatform);
        }

        let running = !self.running_process_ids()?.is_empty();
        let executable = self.require_executable(running)?;

        if running {
            self.runtime
                .request_close(&executable.path)
                .map_err(|_| RemSoundError::StopFailed)?;
            let stopped = self
                .runtime
                .wait_until_stopped(Duration::from_secs(5))
                .map_err(|_| RemSoundError::ProbeFailed)?;
            if !stopped {
                return Err(RemSoundError::StopTimeout);
            }
        }

        self.runtime
            .launch_minimized(&executable.path)
            .map_err(|_| RemSoundError::StartFailed)?;

        Ok(RemSoundActionResult {
            requested: true,
            state: RemSoundLifecycleState::Starting,
        })
    }
}

pub struct UnsupportedRemSoundProvider;

impl RemSoundProvider for UnsupportedRemSoundProvider {
    fn status(&self) -> Result<RemSoundStatus, RemSoundError> {
        Ok(RemSoundStatus {
            platform_supported: false,
            installed: false,
            running: false,
            manageable: false,
            state: RemSoundLifecycleState::Unsupported,
            version: None,
            executable_source: None,
        })
    }

    fn start(&self) -> Result<RemSoundActionResult, RemSoundError> {
        Err(RemSoundError::UnsupportedPlatform)
    }

    fn stop(&self) -> Result<RemSoundActionResult, RemSoundError> {
        Err(RemSoundError::UnsupportedPlatform)
    }

    fn restart(&self) -> Result<RemSoundActionResult, RemSoundError> {
        Err(RemSoundError::UnsupportedPlatform)
    }
}

#[cfg(target_os = "windows")]
pub struct WindowsRemSoundProvider {
    inner: ManagedRemSoundProvider<WindowsRemSoundRuntime>,
}

#[cfg(target_os = "windows")]
impl WindowsRemSoundProvider {
    pub fn new() -> Self {
        Self {
            inner: ManagedRemSoundProvider::new(WindowsRemSoundRuntime),
        }
    }
}

#[cfg(target_os = "windows")]
impl RemSoundProvider for WindowsRemSoundProvider {
    fn status(&self) -> Result<RemSoundStatus, RemSoundError> {
        self.inner.status()
    }

    fn start(&self) -> Result<RemSoundActionResult, RemSoundError> {
        self.inner.start()
    }

    fn stop(&self) -> Result<RemSoundActionResult, RemSoundError> {
        self.inner.stop()
    }

    fn restart(&self) -> Result<RemSoundActionResult, RemSoundError> {
        self.inner.restart()
    }
}

#[cfg(target_os = "windows")]
struct WindowsRemSoundRuntime;

#[cfg(target_os = "windows")]
impl WindowsRemSoundRuntime {
    fn bundled_candidates() -> Vec<PathBuf> {
        let Some(parent) = std::env::current_exe()
            .ok()
            .and_then(|path| path.parent().map(Path::to_path_buf))
        else {
            return Vec::new();
        };
        vec![
            parent.join("RemSound").join("RemSound.exe"),
            parent.join("RemSound.exe"),
        ]
    }

    fn installed_candidate() -> Option<PathBuf> {
        std::env::var_os("LOCALAPPDATA").map(|root| {
            PathBuf::from(root)
                .join("Programs")
                .join("RemSound")
                .join("RemSound.exe")
        })
    }

    fn is_remsound_running() -> Result<Vec<u32>, String> {
        use sysinfo::System;

        let mut process_ids: Vec<u32> = System::new_all()
            .processes()
            .iter()
            .filter(|(_, process)| {
                process.name().eq_ignore_ascii_case("RemSound.exe")
                    || process.name().eq_ignore_ascii_case("RemSound")
            })
            .map(|(pid, _)| pid.as_u32())
            .collect();
        process_ids.sort_unstable();
        Ok(process_ids)
    }
}

#[cfg(target_os = "windows")]
impl RemSoundRuntime for WindowsRemSoundRuntime {
    fn platform_supported(&self) -> bool {
        true
    }

    fn resolve_executable(&self) -> Result<Option<ResolvedRemSoundExecutable>, String> {
        for path in Self::bundled_candidates() {
            if path.is_file() {
                return Ok(Some(ResolvedRemSoundExecutable {
                    path,
                    source: RemSoundExecutableSource::Bundled,
                }));
            }
        }

        if let Some(path) = Self::installed_candidate() {
            if path.is_file() {
                return Ok(Some(ResolvedRemSoundExecutable {
                    path,
                    source: RemSoundExecutableSource::Installed,
                }));
            }
        }

        Ok(None)
    }

    fn running_process_ids(&self) -> Result<Vec<u32>, String> {
        Self::is_remsound_running()
    }

    fn version(&self, executable: &Path) -> Result<Option<String>, String> {
        use std::process::{Command, Stdio};

        let output = Command::new(executable)
            .arg("--version")
            .stdin(Stdio::null())
            .output()
            .map_err(|error| error.to_string())?;
        if !output.status.success() {
            return Ok(None);
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        Ok(stdout
            .lines()
            .map(str::trim)
            .find(|line| !line.is_empty())
            .map(str::to_string))
    }

    fn launch_minimized(&self, executable: &Path) -> Result<(), String> {
        use std::os::windows::process::CommandExt;
        use std::process::{Command, Stdio};

        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;

        Command::new(executable)
            .args(["--minimized", "--silent"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .map(|_| ())
            .map_err(|error| error.to_string())
    }

    fn request_close(&self, executable: &Path) -> Result<(), String> {
        use std::process::{Command, Stdio};

        let output = Command::new(executable)
            .args(["--close", "--silent"])
            .stdin(Stdio::null())
            .output()
            .map_err(|error| error.to_string())?;
        if output.status.success() {
            Ok(())
        } else {
            Err("RemSound close command failed".into())
        }
    }

    fn wait_until_stopped(&self, timeout: Duration) -> Result<bool, String> {
        use std::{
            thread,
            time::{Duration as StdDuration, Instant},
        };

        let deadline = Instant::now() + timeout;
        loop {
            if Self::is_remsound_running()?.is_empty() {
                return Ok(true);
            }
            if Instant::now() >= deadline {
                return Ok(false);
            }
            thread::sleep(StdDuration::from_millis(100));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        cell::{Cell, RefCell},
        collections::VecDeque,
    };

    #[derive(Clone)]
    struct FakeRuntime {
        supported: bool,
        executable: Option<ResolvedRemSoundExecutable>,
        running: RefCell<Vec<u32>>,
        versions: RefCell<VecDeque<Result<Option<String>, String>>>,
        launches: Cell<u32>,
        closes: Cell<u32>,
        wait_result: Cell<bool>,
    }

    impl FakeRuntime {
        fn installed(running: bool) -> Self {
            Self {
                supported: true,
                executable: Some(ResolvedRemSoundExecutable {
                    path: PathBuf::from("C:/RemSound/RemSound.exe"),
                    source: RemSoundExecutableSource::Installed,
                }),
                running: RefCell::new(if running { vec![7] } else { vec![] }),
                versions: RefCell::new(VecDeque::from([Ok(Some("RemSound 1.2.3".into()))])),
                launches: Cell::new(0),
                closes: Cell::new(0),
                wait_result: Cell::new(true),
            }
        }
    }

    impl RemSoundRuntime for FakeRuntime {
        fn platform_supported(&self) -> bool {
            self.supported
        }

        fn resolve_executable(&self) -> Result<Option<ResolvedRemSoundExecutable>, String> {
            Ok(self.executable.clone())
        }

        fn running_process_ids(&self) -> Result<Vec<u32>, String> {
            Ok(self.running.borrow().clone())
        }

        fn version(&self, _: &Path) -> Result<Option<String>, String> {
            self.versions.borrow_mut().pop_front().unwrap_or(Ok(None))
        }

        fn launch_minimized(&self, _: &Path) -> Result<(), String> {
            self.launches.set(self.launches.get() + 1);
            Ok(())
        }

        fn request_close(&self, _: &Path) -> Result<(), String> {
            self.closes.set(self.closes.get() + 1);
            Ok(())
        }

        fn wait_until_stopped(&self, _: Duration) -> Result<bool, String> {
            Ok(self.wait_result.get())
        }
    }

    #[test]
    fn status_distinguishes_installed_stopped_and_running() {
        let runtime = FakeRuntime::installed(false);
        let provider = ManagedRemSoundProvider::new(runtime);
        let stopped = provider.status().unwrap();
        assert!(stopped.platform_supported);
        assert!(stopped.installed);
        assert!(!stopped.running);
        assert!(stopped.manageable);
        assert_eq!(stopped.state, RemSoundLifecycleState::Stopped);
        assert_eq!(stopped.version.as_deref(), Some("RemSound 1.2.3"));
        assert_eq!(
            stopped.executable_source,
            Some(RemSoundExecutableSource::Installed)
        );

        provider.runtime.running.replace(vec![9]);
        let running = provider.status().unwrap();
        assert!(running.running);
        assert_eq!(running.state, RemSoundLifecycleState::Running);
    }

    #[test]
    fn missing_install_fails_closed_without_launching_arbitrary_process() {
        let runtime = FakeRuntime {
            executable: None,
            ..FakeRuntime::installed(false)
        };
        let provider = ManagedRemSoundProvider::new(runtime);
        assert_eq!(provider.start().unwrap_err(), RemSoundError::NotInstalled);
        assert_eq!(provider.runtime.launches.get(), 0);
    }

    #[test]
    fn start_is_idempotent_when_remsound_is_already_running() {
        let provider = ManagedRemSoundProvider::new(FakeRuntime::installed(true));
        let result = provider.start().unwrap();
        assert!(!result.requested);
        assert_eq!(result.state, RemSoundLifecycleState::Running);
        assert_eq!(provider.runtime.launches.get(), 0);
    }

    #[test]
    fn start_requests_fixed_minimized_launch() {
        let provider = ManagedRemSoundProvider::new(FakeRuntime::installed(false));
        let result = provider.start().unwrap();
        assert!(result.requested);
        assert_eq!(result.state, RemSoundLifecycleState::Starting);
        assert_eq!(provider.runtime.launches.get(), 1);
    }

    #[test]
    fn stop_is_idempotent_when_already_stopped() {
        let provider = ManagedRemSoundProvider::new(FakeRuntime::installed(false));
        let result = provider.stop().unwrap();
        assert!(!result.requested);
        assert_eq!(result.state, RemSoundLifecycleState::Stopped);
        assert_eq!(provider.runtime.closes.get(), 0);
    }

    #[test]
    fn restart_closes_waits_then_launches() {
        let provider = ManagedRemSoundProvider::new(FakeRuntime::installed(true));
        let result = provider.restart().unwrap();
        assert!(result.requested);
        assert_eq!(result.state, RemSoundLifecycleState::Starting);
        assert_eq!(provider.runtime.closes.get(), 1);
        assert_eq!(provider.runtime.launches.get(), 1);
    }

    #[test]
    fn restart_timeout_never_starts_a_second_copy() {
        let runtime = FakeRuntime::installed(true);
        runtime.wait_result.set(false);
        let provider = ManagedRemSoundProvider::new(runtime);
        assert_eq!(provider.restart().unwrap_err(), RemSoundError::StopTimeout);
        assert_eq!(provider.runtime.closes.get(), 1);
        assert_eq!(provider.runtime.launches.get(), 0);
    }

    #[test]
    fn unsupported_provider_reports_capability_without_mutating_state() {
        let provider = UnsupportedRemSoundProvider;
        let status = provider.status().unwrap();
        assert_eq!(status.state, RemSoundLifecycleState::Unsupported);
        assert_eq!(
            provider.start().unwrap_err(),
            RemSoundError::UnsupportedPlatform
        );
    }
}
