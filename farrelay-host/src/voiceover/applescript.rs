#![cfg(any(test, target_os = "macos"))]

use super::{
    VoiceOverError, VoiceOverMoveDirection, VoiceOverMoveResult, VoiceOverPressResult,
    VoiceOverProvider, VoiceOverState, VoiceOverStatus,
};
use crate::exec::{CommandInvocation, CommandOutput, CommandRunner};
#[cfg(target_os = "macos")]
use sysinfo::System;

pub const OSASCRIPT: &str = "/usr/bin/osascript";
const MAX_DIAGNOSTIC_CHARS: usize = 256;

pub const SCRIPT_LAST_PHRASE: &str =
    "tell application \"VoiceOver\" to return content of last phrase";
pub const SCRIPT_VOICEOVER_CURSOR_TEXT: &str =
    "tell application \"VoiceOver\" to return text under cursor of vo cursor";
pub const SCRIPT_KEYBOARD_CURSOR_TEXT: &str =
    "tell application \"VoiceOver\" to return text under cursor of keyboard cursor";
pub const SCRIPT_PRESS: &str = "tell application \"VoiceOver\" to tell vo cursor to press";
pub const SCRIPT_MOVE_LEFT: &str = "tell application \"VoiceOver\" to tell vo cursor to move left";
pub const SCRIPT_MOVE_RIGHT: &str =
    "tell application \"VoiceOver\" to tell vo cursor to move right";
pub const SCRIPT_MOVE_UP: &str = "tell application \"VoiceOver\" to tell vo cursor to move up";
pub const SCRIPT_MOVE_DOWN: &str = "tell application \"VoiceOver\" to tell vo cursor to move down";
pub const SCRIPT_MOVE_INTO: &str =
    "tell application \"VoiceOver\" to tell vo cursor to move into item";
pub const SCRIPT_MOVE_OUT: &str =
    "tell application \"VoiceOver\" to tell vo cursor to move out of item";

const ALL_SCRIPTS: &[&str] = &[
    SCRIPT_LAST_PHRASE,
    SCRIPT_VOICEOVER_CURSOR_TEXT,
    SCRIPT_KEYBOARD_CURSOR_TEXT,
    SCRIPT_PRESS,
    SCRIPT_MOVE_LEFT,
    SCRIPT_MOVE_RIGHT,
    SCRIPT_MOVE_UP,
    SCRIPT_MOVE_DOWN,
    SCRIPT_MOVE_INTO,
    SCRIPT_MOVE_OUT,
];

impl VoiceOverMoveDirection {
    fn applescript(self) -> &'static str {
        match self {
            Self::Left => SCRIPT_MOVE_LEFT,
            Self::Right => SCRIPT_MOVE_RIGHT,
            Self::Up => SCRIPT_MOVE_UP,
            Self::Down => SCRIPT_MOVE_DOWN,
            Self::Into => SCRIPT_MOVE_INTO,
            Self::Out => SCRIPT_MOVE_OUT,
        }
    }
}

pub trait VoiceOverProcessProbe {
    fn voiceover_process_running(&self) -> bool;
}

#[cfg(target_os = "macos")]
pub struct SysinfoVoiceOverProbe;

#[cfg(target_os = "macos")]
impl VoiceOverProcessProbe for SysinfoVoiceOverProbe {
    fn voiceover_process_running(&self) -> bool {
        let system = System::new_all();
        system
            .processes()
            .values()
            .any(|process| process.name().eq_ignore_ascii_case("VoiceOver"))
    }
}

/// macOS VoiceOver control through fixed `/usr/bin/osascript` templates.
///
/// Scripts are constants. Request parameters never become AppleScript source.
pub struct AppleScriptVoiceOverProvider<R, P> {
    runner: R,
    probe: P,
}

impl<R, P> AppleScriptVoiceOverProvider<R, P> {
    pub fn new(runner: R, probe: P) -> Self {
        Self { runner, probe }
    }
}

impl<R, P> VoiceOverProvider for AppleScriptVoiceOverProvider<R, P>
where
    R: CommandRunner,
    P: VoiceOverProcessProbe,
{
    fn status(&self) -> Result<VoiceOverStatus, VoiceOverError> {
        let voiceover_running = self.probe.voiceover_process_running();
        match self.run_script(SCRIPT_LAST_PHRASE) {
            Ok(_) => Ok(VoiceOverStatus {
                platform_supported: true,
                available: true,
                voiceover_running,
                applescript_bridge_usable: true,
                message: None,
            }),
            Err(VoiceOverError::ControlUnavailable { message })
            | Err(VoiceOverError::Unavailable { message }) => Ok(VoiceOverStatus {
                platform_supported: true,
                available: false,
                voiceover_running,
                applescript_bridge_usable: false,
                message: Some(message),
            }),
            Err(error) => Err(error),
        }
    }

    fn move_cursor(
        &self,
        direction: VoiceOverMoveDirection,
    ) -> Result<VoiceOverMoveResult, VoiceOverError> {
        self.run_script(direction.applescript())?;
        Ok(VoiceOverMoveResult { moved: true })
    }

    fn press(&self) -> Result<VoiceOverPressResult, VoiceOverError> {
        self.run_script(SCRIPT_PRESS)?;
        Ok(VoiceOverPressResult { pressed: true })
    }

    fn state(&self) -> Result<VoiceOverState, VoiceOverError> {
        let last_spoken_phrase = optional_script_value(self.run_script(SCRIPT_LAST_PHRASE));
        let voiceover_cursor_text =
            optional_script_value(self.run_script(SCRIPT_VOICEOVER_CURSOR_TEXT));
        let keyboard_cursor_text =
            optional_script_value(self.run_script(SCRIPT_KEYBOARD_CURSOR_TEXT));
        if last_spoken_phrase.is_none()
            && voiceover_cursor_text.is_none()
            && keyboard_cursor_text.is_none()
        {
            return Err(self.classify_failure(VoiceOverError::ControlUnavailable {
                message: "VoiceOver state is not currently readable".into(),
            }));
        }
        Ok(VoiceOverState {
            last_spoken_phrase,
            voiceover_cursor_text,
            keyboard_cursor_text,
        })
    }
}

impl<R, P> AppleScriptVoiceOverProvider<R, P>
where
    R: CommandRunner,
    P: VoiceOverProcessProbe,
{
    fn run_script(&self, script: &'static str) -> Result<String, VoiceOverError> {
        let invocation = osascript_invocation(script);
        let output = self
            .runner
            .run(&invocation)
            .map_err(|error| VoiceOverError::Internal {
                message: bounded_diagnostic(&error),
            })?;
        if output.exit_code != 0 {
            return Err(self.classify_failure(script_failure(&output)));
        }
        Ok(normalize_script_value(&output.stdout))
    }

    fn classify_failure(&self, error: VoiceOverError) -> VoiceOverError {
        match error {
            VoiceOverError::ControlUnavailable { message }
                if !self.probe.voiceover_process_running() =>
            {
                VoiceOverError::Unavailable { message }
            }
            other => other,
        }
    }
}

fn osascript_invocation(script: &'static str) -> CommandInvocation {
    CommandInvocation {
        program: OSASCRIPT.into(),
        args: vec!["-e".into(), script.into()],
    }
}

fn optional_script_value(result: Result<String, VoiceOverError>) -> Option<String> {
    match result {
        Ok(value) if value.is_empty() => None,
        Ok(value) => Some(value),
        Err(_) => None,
    }
}

fn normalize_script_value(stdout: &str) -> String {
    let trimmed = stdout.trim();
    if trimmed.eq_ignore_ascii_case("missing value") {
        String::new()
    } else {
        trimmed.to_string()
    }
}

fn script_failure(output: &CommandOutput) -> VoiceOverError {
    let diagnostic = bounded_diagnostic(&output.stderr);
    let message = if diagnostic.is_empty() {
        "VoiceOver AppleScript control is not currently usable".into()
    } else {
        diagnostic
    };
    VoiceOverError::ControlUnavailable { message }
}

fn bounded_diagnostic(raw: &str) -> String {
    let mut sanitized = raw.to_string();
    for script in ALL_SCRIPTS {
        sanitized = sanitized.replace(script, "");
    }
    let collapsed = sanitized.split_whitespace().collect::<Vec<_>>().join(" ");
    match collapsed.char_indices().nth(MAX_DIAGNOSTIC_CHARS) {
        Some((index, _)) => collapsed[..index].trim().to_string(),
        None => collapsed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::exec::CommandOutput;
    use std::cell::RefCell;

    struct ConstProbe {
        running: bool,
    }

    impl VoiceOverProcessProbe for ConstProbe {
        fn voiceover_process_running(&self) -> bool {
            self.running
        }
    }

    struct RecordingRunner {
        calls: RefCell<Vec<CommandInvocation>>,
        outputs: RefCell<Vec<CommandOutput>>,
    }

    impl RecordingRunner {
        fn new(outputs: Vec<CommandOutput>) -> Self {
            Self {
                calls: RefCell::new(Vec::new()),
                outputs: RefCell::new(outputs),
            }
        }
    }

    impl CommandRunner for RecordingRunner {
        fn run(&self, invocation: &CommandInvocation) -> Result<CommandOutput, String> {
            self.calls.borrow_mut().push(invocation.clone());
            let mut outputs = self.outputs.borrow_mut();
            if outputs.is_empty() {
                return Ok(success(""));
            }
            Ok(outputs.remove(0))
        }
    }

    fn success(stdout: &str) -> CommandOutput {
        CommandOutput {
            exit_code: 0,
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }

    fn failure(stderr: &str) -> CommandOutput {
        CommandOutput {
            exit_code: 1,
            stdout: String::new(),
            stderr: stderr.into(),
        }
    }

    fn provider(
        outputs: Vec<CommandOutput>,
        running: bool,
    ) -> AppleScriptVoiceOverProvider<RecordingRunner, ConstProbe> {
        AppleScriptVoiceOverProvider::new(RecordingRunner::new(outputs), ConstProbe { running })
    }

    fn assert_osascript(call: &CommandInvocation, script: &str) {
        assert_eq!(call.program, OSASCRIPT);
        assert_eq!(call.args, ["-e", script]);
        assert!(!call.program.contains("sh"));
        assert!(!call.args.iter().any(|arg| arg.contains("sh -c")));
    }

    #[test]
    fn move_maps_each_direction_to_a_fixed_osascript_template() {
        let cases = [
            (VoiceOverMoveDirection::Left, SCRIPT_MOVE_LEFT),
            (VoiceOverMoveDirection::Right, SCRIPT_MOVE_RIGHT),
            (VoiceOverMoveDirection::Up, SCRIPT_MOVE_UP),
            (VoiceOverMoveDirection::Down, SCRIPT_MOVE_DOWN),
            (VoiceOverMoveDirection::Into, SCRIPT_MOVE_INTO),
            (VoiceOverMoveDirection::Out, SCRIPT_MOVE_OUT),
        ];
        for (direction, script) in cases {
            let provider = provider(vec![success("")], true);
            provider.move_cursor(direction).unwrap();
            let calls = provider.runner.calls.borrow().clone();
            assert_eq!(calls.len(), 1);
            assert_osascript(&calls[0], script);
        }
    }

    #[test]
    fn press_dispatches_exactly_one_fixed_script() {
        let provider = provider(vec![success("")], true);
        let result = provider.press().unwrap();
        assert!(result.pressed);
        let calls = provider.runner.calls.borrow().clone();
        assert_eq!(calls.len(), 1);
        assert_osascript(&calls[0], SCRIPT_PRESS);
    }

    #[test]
    fn state_returns_independent_optional_fields() {
        let provider = provider(
            vec![
                success("Button, Mail\n"),
                success("missing value\n"),
                success("Search\n"),
            ],
            true,
        );
        let state = provider.state().unwrap();
        assert_eq!(state.last_spoken_phrase.as_deref(), Some("Button, Mail"));
        assert_eq!(state.voiceover_cursor_text, None);
        assert_eq!(state.keyboard_cursor_text.as_deref(), Some("Search"));
        let calls = provider.runner.calls.borrow().clone();
        assert_eq!(calls.len(), 3);
        assert_osascript(&calls[0], SCRIPT_LAST_PHRASE);
        assert_osascript(&calls[1], SCRIPT_VOICEOVER_CURSOR_TEXT);
        assert_osascript(&calls[2], SCRIPT_KEYBOARD_CURSOR_TEXT);
    }

    #[test]
    fn status_reports_bridge_failure_without_claiming_an_exact_cause() {
        let provider = provider(
            vec![failure(
                "execution error: VoiceOver got an error: AppleEvent handler failed. (-10000)",
            )],
            true,
        );
        let status = provider.status().unwrap();
        assert!(status.platform_supported);
        assert!(!status.available);
        assert!(status.voiceover_running);
        assert!(!status.applescript_bridge_usable);
        let message = status.message.unwrap();
        assert!(!message.contains("tell application"));
        assert!(!message.contains(SCRIPT_LAST_PHRASE));
    }

    #[test]
    fn script_failures_do_not_include_applescript_source() {
        let provider = provider(
            vec![failure(&format!(
                "{} execution error: not allowed",
                SCRIPT_PRESS
            ))],
            true,
        );
        let error = provider.press().unwrap_err();
        assert_eq!(error.code(), "voiceover_control_unavailable");
        assert!(!error.message().contains("tell application"));
        assert!(!error.message().contains(SCRIPT_PRESS));
        assert!(error.message().len() <= MAX_DIAGNOSTIC_CHARS);
    }

    #[test]
    fn missing_voiceover_process_is_unavailable_not_a_guessed_tcc_cause() {
        let error = provider(vec![failure("execution error: failed")], false)
            .press()
            .unwrap_err();
        assert_eq!(error.code(), "voiceover_unavailable");
        assert!(!error.message().contains("tell application"));
    }

    #[test]
    fn request_like_script_text_never_becomes_an_invocation() {
        let provider = provider(vec![success("")], true);
        provider.move_cursor(VoiceOverMoveDirection::Right).unwrap();
        let call = provider.runner.calls.borrow()[0].clone();
        assert_osascript(&call, SCRIPT_MOVE_RIGHT);
        assert!(!call.args.iter().any(|arg| arg.contains("do shell script")));
    }

    #[test]
    fn diagnostics_are_bounded() {
        let long = "x".repeat(400);
        let bounded = bounded_diagnostic(&long);
        assert_eq!(bounded.len(), MAX_DIAGNOSTIC_CHARS);
    }
}
