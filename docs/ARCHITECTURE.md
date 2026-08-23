
### Tree Diagram of the proposed architecture

```bash

orchestration-server/
├── compose.yaml              # all services, profiles for optional layers
├── .env                      # NON-SENSITIVE config only (ports, TZ, model names)
├── secrets/                  # SOPS+age encrypted, one secret per file, 0600
│   ├── hosted_provider_key
│   └── ...                   # signal-cli's linked-device session state is
│                              # a directory, not a single value, so it's a
│                              # bind-mounted volume (see services/signal-cli/),
│                              # not a SOPS secret here
├── services/
│   ├── hermes/               # config.yaml, context files (AGENTS.md / SOUL.md)
│   ├── signal-cli/           # containerized signal-cli daemon (Phase 2) — own volume for linked-device session state
│   ├── langgraph/            # Dockerfile, pipeline defs, MCP server
│   ├── worker-image/         # Dockerfile for the confined terminal backend
│   ├── ollama/               # Modelfiles, model manifest
│   └── observability/        # prometheus.yml, loki config, promtail, dashboards, alert rules
├── runbooks/
│   ├── restore.md            # THE portability guarantee — tested, not assumed
│   ├── model-swap.md
│   └── incident-response.md
└── renovate.json

```