//! macOS host/process listing.
//!
//! VoiceOver control is not implemented here. `platform::voiceover_host()`
//! returns `AppleScriptVoiceOverProvider`, which runs only fixed
//! `/usr/bin/osascript` templates. AXUIElement and CGEvent remain deferred.

pub use super::common::SystemProvider;
