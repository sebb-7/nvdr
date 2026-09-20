use crate::{
    capabilities::Capabilities,
    host::HostProvider,
    process::{ProcessError, ProcessProvider},
    recovery::{NvdaRecoveryError, NvdaRecoveryProvider},
    voiceover::{VoiceOverError, VoiceOverMoveDirection, VoiceOverProvider},
};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct Request {
    pub version: Option<u32>,
    pub request_id: Option<String>,
    pub operation: Option<String>,
    pub params: Option<Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Response {
    pub version: u32,
    pub request_id: Option<String>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorBody>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: String,
    pub message: String,
}

pub struct ErrorResponse {
    request_id: Option<String>,
    code: &'static str,
    message: String,
}

impl ErrorResponse {
    pub fn new(request_id: Option<String>, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            request_id,
            code,
            message: message.into(),
        }
    }
}

impl Response {
    fn success(request_id: Option<String>, result: impl Serialize) -> Self {
        Self {
            version: 1,
            request_id,
            ok: true,
            result: Some(serde_json::to_value(result).expect("serializable result")),
            error: None,
        }
    }

    pub fn error(error: ErrorResponse) -> Self {
        Self {
            version: 1,
            request_id: error.request_id,
            ok: false,
            result: None,
            error: Some(ErrorBody {
                code: error.code.into(),
                message: error.message,
            }),
        }
    }
}

pub fn dispatch<H, P, V, R>(
    request: Request,
    host: &H,
    processes: &P,
    voiceover: &V,
    recovery: &R,
    capabilities: Capabilities,
) -> Response
where
    H: HostProvider,
    P: ProcessProvider,
    V: VoiceOverProvider,
    R: NvdaRecoveryProvider,
{
    let request_id = request.request_id.clone();
    let version = match request.version {
        Some(version) => version,
        None => {
            return Response::error(ErrorResponse::new(
                request_id,
                "invalid_request",
                "missing required field: version",
            ))
        }
    };
    if version != 1 {
        return Response::error(ErrorResponse::new(
            request_id,
            "unsupported_protocol_version",
            format!("unsupported protocol version: {version}"),
        ));
    }
    let operation = match request.operation {
        Some(operation) if !operation.is_empty() => operation,
        _ => {
            return Response::error(ErrorResponse::new(
                request_id,
                "invalid_request",
                "missing required field: operation",
            ))
        }
    };
    if request.request_id.is_none() {
        return Response::error(ErrorResponse::new(
            None,
            "invalid_request",
            "missing required field: request_id",
        ));
    }
    match operation.as_str() {
        "capabilities" => Response::success(request_id, capabilities),
        "host.info" => match host.host_info() {
            Ok(info) => Response::success(request_id, info),
            Err(e) => Response::error(ErrorResponse::new(request_id, "internal_error", e)),
        },
        "process.list" => match processes.list_processes() {
            Ok(list) => Response::success(request_id, list),
            Err(e) => Response::error(ErrorResponse::new(request_id, "internal_error", e)),
        },
        "process.info" => match parse_pid(request.params) {
            Ok(pid) => match processes.process_info(pid) {
                Ok(info) => Response::success(request_id, info),
                Err(ProcessError::NotFound) => Response::error(ErrorResponse::new(
                    request_id,
                    "process_not_found",
                    format!("process {pid} was not found"),
                )),
            },
            Err(e) => Response::error(ErrorResponse::new(request_id, "invalid_parameters", e)),
        },
        "voiceover.status" => voiceover_result(request_id, voiceover.status()),
        "voiceover.move" => match parse_direction(request.params) {
            Ok(direction) => voiceover_result(request_id, voiceover.move_cursor(direction)),
            Err(e) => Response::error(ErrorResponse::new(request_id, "invalid_parameters", e)),
        },
        "voiceover.press" => voiceover_result(request_id, voiceover.press()),
        "voiceover.state" => voiceover_result(request_id, voiceover.state()),
        "recovery.nvda.status" => match parse_empty_params(request.params) {
            Ok(()) => recovery_result(request_id, recovery.status()),
            Err(error) => {
                Response::error(ErrorResponse::new(request_id, "invalid_parameters", error))
            }
        },
        "recovery.nvda.restart" => match parse_empty_params(request.params) {
            Ok(()) => recovery_result(request_id, recovery.restart()),
            Err(error) => {
                Response::error(ErrorResponse::new(request_id, "invalid_parameters", error))
            }
        },
        _ => Response::error(ErrorResponse::new(
            request_id,
            "unsupported_operation",
            format!("unsupported operation: {operation}"),
        )),
    }
}

fn recovery_result<T: Serialize>(
    request_id: Option<String>,
    result: Result<T, NvdaRecoveryError>,
) -> Response {
    match result {
        Ok(value) => Response::success(request_id, value),
        Err(error) => Response::error(ErrorResponse::new(
            request_id,
            error.code(),
            error.message(),
        )),
    }
}

fn voiceover_result<T: Serialize>(
    request_id: Option<String>,
    result: Result<T, VoiceOverError>,
) -> Response {
    match result {
        Ok(value) => Response::success(request_id, value),
        Err(error) => Response::error(ErrorResponse::new(
            request_id,
            error.code(),
            error.message().to_string(),
        )),
    }
}

fn parse_pid(params: Option<Value>) -> Result<u32, String> {
    let params = params.ok_or_else(|| "missing params.pid".to_string())?;
    let pid = params
        .get("pid")
        .and_then(Value::as_u64)
        .ok_or_else(|| "params.pid must be a non-negative integer".to_string())?;
    u32::try_from(pid).map_err(|_| "params.pid is out of range".into())
}

fn parse_direction(params: Option<Value>) -> Result<VoiceOverMoveDirection, String> {
    let params = params.ok_or_else(|| "missing params.direction".to_string())?;
    let raw = params
        .get("direction")
        .and_then(Value::as_str)
        .ok_or_else(|| "params.direction must be a string".to_string())?;
    VoiceOverMoveDirection::parse(raw)
        .ok_or_else(|| "params.direction must be left, right, up, down, into, or out".into())
}

fn parse_empty_params(params: Option<Value>) -> Result<(), String> {
    match params {
        Some(Value::Object(values)) if values.is_empty() => Ok(()),
        Some(Value::Object(_)) => Err("recovery operations do not accept parameters".into()),
        Some(_) => Err("params must be an empty object".into()),
        None => Err("missing params".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        host::HostInfo,
        process::{ProcessInfo, ProcessStatus},
        recovery::{
            NvdaRecoveryError, NvdaRecoveryProvider, NvdaRecoveryStatus, NvdaRestartResult,
        },
        voiceover::{
            UnsupportedVoiceOverProvider, VoiceOverMoveResult, VoiceOverPressResult,
            VoiceOverState, VoiceOverStatus,
        },
    };
    use std::cell::RefCell;

    struct Fake;

    impl HostProvider for Fake {
        fn host_info(&self) -> Result<HostInfo, String> {
            Ok(HostInfo {
                os_family: "x".into(),
                os_version: None,
                architecture: "x".into(),
                hostname: None,
                implementation: "farrelay-host".into(),
                version: "0.1.0".into(),
            })
        }
    }

    impl ProcessProvider for Fake {
        fn list_processes(&self) -> Result<Vec<ProcessInfo>, String> {
            Ok(vec![])
        }

        fn process_info(&self, _: u32) -> Result<ProcessInfo, ProcessError> {
            Err(ProcessError::NotFound)
        }
    }

    #[derive(Default)]
    struct RecordingVoiceOver {
        moves: RefCell<Vec<VoiceOverMoveDirection>>,
        presses: RefCell<u32>,
        fail_with: Option<VoiceOverError>,
        state: VoiceOverState,
    }

    impl RecordingVoiceOver {
        fn failing(error: VoiceOverError) -> Self {
            Self {
                fail_with: Some(error),
                ..Self::default()
            }
        }
    }

    impl VoiceOverProvider for RecordingVoiceOver {
        fn status(&self) -> Result<VoiceOverStatus, VoiceOverError> {
            if let Some(error) = &self.fail_with {
                return Err(error.clone());
            }
            Ok(VoiceOverStatus {
                platform_supported: true,
                available: true,
                voiceover_running: true,
                applescript_bridge_usable: true,
                message: None,
            })
        }

        fn move_cursor(
            &self,
            direction: VoiceOverMoveDirection,
        ) -> Result<VoiceOverMoveResult, VoiceOverError> {
            if let Some(error) = &self.fail_with {
                return Err(error.clone());
            }
            self.moves.borrow_mut().push(direction);
            Ok(VoiceOverMoveResult { moved: true })
        }

        fn press(&self) -> Result<VoiceOverPressResult, VoiceOverError> {
            if let Some(error) = &self.fail_with {
                return Err(error.clone());
            }
            *self.presses.borrow_mut() += 1;
            Ok(VoiceOverPressResult { pressed: true })
        }

        fn state(&self) -> Result<VoiceOverState, VoiceOverError> {
            if let Some(error) = &self.fail_with {
                return Err(error.clone());
            }
            Ok(self.state.clone())
        }
    }

    fn req(json: &str) -> Request {
        serde_json::from_str(json).unwrap()
    }

    fn call(json: &str, voiceover: &impl VoiceOverProvider, caps: Capabilities) -> Response {
        dispatch(req(json), &Fake, &Fake, voiceover, &FakeRecovery, caps)
    }

    struct FakeRecovery;
    impl NvdaRecoveryProvider for FakeRecovery {
        fn status(&self) -> Result<NvdaRecoveryStatus, NvdaRecoveryError> {
            Ok(NvdaRecoveryStatus {
                nvda_running: false,
                recovery_task_ready: true,
            })
        }
        fn restart(&self) -> Result<NvdaRestartResult, NvdaRecoveryError> {
            Ok(NvdaRestartResult {
                requested: true,
                task_started: true,
            })
        }
    }

    #[test]
    fn preserves_id_and_returns_capabilities() {
        let r = call(
            r#"{"version":1,"request_id":"abc","operation":"capabilities"}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert!(r.ok);
        assert_eq!(r.request_id.as_deref(), Some("abc"));
        let operations = r.result.unwrap()["operations"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|value| value.as_str().map(str::to_string))
            .collect::<Vec<_>>();
        assert_eq!(
            &operations[..3],
            ["host.info", "process.list", "process.info"]
        );
    }

    #[test]
    fn existing_process_and_host_operations_remain_unchanged() {
        let info = call(
            r#"{"version":1,"request_id":"h","operation":"host.info"}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert!(info.ok);
        assert_eq!(info.result.unwrap()["implementation"], "farrelay-host");

        let missing = call(
            r#"{"version":1,"request_id":"p","operation":"process.info","params":{"pid":99}}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert_eq!(missing.error.unwrap().code, "process_not_found");
        assert_eq!(missing.request_id.as_deref(), Some("p"));
    }

    #[test]
    fn rejects_unknown_operation() {
        let r = call(
            r#"{"version":1,"request_id":"x","operation":"nope"}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert_eq!(r.error.unwrap().code, "unsupported_operation");
    }

    #[test]
    fn rejects_bad_pid_and_missing_fields() {
        let r = call(
            r#"{"version":1,"request_id":"x","operation":"process.info","params":{"pid":"7"}}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert_eq!(r.error.unwrap().code, "invalid_parameters");

        let r = call(
            r#"{"version":1,"request_id":"x"}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert_eq!(r.error.unwrap().code, "invalid_request");
    }

    #[test]
    fn missing_process_is_structured() {
        let r = call(
            r#"{"version":1,"request_id":"x","operation":"process.info","params":{"pid":99}}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::v1(),
        );
        assert_eq!(r.error.unwrap().code, "process_not_found");
    }

    #[test]
    fn macos_capability_payload_includes_voiceover_operations() {
        let r = call(
            r#"{"version":1,"request_id":"caps","operation":"capabilities"}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::for_os("macos"),
        );
        let result = r.result.unwrap();
        let operations = result["operations"].as_array().unwrap();
        let names: Vec<_> = operations.iter().filter_map(|v| v.as_str()).collect();
        assert_eq!(
            names,
            [
                "host.info",
                "process.list",
                "process.info",
                "voiceover.status",
                "voiceover.move",
                "voiceover.press",
                "voiceover.state",
            ]
        );
    }

    #[test]
    fn voiceover_move_accepts_each_supported_direction() {
        let voiceover = RecordingVoiceOver::default();
        for direction in ["left", "right", "up", "down", "into", "out"] {
            let r = call(
                &format!(
                    r#"{{"version":1,"request_id":"{direction}","operation":"voiceover.move","params":{{"direction":"{direction}","script":"do shell script \"evil\""}}}}"#
                ),
                &voiceover,
                Capabilities::for_os("macos"),
            );
            assert!(r.ok, "{}", direction);
            assert_eq!(r.request_id.as_deref(), Some(direction));
            assert_eq!(r.result.as_ref().unwrap()["moved"], true);
            let encoded = serde_json::to_string(&r).unwrap();
            assert!(!encoded.contains("tell application"));
            assert!(!encoded.contains("do shell script"));
        }
        assert_eq!(
            voiceover.moves.borrow().as_slice(),
            [
                VoiceOverMoveDirection::Left,
                VoiceOverMoveDirection::Right,
                VoiceOverMoveDirection::Up,
                VoiceOverMoveDirection::Down,
                VoiceOverMoveDirection::Into,
                VoiceOverMoveDirection::Out,
            ]
        );
    }

    #[test]
    fn voiceover_move_rejects_unknown_values() {
        let voiceover = RecordingVoiceOver::default();
        let r = call(
            r#"{"version":1,"request_id":"bad","operation":"voiceover.move","params":{"direction":"diagonal"}}"#,
            &voiceover,
            Capabilities::for_os("macos"),
        );
        assert_eq!(r.error.unwrap().code, "invalid_parameters");
        assert_eq!(r.request_id.as_deref(), Some("bad"));
        assert!(voiceover.moves.borrow().is_empty());
    }

    #[test]
    fn voiceover_press_dispatches_exactly_one_provider_action() {
        let voiceover = RecordingVoiceOver::default();
        let r = call(
            r#"{"version":1,"request_id":"press-1","operation":"voiceover.press","params":{"script":"beep"}}"#,
            &voiceover,
            Capabilities::for_os("macos"),
        );
        assert!(r.ok);
        assert_eq!(r.request_id.as_deref(), Some("press-1"));
        assert_eq!(r.result.unwrap()["pressed"], true);
        assert_eq!(*voiceover.presses.borrow(), 1);
    }

    #[test]
    fn voiceover_state_returns_structured_optional_fields() {
        let voiceover = RecordingVoiceOver {
            state: VoiceOverState {
                last_spoken_phrase: Some("Mail".into()),
                voiceover_cursor_text: None,
                keyboard_cursor_text: Some("Inbox".into()),
            },
            ..RecordingVoiceOver::default()
        };
        let r = call(
            r#"{"version":1,"request_id":"state-1","operation":"voiceover.state"}"#,
            &voiceover,
            Capabilities::for_os("macos"),
        );
        assert!(r.ok);
        let result = r.result.unwrap();
        assert_eq!(result["last_spoken_phrase"], "Mail");
        assert!(result.get("voiceover_cursor_text").is_none());
        assert_eq!(result["keyboard_cursor_text"], "Inbox");
    }

    #[test]
    fn provider_failures_become_structured_protocol_errors() {
        let voiceover = RecordingVoiceOver::failing(VoiceOverError::ControlUnavailable {
            message: "VoiceOver AppleScript control is not currently usable".into(),
        });
        let r = call(
            r#"{"version":1,"request_id":"fail-1","operation":"voiceover.status"}"#,
            &voiceover,
            Capabilities::for_os("macos"),
        );
        assert!(!r.ok);
        assert_eq!(r.request_id.as_deref(), Some("fail-1"));
        let error = r.error.unwrap();
        assert_eq!(error.code, "voiceover_control_unavailable");
        assert!(!error.message.contains("tell application"));
    }

    #[test]
    fn unsupported_platform_voiceover_ops_are_structured() {
        let r = call(
            r#"{"version":1,"request_id":"linux-vo","operation":"voiceover.move","params":{"direction":"right"}}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::for_os("linux"),
        );
        assert_eq!(r.request_id.as_deref(), Some("linux-vo"));
        assert_eq!(r.error.unwrap().code, "unsupported_platform");
    }

    #[test]
    fn recovery_rejects_parameters_and_keeps_protocol_output_structured() {
        let status = call(
            r#"{"version":1,"request_id":"recovery-status","operation":"recovery.nvda.status","params":{"task":"evil","command":"evil"}}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::for_os("windows"),
        );
        assert!(!status.ok);
        assert_eq!(status.error.unwrap().code, "invalid_parameters");

        let restart = call(
            r#"{"version":1,"request_id":"recovery-restart","operation":"recovery.nvda.restart","params":{}}"#,
            &UnsupportedVoiceOverProvider,
            Capabilities::for_os("windows"),
        );
        assert!(restart.ok);
        assert_eq!(restart.result.unwrap()["task_started"], true);
    }

    #[allow(dead_code)]
    fn _status(_: ProcessStatus) {}
}
