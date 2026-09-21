//! The small, deliberately constrained Windows distribution updater.
//!
//! Network metadata can select a release archive only. It cannot select a
//! command, an executable name, an installation directory, or a script.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

pub const SCHEMA_VERSION: u32 = 1;
pub const DISTRIBUTION_BINARIES: [&str; 3] =
    ["farrelay.exe", "farrelay-host.exe", "farrelay-updater.exe"];
pub const RELEASE_URL_PREFIX: &str = "https://github.com/sebb-7/farrelay-releases/releases/download/";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Channel {
    Stable,
    Beta,
}

impl std::fmt::Display for Channel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Stable => "stable",
            Self::Beta => "beta",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateAsset {
    pub archive_url: String,
    pub sha256: String,
    pub size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateManifest {
    pub schema_version: u32,
    pub channel: Channel,
    pub version: String,
    pub published_at: String,
    pub assets: std::collections::BTreeMap<String, UpdateAsset>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallConfig {
    pub schema_version: u32,
    pub channel: Channel,
    pub installed_version: String,
    pub install_dir: PathBuf,
    pub manifest_url: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpdatePlan {
    pub version: String,
    pub asset: UpdateAsset,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseVersion {
    numbers: Vec<u64>,
    prerelease: Option<String>,
}

impl ReleaseVersion {
    pub fn parse(value: &str) -> Result<Self, String> {
        let (core, prerelease) = value
            .split_once('-')
            .map_or((value, None), |(a, b)| (a, Some(b)));
        if core.is_empty()
            || prerelease.is_some_and(|v| {
                v.is_empty()
                    || !v
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
            })
        {
            return Err(format!("invalid release version {value:?}"));
        }
        let numbers = core
            .split('.')
            .map(|part| {
                part.parse::<u64>()
                    .map_err(|_| format!("invalid release version {value:?}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        if numbers.is_empty() {
            return Err(format!("invalid release version {value:?}"));
        }
        Ok(Self {
            numbers,
            prerelease: prerelease.map(str::to_owned),
        })
    }
}

impl Ord for ReleaseVersion {
    fn cmp(&self, other: &Self) -> Ordering {
        let width = self.numbers.len().max(other.numbers.len());
        for idx in 0..width {
            match self
                .numbers
                .get(idx)
                .unwrap_or(&0)
                .cmp(other.numbers.get(idx).unwrap_or(&0))
            {
                Ordering::Equal => {}
                result => return result,
            }
        }
        match (&self.prerelease, &other.prerelease) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(a), Some(b)) => a.cmp(b),
        }
    }
}
impl PartialOrd for ReleaseVersion {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

pub fn parse_manifest(input: &str) -> Result<UpdateManifest, String> {
    let manifest: UpdateManifest =
        serde_json::from_str(input).map_err(|e| format!("invalid update manifest: {e}"))?;
    if manifest.schema_version != SCHEMA_VERSION {
        return Err(format!(
            "unsupported update manifest schema {}",
            manifest.schema_version
        ));
    }
    ReleaseVersion::parse(&manifest.version)?;
    if manifest.published_at.trim().is_empty() {
        return Err("manifest has no published_at value".into());
    }
    Ok(manifest)
}

pub fn plan_update(
    input: &str,
    channel: Channel,
    architecture: &str,
    installed_version: &str,
) -> Result<Option<UpdatePlan>, String> {
    let manifest = parse_manifest(input)?;
    if manifest.channel != channel {
        return Err("manifest channel does not match installed channel".into());
    }
    let asset = manifest
        .assets
        .get(architecture)
        .ok_or_else(|| format!("manifest has no {architecture} asset"))?
        .clone();
    validate_asset(&asset)?;
    if ReleaseVersion::parse(&manifest.version)? <= ReleaseVersion::parse(installed_version)? {
        return Ok(None);
    }
    Ok(Some(UpdatePlan {
        version: manifest.version,
        asset,
    }))
}

pub fn validate_asset(asset: &UpdateAsset) -> Result<(), String> {
    if !asset.archive_url.starts_with(RELEASE_URL_PREFIX) {
        return Err(
            "update archive URL is outside the trusted FarRelay GitHub release path".into(),
        );
    }
    if asset.size == 0 {
        return Err("update asset has an invalid size".into());
    }
    if asset.sha256.len() != 64 || !asset.sha256.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("update asset has an invalid SHA-256".into());
    }
    Ok(())
}

pub fn verify_file(path: &Path, expected_hash: &str, expected_size: u64) -> Result<(), String> {
    let metadata = fs::metadata(path).map_err(|e| format!("reading downloaded update: {e}"))?;
    if metadata.len() != expected_size {
        return Err(format!(
            "downloaded update size mismatch (got {}, expected {expected_size})",
            metadata.len()
        ));
    }
    let mut file = fs::File::open(path).map_err(|e| format!("opening downloaded update: {e}"))?;
    let mut hash = Sha256::new();
    let mut buffer = [0_u8; 32 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|e| format!("hashing downloaded update: {e}"))?;
        if read == 0 {
            break;
        }
        hash.update(&buffer[..read]);
    }
    let got = format!("{:x}", hash.finalize());
    if !got.eq_ignore_ascii_case(expected_hash) {
        return Err("downloaded update SHA-256 mismatch".into());
    }
    Ok(())
}

/// Replace all distribution executables as one logical unit. Every staged file
/// is checked before the first installed file is moved; any later failure
/// restores copies from `rollback_dir`.
pub fn apply_staged_release(
    install_dir: &Path,
    staging_dir: &Path,
    rollback_dir: &Path,
) -> Result<(), String> {
    for name in DISTRIBUTION_BINARIES {
        let path = staging_dir.join(name);
        if !path.is_file() || fs::metadata(&path).map_err(|e| e.to_string())?.len() == 0 {
            return Err(format!("staging is incomplete: {name}"));
        }
    }
    fs::create_dir_all(install_dir).map_err(|e| format!("creating install directory: {e}"))?;
    let fresh_rollback = rollback_dir.with_extension("new");
    let _ = fs::remove_dir_all(&fresh_rollback);
    fs::create_dir_all(&fresh_rollback).map_err(|e| format!("creating rollback directory: {e}"))?;
    for name in DISTRIBUTION_BINARIES {
        let installed = install_dir.join(name);
        if installed.exists() {
            fs::copy(&installed, fresh_rollback.join(name))
                .map_err(|e| format!("backing up {name}: {e}"))?;
        }
    }
    let _ = fs::remove_dir_all(rollback_dir);
    fs::rename(&fresh_rollback, rollback_dir)
        .map_err(|e| format!("activating rollback copy: {e}"))?;
    let mut replaced = Vec::new();
    for name in DISTRIBUTION_BINARIES {
        let next = install_dir.join(format!(".{name}.next"));
        fs::copy(staging_dir.join(name), &next).map_err(|e| format!("staging {name}: {e}"))?;
        let installed = install_dir.join(name);
        let previous = install_dir.join(format!(".{name}.previous"));
        let _ = fs::remove_file(&previous);
        if installed.exists() {
            fs::rename(&installed, &previous).map_err(|e| format!("preparing {name}: {e}"))?;
        }
        if let Err(error) = fs::rename(&next, &installed) {
            if previous.exists() {
                let _ = fs::rename(&previous, &installed);
            }
            rollback_release(install_dir, rollback_dir).ok();
            return Err(format!("replacing {name}: {error}"));
        }
        let _ = fs::remove_file(previous);
        replaced.push(name);
    }
    let _ = replaced;
    Ok(())
}

pub fn rollback_release(install_dir: &Path, rollback_dir: &Path) -> Result<(), String> {
    for name in DISTRIBUTION_BINARIES {
        let old = rollback_dir.join(name);
        if old.is_file() {
            fs::copy(&old, install_dir.join(name)).map_err(|e| format!("restoring {name}: {e}"))?;
        }
    }
    Ok(())
}

pub fn unzip_update(archive: &Path, staging: &Path) -> Result<(), String> {
    let file = fs::File::open(archive).map_err(|e| format!("opening verified archive: {e}"))?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("invalid update archive: {e}"))?;
    let _ = fs::remove_dir_all(staging);
    fs::create_dir_all(staging).map_err(|e| e.to_string())?;
    for name in DISTRIBUTION_BINARIES {
        let mut item = zip
            .by_name(name)
            .map_err(|_| format!("update archive is missing {name}"))?;
        let mut output = fs::File::create(staging.join(name)).map_err(|e| e.to_string())?;
        io::copy(&mut item, &mut output).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};
    fn asset(hash: &str) -> UpdateAsset {
        UpdateAsset {
            archive_url: format!("{RELEASE_URL_PREFIX}v1/update.zip"),
            sha256: hash.into(),
            size: 1,
        }
    }
    fn manifest(version: &str, channel: &str) -> String {
        format!(
            r#"{{"schema_version":1,"channel":"{channel}","version":"{version}","published_at":"2026-09-20T00:00:00Z","assets":{{"windows_x86_64":{{"archive_url":"{RELEASE_URL_PREFIX}v1/update.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1}}}}}}"#
        )
    }
    fn temp(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "farrelay-updater-{label}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
    #[test]
    fn accepts_newer_release() {
        assert_eq!(
            plan_update(
                &manifest("0.2.0-beta.1", "beta"),
                Channel::Beta,
                "windows_x86_64",
                "0.1.0"
            )
            .unwrap()
            .unwrap()
            .version,
            "0.2.0-beta.1"
        );
    }
    #[test]
    fn refuses_same_and_downgrade() {
        assert!(plan_update(
            &manifest("0.1.0", "stable"),
            Channel::Stable,
            "windows_x86_64",
            "0.1.0"
        )
        .unwrap()
        .is_none());
        assert!(plan_update(
            &manifest("0.0.9", "stable"),
            Channel::Stable,
            "windows_x86_64",
            "0.1.0"
        )
        .unwrap()
        .is_none());
    }
    #[test]
    fn rejects_schema_channel_and_architecture() {
        assert!(plan_update(
            &manifest("0.2.0", "beta"),
            Channel::Stable,
            "windows_x86_64",
            "0.1.0"
        )
        .is_err());
        assert!(plan_update(
            &manifest("0.2.0", "stable"),
            Channel::Stable,
            "arm64",
            "0.1.0"
        )
        .is_err());
        assert!(parse_manifest(r#"{"schema_version":2,"channel":"stable","version":"1.0.0","published_at":"x","assets":{}}"#).is_err());
    }
    #[test]
    fn rejects_unknown_fields_bad_hash_and_remote_commands() {
        assert!(parse_manifest(r#"{"schema_version":1,"channel":"stable","version":"1.0.0","published_at":"x","assets":{},"command":"bad"}"#).is_err());
        assert!(validate_asset(&asset("bad")).is_err());
        let mut unsafe_asset = asset(&"a".repeat(64));
        unsafe_asset.archive_url = "https://evil.example/update.zip".into();
        assert!(validate_asset(&unsafe_asset).is_err());
    }
    #[test]
    fn detects_hash_and_partial_staging() {
        let dir = temp("verify");
        let file = dir.join("file");
        fs::write(&file, b"x").unwrap();
        assert!(verify_file(&file, &"0".repeat(64), 1).is_err());
        let staging = dir.join("staging");
        fs::create_dir_all(&staging).unwrap();
        fs::write(staging.join("farrelay.exe"), b"x").unwrap();
        assert!(
            apply_staged_release(&dir.join("install"), &staging, &dir.join("rollback")).is_err()
        );
        let _ = fs::remove_dir_all(dir);
    }
    #[test]
    fn replaces_and_rolls_back_as_a_unit() {
        let dir = temp("replace");
        let install = dir.join("install");
        let stage = dir.join("stage");
        fs::create_dir_all(&install).unwrap();
        fs::create_dir_all(&stage).unwrap();
        for name in DISTRIBUTION_BINARIES {
            fs::write(install.join(name), format!("old-{name}")).unwrap();
            fs::write(stage.join(name), format!("new-{name}")).unwrap();
        }
        apply_staged_release(&install, &stage, &dir.join("rollback")).unwrap();
        assert_eq!(
            fs::read_to_string(install.join("farrelay.exe")).unwrap(),
            "new-farrelay.exe"
        );
        rollback_release(&install, &dir.join("rollback")).unwrap();
        assert_eq!(
            fs::read_to_string(install.join("farrelay.exe")).unwrap(),
            "old-farrelay.exe"
        );
        let _ = fs::remove_dir_all(dir);
    }
}
