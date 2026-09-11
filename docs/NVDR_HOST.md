# `nvdr-host`

`nvdr-host` is an independent target-side executable for Windows, macOS, and Linux. It exposes a platform-neutral, versioned structured capability protocol over newline-delimited JSON (NDJSON): requests arrive on stdin and responses leave on stdout. Operational diagnostics belong on stderr. The intended future transport is an authenticated SSH exec channel; the host does not open a separate network listener.

The v1 host supports only `host.info`, `process.list`, and `process.info`. It has no arbitrary shell execution, command runner, daemon installation, or service lifecycle API. It remains separate from the existing NVDR relay/client responsibilities.

```text
Apple NVDR
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
                nvdr-host
                    │
                    ├── host.info
                    ├── process.list
                    └── process.info
```
