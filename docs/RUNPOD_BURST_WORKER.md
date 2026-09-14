# RunPod burst-worker compatibility

RunPod worker creation, setup, bootstrap, lifecycle, and provider state are
owned by `runpod-ollama-fleet` (RPOF).

Historical `bin/lme runpod-*` commands remain available as compatibility
entry points. They invoke the external RPOF executable through
`bin/lme-rpof`; LME does not load RPOF Ruby or retain provider helper
implementations.

Use the `runpod-ollama-fleet` repository for direct provider operation,
worker setup scripts, and provider-specific troubleshooting. LME continues to
own AdventureFinder experiment intent and consumes RPOF through the frozen
versioned JSON capability-check and dispatch boundary.
