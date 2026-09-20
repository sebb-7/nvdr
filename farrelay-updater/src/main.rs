use farrelay_updater::{
    apply_staged_release, plan_update, rollback_release, unzip_update, verify_file, InstallConfig,
    RELEASE_URL_PREFIX,
};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const DISTRIBUTION_VERSION: &str = match option_env!("FARRELAY_DIST_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};

fn data_dir() -> PathBuf {
    env::var_os("FARRELAY_DATA_DIR")
        .map(PathBuf::from)
        .or_else(|| env::var_os("PROGRAMDATA").map(|v| PathBuf::from(v).join("FarRelay")))
        .unwrap_or_else(|| PathBuf::from("C:/ProgramData/FarRelay"))
}
fn config_path() -> PathBuf {
    data_dir().join("install.json")
}
fn load_config() -> Result<InstallConfig, String> {
    let value = fs::read_to_string(config_path())
        .map_err(|e| format!("read {}: {e}", config_path().display()))?;
    let config: InstallConfig =
        serde_json::from_str(&value).map_err(|e| format!("invalid install configuration: {e}"))?;
    if config.schema_version != 1 || !config.manifest_url.starts_with(RELEASE_URL_PREFIX) {
        return Err("install configuration has an unsupported schema or update source".into());
    }
    Ok(config)
}
fn architecture() -> &'static str {
    "windows_x86_64"
}
fn download(url: &str, destination: &Path) -> Result<(), String> {
    if !url.starts_with(RELEASE_URL_PREFIX) {
        return Err("refusing untrusted update URL".into());
    }
    let status = Command::new("curl.exe")
        .args([
            "--fail",
            "--location",
            "--proto",
            "=https",
            "--tlsv1.2",
            "--silent",
            "--show-error",
            "--output",
        ])
        .arg(destination)
        .arg(url)
        .status()
        .map_err(|e| format!("starting built-in HTTPS downloader: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("HTTPS download failed".into())
    }
}
fn binaries_busy() -> bool {
    #[cfg(windows)]
    {
        ["farrelay.exe", "farrelay-host.exe"].iter().any(|name| {
            Command::new("tasklist.exe")
                .args(["/FI", &format!("IMAGENAME eq {name}"), "/NH"])
                .output()
                .map(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .to_ascii_lowercase()
                        .contains(name)
                })
                .unwrap_or(true)
        })
    }
    #[cfg(not(windows))]
    {
        false
    }
}
fn check_and_install(install: bool) -> Result<(), String> {
    let mut config = load_config()?;
    let work = data_dir().join("updates");
    fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    let manifest_file = work.join("manifest.json");
    download(&config.manifest_url, &manifest_file)?;
    let manifest = fs::read_to_string(&manifest_file).map_err(|e| e.to_string())?;
    let Some(plan) = plan_update(
        &manifest,
        config.channel,
        architecture(),
        &config.installed_version,
    )?
    else {
        println!(
            "FarRelay {} is current on the {} channel.",
            config.installed_version, config.channel
        );
        return Ok(());
    };
    println!(
        "FarRelay update available: {} -> {}",
        config.installed_version, plan.version
    );
    if !install {
        return Ok(());
    }
    if binaries_busy() {
        return Err("FarRelay is busy; update deferred without stopping active control".into());
    }
    let archive = work.join("download.zip");
    download(&plan.asset.archive_url, &archive)?;
    verify_file(&archive, &plan.asset.sha256, plan.asset.size)?;
    let staging = work.join("staging");
    unzip_update(&archive, &staging)?;
    apply_staged_release(&config.install_dir, &staging, &work.join("rollback"))?;
    config.installed_version = plan.version;
    fs::write(
        config_path(),
        serde_json::to_vec_pretty(&config).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    println!("FarRelay update installed.");
    Ok(())
}
fn usage() {
    eprintln!(
        "Usage: farrelay-updater <status|check|update|rollback|--check-and-install|--version>"
    );
}
fn main() {
    let command = env::args().nth(1).unwrap_or_else(|| "status".into());
    let result = match command.as_str() {
        "--version" | "version" => {
            println!("farrelay-updater {DISTRIBUTION_VERSION}");
            Ok(())
        }
        "status" => load_config().map(|c| {
            println!(
                "FarRelay {} ({})\nInstall: {}\nSource: {}",
                c.installed_version,
                c.channel,
                c.install_dir.display(),
                c.manifest_url
            )
        }),
        "check" => check_and_install(false),
        "update" | "--check-and-install" => check_and_install(true),
        "rollback" => load_config()
            .and_then(|c| rollback_release(&c.install_dir, &data_dir().join("updates/rollback")))
            .map(|_| println!("FarRelay rollback restored.")),
        _ => {
            usage();
            Err("unsupported updater command".into())
        }
    };
    if let Err(error) = result {
        eprintln!("farrelay-updater: {error}");
        std::process::exit(1);
    }
}
