
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
<!-- Phase 3 egress rules applied to the real DOCKER-USER chain (not
     expressible in compose.yaml -- live host/Docker-Desktop-VM firewall
     state, must be reapplied after any Docker Desktop reset or host
     rebuild). Design deviates from the original plan's pure IP-allowlist
     (docs/superpowers/plans/2026-08-23-phase3-terminal-confinement.md
     Task 4): IP-based rules proved unreliable live (GitHub's DNS rotated
     across 3 different IPs within minutes of testing). Replaced with
     sniproxy (compose service, DNS-hijack + TLS SNI inspection) on a
     dedicated styx_net (172.31.0.0/24, sniproxy static at .10) --
     allowed domains (services/worker-image/sniproxy/domainlist.csv)
     resolve to sniproxy's own IP and get proxied by SNI; everything else
     resolves to its real IP and is blocked at the firewall layer.

     DOCKER-USER rules to reapply (via a privileged --net=host container,
     since neither dockerd nor iptables/nft live in the WSL2 distro
     itself -- dockerd runs inside Docker Desktop's own internal VM):

       iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
       iptables -I DOCKER-USER 2 -s 172.31.0.10 -j ACCEPT
       iptables -A DOCKER-USER -s 172.31.0.0/24 -d 172.31.0.10 -j ACCEPT
       iptables -A DOCKER-USER -s 172.31.0.0/24 -j REJECT --reject-with icmp-port-unreachable

     Rule 1 (stateful ESTABLISHED,RELATED accept) is required: without it,
     sniproxy's own reply traffic -- source 172.31.0.10, itself inside
     172.31.0.0/24 -- gets caught by the final REJECT on its way back,
     producing a silent, hard-to-diagnose timeout despite the forward
     SYN being accepted. Rule 2 is required for the same underlying
     reason but for sniproxy's own outbound connections to real upstream
     servers (fetching the actual site content after SNI inspection),
     whose source IP is also 172.31.0.10.

     CAUTION: DOCKER-USER is a host-global chain, not scoped per Docker
     network -- any rule here without an explicit -s/-d match affects ALL
     container traffic on the host. Do not append an unscoped rule; a
     prior attempt at this exact rule set without source-scoping broke
     signal-cli's connectivity to Signal's servers in production. Do not
     remove or reorder past Docker Desktop's own pre-existing rules
     (ports 3128/5555/53, then a REJECT scoped to its own internal
     interfaces -- not a general catch-all, verify via `-v` output before
     assuming otherwise). -->
