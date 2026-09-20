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

| Maturity | Required evidence |
| --- | --- |
| Developer build | Builds, deterministic unit/reliability tests, and `git diff --check` pass. |
| Internal beta | Affected iOS/macOS/host CI is green; protocol malformed-input and persistence tests pass; known issues reviewed. |
| External beta | Internal-beta evidence plus status-truth, event/redaction, capability/compatibility, migration-fixture, and controller-generation tests green; physical iPhone/iPad accessibility and hardware-keyboard smoke checklist completed for the build. |
| Release candidate | External-beta evidence plus target shutdown/network-loss tests, rollback review, and no unreviewed data-loss or stuck-input issue. |

## Rollback

Record the last physically validated build SHA before inviting testers. Profiles are
backward-compatible only when a newer profile adds optional Codable fields; a
rollback is unsafe when it depends on newly required fields or credential
migration behavior. Never overwrite malformed profile bytes during startup;
preserve them for recovery before installing an older build.

## Phase 3 reliability evidence

Before an external beta, record the exact iOS CI run and, when a host protocol
changes, the affected host CI run. CI does not prove hardware accessibility,
multi-device lease behavior, actual host capability advertisement, or a real
install-over-old-build migration; those remain physical or simulated evidence
and must be reported separately.
