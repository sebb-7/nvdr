# FarRelay scripting

`farrelay` has a one-shot, non-interactive mode for scripts and AI workflows. It sends the same deterministic NVDA Remote input operations as the terminal client; it does not expose arbitrary shell execution.

```sh
farrelay -c 123456789 -k 'nvda+t; alt+f4; win+d'
farrelay -c 123456789 -s script.txt
farrelay -c 123456789 -s script.txt > title.txt 2> farrelay.log
```

The command grammar and relay wire protocol are unchanged from the upstream NVDA Remote-compatible client.
