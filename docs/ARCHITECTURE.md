
### Tree Diagram of the proposed architecture

```bash

orchestration-server/
├── compose.yaml              # all services, profiles for optional layers
├── .env                      # NON-SENSITIVE config only (ports, TZ, model names)
├── secrets/                  # SOPS+age encrypted, one secret per file, 0600
│   ├── signal_registration    # Signal is the messaging platform (decided 2026-08-18, was Telegram)
│   ├── hosted_provider_key
│   └── ...
├── services/
│   ├── hermes/               # config.yaml, context files (AGENTS.md / SOUL.md)
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