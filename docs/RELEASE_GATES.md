# Release gates and rollback policy

CI success is necessary evidence, not physical validation.

| Maturity | Required evidence |
| --- | --- |
| Developer build | Builds, deterministic unit/reliability tests, and `git diff --check` pass. |
| Internal beta | Affected iOS/macOS/host CI is green; protocol malformed-input and persistence tests pass; known issues reviewed. |
| External beta | Internal-beta evidence plus physical iPhone/iPad accessibility and hardware-keyboard smoke checklist completed for the build. |
| Release candidate | External-beta evidence plus target shutdown/network-loss tests, rollback review, and no unreviewed data-loss or stuck-input issue. |

## Rollback

Record the last physically validated build SHA before inviting testers. Profiles are
backward-compatible only when a newer profile adds optional Codable fields; a
rollback is unsafe when it depends on newly required fields or credential
migration behavior. Never overwrite malformed profile bytes during startup;
preserve them for recovery before installing an older build.
