pub use super::common::SystemProvider;

use crate::{
    exec::StdCommandRunner,
    recovery::{NvdaProcessProbe, NvdaRecoveryProvider, WindowsNvdaRecoveryProvider},
};
use sysinfo::System;

pub fn nvda_recovery_host() -> impl NvdaRecoveryProvider {
    WindowsNvdaRecoveryProvider::new(StdCommandRunner, SysinfoNvdaProcessProbe)
}

struct SysinfoNvdaProcessProbe;

impl NvdaProcessProbe for SysinfoNvdaProcessProbe {
    fn nvda_process_ids(&self) -> Vec<u32> {
        let mut process_ids: Vec<u32> = System::new_all()
            .processes()
            .iter()
            .filter(|(_, process)| {
                process.name().eq_ignore_ascii_case("nvda.exe")
                    || process.name().eq_ignore_ascii_case("nvda")
            })
            .map(|(pid, _)| pid.as_u32())
            .collect();
        process_ids.sort_unstable();
        process_ids
    }
}
