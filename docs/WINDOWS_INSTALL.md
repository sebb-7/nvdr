# FarRelay on Windows

Download the `FarRelay-Setup-<version>.exe` asset for the desired channel and
run it once. The standard Inno Setup installer uses normal Windows controls,
supports `/VERYSILENT` for managed tester deployment, and installs to
`C:\Program Files\FarRelay`. No Rust installation, repository checkout, or
manual binary copying is needed.

It installs these independent components: `farrelay.exe` (the relay/IPC
client), `farrelay-host.exe` (the SSH host protocol), and
`farrelay-updater.exe`. The installer adds that directory to the system PATH,
so a new SSH session can use `farrelay --version`, `farrelay-host`, and
`farrelay-updater status` without a repository-local path. The add-on is
placed beside the installation in `addons`; NVDA users install the supplied
`FarRelayBridge-<version>.nvda-addon` through NVDA's supported Add-on Store or
Add-on Manager workflow. FarRelay never installs an NVDA add-on silently.

## Recovery and update tasks

During setup, the installer calls the canonical
`farrelay-host/scripts/Install-FarRelayNvdaRecoveryTask.ps1` script. If NVDA's
UIAccess executable is present, it reconciles the one fixed task, `FarRelay
Recover NVDA`. The task starts `nvda_uiAccess.exe` directly as the interactive
user at Limited run level. It does not kill NVDA, use `nvda.exe --quit`, store
a password, or create a UAC prompt when recovery is requested remotely. If
NVDA is absent, installation continues and reports that recovery is
unavailable.

Setup also creates the fixed daily `FarRelay Update Check` task. It runs only
`farrelay-updater.exe --check-and-install` as SYSTEM, because replacing files
under Program Files needs elevation. The task has no caller-controlled
arguments, stores no credentials, and is not exposed through the FarRelay host
protocol. It defers instead of killing a busy FarRelay process.

The selected channel is persisted in `%ProgramData%\FarRelay\install.json`.
Beta installers use `beta`; stable installers use `stable`. The updater has
local diagnostic commands: `farrelay-updater status`, `farrelay-updater check`,
`farrelay-updater update`, and the administrator-only local recovery command
`farrelay-updater rollback`.

## Update security and rollback

The updater accepts schema version 1 manifests only. A manifest contains a
channel, version, publication time, and one architecture-specific asset with a
SHA-256 and byte size. It rejects unknown fields, channel/architecture
mismatches, downgrades, invalid hashes, malformed manifests, non-GitHub
FarRelay release URLs, and any command or script field. It downloads only over
HTTPS from the pinned FarRelay GitHub release path, verifies size and SHA-256,
then unpacks the three fixed executable names into ProgramData staging.

Only after all files validate does it replace the distribution as a release
unit. The previous executable set is retained in
`%ProgramData%\FarRelay\updates\rollback` until the next successful update;
`rollback` copies that set back. Failed staging and hash failures leave the
installed binaries alone. Current beta artifacts are unsigned unless a future
release configures Authenticode credentials, so Windows SmartScreen may warn;
the release workflow deliberately contains no certificates or secrets.

## Release maintainers

Run **Windows Distribution Release** manually with a version and channel. It
builds the two existing Rust binaries plus the dedicated updater on GitHub's
Windows runner, creates the NVDA add-on, installer, portable ZIP, updater ZIP,
channel manifest, and `SHA256SUMS.txt`. Publishing is opt-in; it updates the
channel release tag (`farrelay-beta` or `farrelay-stable`) so the static
manifest URL remains stable. The workflow is Windows x86_64 today, while the
manifest's asset map is intentionally extensible for macOS and Linux later.

The release version entered in the manual workflow is the Windows distribution
source of truth. The workflow passes it to the artifact names, installer, update
manifest, channel configuration, and the compile-time `FARRELAY_DIST_VERSION`
value, so all three installed `--version` commands identify the same release.
Developer builds retain the package version from Cargo.
