# FarRelay release-integration audit — 2026-09-22

## Canonical baseline and method

- Remote baseline: `origin/main` = `56fedfb7ecaaca66066b73d47ad20859553fc07f`
  (`fix: isolate Mac socket endpoint cleanup`).  It matched the expected SHA
  after `git fetch --all --prune`.
- Integration worktree: `C:\Users\SEBASTIAN\Documents\NVDR\nvdr-release-integration`,
  branch `integration/farrelay-release-rc-2026-09-22`, initially clean at that
  exact SHA.
- Audit method: `git cherry -v origin/main <branch>`,
  `git log --left-right --cherry-pick`, merge-base inspection, and direct diff
  inspection.  “Effective” means a patch absent from `origin/main`, not merely
  an unmerged commit.

`origin/main` already contains the earlier rename, SSH, terminal, host-shell,
accessibility, function-key, and Mac-foundation histories.  They must not be
reapplied merely because their branch tips remain published.

## Branch inventory and classification

| Branch | Head | Relationship / effective patches | CI evidence available at audit | Classification | Decision / replacement |
| --- | --- | --- | --- | --- | --- |
| `chore/farrelay-rename` | `968cbc8d2246` | 107 main-only / 0 effective branch patches | Historical work only | ALREADY-IN-MAIN | Rename is in main. |
| `chore/farrelay-testflight` | `2a4d0c700663` | 98 / 0 | Historical work only | ALREADY-IN-MAIN | Current TestFlight workflow is already in main. |
| `codex/controller-testflight-followup` | `069fc5f87774` | 15 effective patches | Superseded by later green controller CI | SUPERSEDED | Entire patch set is carried by the current controller stack. |
| `codex/product-reliability-phase3-foundation` | `ffdd3af86a85` | 34 / 1 (`ffdd3af`) | Its focused tests accompany the patch; revalidated in this RC | INCLUDE-UNIQUE | Truthful status/event foundation; apply before UI/controller work. |
| `docs/macos-voiceover-remote-roadmap` | `9eb7916dc725` | 86 / 0 effective content | Documentation-only | HOLD-MACOS | Explicit Mac hold boundary; no cherry-pick. |
| `feat/accessibility-hardening` | `0dcf1e911322` | 70 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Effective patches are in main. |
| `feat/accessibility-polish` | `08ea1f9f3d55` | 74 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Effective patches are in main. |
| `feat/accessible-terminal-conversation` | `19f31aa70494` | 92 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Effective patches are in main. |
| `feat/controller-profiles-remote-control` | `98054baebdbb` | 0 / 134 | iOS CI [35774988921](https://github.com/sebb-7/nvdr/actions/runs/35774988921) passed | INCLUDE-UNIQUE | Cumulative controller, BSI, command, recovery, updater, and distribution slice. Includes latest controller-hold correction. |
| `feat/farrelay-host-client` | `2ab4e47e99aa` | 106 / 0 | Historical CI | ALREADY-IN-MAIN | Host client is in main. |
| `feat/host-profiles-app-shell` | `a8756f909d3b` | 86 / 0 | Historical CI | ALREADY-IN-MAIN | App shell/profile baseline is in main. |
| `feat/ios-controller-adapter` | `649e6e184cb0` | 0 / 8 | Revalidated by controller-head CI | SUPERSEDED | Carried and hardened by `feat/controller-profiles-remote-control`. |
| `feat/ios-controller-layers-and-text-mode` | `8a5aa16156bf` | 0 / 21 | Revalidated by controller-head CI | SUPERSEDED | Merged into the current controller stack; its merge is preserved semantically. |
| `feat/macos-full-remote-foundation` | `713554eaa5a7` | 24 / 0 | Mac foundation already landed | HOLD-MACOS | Keep main’s landed foundation; do not reintegrate product work. |
| `feat/macos-remote-control-ui` | `c3df1f4e5d18` | 79 / 3 | No release evidence for this unlanded UI | HOLD-MACOS | Explicitly excluded unfinished Mac remote-control UI. |
| `feat/macos-voiceover-host` | `c5019ac27530` | 79 / 0 | Mac foundation already landed | HOLD-MACOS | Explicitly excluded unfinished Mac VoiceOver product work. |
| `feat/nvdr-host-v1` | `b17ac1545545` | 108 / 0 | Historical CI | ALREADY-IN-MAIN | Superseded FarRelay host implementation is in main. |
| `feat/remote-control-profiles` | `6039476aa33e` | 0 / 72; one non-equivalent commit implementation | Superseded during semantic conflict review | SUPERSEDED | Its status model conflicts with, and is superseded by, the current controller stack’s `ControllerDeviceStatus`, refresh lifecycle, presentation, and tests. |
| `feat/remote-intent-capability-router` | `747246265552` | 0 / 2 | Revalidated by controller-head CI | SUPERSEDED | Router and Mac-intent guard are included in the current controller stack. |
| `feat/remote-intent-v2-recovery` | `8e0f6f1cc4ff` | 0 / 129; 68 patches differ from current controller tip | Windows Distribution Release [35683138879](https://github.com/sebb-7/nvdr/actions/runs/35683138879) passed | INCLUDE-UNIQUE | Apply only the 68 patch-equivalent differences: hardened updater, travel/control-center, tester gateway/onboarding, and release reliability. |
| `feat/remsound-receiver-phase1` | `f223dfa0d5d8` | 0 / 3 (`6860dc5`, `00db33c`, `f223dfa`) | iOS CI [35776542140](https://github.com/sebb-7/nvdr/actions/runs/35776542140) passed; 284 XCTest tests | INCLUDE-UNIQUE | Include as final RC slice. Main promotion remains conditional on physical encrypted PCM validation. |
| `feat/ssh-foundation` | `bbea7e77dfaf` | 117 / 0 | Historical CI | ALREADY-IN-MAIN | SSH foundation is in main. |
| `feat/terminal-session-manager` | `7814e98565a3` | 84 / 0 | Historical CI | ALREADY-IN-MAIN | Terminal manager is in main. |
| `fix/accessible-conversation-input` | `a4bd597cc2b9` | 57 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Effective accessibility patch is in main. |
| `fix/accessible-conversation-input-hardening` | `7ffc2fc7270a` | 37 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Effective hardening patch is in main. |
| `fix/build16-missing-status-and-fkeys` | `e5cdf6c1d4b3` | 22 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Later controller work preserves the result. |
| `fix/build18-function-key-capture` | `27eb906fd58e` | 16 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Later controller work preserves the result. |
| `fix/physical-accessibility-stabilization` | `bc76b33cc099` | 61 / 0 | Historical iOS CI | ALREADY-IN-MAIN | Effective patch is in main. |
| `fix/product-reliability-phase1` | `e333fd41eca6` | 31 / 0 | Historical CI | ALREADY-IN-MAIN | Phase 1 is in main; Phase 3’s one unique patch is separately selected. |
| `integration/macos-full-remote-foundation` | `56fedfb7ecaa` | 0 / 0 | Current main | ALREADY-IN-MAIN | Exactly the canonical baseline. |
| `refactor/codebase-quality` | `b0e7b3191a1e` | 65 / 0 | Historical CI | ALREADY-IN-MAIN | No release patch remains missing. |
| `release/testflight-integration-rc` | `0945caae7d65` | 64 / 0 | Historical release branch | OBSOLETE | Predates current main; not a release base or patch source. |
| `spike/terminal-engine-compat` | `c14fea1a4ca4` | 128 / 7 | Spike-only evidence | EXPERIMENTAL | Keep out of this release. |

## Patch-equivalence findings

1. All historical branches marked `ALREADY-IN-MAIN` returned no `+` patch from
   `git cherry -v origin/main`; their commit ancestry differs but their effective
   content is already present.
2. The controller stack contains the remote-intent router, controller adapter,
   layers/text mode, and TestFlight follow-ups.  Cherry-picking those older
   branches separately would duplicate patches.
3. `feat/remote-control-profiles` has one non-equivalent commit, `6039476`,
   but semantic review established that it is an older competing status-model
   implementation. The current controller stack already provides the capability
   with newer lifecycle and UI integration, so the older implementation is not
   reapplied.
4. `feat/remote-intent-v2-recovery` and the current controller tip diverged.
   Their `--cherry-pick` comparison leaves 73 controller-only and 68
   recovery/distribution-only patches.  Both sets are needed; the overlapping
   patches are not reapplied.
5. The three RemSound commits are independent, iOS-only receiver work and do
   not overlap the controller/recovery patches.

## Dependency graph and ordered integration plan

```text
Phase 3 truthful status foundation (ffdd3af)
        │
        ├── controller cumulative stack (router → adapter → layers/BSI →
        │   recovery → profiles/rotor → held modifiers/F-key hardening)
        │        │
        │
        └── remote-v2 unique updater/distribution/control-center differences
                 │
                 └── RemSound receiver (6860dc5, 00db33c, f223dfa)
```

The controller merge commit `6e69747` is applied with mainline parent 1 after
its first-parent prerequisite range, preserving the merged layers/text-mode
delta without importing a divergent branch wholesale.  Every subsequent
selection is an ordered cherry-pick of only the listed effective patch slice.

## Promotion boundary

This document records an RC plan, not a main promotion.  The exact integrated
SHA must pass all local and hosted checks, be the SHA built by TestFlight, and
then pass physical controller/recovery/accessibility validation.  RemSound also
requires a Windows G14 → iPhone encrypted-PCM interoperability pass; if it
fails, only the three-commit RemSound slice is removed and the remaining RC is
revalidated.

## Integration record

### Applied slices

1. `ffdd3af` Phase 3 truthful status/event foundation.
2. Current controller stack through `98054ba`, preserving its layers/text,
   recovery, profiles, quick navigation, BSI/quick command, F-key, and
   held-modifier corrections.
3. The 68 `--cherry-pick`-unique differences from
   `feat/remote-intent-v2-recovery` (updater, travel/control center, tester
   distribution, and release hardening).
4. RemSound Phase 1: `6860dc5`, `00db33c`, and `f223dfa`.

### Significant conflict decisions

- Phase 3’s app composition was combined with the current input diagnostics and
  Mac session environment; the event store is shared with `BridgeClient`.
- The host capability implementation advertises both macOS optional features
  and Windows fixed recovery operations.  The documentation distinguishes
  native Mac lease ownership from a host lease API.
- Event emission and sound-cue lifecycle behavior were retained together; an
  NVDA loss still creates a safe critical event while lifecycle cues retain
  their restart distinction.
- The current controller stack’s `ControllerDeviceStatus` was retained over
  the older `ControllerStatusSnapshot` implementation from
  `feat/remote-control-profiles`.  The latter was aborted before commit because
  it would have introduced a duplicate state model and refresh lifecycle.
- RemSound’s `AudioReceiverModel` was added to the existing controller, event,
  lifecycle, and modal composition; controller control remains independent of
  audio receiver startup or failure.
- `728567f` was skipped because it became an empty, duplicate fixture after
  the already-integrated controller profile changes.

### Local checkpoint evidence

- Root client: `cargo fmt --check`, `cargo clippy --all-targets --locked -- -D
  warnings`, and `cargo test --locked` (9 passed).
- `farrelay-host`: format, clippy, and tests (35 passed).
- `farrelay-updater`: rustfmt applied, format, clippy, and tests (9 passed).
- `git diff --check` passed at the checkpoint.  Apple-platform builds/tests and
  distribution-gateway CI still require hosted validation for this exact RC.
