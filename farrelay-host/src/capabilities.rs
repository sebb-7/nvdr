use serde::Serialize;

const BASE_OPERATIONS: &[&str] = &["host.info", "process.list", "process.info"];
const VOICEOVER_OPERATIONS: &[&str] = &[
    "voiceover.status",
    "voiceover.move",
    "voiceover.press",
    "voiceover.state",
];
const MACOS_FEATURES: &[&str] = &["macRemote", "voiceOverSemanticFeedback"];
const WINDOWS_RECOVERY_OPERATIONS: &[&str] = &["recovery.nvda.status", "recovery.nvda.restart"];
const WINDOWS_REMSOUND_OPERATIONS: &[&str] = &[
    "remsound.status",
    "remsound.start",
    "remsound.stop",
    "remsound.restart",
];
const WINDOWS_FEATURES: &[&str] = &["remoteAudioOrchestration", "remSoundProcessControl"];

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Capabilities {
    pub protocol_version: u32,
    pub host_implementation: String,
    pub host_version: String,
    pub operations: Vec<String>,
    /// Extensible feature identifiers. Operations describe callable RPCs;
    /// features describe product capabilities and may be safely ignored by an
    /// older client when they are optional.
    pub features: Vec<String>,
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
        if os == "windows" {
            operations.extend(
                WINDOWS_RECOVERY_OPERATIONS
                    .iter()
                    .map(|op| (*op).to_string()),
            );
            operations.extend(
                WINDOWS_REMSOUND_OPERATIONS
                    .iter()
                    .map(|op| (*op).to_string()),
            );
        }
        let features = if os == "macos" {
            MACOS_FEATURES
                .iter()
                .map(|feature| (*feature).to_string())
                .collect()
        } else if os == "windows" {
            WINDOWS_FEATURES
                .iter()
                .map(|feature| (*feature).to_string())
                .collect()
        } else {
            Vec::new()
        };
        Self {
            protocol_version: 1,
            host_implementation: "farrelay-host".into(),
            host_version: crate::DISTRIBUTION_VERSION.into(),
            operations,
            features,
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
        if std::env::consts::OS == "macos" {
            assert_eq!(caps.features, ["macRemote", "voiceOverSemanticFeedback"]);
        } else if std::env::consts::OS == "windows" {
            assert_eq!(
                caps.features,
                ["remoteAudioOrchestration", "remSoundProcessControl"]
            );
        } else {
            assert!(caps.features.is_empty());
        }
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
        assert_eq!(
            Capabilities::for_os("macos").features,
            ["macRemote", "voiceOverSemanticFeedback"]
        );
    }

    #[test]
    fn linux_and_windows_capabilities_exclude_voiceover_operations() {
        for os in ["linux", "windows"] {
            let caps = Capabilities::for_os(os);
            assert!(caps.operations.starts_with(&[
                "host.info".into(),
                "process.list".into(),
                "process.info".into()
            ]));
            assert!(caps
                .operations
                .iter()
                .all(|operation| !operation.starts_with("voiceover.")));
        }
    }

    #[test]
    fn only_windows_advertises_fixed_nvda_recovery() {
        let windows = Capabilities::for_os("windows");
        assert!(windows.operations.contains(&"recovery.nvda.status".into()));
        assert!(windows.operations.contains(&"recovery.nvda.restart".into()));
        for os in ["linux", "macos"] {
            assert!(Capabilities::for_os(os)
                .operations
                .iter()
                .all(|op| !op.starts_with("recovery.nvda")));
        }
    }

    #[test]
    fn only_windows_advertises_remsound_orchestration() {
        let windows = Capabilities::for_os("windows");
        for operation in WINDOWS_REMSOUND_OPERATIONS {
            assert!(windows.operations.contains(&(*operation).to_string()));
        }
        assert_eq!(
            windows.features,
            ["remoteAudioOrchestration", "remSoundProcessControl"]
        );
        for os in ["linux", "macos"] {
            let caps = Capabilities::for_os(os);
            assert!(caps
                .operations
                .iter()
                .all(|op| !op.starts_with("remsound.")));
            assert!(caps
                .features
                .iter()
                .all(|feature| !feature.starts_with("remSound")));
        }
    }
}
