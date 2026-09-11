use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Capabilities {
    pub protocol_version: u32,
    pub host_implementation: String,
    pub host_version: String,
    pub operations: Vec<String>,
}

impl Capabilities {
    pub fn v1() -> Self {
        Self {
            protocol_version: 1,
            host_implementation: "nvdr-host".into(),
            host_version: env!("CARGO_PKG_VERSION").into(),
            operations: vec![
                "host.info".into(),
                "process.list".into(),
                "process.info".into(),
            ],
        }
    }
}
