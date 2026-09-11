use crate::{
    host::{HostInfo, HostProvider},
    process::{ProcessError, ProcessInfo, ProcessProvider, ProcessStatus},
};
use sysinfo::{Pid, ProcessStatus as SysProcessStatus, System};

pub struct SystemProvider {
    system: System,
}

impl SystemProvider {
    pub fn new() -> Self {
        Self {
            system: System::new_all(),
        }
    }
}

impl HostProvider for SystemProvider {
    fn host_info(&self) -> Result<HostInfo, String> {
        Ok(HostInfo {
            os_family: std::env::consts::OS.into(),
            os_version: System::long_os_version(),
            architecture: std::env::consts::ARCH.into(),
            hostname: System::host_name(),
            implementation: "nvdr-host".into(),
            version: env!("CARGO_PKG_VERSION").into(),
        })
    }
}

impl ProcessProvider for SystemProvider {
    fn list_processes(&self) -> Result<Vec<ProcessInfo>, String> {
        let mut list: Vec<_> = self.system.processes().values().map(to_info).collect();
        list.sort_by_key(|p| p.pid);
        Ok(list)
    }

    fn process_info(&self, pid: u32) -> Result<ProcessInfo, ProcessError> {
        self.system
            .process(Pid::from_u32(pid))
            .map(to_info)
            .ok_or(ProcessError::NotFound)
    }
}

fn to_info(process: &sysinfo::Process) -> ProcessInfo {
    ProcessInfo {
        pid: process.pid().as_u32(),
        name: process.name().to_string_lossy().into_owned(),
        status: Some(match process.status() {
            SysProcessStatus::Run => ProcessStatus::Running,
            SysProcessStatus::Sleep => ProcessStatus::Sleeping,
            SysProcessStatus::Stop => ProcessStatus::Stopped,
            SysProcessStatus::Zombie => ProcessStatus::Zombie,
            _ => ProcessStatus::Unknown,
        }),
    }
}
