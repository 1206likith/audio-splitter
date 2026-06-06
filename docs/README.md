# Audio Splitter v2 — Documentation

Reference documentation for the ASP-2 audio fabric, produced in Phase 8
(Hardening + Beta).

| Doc | What it covers |
|-----|----------------|
| [protocol-spec.md](protocol-spec.md) | Normative ASP-2 wire spec: binary frame, FEC, codec ids, control plane, crypto envelope, versioning. |
| [plugin-development.md](plugin-development.md) | Plugin SDK v1: the three node contracts, registration, authoring rules, the `SampleTonePlugin` template. |
| [deployment.md](deployment.md) | Build targets, running a session, optional/external capability matrix, measured capacity, soak/beta gate. |
| [security-audit.md](security-audit.md) | Phase 8 threat model, findings + remediations, crypto review, residual risk register. |

See also `third_party/README.md` for vendoring native binaries (Opus, RNNoise,
Steam Audio, whisper) and the per-phase deferral tables, and `MEMORY.md` /
`memory/project_v2_phase*.md` for the build's phase-by-phase checkpoint history.
