use serde::{Deserialize, Serialize};
use serde_json::Value;
use crate::{capabilities::Capabilities, host::HostProvider, process::{ProcessError, ProcessProvider}};

#[derive(Debug, Deserialize)]
pub struct Request { pub version: Option<u32>, pub request_id: Option<String>, pub operation: Option<String>, pub params: Option<Value> }
#[derive(Debug, Serialize, Deserialize)]
pub struct Response { pub version: u32, pub request_id: Option<String>, pub ok: bool, #[serde(skip_serializing_if = "Option::is_none")] pub result: Option<Value>, #[serde(skip_serializing_if = "Option::is_none")] pub error: Option<ErrorBody> }
#[derive(Debug, Serialize, Deserialize)]
pub struct ErrorBody { pub code: String, pub message: String }
pub struct ErrorResponse { request_id: Option<String>, code: &'static str, message: String }
impl ErrorResponse { pub fn new(request_id: Option<String>, code: &'static str, message: impl Into<String>) -> Self { Self { request_id, code, message: message.into() } } }
impl Response {
    fn success(request_id: Option<String>, result: impl Serialize) -> Self { Self { version: 1, request_id, ok: true, result: Some(serde_json::to_value(result).expect("serializable result")), error: None } }
    pub fn error(error: ErrorResponse) -> Self { Self { version: 1, request_id: error.request_id, ok: false, result: None, error: Some(ErrorBody { code: error.code.into(), message: error.message }) } }
}
pub fn dispatch<H, P>(request: Request, host: &H, processes: &P, capabilities: Capabilities) -> Response where H: HostProvider, P: ProcessProvider {
    let request_id = request.request_id.clone();
    let version = match request.version { Some(version) => version, None => return Response::error(ErrorResponse::new(request_id, "invalid_request", "missing required field: version")) };
    if version != 1 { return Response::error(ErrorResponse::new(request_id, "unsupported_protocol_version", format!("unsupported protocol version: {version}"))); }
    let operation = match request.operation { Some(operation) if !operation.is_empty() => operation, _ => return Response::error(ErrorResponse::new(request_id, "invalid_request", "missing required field: operation")) };
    if request.request_id.is_none() { return Response::error(ErrorResponse::new(None, "invalid_request", "missing required field: request_id")); }
    match operation.as_str() {
        "capabilities" => Response::success(request_id, capabilities),
        "host.info" => match host.host_info() { Ok(info) => Response::success(request_id, info), Err(e) => Response::error(ErrorResponse::new(request_id, "internal_error", e)) },
        "process.list" => match processes.list_processes() { Ok(list) => Response::success(request_id, list), Err(e) => Response::error(ErrorResponse::new(request_id, "internal_error", e)) },
        "process.info" => match parse_pid(request.params) { Ok(pid) => match processes.process_info(pid) { Ok(info) => Response::success(request_id, info), Err(ProcessError::NotFound) => Response::error(ErrorResponse::new(request_id, "process_not_found", format!("process {pid} was not found"))), Err(ProcessError::Backend(e)) => Response::error(ErrorResponse::new(request_id, "internal_error", e)) }, Err(e) => Response::error(ErrorResponse::new(request_id, "invalid_parameters", e)) },
        _ => Response::error(ErrorResponse::new(request_id, "unsupported_operation", format!("unsupported operation: {operation}"))),
    }
}
fn parse_pid(params: Option<Value>) -> Result<u32, String> { let params = params.ok_or_else(|| "missing params.pid".to_string())?; let pid = params.get("pid").and_then(Value::as_u64).ok_or_else(|| "params.pid must be a non-negative integer".to_string())?; u32::try_from(pid).map_err(|_| "params.pid is out of range".into()) }

#[cfg(test)]
mod tests {
    use super::*; use crate::{host::HostInfo, process::{ProcessInfo, ProcessStatus}};
    struct Fake;
    impl HostProvider for Fake { fn host_info(&self)->Result<HostInfo,String>{Ok(HostInfo{os_family:"x".into(),os_version:None,architecture:"x".into(),hostname:None,implementation:"nvdr-host".into(),version:"0.1.0".into()})} }
    impl ProcessProvider for Fake { fn list_processes(&self)->Result<Vec<ProcessInfo>,String>{Ok(vec![])} fn process_info(&self,_:u32)->Result<ProcessInfo,ProcessError>{Err(ProcessError::NotFound)} }
    fn req(json:&str)->Request{serde_json::from_str(json).unwrap()}
    #[test] fn preserves_id_and_returns_capabilities(){let r=dispatch(req(r#"{"version":1,"request_id":"abc","operation":"capabilities"}"#),&Fake,&Fake,Capabilities::v1());assert!(r.ok);assert_eq!(r.request_id.as_deref(),Some("abc"));}
    #[test] fn rejects_unknown_operation(){let r=dispatch(req(r#"{"version":1,"request_id":"x","operation":"nope"}"#),&Fake,&Fake,Capabilities::v1());assert_eq!(r.error.unwrap().code,"unsupported_operation");}
    #[test] fn rejects_bad_pid_and_missing_fields(){let r=dispatch(req(r#"{"version":1,"request_id":"x","operation":"process.info","params":{"pid":"7"}}"#),&Fake,&Fake,Capabilities::v1());assert_eq!(r.error.unwrap().code,"invalid_parameters");let r=dispatch(req(r#"{"version":1,"request_id":"x"}"#),&Fake,&Fake,Capabilities::v1());assert_eq!(r.error.unwrap().code,"invalid_request");}
    #[test] fn missing_process_is_structured(){let r=dispatch(req(r#"{"version":1,"request_id":"x","operation":"process.info","params":{"pid":99}}"#),&Fake,&Fake,Capabilities::v1());assert_eq!(r.error.unwrap().code,"process_not_found");}
    #[allow(dead_code)] fn _status(_: ProcessStatus) {}
}
