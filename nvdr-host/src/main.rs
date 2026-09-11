mod capabilities;
mod host;
mod platform;
mod process;
mod protocol;

use std::io::{self, BufRead, Write};

use capabilities::Capabilities;
use host::HostProvider;
use platform::SystemProvider;
use process::ProcessProvider;
use protocol::{dispatch, ErrorResponse, Request, Response};

fn main() {
    let provider = SystemProvider::new();
    let stdin = io::stdin();
    let mut stdout = io::BufWriter::new(io::stdout().lock());

    for line in stdin.lock().lines() {
        let response = match line {
            Ok(line) => handle_line(&line, &provider),
            Err(error) => Response::error(ErrorResponse::new(
                None,
                "internal_error",
                format!("failed to read request: {error}"),
            )),
        };

        if serde_json::to_writer(&mut stdout, &response).is_err()
            || stdout.write_all(b"\n").is_err()
            || stdout.flush().is_err()
        {
            eprintln!("failed to write protocol response");
            break;
        }
    }
}

fn handle_line<P>(line: &str, provider: &P) -> Response
where
    P: HostProvider + ProcessProvider,
{
    match serde_json::from_str::<Request>(line) {
        Ok(request) => dispatch(request, provider, provider, Capabilities::v1()),
        Err(error) => Response::error(ErrorResponse::new(
            None,
            "malformed_json",
            format!("request is not valid JSON: {error}"),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    use host::HostInfo;
    use process::{ProcessInfo, ProcessStatus};

    #[derive(Default)]
    struct FakeProvider;

    impl HostProvider for FakeProvider {
        fn host_info(&self) -> Result<HostInfo, String> {
            Ok(HostInfo {
                os_family: "test".into(),
                os_version: Some("1".into()),
                architecture: "test".into(),
                hostname: Some("fake".into()),
                implementation: "nvdr-host".into(),
                version: "0.1.0".into(),
            })
        }
    }
    impl ProcessProvider for FakeProvider {
        fn list_processes(&self) -> Result<Vec<ProcessInfo>, String> {
            Ok(vec![ProcessInfo {
                pid: 7,
                name: "fixture".into(),
                status: Some(ProcessStatus::Running),
            }])
        }
        fn process_info(&self, pid: u32) -> Result<ProcessInfo, process::ProcessError> {
            if pid == 7 {
                Ok(ProcessInfo {
                    pid,
                    name: "fixture".into(),
                    status: Some(ProcessStatus::Running),
                })
            } else {
                Err(process::ProcessError::NotFound)
            }
        }
    }

    #[test]
    fn stream_continues_after_invalid_request() {
        let provider = FakeProvider;
        let input = "{\"version\":1,\"request_id\":\"a\",\"operation\":\"capabilities\"}\nnot json\n{\"version\":1,\"request_id\":\"b\",\"operation\":\"process.info\",\"params\":{\"pid\":7}}\n";
        let mut output = Vec::new();
        for line in Cursor::new(input).lines() {
            let response = handle_line(&line.unwrap(), &provider);
            serde_json::to_writer(&mut output, &response).unwrap();
            output.push(b'\n');
        }
        let lines: Vec<_> = String::from_utf8(output).unwrap().lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].contains("\"request_id\":\"a\""));
        assert!(lines[1].contains("malformed_json"));
        assert!(lines[2].contains("\"request_id\":\"b\""));
        assert!(lines
            .iter()
            .all(|line| serde_json::from_str::<serde_json::Value>(line).is_ok()));
    }
}
