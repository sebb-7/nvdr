mod common;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "linux")]
pub use linux::SystemProvider;
#[cfg(target_os = "macos")]
pub use macos::SystemProvider;
#[cfg(target_os = "windows")]
pub use windows::SystemProvider;

use crate::voiceover::VoiceOverProvider;

#[cfg(target_os = "macos")]
use crate::exec::StdCommandRunner;
#[cfg(not(target_os = "macos"))]
use crate::voiceover::UnsupportedVoiceOverProvider;
#[cfg(target_os = "macos")]
use crate::voiceover::{AppleScriptVoiceOverProvider, SysinfoVoiceOverProbe};

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
compile_error!("farrelay-host supports Windows, macOS, and Linux only");

#[cfg(target_os = "macos")]
pub fn voiceover_host() -> impl VoiceOverProvider {
    AppleScriptVoiceOverProvider::new(StdCommandRunner, SysinfoVoiceOverProbe)
}

#[cfg(not(target_os = "macos"))]
pub fn voiceover_host() -> impl VoiceOverProvider {
    UnsupportedVoiceOverProvider
}
