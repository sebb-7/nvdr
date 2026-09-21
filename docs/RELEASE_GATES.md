# Release gates and rollback policy

CI success is necessary evidence, not physical validation.

## Windows distribution gate

The manually dispatched **Windows Distribution Release** workflow is the only
Windows publishing path. Before publishing a channel asset, its root, host, and
updater tests must pass, the updater manifest/hash/staging tests must pass, and
the generated installer must build on the GitHub Windows runner. Verify the
published `SHA256SUMS.txt`, install on a non-developer Windows tester machine,
confirm `farrelay --version`, `farrelay-host --version`, and
`farrelay-updater status` in a fresh SSH session, then verify that the fixed
recovery task remains Interactive/Limited when NVDA UIAccess is installed.

The release workflow has no signing secret. Until Authenticode credentials are
provisioned, beta artifacts may show SmartScreen warnings and must be treated as
internal/tester builds. A failed update must be tested by the local updater's
rollback path before a travel-critical release is promoted.

For a travel-critical Windows target, run
`windows/release/Test-FarRelayTravelReadiness.ps1` from an elevated PowerShell
after installing the candidate. Zero failures are required. The script verifies
unambiguous FarRelay binary resolution/version, automatic running `sshd`, an
SSH listener, the structured recovery status path, the fixed Interactive/Limited
NVDA recovery task, and AC sleep/hibernate policy. Lid-close policy may be a
warning unless `-RequireLidClosedReady` is supplied. This automated gate does
not replace a real remote test from the phone over the network path that will be
used during travel.

| Maturity | Required evidence |
| --- | --- |
| Developer build | Builds, deterministic unit/reliability tests, and `git diff --check` pass. |
| Internal beta | Affected iOS/macOS/host CI is green; protocol malformed-input and persistence tests pass; known issues reviewed. |
| External beta | Internal-beta evidence plus physical iPhone/iPad accessibility and hardware-keyboard smoke checklist completed for the build. |
| Release candidate | External-beta evidence plus target shutdown/network-loss tests, rollback review, zero travel-readiness failures for an unattended Windows target, and no unreviewed data-loss or stuck-input issue. |

## Rollback

Record the last physically validated build SHA before inviting testers. Profiles are
backward-compatible only when a newer profile adds optional Codable fields; a
rollback is unsafe when it depends on newly required fields or credential
migration behavior. Never overwrite malformed profile bytes during startup;
preserve them for recovery before installing an older build.
