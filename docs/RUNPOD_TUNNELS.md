# RunPod tunnel compatibility

RunPod tunnel lifecycle and implementation are owned by
`runpod-ollama-fleet` (RPOF).

The historical LME command remains supported:

```bash
bin/lme runpod-tunnels ...
```

It is a compatibility entry point that invokes the external RPOF executable
through `bin/lme-rpof`; LME does not load RPOF Ruby or manage tunnel state
itself.

For direct provider operation and low-level helper documentation, use the
`runpod-ollama-fleet` repository.
