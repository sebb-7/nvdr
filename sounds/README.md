# FarRelay sound cues

Place short PCM WAV UI cues here. `ios/project.yml` bundles this directory, so
adding or replacing a WAV and regenerating the project is sufficient.

App filenames: `connected.wav`, `disconnected.wav`, `keyboard-remote.wav`,
`keyboard-local.wav`, `terminal-open.wav`, `push_clipboard.wav`,
`receive_clipboard.wav`, `nvda-started.wav`, `nvda-stopped.wav`, `action.wav`,
`success.wav`, `warning.wav`, `error.wav`, and `copied.wav`.

Remote NVDA wave events match a safe basename, case-insensitively. For example,
`C:\Program Files\NVDA\waves\browseMode.wav` plays local `browseMode.wav`.
Missing WAVs are silent and safe; audio remains supplementary to status and
accessibility feedback.
