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
    fn nvda_running(&self) -> bool {
        System::new_all().processes().values().any(|process| {
            process.name().eq_ignore_ascii_case("nvda.exe")
                || process.name().eq_ignore_ascii_case("nvda")
        })
    }
}
