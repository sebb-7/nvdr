#[cfg(target_os = "macos")]
use std::process::{Command, Stdio};

/// A captured program invocation. Callers must pass a fixed program path and
/// argument list — never a shell string.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandInvocation {
    pub program: String,
    pub args: Vec<String>,
}

/// Captured stdout/stderr from a child process. Callers must not write this
/// data to the protocol stdout stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

pub trait CommandRunner {
    fn run(&self, invocation: &CommandInvocation) -> Result<CommandOutput, String>;
}

/// Direct `std::process::Command` execution. stdin is null so child processes
/// cannot consume `farrelay-host` protocol input.
#[cfg(target_os = "macos")]
pub struct StdCommandRunner;

#[cfg(target_os = "macos")]
impl CommandRunner for StdCommandRunner {
    fn run(&self, invocation: &CommandInvocation) -> Result<CommandOutput, String> {
        let output = Command::new(&invocation.program)
            .args(&invocation.args)
            .stdin(Stdio::null())
            .output()
            .map_err(|error| error.to_string())?;
        Ok(CommandOutput {
            exit_code: output.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct RecordingRunner {
        calls: RefCell<Vec<CommandInvocation>>,
        output: CommandOutput,
    }

    impl CommandRunner for RecordingRunner {
        fn run(&self, invocation: &CommandInvocation) -> Result<CommandOutput, String> {
            self.calls.borrow_mut().push(invocation.clone());
            Ok(self.output.clone())
        }
    }

    #[test]
    fn invocation_is_program_and_argv_not_a_shell_string() {
        let runner = RecordingRunner {
            calls: RefCell::new(Vec::new()),
            output: CommandOutput {
                exit_code: 0,
                stdout: String::new(),
                stderr: String::new(),
            },
        };
        let invocation = CommandInvocation {
            program: "/usr/bin/osascript".into(),
            args: vec!["-e".into(), "return 1".into()],
        };
        runner.run(&invocation).unwrap();
        assert_eq!(runner.calls.borrow().as_slice(), [invocation]);
    }
}
