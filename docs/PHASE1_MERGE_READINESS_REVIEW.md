# Phase 1 merge-readiness review

Reviewed: 2026-09-16

## Scope

In scope: the iOS client, shared Swift required for the iOS/macOS direction,
SSH session and PTY transport, terminal engine, FarRelay host client, and
Windows/macOS host paths. Android and the legacy NVDA Remote add-on are not
evaluated as shipping Phase 1 clients. The add-on was not changed by the final
candidate, so it is not a Phase 1 regression gate.

## Branch cleanup

- Merge target: `main`; merge base: `74c74bbb1cc1f4db36f86b1afc6b989e193fd18c`.
- Previously validated Phase 1 application revision: `8d644437f4b652ca14a178881eaabc0eb5fe6440`.
- `ffdd3af feat: add truthful status and event foundations` was confirmed to
  contain only Phase 3 status/event, capability, controller-gate, and schema
  foundation work. It was preserved unchanged on
  `codex/product-reliability-phase3-foundation` and removed from this Phase 1
  branch before validation.
- The useful portion of `80c1596` was reconstructed: this report and removal
  of the cumulative-diff trailing blank line in
  `ios/FarRelay/TerminalPresentationView.swift`. No Phase 3 source remains in
  the candidate.

## Validation matrix

| Area | Evidence | Result | Further validation |
| --- | --- | --- | --- |
| Root Rust | `cargo fmt --check`, `cargo check --locked`, `cargo test --locked`, `cargo clippy --locked --all-targets -- -D warnings` | PASS — 5 tests | none locally |
| FarRelay Host | Same locked Rust commands | PASS — 27 tests | Windows host smoke test still required |
| iOS / Swift | Exact-candidate iOS CI workflow | Pending | Required before merge; includes XcodeGen, package resolution, simulator build, SSH, terminal, and app tests |
| SSH / terminal path | Existing iOS unit suite plus static lifecycle review | Pending exact-head CI | Physical remote-host smoke test required before beta |
| macOS/shared direction | Source/project configuration review | PASS static review | Mac build and VoiceOver smoke test required |
| Accessibility | Existing policy/unit coverage reviewed | PASS automated scope | iPhone/iPad VoiceOver, keyboard, and BSI smoke tests required before beta |
| Android | Out of current project scope; not evaluated | n/a | n/a |
| Legacy NVDA add-on | Out of current shipping-client scope; not evaluated | n/a | n/a |
| Repository hygiene | `git diff --check` and working-tree inspection | PASS | none |

## CI and manual validation

The historical successful iOS CI run
[35138652377](https://github.com/sebb-7/nvdr/actions/runs/35138652377) and
TestFlight workflow [35130548149](https://github.com/sebb-7/nvdr/actions/runs/35130548149)
validate `8d64443`, not the final branch commit carrying this report and the
whitespace correction. An exact-candidate iOS CI run is required before merge.

Before external beta, complete and record:

- iPhone/iPad VoiceOver connection, error, focus, terminal-output, keyboard,
  and Braille Screen Input checks.
- Windows FarRelay host command-line startup, SSH authentication, diagnostics,
  and reconnect behavior.
- iOS → SSH → PTY → terminal-engine → remote-host end-to-end exercise,
  including disconnect/reconnect, UTF-8, ANSI, resize, scrollback, alternate
  screen, and OSC 133 behavior.
- macOS host build and manual VoiceOver/permission checks on a Mac.

## Remaining issues

### Merge blockers

- A successful iOS CI run for the exact final Phase 1 candidate is required.

### External-beta blockers

- The physical iOS, SSH/Windows-host, and Mac validation above has not yet
  been recorded.

### Post-Phase-1 follow-ups

- Continue Phase 3 from `codex/product-reliability-phase3-foundation`; it is
  intentionally excluded from this candidate.
