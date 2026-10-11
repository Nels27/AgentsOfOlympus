# AgentsOfOlympus
An AI Agent Orchestration Server Implementation


# Table of Contents
- [Purpose](#purpose)
- [Architecture](#architecture)
- [Roadmap](#roadmap)
- [Project Status](#project-status)
- [Contributing](#contributing)

# Purpose
An AI agent platform designed with a strong security posture. It can be designed to run on a homelab setup with more than one mini PC. One mini PC will hold the agents, while the other mini PC will serve as the observation node for the system's performance. 

# Architecture

The main orchestrator will be Hermes which is built by [Nous Research](https://github.com/NousResearch).

It will run as a containerized application.

The observation node lives on a separate device to allow a sandboxed monitoring method. It is not observable by the agent.

Communication with the agent orchestrator can be conducted through various interfaces such as Signal, Telegram, or Discord.

# Roadmap

The current roadmap is shown below. The in depth tasks are on this [document](/docs/Roadmap.md).

```mermaid
gantt
    title Agents of Olympus — Rebuild Roadmap (start Sat 2026-10-10)
    dateFormat YYYY-MM-DD
    axisFormat %b %d
    tickInterval 1week

    section Foundation
    ThinkCentre base · 2 sess / 5h                              :t1, 2026-10-10, 2026-10-12
    P0 Host foundation · 4 sess / 8h                            :crit, t2, 2026-10-12, 2026-10-16
    P1 Telemetry (Argus) · 8 sess / 17h                         :crit, t3, 2026-10-16, 2026-10-24
    P2 Network & inference · 5 sess / 11h                       :crit, t4, 2026-10-24, 2026-10-29
    section Containment
    P3 Hermes core + Telegram · 11 sess / 23h                   :crit, t5, 2026-10-29, 2026-11-11
    P4 Daedalus sandbox · 10 sess / 21h                         :crit, t6, 2026-11-11, 2026-11-22
    section Capabilities
    Enrichment benchmark (Sundays) · 5 sess / 12.5h             :t7, 2026-11-01, 2026-12-07
    P5 Hephaestus · 21 sess / 43.5h                             :crit, t8, 2026-11-23, 2026-11-26
    P5 Hephaestus (cont.)                                       :crit, t9, 2026-11-30, 2026-12-19
    P6 Automation · 3 sess / 7h                                 :crit, t10, 2026-12-19, 2026-12-21
    P6 Automation (cont.)                                       :crit, t11, 2027-01-04, 2027-01-05
    P8 Delegation · 5 sess / 10.5h                              :crit, t12, 2027-01-05, 2027-01-10
    P10 OTLP export · 3 sess / 6.5h                             :crit, t13, 2027-01-10, 2027-01-13
    section Optional
    P7 Web tools (optional) · 4 sess / 8.5h                     :t14, 2027-01-13, 2027-01-17
    P9 Dashboard + Signal (optional) · 9 sess / 19.5h           :t15, 2027-01-17, 2027-01-26
    section Off
    Thanksgiving                                                :done, off1, 2026-11-26, 2026-11-30
    Holiday break                                               :done, off2, 2026-12-21, 2027-01-04
    section Milestones
    Styx enforcing                                              :milestone, m_styx, 2026-10-28, 0d
    Hermes live                                                 :milestone, m_hermes, 2026-11-10, 0d
    Containment done                                            :milestone, m_contain, 2026-11-21, 0d
    Graph queryable                                             :milestone, m_graph, 2026-12-15, 0d
    Core plan done                                              :milestone, m_core, 2027-01-12, 0d
    Full plan done                                              :milestone, m_all, 2027-01-25, 0d
```

| Milestone | Date | Meaning |
|---|---|---|
| Styx enforcing | Wed Oct 28, 2026 | All egress forced through per-source allowlists |
| Hermes live | Tue Nov 10, 2026 | Hermes on Telegram with P3 gates passed |
| Containment done | Sat Nov 21, 2026 | Shell runs in Daedalus; exfil gates passed |
| Graph queryable | Tue Dec 15, 2026 | Hephaestus gates passed |
| Core plan done | Tue Jan 12, 2027 | P10 gate passed |
| Full plan done | Mon Jan 25, 2027 | Optional P7 + P9 complete |

> **Schedule risk:** zero slack. Any missed session shifts everything after it. The biggest single risk is the P4 file-tool location check — if file tools act on the Hermes container rather than Daedalus, P4 and later shift 1–2 weeks.

# Project Status

This project is currently in Phase 1. Please observe the Road map to understand what that means in detail.

# Contributing
[@nels27](https://github.com/Nels27)
[@claude](https://github.com/claude)