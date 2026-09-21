//! Narrow, out-of-band NVDA recovery. This module intentionally has no
//! request-controlled executable, task name, shell source, or command line.

#[cfg(target_os = "windows")]
use crate::exec::{CommandInvocation, CommandRunner};

#[cfg(target_os = "windows")]
pub const NVDA_RECOVERY_TASK_NAME: &str = "FarRelay Recover NVDA";

#[cfg(target_os = "windows")]
const RESTART_POLL_ATTEMPTS: usize = 40;
#[cfg(target_os = "windows")]
const RESTART_POLL_INTERVAL_MS: u64 = 250;

#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
pub struct NvdaRecoveryStatus {
    pub nvda_running: bool,
    pub recovery_task_ready: bool,
}

#[derive(Debug, Clone, serde::Serialize, PartialEq, Eq)]
pub struct NvdaRestartResult {
    pub requested: bool,
    pub task_started: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NvdaRecoveryError {
    #[cfg(any(test, not(target_os = "windows")))]
    UnsupportedPlatform,
    #[cfg(target_os = "windows")]
    SetupRequired,
    #[cfg(target_os = "windows")]
    Failed,
}

impl NvdaRecoveryError {
    pub fn code(&self) -> &'static str {
        match self {
            #[cfg(any(test, not(target_os = "windows")))]
            Self::UnsupportedPlatform => "unsupported_platform",
            #[cfg(target_os = "windows")]
            Self::SetupRequired => "recovery_setup_required",
            #[cfg(target_os = "windows")]
            Self::Failed => "recovery_failed",
        }
    }

    pub fn message(&self) -> &'static str {
        match self {
            #[cfg(any(test, not(target_os = "windows")))]
            Self::UnsupportedPlatform => "NVDA recovery is not available on this platform",
            #[cfg(target_os = "windows")]
            Self::SetupRequired => "The fixed FarRelay NVDA recovery task is missing or outdated",
            #[cfg(target_os = "windows")]
            Self::Failed => "NVDA restart could not be verified",
        }
    }
}

pub trait NvdaRecoveryProvider {
    fn status(&self) -> Result<NvdaRecoveryStatus, NvdaRecoveryError>;
    fn restart(&self) -> Result<NvdaRestartResult, NvdaRecoveryError>;
}

#[cfg(any(test, not(target_os = "windows")))]
pub struct UnsupportedNvdaRecoveryProvider;

#[cfg(any(test, not(target_os = "windows")))]
impl NvdaRecoveryProvider for UnsupportedNvdaRecoveryProvider {
    fn status(&self) -> Result<NvdaRecoveryStatus, NvdaRecoveryError> {
        Err(NvdaRecoveryError::UnsupportedPlatform)
    }

    fn restart(&self) -> Result<NvdaRestartResult, NvdaRecoveryError> {
        Err(NvdaRecoveryError::UnsupportedPlatform)
    }
}

#[cfg(target_os = "windows")]
pub trait NvdaProcessProbe {
    fn nvda_process_ids(&self) -> Vec<u32>;

    fn nvda_running(&self) -> bool {
        !self.nvda_process_ids().is_empty()
    }

    fn wait_for_restart(&self, previous: &[u32]) -> bool {
        let mut previous = previous.to_vec();
        previous.sort_unstable();
        for _ in 0..RESTART_POLL_ATTEMPTS {
            std::thread::sleep(std::time::Duration::from_millis(RESTART_POLL_INTERVAL_MS));
            let mut current = self.nvda_process_ids();
            current.sort_unstable();
            if !current.is_empty() && current != previous {
                return true;
            }
        }
        false
    }
}

/// Runs only the repository-provisioned fixed scheduled task. This is not a
/// command runner protocol: both invocations are compile-time constants.
#[cfg(target_os = "windows")]
pub struct WindowsNvdaRecoveryProvider<R, P> {
    runner: R,
    probe: P,
}

#[cfg(target_os = "windows")]
impl<R, P> WindowsNvdaRecoveryProvider<R, P> {
    pub fn new(runner: R, probe: P) -> Self {
        Self { runner, probe }
    }
}

#[cfg(target_os = "windows")]
impl<R: CommandRunner, P: NvdaProcessProbe> NvdaRecoveryProvider
    for WindowsNvdaRecoveryProvider<R, P>
{
    fn status(&self) -> Result<NvdaRecoveryStatus, NvdaRecoveryError> {
        Ok(NvdaRecoveryStatus {
            nvda_running: self.probe.nvda_running(),
            recovery_task_ready: self.task_ready(),
        })
    }

    fn restart(&self) -> Result<NvdaRestartResult, NvdaRecoveryError> {
        if !self.task_ready() {
            return Err(NvdaRecoveryError::SetupRequired);
        }

        let previous_process_ids = self.probe.nvda_process_ids();
        let output = self
            .runner
            .run(&run_task_invocation())
            .map_err(|_| NvdaRecoveryError::Failed)?;
        if output.exit_code != 0 {
            return Err(NvdaRecoveryError::Failed);
        }

        // schtasks /run returning zero means Task Scheduler accepted the request;
        // it does not prove that the task action succeeded. Do not report a
        // performed recovery until NVDA actually transitions to a new process.
        if !self.probe.wait_for_restart(&previous_process_ids) {
            return Err(NvdaRecoveryError::Failed);
        }

        Ok(NvdaRestartResult {
            requested: true,
            task_started: true,
        })
    }
}

#[cfg(target_os = "windows")]
impl<R: CommandRunner, P: NvdaProcessProbe> WindowsNvdaRecoveryProvider<R, P> {
    fn task_ready(&self) -> bool {
        self.runner.run(&query_task_invocation()).is_ok_and(|output| {
            if output.exit_code != 0 {
                return false;
            }
            let definition = output.stdout.to_ascii_lowercase();
            definition.contains("nvda_slave.exe") && definition.contains("launchnvda")
        })
    }
}

#[cfg(target_os = "windows")]
fn query_task_invocation() -> CommandInvocation {
    CommandInvocation {
        program: "schtasks.exe".into(),
        args: vec![
            "/query".into(),
            "/tn".into(),
            NVDA_RECOVERY_TASK_NAME.into(),
            "/xml".into(),
        ],
    }
}

#[cfg(target_os = "windows")]
fn run_task_invocation() -> CommandInvocation {
    CommandInvocation {
        program: "schtasks.exe".into(),
        args: vec!["/run".into(), "/tn".into(), NVDA_RECOVERY_TASK_NAME.into()],
    }
}

#[cfg(all(test, target_os = "windows"))]
mod tests {
    use super::*;
    use crate::exec::CommandOutput;
    use std::cell::RefCell;

    struct Probe {
        process_ids: Vec<u32>,
        restart_verified: bool,
    }

    impl Probe {
        fn new(process_ids: Vec<u32>, restart_verified: bool) -> Self {
            Self {
                process_ids,
                restart_verified,
            }
        }
    }

    impl NvdaProcessProbe for Probe {
        fn nvda_process_ids(&self) -> Vec<u32> {
            self.process_ids.clone()
        }

        fn wait_for_restart(&self, _previous: &[u32]) -> bool {
            self.restart_verified
        }
    }

    struct Runner {
        outputs: RefCell<Vec<CommandOutput>>,
        calls: RefCell<Vec<CommandInvocation>>,
    }

    impl Runner {
        fn new(outputs: Vec<CommandOutput>) -> Self {
            Self {
                outputs: RefCell::new(outputs),
                calls: RefCell::new(vec![]),
            }
        }
    }

    impl CommandRunner for Runner {
        fn run(&self, invocation: &CommandInvocation) -> Result<CommandOutput, String> {
            self.calls.borrow_mut().push(invocation.clone());
            Ok(self.outputs.borrow_mut().remove(0))
        }
    }

    fn ready_task() -> CommandOutput {
        CommandOutput {
            exit_code: 0,
            stdout: r#"<Task><Actions><Exec><Command>C:\Program Files\NVDA\nvda_slave.exe</Command><Arguments>launchNVDA</Arguments></Exec></Actions></Task>"#.into(),
            stderr: String::new(),
        }
    }

    fn success() -> CommandOutput {
        CommandOutput {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        }
    }

    fn failure() -> CommandOutput {
        CommandOutput {
            exit_code: 1,
            stdout: String::new(),
            stderr: "untrusted diagnostic".into(),
        }
    }

    #[test]
    fn status_reports_running_and_fixed_task_readiness() {
        let provider = WindowsNvdaRecoveryProvider::new(
            Runner::new(vec![ready_task()]),
            Probe::new(vec![41772], true),
        );
        assert_eq!(
            provider.status().unwrap(),
            NvdaRecoveryStatus {
                nvda_running: true,
                recovery_task_ready: true
            }
        );
    }

    #[test]
    fn outdated_task_is_not_reported_ready() {
        let old_task = CommandOutput {
            exit_code: 0,
            stdout: r#"<Task><Actions><Exec><Command>C:\Program Files\NVDA\nvda_uiAccess.exe</Command></Exec></Actions></Task>"#.into(),
            stderr: String::new(),
        };
        let provider = WindowsNvdaRecoveryProvider::new(
            Runner::new(vec![old_task]),
            Probe::new(vec![41772], true),
        );
        assert!(!provider.status().unwrap().recovery_task_ready);
    }

    #[test]
    fn restart_runs_only_the_fixed_task_and_requires_pid_transition() {
        let provider = WindowsNvdaRecoveryProvider::new(
            Runner::new(vec![ready_task(), success()]),
            Probe::new(vec![41772], true),
        );
        assert_eq!(
            provider.restart().unwrap(),
            NvdaRestartResult {
                requested: true,
                task_started: true
            }
        );
        let calls = provider.runner.calls.borrow();
        assert_eq!(calls[0], query_task_invocation());
        assert_eq!(calls[1], run_task_invocation());
        assert!(calls.iter().all(|call| call.program == "schtasks.exe"
            && !call
                .args
                .iter()
                .any(|arg| arg.contains("powershell") || arg.contains("cmd"))));
    }

    #[test]
    fn scheduler_acceptance_without_pid_transition_is_failure() {
        let provider = WindowsNvdaRecoveryProvider::new(
            Runner::new(vec![ready_task(), success()]),
            Probe::new(vec![41772], false),
        );
        assert_eq!(provider.restart().unwrap_err(), NvdaRecoveryError::Failed);
    }

    #[test]
    fn missing_task_fails_closed_without_run_fallback() {
        let provider = WindowsNvdaRecoveryProvider::new(
            Runner::new(vec![failure()]),
            Probe::new(vec![], false),
        );
        assert_eq!(
            provider.restart().unwrap_err(),
            NvdaRecoveryError::SetupRequired
        );
        assert_eq!(
            provider.runner.calls.borrow().as_slice(),
            [query_task_invocation()]
        );
    }

    #[test]
    fn unsupported_platform_is_typed() {
        assert_eq!(
            UnsupportedNvdaRecoveryProvider.status().unwrap_err().code(),
            "unsupported_platform"
        );
    }
}
