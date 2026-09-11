use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProcessStatus {
    Running,
    Sleeping,
    Stopped,
    Zombie,
    Unknown,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct ProcessInfo {
    pub pid: u32,
    pub name: String,
    pub status: Option<ProcessStatus>,
}

#[derive(Debug)]
pub enum ProcessError {
    NotFound,
    Backend(String),
}

pub trait ProcessProvider {
    fn list_processes(&self) -> Result<Vec<ProcessInfo>, String>;
    fn process_info(&self, pid: u32) -> Result<ProcessInfo, ProcessError>;
}
