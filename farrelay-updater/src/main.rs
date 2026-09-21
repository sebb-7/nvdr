use farrelay_updater::{
    apply_staged_release, plan_update, rollback_release, unzip_update, verify_file, Channel,
    InstallConfig,
};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

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

fn credential_path() -> PathBuf {
    data_dir().join("device.credential")
}

fn tester_profile_path() -> PathBuf {
    data_dir().join("tester.json")
}

fn update_status_path() -> PathBuf {
    data_dir().join("update-status.json")
}

fn valid_manifest_url(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("https://") else {
        return false;
    };
    if rest.contains('@') || rest.contains('#') || rest.contains('?') {
        return false;
    }
    let Some((host, path)) = rest.split_once('/') else {
        return false;
    };
    !host.is_empty() && path == "v1/manifest"
}

fn gateway_origin(manifest_url: &str) -> Result<String, String> {
    if !valid_manifest_url(manifest_url) {
        return Err("install configuration has an invalid authenticated gateway URL".into());
    }
    let rest = manifest_url
        .strip_prefix("https://")
        .ok_or_else(|| "gateway must use HTTPS".to_string())?;
    let (host, _) = rest
        .split_once('/')
        .ok_or_else(|| "gateway URL has no path".to_string())?;
    Ok(format!("https://{host}"))
}

fn load_config() -> Result<InstallConfig, String> {
    let value = fs::read_to_string(config_path())
        .map_err(|e| format!("read {}: {e}", config_path().display()))?;
    let config: InstallConfig =
        serde_json::from_str(&value).map_err(|e| format!("invalid install configuration: {e}"))?;
    if config.schema_version != 1 || !valid_manifest_url(&config.manifest_url) {
        return Err("install configuration has an unsupported schema or gateway".into());
    }
    Ok(config)
}

fn architecture() -> &'static str {
    "windows_x86_64"
}

fn join_gateway_path(manifest_url: &str, relative: &str) -> Result<String, String> {
    if !relative.starts_with("/v1/download/")
        || relative.contains("..")
        || relative.contains("://")
        || relative.contains('\\')
        || relative.contains('?')
        || relative.contains('#')
    {
        return Err("update path is outside the authenticated FarRelay gateway".into());
    }
    Ok(format!("{}{}", gateway_origin(manifest_url)?, relative))
}

fn curl_download(url: &str, destination: &Path, bearer: Option<&str>) -> Result<(), String> {
    if !url.starts_with("https://") {
        return Err("refusing non-HTTPS download".into());
    }
    let mut command = Command::new("curl.exe");
    command.args([
        "--fail",
        "--location",
        "--proto",
        "=https",
        "--tlsv1.2",
        "--silent",
        "--show-error",
        "--config",
        "-",
        "--output",
    ]);
    command.arg(destination).arg(url).stdin(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| format!("starting built-in HTTPS downloader: {e}"))?;
    if let Some(token) = bearer {
        let stdin = child
            .stdin
            .as_mut()
            .ok_or_else(|| "unable to secure updater authorization input".to_string())?;
        writeln!(stdin, "header = \"Authorization: Bearer {token}\"")
            .map_err(|e| format!("writing authorization header: {e}"))?;
    }
    drop(child.stdin.take());
    let status = child
        .wait()
        .map_err(|e| format!("waiting for built-in HTTPS downloader: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("authenticated HTTPS download failed; tester access may be revoked".into())
    }
}

fn curl_post_json(url: &str, body: &[u8]) -> Result<Vec<u8>, String> {
    if !url.starts_with("https://") {
        return Err("refusing non-HTTPS activation request".into());
    }
    let mut child = Command::new("curl.exe")
        .args([
            "--fail",
            "--location",
            "--proto",
            "=https",
            "--tlsv1.2",
            "--silent",
            "--show-error",
            "--request",
            "POST",
            "--header",
            "Content-Type: application/json",
            "--data-binary",
            "@-",
        ])
        .arg(url)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("starting activation request: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or_else(|| "activation request has no input stream".to_string())?
        .write_all(body)
        .map_err(|e| format!("sending activation request: {e}"))?;
    drop(child.stdin.take());
    let output = child
        .wait_with_output()
        .map_err(|e| format!("waiting for activation request: {e}"))?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err("tester activation was rejected or unavailable".into())
    }
}

fn powershell_transform_command(script: &str) -> String {
    format!(
        "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Security;{script}"
    )
}

fn powershell_transform(script: &str, input: &str) -> Result<String, String> {
    let command = powershell_transform_command(script);
    let mut child = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
        ])
        .arg(&command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("starting Windows credential protection: {e}"))?;
    child
        .stdin
        .as_mut()
        .ok_or_else(|| "credential protection has no input stream".to_string())?
        .write_all(input.as_bytes())
        .map_err(|e| format!("writing credential protection input: {e}"))?;
    drop(child.stdin.take());
    let output = child
        .wait_with_output()
        .map_err(|e| format!("waiting for Windows credential protection: {e}"))?;
    if !output.status.success() {
        return Err("Windows credential protection failed".into());
    }
    String::from_utf8(output.stdout)
        .map(|s| s.trim().to_owned())
        .map_err(|e| format!("credential protection returned invalid UTF-8: {e}"))
}

fn protect_device_token(token: &str) -> Result<(), String> {
    fs::create_dir_all(data_dir()).map_err(|e| format!("creating FarRelay data directory: {e}"))?;
    let protected = powershell_transform(
        "$p=[Console]::In.ReadToEnd();$b=[Text.Encoding]::UTF8.GetBytes($p);$e=[Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine);[Convert]::ToBase64String($e)",
        token,
    )?;
    fs::write(credential_path(), protected.as_bytes())
        .map_err(|e| format!("writing protected device credential: {e}"))?;
    let status = Command::new("icacls.exe")
        .arg(credential_path())
        .args([
            "/inheritance:r",
            "/grant:r",
            "*S-1-5-18:F",
            "*S-1-5-32-544:F",
        ])
        .status()
        .map_err(|e| format!("securing device credential ACL: {e}"))?;
    if !status.success() {
        return Err("unable to restrict device credential permissions".into());
    }
    Ok(())
}

fn load_device_token() -> Result<String, String> {
    let protected = fs::read_to_string(credential_path()).map_err(|_| {
        "FarRelay is not activated on this device. Run farrelay-updater activate as administrator."
            .to_string()
    })?;
    let token = powershell_transform(
        "$p=[Console]::In.ReadToEnd().Trim();$e=[Convert]::FromBase64String($p);$b=[Security.Cryptography.ProtectedData]::Unprotect($e,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine);[Text.Encoding]::UTF8.GetString($b)",
        &protected,
    )?;
    if token.trim().is_empty() {
        Err("stored FarRelay device credential is empty".into())
    } else {
        Ok(token)
    }
}

#[derive(Debug, Deserialize)]
struct ActivationResponse {
    device_id: String,
    device_token: String,
    channel: Channel,
    #[serde(default)]
    tester_name: Option<String>,
    #[serde(default)]
    activated_at: Option<String>,
    #[serde(default)]
    access_expires_at: Option<String>,
    #[serde(default)]
    testflight_url: String,
    #[serde(default)]
    feedback_url: String,
}

#[derive(Debug, Deserialize, Serialize)]
struct TesterProfile {
    tester_name: String,
    computer_name: String,
    channel: Channel,
    activated_at: String,
    access_expires_at: Option<String>,
    #[serde(default)]
    testflight_url: String,
    #[serde(default)]
    feedback_url: String,
    #[serde(default)]
    current_release: Option<String>,
}

fn save_tester_profile(profile: &TesterProfile) -> Result<(), String> {
    fs::create_dir_all(data_dir()).map_err(|e| format!("creating FarRelay data directory: {e}"))?;
    fs::write(
        tester_profile_path(),
        serde_json::to_vec_pretty(profile).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("writing tester profile: {e}"))
}

fn sync_tester_profile(config: &InstallConfig, token: &str, work: &Path) -> Result<(), String> {
    let profile_file = work.join("profile.json");
    let profile_url = format!("{}/v1/profile", gateway_origin(&config.manifest_url)?);
    curl_download(&profile_url, &profile_file, Some(token))?;
    let raw = fs::read_to_string(&profile_file).map_err(|e| e.to_string())?;
    let profile: TesterProfile =
        serde_json::from_str(&raw).map_err(|e| format!("invalid tester profile: {e}"))?;
    save_tester_profile(&profile)
}

fn write_update_status(
    state: &str,
    installed_version: &str,
    latest_version: Option<&str>,
    update_available: bool,
    message: &str,
) -> Result<(), String> {
    fs::create_dir_all(data_dir()).map_err(|e| e.to_string())?;
    let value = serde_json::json!({
        "state": state,
        "installed_version": installed_version,
        "latest_version": latest_version,
        "update_available": update_available,
        "message": message,
    });
    fs::write(
        update_status_path(),
        serde_json::to_vec_pretty(&value).map_err(|e| e.to_string())?,
    )
    .map_err(|e| format!("writing update status: {e}"))
}

fn activate(code: String) -> Result<(), String> {
    let config = load_config()?;
    let origin = gateway_origin(&config.manifest_url)?;
    let device_name = env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows device".into());
    let body = serde_json::json!({
        "invite_code": code.trim(),
        "device_name": device_name,
    });
    let response = curl_post_json(
        &format!("{origin}/v1/activate"),
        &serde_json::to_vec(&body).map_err(|e| e.to_string())?,
    )?;
    let activation: ActivationResponse =
        serde_json::from_slice(&response).map_err(|e| format!("invalid activation response: {e}"))?;
    if activation.channel != config.channel {
        return Err("tester code is for a different FarRelay release channel".into());
    }
    if activation.device_token.len() < 32 || activation.device_id.trim().is_empty() {
        return Err("activation response did not contain a valid device credential".into());
    }
    protect_device_token(&activation.device_token)?;
    let profile = TesterProfile {
        tester_name: activation.tester_name.unwrap_or_else(|| "Tester".into()),
        computer_name: device_name,
        channel: activation.channel,
        activated_at: activation.activated_at.unwrap_or_else(|| "unknown".into()),
        access_expires_at: activation.access_expires_at,
        testflight_url: activation.testflight_url,
        feedback_url: activation.feedback_url,
        current_release: Some(config.installed_version.clone()),
    };
    save_tester_profile(&profile)?;
    println!(
        "FarRelay tester access activated for device {} on the {} channel.",
        activation.device_id, activation.channel
    );
    Ok(())
}

fn read_activation_code() -> Result<String, String> {
    if let Some(code) = env::args().nth(2) {
        if !code.trim().is_empty() {
            return Ok(code);
        }
    }
    print!("Enter FarRelay tester activation code: ");
    io::stdout().flush().map_err(|e| e.to_string())?;
    let mut code = String::new();
    io::stdin()
        .read_line(&mut code)
        .map_err(|e| format!("reading activation code: {e}"))?;
    let code = code.trim().to_owned();
    if code.is_empty() {
        Err("activation code is required".into())
    } else {
        Ok(code)
    }
}

fn provision_shell_links(install_dir: &Path) -> Result<(), String> {
    let script = install_dir.join("scripts").join("Install-FarRelayShellLinks.ps1");
    if !script.is_file() {
        return Err("FarRelay shell-link provisioning script is missing".into());
    }
    let status = Command::new("powershell.exe")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(&script)
        .arg("-InstallDirectory")
        .arg(install_dir)
        .status()
        .map_err(|e| format!("starting FarRelay shell-link provisioning: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err("FarRelay shell-link provisioning failed".into())
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
    let token = load_device_token()?;
    let work = data_dir().join("updates");
    fs::create_dir_all(&work).map_err(|e| e.to_string())?;
    if let Err(error) = sync_tester_profile(&config, &token, &work) {
        eprintln!("farrelay-updater: warning: could not refresh beta profile: {error}");
    }
    write_update_status(
        "checking",
        &config.installed_version,
        None,
        false,
        "Checking the private FarRelay release channel.",
    )?;
    let manifest_file = work.join("manifest.json");
    curl_download(&config.manifest_url, &manifest_file, Some(&token))?;
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
        write_update_status(
            "current",
            &config.installed_version,
            Some(&config.installed_version),
            false,
            "FarRelay is current.",
        )?;
        return Ok(());
    };
    println!(
        "FarRelay update available: {} -> {}",
        config.installed_version, plan.version
    );
    if !install {
        write_update_status(
            "available",
            &config.installed_version,
            Some(&plan.version),
            true,
            "A FarRelay update is available.",
        )?;
        return Ok(());
    }
    if binaries_busy() {
        return Err("FarRelay is busy; update deferred without stopping active control".into());
    }
    let archive = work.join("download.zip");
    let archive_url = join_gateway_path(&config.manifest_url, &plan.asset.archive_url)?;
    curl_download(&archive_url, &archive, Some(&token))?;
    verify_file(&archive, &plan.asset.sha256, plan.asset.size)?;
    let staging = work.join("staging");
    unzip_update(&archive, &staging)?;
    apply_staged_release(&config.install_dir, &staging, &work.join("rollback"))?;
    if let Err(error) = provision_shell_links(&config.install_dir) {
        eprintln!("farrelay-updater: warning: {error}");
    }
    config.installed_version = plan.version;
    fs::write(
        config_path(),
        serde_json::to_vec_pretty(&config).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    write_update_status(
        "installed",
        &config.installed_version,
        Some(&config.installed_version),
        false,
        "FarRelay update installed successfully.",
    )?;
    if let Ok(token) = load_device_token() {
        let _ = sync_tester_profile(&config, &token, &work);
    }
    println!("FarRelay update installed.");
    Ok(())
}

fn usage() {
    eprintln!(
        "Usage: farrelay-updater <status|activate [code]|check|update|rollback|--check-and-install|--version>"
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
                "FarRelay {} ({})\nInstall: {}\nGateway: {}\nCredential installed: {} (SYSTEM/Administrator access)",
                c.installed_version,
                c.channel,
                c.install_dir.display(),
                c.manifest_url,
                if credential_path().is_file() { "yes" } else { "no" }
            )
        }),
        "activate" => read_activation_code().and_then(activate),
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
        if matches!(command.as_str(), "check" | "update" | "--check-and-install") {
            if let Ok(config) = load_config() {
                let _ = write_update_status(
                    "error",
                    &config.installed_version,
                    None,
                    false,
                    &error,
                );
            }
        }
        eprintln!("farrelay-updater: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpapi_transform_loads_system_security_in_clean_powershell() {
        let command = powershell_transform_command("Write-Output ok");
        assert!(command.starts_with(
            "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Security;"
        ));
        assert!(command.ends_with("Write-Output ok"));
    }

    #[test]
    fn accepts_only_root_https_manifest_endpoint() {
        assert!(valid_manifest_url("https://example.workers.dev/v1/manifest"));
        assert!(!valid_manifest_url("http://example.workers.dev/v1/manifest"));
        assert!(!valid_manifest_url("https://user@example.workers.dev/v1/manifest"));
        assert!(!valid_manifest_url("https://example.workers.dev/v1/other"));
    }

    #[test]
    fn joins_only_authenticated_download_paths() {
        let manifest = "https://example.workers.dev/v1/manifest";
        assert_eq!(
            join_gateway_path(manifest, "/v1/download/0.2.0-beta.3/windows_x86_64").unwrap(),
            "https://example.workers.dev/v1/download/0.2.0-beta.3/windows_x86_64"
        );
        assert!(join_gateway_path(manifest, "https://evil.example/x").is_err());
        assert!(join_gateway_path(manifest, "/v1/download/../secret").is_err());
    }
}
