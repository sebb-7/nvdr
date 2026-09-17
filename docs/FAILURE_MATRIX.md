# Failure matrix

Status: **Automated** means a deterministic unit/integration seam exists;
**Physical** means the listed device/network exercise is still required.

| Scenario | Expected state transition | Expected UI | Cleanup | Reconnect | Automated test | Physical |
| --- | --- | --- | --- | --- | --- | --- |
| Target powered off / DNS unreachable / Wi-Fi absent | Connecting → Failed | Connect; truthful unreachable error | no live channel or held keys | user Retry | connection-action regression | required |
| Connection refused / SSH unavailable | Connecting → Failed | Connect; refused/unavailable error | close attempt | user Retry | SSH failure seam | required |
| SSH authentication failure / host-key mismatch | Authenticating → Failed | Connect; safe error | no retry loop | explicit user correction | SSH classifier tests | required |
| SSH transport drop / network change / lid close | Connected → Reconnecting or Disconnected | Reconnecting/Disconnected, never Connected | release input, invalidate generation | policy controlled | supervisor tests | required |
| Sleep / hibernate / shutdown / reboot / resume | Connected → Disconnected or Failed | Connection lost | close old channel | user retry or policy | PTY EOF/failure tests | required |
| Shell exit / remote EOF / shutdown in terminal | Terminal Connected → Ended | Ended; transcript remains | PTY/session released | replacement terminal | terminal EOF tests | required |
| PTY reset/error / terminal process crash | Terminal Connected → Failed | Failed; transcript remains | PTY/session released | replacement terminal | terminal failure tests | required |
| User closes one of multiple terminals | one terminal → Closed | only that terminal closes | only its SSH/PTy closes | n/a | manager tests | required |
| NVDA relay unreachable / wrong channel | Connecting → Failed | safe failure | input released | retry by policy | bridge/supervisor seam | required |
| Master alone / slave joins / slave leaves | relay connected ↔ waiting ↔ ready | Waiting or NVDA connected | disable forwarding unless ready | existing channel | IPC mapping tests | required |
| Relay drops / remote process exits / background | Ready → Reconnecting/Disconnected | truthful status | release all keys | policy controlled | lifecycle tests | required |
| A-Z, digits, punctuation, arrows, Tab, Escape, Enter, Backspace/Delete | logical down/up pair | no false support claim | release on loss | n/a | mapping tests | sampled |
| F1-F12, Shift/Control/Alt+F1, F13-F24 where exposed | exact Windows VK/chord | no local interception while forwarding | balanced release | n/a | iOS mapping; Mac HID mapping | required |
| repeat / held modifier during loss / emergency stop | no stuck remote key | forwarding off / connection lost | release_all | new channel clean | input state tests | required |
| VoiceOver on or off | supported keys use priority/raw fallback | same truthful state | no duplicate logical key | n/a | priority policy tests | required |
| App background/foreground/termination/phone lock | forwarding suspended | no stale connected speech | release keys; generation gate | policy controlled | lifecycle tests | required |
| Profile edit/delete during reconnect | stale profile cannot mutate active replacement | current state remains scoped | preserve retained terminal snapshot | explicit new action | manager/generation tests | required |
| Mac host permission/provider/process loss | Ready → degraded | capability-specific reason | release injected keys | explicit re-establish | host tests | required |

The matrix intentionally records physical work separately: CI does not prove a
real Windows target shutdown, a hardware function row, or system screen-reader
interception.

## iOS reliability additions

| Scenario | Expected state transition | Expected UI | Cleanup | Reconnect | Automated test | Physical |
| --- | --- | --- | --- | --- | --- | --- |
| App inactive/background, device lock | forwarding → off; transport truth unchanged until an event | no false Ready announcement | `release_all`, clear held keys | supervisor decides only after a real failure | scene policy/input chaos | required |
| Foreground/unlock | no synthetic reconnect | current truthful status | no replacement generation | existing supervisor only | scene policy regression | required |
| Stale connect callback after cancel/new connect | ignored | current session unchanged | late connection closes | current generation only | supervisor stale-generation tests | simulated |
| Corrupt profile JSON | startup remains usable | recovery message | preserve original bytes | n/a | profile corruption regression | n/a |
| Unknown/truncated IPC | inert/unknown or deterministic error | no false Ready | no action | n/a | bounded malformed IPC chaos | n/a |
| VoiceOver/Quick Nav, BSI, keyboard detach | local ownership remains recoverable | documented local/remote control state | release keys at ownership boundary | n/a | input-state tests | required |
