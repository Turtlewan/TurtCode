---
skill: apex-homelab
backend: claude
version: 1.2.0
last_updated: 2026-06-01
sources:
  - Home Assistant Docs — home-assistant.io/docs
  - ESPHome Docs / Changelog — esphome.io
  - HA Connect ZBT-2 — home-assistant.io/connect/zbt-2
  - Matter / Thread 1.4 — csa-iot.org
  - Proxmox VE 9.x — proxmox.com
staleness_threshold: 30d
description: >
  Use when planning home automation, IoT sensor builds, OR home-lab / self-hosting
  infrastructure (the host that runs the stack). Triggers: Home Assistant, ESPHome, Zigbee,
  Z-Wave, Matter, Thread, MQTT, "home lab", "smart home", presence/occupancy detection, local
  voice (Wyoming/Whisper), ESP32; and Proxmox, Docker Compose self-hosting, reverse proxy
  (Traefik/Caddy/NPM), Tailscale, homelab backups. Not: cloud IoT platforms (AWS IoT / Azure
  IoT Hub), commercial building automation (BACnet / KNX), or team/prod CI (→ apex-devops).
---

# Home Lab / Home Automation Specialist — Planning Mode

## Stack assumptions

Assumes the **Home Assistant + ESPHome + MQTT** stack (the dominant local-first home-automation
platform) — not openHAB/Hubitat/cloud ecosystems. Cohesive enough that no swap-table is needed.
The impl.md API-client examples show two languages (Python `httpx`, TypeScript `ws`) as
illustrations; use whichever the consuming app is in.

## When to activate
Building home automation applications, integrating with smart home devices, creating custom
IoT sensors, building apps that integrate with daily life (presence, appliances, notifications,
voice, energy monitoring), or connecting services to Home Assistant.

## Questions to ask before designing

- What is the integration point? (Home Assistant, standalone MQTT, direct REST/WebSocket?)
- Does it need to work when internet is down? (local-first vs cloud-dependent)
- Is this a sensor (reads data) or an actuator (controls something)?
- What hardware platform? (ESP32 for sensors, Raspberry Pi for hub, existing smart devices)
- What protocol do the target devices use? (Zigbee, Z-Wave, Matter, WiFi, MQTT)
- Does it require presence detection, occupancy, or user location?

## Stack — standard layers

```
Physical devices
    ↓ (Zigbee / Z-Wave / Matter / WiFi / MQTT)
Home Assistant (hub — orchestration, automations, dashboard)
    ├── ESPHome (custom ESP32 firmware — sensors, switches)
    ├── Zigbee2MQTT or ZHA (Zigbee coordinator bridge)
    ├── Mosquitto (MQTT broker — message bus for custom devices)
    └── Node-RED (complex flows, external API integration)
    ↓
Your applications (via REST API / WebSocket API / webhooks)
```

## Protocol selection

| Protocol | Use when | Notes |
|----------|----------|-------|
| **Zigbee** | Large sensor network, battery devices | Mesh; local-only; needs USB coordinator |
| **Z-Wave** | Locks, security, reliable mesh | Z-Wave JS; 30m range; pricier devices |
| **MQTT** | Custom devices (ESPHome), inter-service | Pub/sub; broker required (Mosquitto) |
| **Matter/Thread** | New cross-platform devices | **Matter 1.4** + **Thread 1.4** now share credentials across Apple/Google/Amazon border routers (the old "one mesh per brand" problem is largely solved for 1.4-certified gear). Needs a Thread border router (**HA ZBT-2** — ZBT-1 is discontinued). Matter 1.5 cameras not yet supported by HA (as of 2026-06). |
| **WiFi** | High-bandwidth (cameras), powerful MCUs | Cloud-dependency risk unless local API used |
| **Bluetooth LE** | Presence detection, beacons | ESPHome BT proxy extends range |

**Default stack for new sensor projects:** ESP32 + ESPHome + MQTT (or native HA API) → Home Assistant

## Hardware platforms

**ESP32** — default for custom sensors and actuators:
- ESP32 (classic): general purpose, WiFi + BLE, 2 cores
- ESP32-S3: BLE 5.0, native USB, 45 GPIO — use for USB-connected devices
- ESP32-C3: cheaper, lower power, RISC-V — **preferred for new battery-powered nodes**
- Prefer ESP32-C3 over ESP8266 for new projects (ESP8266 is WiFi-only, RAM-limited — still
  maintained, but ESP32-C3 wins on every axis; reserve ESP8266 for migrating existing hardware)

**Raspberry Pi** — for running Home Assistant OS or custom hub services:
- Pi 4/5: full HA OS host; Pi 5 recommended for local Whisper STT
- Pi Zero 2 W: lightweight local service node

**USB Zigbee coordinators:** prefer **EFR32MG24-based** — Sonoff **ZBDongle-E (MG24)** or the
**HA ZBT-2**; **SMLIGHT SLZB-06MG24** for PoE/LAN. Avoid the EOL **Conbee II**. Note the ZBT-2 is
Zigbee **or** Thread, not both at once.

## Homelab infrastructure

The layer that *hosts* Home Assistant and other self-hosted services. Present options with
trade-offs and recommend by scale — don't mandate.

**Host strategy** (the fork everything else hangs off):

| Scale | Host | Trade-off |
|-------|------|-----------|
| HA only / beginner | Bare-metal HAOS (or Pi 5 + NVMe — never SD card) | simplest, fewest moving parts; can't run other VMs |
| HA + a few services | Docker Compose on a mini-PC (no hypervisor) | simpler than Proxmox; enough for most homelabs |
| HA + many services + snapshots | **Proxmox VE 9.x**, HAOS in a VM | full flexibility + snapshot DR; needs ≥8 GB RAM |
| Multi-machine failover | Proxmox cluster (3+ nodes for quorum) | overkill for a single-box hub |

HAOS-in-Proxmox VM: q35 + OVMF (Secure Boot off) + VirtIO SCSI, 2 vCPU / 4 GB+, USB Zigbee dongle
passed through via a persistent `/dev/serial/by-id/...` path. Steps → `references/homelab-infra.md`.

**Container runtime:** default **Docker + Compose v2** (`docker compose`, not the deprecated v1
`docker-compose`). Prefer **Podman (rootless)** if starting fresh and security posture matters. One
Linux VM running one Compose stack is the dominant pattern. **Don't run Docker inside an LXC** — use
a VM (Proxmox doesn't officially support Docker-in-LXC).

**Reverse proxy + TLS:**

| Tool | Best for | Trade-off |
|------|----------|-----------|
| Nginx Proxy Manager | beginners, GUI, non-Docker backends | heavier; no Docker auto-discovery |
| Caddy | config-file simplicity, automatic HTTPS | lightest; smaller plugin ecosystem |
| Traefik | Docker-Compose-first (label auto-discovery) | steeper config; best for dynamic stacks |

Internal-only services → DNS-01 ACME (no public port 80 needed); public → HTTP-01 or DNS-01.

**Remote access (split pattern):** **Tailscale** (WireGuard-based, easiest) for personal device
access; self-hosted **WireGuard** for lowest-latency full control; **Cloudflare Tunnel** for
publicly *shared* services / CGNAT; **Nabu Casa** for HA-only. Never expose raw ports (see Security).

**Storage:** ext4 (simplest, Proxmox default) vs **ZFS** (checksums + snapshots + PBS backups;
budget 1–2 GB ARC RAM) vs btrfs (mirrors only — RAID 5/6 still unstable). HA's recorder writes
constantly — put the HA DB on a TLC/NVMe disk with high TBW and purge old records. TrueNAS only for
a dedicated multi-disk NAS (≥16 GB RAM); overkill for one mini-PC.

**Backups (3-2-1):** Proxmox Backup Server (on-host VM is fine for a single node) for VM/LXC +
**HA Supervisor backups** (portable HA state) + an offsite copy via **restic + rclone** to B2/S3.

**Monitoring (by scale):** start with **Uptime Kuma** (~80% of needs); add **Prometheus + Grafana**
only for trends or 10+ containers; **Glances** for live debugging.

**Networking / firewall (scale-gated):** a VLAN-capable consumer router (UniFi, Asus-Merlin)
suffices for most. **OPNsense** (preferred over pfSense in 2026) only when you need IDS/IPS or the
router lacks VLANs — dedicated hardware beats a firewall-in-a-VM (Proxmox down = network down).

**Secrets / git hygiene:** minimum `.env` git-ignored + `.env.example` committed; better **SOPS +
age** (encrypt secrets at rest, commit them) for GitOps; Infisical/Vault only with many dynamic creds.

**Boundary:** at this scale, Compose files in git **are** your IaC — Terraform/OpenTofu (apex-iac)
and Kubernetes (apex-k8s) are overkill for a home hub (k3s is fine as a *learning* target, not the
HA runtime). Image build / CI pipelines → apex-devops. Ceph/SAN → out of scope (cluster-only).

> Worked infra snippets (Proxmox HAOS VM steps, Traefik Compose + labels, Caddyfile, restic+rclone
> backup script, SOPS+age): `references/homelab-infra.md`.

## ESPHome — declarative firmware

ESPHome converts YAML to firmware. No code needed for 90% of sensor projects. As of **ESPHome
2026.1, ESP-IDF is the default framework** for ESP32 (was Arduino) — only set
`framework: type: arduino` when a specific component requires it.

> Full secure device config + mmWave (LD2450) example: `references/esphome-configs.md`.

**Key ESPHome pitfalls (2026):**
- **API `password:` auth was removed in 2026.1** — use `api: encryption: key:` only; a config
  still using `api: password:` won't compile.
- Default `reboot_timeout: 15min` — device reboots if it can't reach HA. Set
  `api: reboot_timeout: 0s` for always-on devices.
- Use unique OTA passwords per device. OTA gained **SHA256 auth in 2026.5** — confirm the OTA
  block matches current platform options.
- API encryption key required — never skip it.

## Home Assistant integration patterns

- **Custom integration** (Python, `custom_components/`): `DataUpdateCoordinator` +
  `async_setup_entry` + `config_flow.py`.
- **REST API** (external apps → HA): `GET /api/states/<entity>`, `POST /api/services/<domain>/<svc>`
  with a Bearer Long-Lived Access Token.
- **WebSocket API** (real-time): auth → `subscribe_events` → `state_changed` stream.
- **Webhook triggers** (push → HA): `POST /api/webhook/<secret-id>`.

> Worked Python (`httpx`) + TypeScript (`ws`) clients: `references/ha-api-clients.md`.

## Automation design

Use native YAML automations (HA 2025.12+ uses the plural `triggers:`/`conditions:`/`actions:`
purpose-specific syntax) for simple trigger-condition-action patterns. Use **Node-RED** for
multi-step decision trees, stateful flows, external HTTP calls, or visual debugging.

**mmWave radar** for occupancy (detects stationary people, unlike PIR): LD2450 / LD2410 via
ESPHome → `has_target` (presence) + `has_still_target` (stationary).

## Daily life integration patterns

| Use case | Stack |
|----------|-------|
| Whole-home energy monitoring | ESPHome + PZEM-004T → HA Energy Dashboard |
| Room occupancy | ESPHome + LD2450 mmWave radar |
| Local voice assistant | Wyoming + Whisper (STT) + Piper (TTS) + HA Assist |
| Presence-based automation | BT proxy array (3+ ESP32 nodes) + HA room tracking |
| Plant/garden watering | ESPHome + capacitive soil moisture sensor + relay |
| Custom notifications | HA Companion app push → `notify.mobile_app_<device>` |
| Appliance monitoring | Zigbee smart plug (power monitoring) → HA energy |

## Local-first vs cloud

Always design for internet outage. Core automations must work without cloud:
- Use `iot_class: local_push` or `local_polling` for all critical integrations
- Nabu Casa (**$6.50/mo**, or $65/yr) for remote access — better than exposing port 8123 directly
- Or self-host: WireGuard/Tailscale VPN to reach HA remotely

## Security practices

- Never expose port 8123 directly to internet — use reverse proxy (Caddy/nginx) with HTTPS + auth
- IoT VLAN: separate network segment for smart devices (IoT → internet OK, IoT → trusted LAN blocked)
- ESPHome: unique API encryption key and OTA password per device
- HACS custom integrations: audit before installing — they have full Python access to HA

## Review checklist

- [ ] ESPHome devices use `api: encryption:` (not removed `api: password:`) + unique OTA password
- [ ] `secrets.yaml` is in `.gitignore` (never committed)
- [ ] HA accessible remotely via Nabu Casa or VPN (never bare port 8123)
- [ ] Zigbee mesh has mains-powered router devices (not battery-only mesh); MG24 coordinator
- [ ] Critical automations don't require cloud/internet to function
- [ ] USB Zigbee dongle uses persistent udev symlink (not `/dev/ttyUSB0`)
- [ ] mmWave radar used for occupancy (not PIR-only) where stationary detection matters
- [ ] Long-lived access tokens generated for machine-to-machine access only
- [ ] Host strategy chosen by scale (bare-metal / Compose / Proxmox — not a cluster by default)
- [ ] Web-facing services behind a reverse proxy with TLS (never raw ports)
- [ ] 3-2-1 backups in place incl. an HA Supervisor backup copied offsite
- [ ] Service secrets in git-ignored `.env` (or SOPS+age) — never committed plaintext

## Standards

- Home Assistant Developer Docs — `developers.home-assistant.io`
- ESPHome — `esphome.io` (check the changelog — fast-moving breaking changes)
- Zigbee2MQTT — `zigbee2mqtt.io`
- Wyoming Protocol (local voice) — `github.com/rhasspy/wyoming`
