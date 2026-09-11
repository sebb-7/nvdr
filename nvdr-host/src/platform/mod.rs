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

#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
compile_error!("nvdr-host supports Windows, macOS, and Linux only");
