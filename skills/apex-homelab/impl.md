---
skill: apex-homelab
backend: deepseek
version: 1.1.0
last_updated: 2026-06-01
sources:
  - ESPHome Docs / Changelog — esphome.io
  - Home Assistant Docs — home-assistant.io/docs
staleness_threshold: 30d
description: >
  Use when coding ESPHome device firmware, Home Assistant automations (YAML), or HA REST/
  WebSocket API clients. Triggers: writing a .yaml ESPHome config, custom_components, an
  automation, or an app that calls the HA API. Not: home-automation design decisions (SKILL.md).
---

# Home Lab / Home Automation — Coding Patterns

## Stack assumptions

Home Assistant + ESPHome + MQTT stack. The API-client examples (`references/ha-api-clients.md`)
show Python (`httpx`) and TypeScript (`ws`) — use whichever the consuming app is in.

## NEVER / ALWAYS

NEVER:
- Commit `secrets.yaml` to git — it contains WiFi passwords, API keys, OTA passwords
- Use the same OTA password across multiple ESPHome devices
- Skip API encryption on ESPHome devices
- Use `api: password:` on ESPHome — it was **removed in 2026.1**; use `api: encryption: key:` only
- Set `framework: type: arduino` by reflex — ESP-IDF is the default since 2026.1; add Arduino
  only when a component requires it
- Expose Home Assistant port 8123 directly to the internet
- Use AsyncStorage/localStorage for sensitive tokens in companion apps — use SecureStore/Keychain
- Hardcode device IPs in automations — use entity IDs

ALWAYS:
- Use `!secret` references in ESPHome YAML for all credentials
- Set `api: reboot_timeout: 0s` for devices that must never lose their connection
- Add `.gitignore` entries for `secrets.yaml`, `.esphome/`, `*.pem`, `*.key`
- Use Long-Lived Access Tokens for machine-to-machine HA API calls
- Test automations in the HA trace debugger before deploying to production
- Use entity areas and labels for organisation — makes bulk targeting easier

## Patterns (templates)

> ESPHome secure device config + mmWave (LD2450) + CLI + `.gitignore`: read
> `references/esphome-configs.md`.
> HA REST (Python httpx) + WebSocket (TypeScript) clients + automation YAML: read
> `references/ha-api-clients.md`.

## Common errors → fix

| Symptom | Fix |
|---------|-----|
| ESPHome compile fails on `api: password:` | removed in 2026.1 — replace with `api: encryption: key:` |
| Device keeps rebooting | default `reboot_timeout: 15min` on API loss — set `reboot_timeout: 0s` |
| OTA rejected | OTA uses SHA256 auth since 2026.5 — confirm `ota: platform: esphome` + correct password |
| HA API 401 | use a Long-Lived Access Token, not a user password; check `Authorization: Bearer` |
| Component needs Arduino | add `esp32: { framework: { type: arduino } }` (IDF is the 2026.1+ default) |
| Zigbee dongle path changes on reboot | use a persistent `/dev/serial/by-id/...` udev symlink |

## Verification checklist

- [ ] `secrets.yaml` is in `.gitignore` — not committed
- [ ] Each device has a unique OTA password
- [ ] API encryption key set on every ESPHome device (`api: encryption:`, not `api: password:`)
- [ ] `reboot_timeout: 0s` set for always-on devices
- [ ] HA accessible remotely via Nabu Casa or Tailscale (not raw port 8123)
- [ ] Long-Lived Access Token used for external API calls (not user password)
- [ ] mmWave radar used for occupancy where stationary detection matters
- [ ] IoT devices on separate VLAN from trusted LAN
- [ ] Automations tested with HA trace debugger
- [ ] ESPHome devices show as "Online" in HA after flash
