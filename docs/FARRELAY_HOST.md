# `farrelay-host`

`farrelay-host` is an independent target-side executable for Windows, macOS, and Linux. It exposes a platform-neutral, versioned structured capability protocol over newline-delimited JSON (NDJSON): requests arrive on stdin and responses leave on stdout. Operational diagnostics belong on stderr. The intended future transport is an authenticated SSH exec channel; the host does not open a separate network listener.

The v1 host supports only `host.info`, `process.list`, and `process.info`. It has no arbitrary shell execution, command runner, daemon installation, or service lifecycle API. It remains separate from the existing NVDA Remote relay/client responsibilities.

```text
FarRelay Apple client
   │
   ├── existing NVDA/remote functionality
   │
   └── SSH
         │
         ├── interactive PTY path
         │
         └── future structured host path
                    │
                    ▼
                farrelay-host
                    │
                    ├── host.info
                    ├── process.list
                    └── process.info
```

Run it through SSH with `ssh target farrelay-host`. The existing relay bridge continues to use `ssh target farrelay --ipc`; these are separate paths and the structured host protocol has not replaced the relay protocol.
