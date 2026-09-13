#[cfg(any(test, target_os = "macos"))]
mod applescript;

#[cfg(target_os = "macos")]
pub use applescript::{AppleScriptVoiceOverProvider, SysinfoVoiceOverProbe};

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceOverMoveDirection {
    Left,
    Right,
    Up,
    Down,
    Into,
    Out,
}

impl VoiceOverMoveDirection {
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            "up" => Some(Self::Up),
            "down" => Some(Self::Down),
            "into" => Some(Self::Into),
            "out" => Some(Self::Out),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct VoiceOverStatus {
    pub platform_supported: bool,
    pub available: bool,
    pub voiceover_running: bool,
    pub applescript_bridge_usable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct VoiceOverMoveResult {
    pub moved: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct VoiceOverPressResult {
    pub pressed: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq, Default)]
pub struct VoiceOverState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_spoken_phrase: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub voiceover_cursor_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keyboard_cursor_text: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceOverError {
    UnsupportedPlatform,
    #[cfg_attr(not(any(test, target_os = "macos")), allow(dead_code))]
    Unavailable {
        message: String,
    },
    #[cfg_attr(not(any(test, target_os = "macos")), allow(dead_code))]
    ControlUnavailable {
        message: String,
    },
    #[cfg_attr(not(any(test, target_os = "macos")), allow(dead_code))]
    Internal {
        message: String,
    },
}

impl VoiceOverError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnsupportedPlatform => "unsupported_platform",
            Self::Unavailable { .. } => "voiceover_unavailable",
            Self::ControlUnavailable { .. } => "voiceover_control_unavailable",
            Self::Internal { .. } => "internal_error",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            Self::UnsupportedPlatform => "VoiceOver operations are not available on this platform",
            Self::Unavailable { message }
            | Self::ControlUnavailable { message }
            | Self::Internal { message } => message,
        }
    }
}

pub trait VoiceOverProvider {
    fn status(&self) -> Result<VoiceOverStatus, VoiceOverError>;
    fn move_cursor(
        &self,
        direction: VoiceOverMoveDirection,
    ) -> Result<VoiceOverMoveResult, VoiceOverError>;
    fn press(&self) -> Result<VoiceOverPressResult, VoiceOverError>;
    fn state(&self) -> Result<VoiceOverState, VoiceOverError>;
}

#[cfg(any(test, not(target_os = "macos")))]
pub struct UnsupportedVoiceOverProvider;

#[cfg(any(test, not(target_os = "macos")))]
impl VoiceOverProvider for UnsupportedVoiceOverProvider {
    fn status(&self) -> Result<VoiceOverStatus, VoiceOverError> {
        Err(VoiceOverError::UnsupportedPlatform)
    }

    fn move_cursor(
        &self,
        _direction: VoiceOverMoveDirection,
    ) -> Result<VoiceOverMoveResult, VoiceOverError> {
        Err(VoiceOverError::UnsupportedPlatform)
    }

    fn press(&self) -> Result<VoiceOverPressResult, VoiceOverError> {
        Err(VoiceOverError::UnsupportedPlatform)
    }

    fn state(&self) -> Result<VoiceOverState, VoiceOverError> {
        Err(VoiceOverError::UnsupportedPlatform)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(test, not(target_os = "macos")))]
    #[test]
    fn unsupported_provider_uses_structured_platform_error() {
        let provider = UnsupportedVoiceOverProvider;
        assert_eq!(
            provider.status().unwrap_err().code(),
            "unsupported_platform"
        );
    }
}
