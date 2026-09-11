use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct HostInfo {
    pub os_family: String,
    pub os_version: Option<String>,
    pub architecture: String,
    pub hostname: Option<String>,
    pub implementation: String,
    pub version: String,
}

pub trait HostProvider {
    fn host_info(&self) -> Result<HostInfo, String>;
}
