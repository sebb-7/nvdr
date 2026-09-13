use serde::Serialize;

const BASE_OPERATIONS: &[&str] = &["host.info", "process.list", "process.info"];
const VOICEOVER_OPERATIONS: &[&str] = &[
    "voiceover.status",
    "voiceover.move",
    "voiceover.press",
    "voiceover.state",
];

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Capabilities {
    pub protocol_version: u32,
    pub host_implementation: String,
    pub host_version: String,
    pub operations: Vec<String>,
}

impl Capabilities {
    pub fn v1() -> Self {
        Self::for_os(std::env::consts::OS)
    }

    pub fn for_os(os: &str) -> Self {
        let mut operations: Vec<String> =
            BASE_OPERATIONS.iter().map(|op| (*op).to_string()).collect();
        if os == "macos" {
            operations.extend(VOICEOVER_OPERATIONS.iter().map(|op| (*op).to_string()));
        }
        Self {
            protocol_version: 1,
            host_implementation: "farrelay-host".into(),
            host_version: env!("CARGO_PKG_VERSION").into(),
            operations,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v1_matches_current_os_and_keeps_protocol_version() {
        let caps = Capabilities::v1();
        assert_eq!(caps, Capabilities::for_os(std::env::consts::OS));
        assert_eq!(caps.protocol_version, 1);
        assert_eq!(caps.host_implementation, "farrelay-host");
        assert_eq!(
            &caps.operations[..3],
            ["host.info", "process.list", "process.info"]
        );
    }

    #[test]
    fn macos_capabilities_include_voiceover_operations() {
        assert_eq!(
            Capabilities::for_os("macos").operations,
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
    fn linux_and_windows_capabilities_exclude_voiceover_operations() {
        for os in ["linux", "windows"] {
            let caps = Capabilities::for_os(os);
            assert_eq!(
                caps.operations,
                ["host.info", "process.list", "process.info"]
            );
            assert!(caps
                .operations
                .iter()
                .all(|operation| !operation.starts_with("voiceover.")));
        }
    }
}
