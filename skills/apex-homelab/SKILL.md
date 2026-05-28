---
skill: apex-homelab
backend: claude
version: 1.0.0
last_updated: 2026-05-28
sources:
  - Home Assistant Developer Docs — developers.home-assistant.io
  - ESPHome Docs — esphome.io/components
  - Home Assistant Docs — home-assistant.io/docs
staleness_threshold: 30d
---

# Home Lab / Home Automation Specialist — Planning Mode

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
    ├── ESPHome (custom ESP32/ESP8266 firmware — sensors, switches)
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
| **Z-Wave** | Locks, security, reliable mesh | 30m range; more expensive devices |
| **MQTT** | Custom devices (ESPHome), inter-service | Pub/sub; broker required (Mosquitto) |
| **Matter/Thread** | New devices, cross-platform future | Thread needs border router (HA ZBT-1/ZBT-2) |
| **WiFi** | High-bandwidth (cameras), powerful MCUs | Cloud-dependency risk unless local API used |
| **Bluetooth LE** | Presence detection, beacons | ESPHome BT proxy extends range |

**Default stack for new sensor projects:** ESP32 + ESPHome + MQTT → Home Assistant

## Hardware platforms

**ESP32** — default for custom sensors and actuators:
- ESP32 (classic): general purpose, WiFi + BLE, 2 cores
- ESP32-S3: BLE 5.0, native USB, 45 GPIO — use for USB-connected devices
- ESP32-C3: cheaper, lower power, RISC-V — use for battery-powered nodes
- Never use ESP8266 for new projects — legacy, WiFi-only, limited RAM

**Raspberry Pi** — for running Home Assistant OS or custom hub services:
- Pi 4/5: full HA OS host; Pi 5 recommended for local Whisper STT
- Pi Zero 2 W: lightweight local service node

**USB Zigbee coordinators:** Sonoff Zigbee 3.0 USB Dongle Plus or Conbee III (verify current community recommendations).

## ESPHome — declarative firmware

ESPHome converts YAML to C++ firmware. No code needed for 90% of sensor projects.

```yaml
# secrets.yaml (never commit)
wifi_ssid: "MyNetwork"
wifi_password: "secret"
api_key: "BASE64_KEY"    # openssl rand -base64 32

# device.yaml
esphome:
  name: living-room-sensor

esp32:
  board: esp32dev

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  ap:
    ssid: "Fallback"
    password: !secret fallback_password

api:
  encryption:
    key: !secret api_key

ota:
  - platform: esphome
    password: !secret ota_password

sensor:
  - platform: bme280_i2c
    temperature:
      name: "Temperature"
    humidity:
      name: "Humidity"
    address: 0x77
    update_interval: 60s
```

**Key ESPHome pitfalls:**
- Default `reboot_timeout: 15min` — device reboots if it can't reach HA. Set `api: reboot_timeout: 0s` for always-on devices.
- Use unique OTA passwords per device. Shared passwords = one compromised device = all exposed.
- API encryption key required — never skip it.

## Home Assistant integration patterns

**Custom integration** (Python, `custom_components/`):
```python
# config_flow.py + coordinator.py + sensor.py
# Standard pattern: DataUpdateCoordinator + async_setup_entry
```

**REST API** (for external apps calling HA):
```bash
# Read state
curl -H "Authorization: Bearer TOKEN" http://ha.local:8123/api/states/sensor.temp

# Set state / trigger service
curl -X POST -H "Authorization: Bearer TOKEN" \
  -d '{"entity_id":"light.living_room"}' \
  http://ha.local:8123/api/services/light/turn_on
```

**WebSocket API** (real-time state subscription from apps):
```javascript
const ws = new WebSocket('ws://ha.local:8123/api/websocket');
// Auth → subscribe_events → state_changed events stream in real-time
```

**Webhook triggers** (push to HA from external services):
```
POST http://ha.local:8123/api/webhook/my-secret-webhook-id
```

## Automation design

**Use native YAML automations** for simple trigger-condition-action patterns:
```yaml
automation:
  - alias: "Turn off lights left on"
    triggers:
      - trigger: state
        entity_id: light.bedroom
        to: "on"
        for: "00:30:00"
    conditions:
      - condition: time
        after: "22:00:00"
    actions:
      - action: light.turn_off
        target:
          entity_id: light.bedroom
```

**Use Node-RED** when you need: multi-step decision trees, stateful flows, external HTTP API calls, or visual debugging.

**mmWave radar** for occupancy (detects stationary people, unlike PIR):
- LD2450 / LD2410 via ESPHome → binary_sensor `has_target` (presence) + `has_still_target` (stationary)

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
- Nabu Casa ($7/mo) for remote access — better than exposing port 8123 directly
- Or self-host: WireGuard/Tailscale VPN to reach HA remotely

## Security practices

- Never expose port 8123 directly to internet — use reverse proxy (Caddy/nginx) with HTTPS + auth
- IoT VLAN: separate network segment for smart devices (pfSense/OPNsense VLAN rule: IoT → internet OK, IoT → trusted LAN blocked)
- ESPHome: unique API key and OTA password per device
- HACS custom integrations: audit before installing — they have full Python access to HA

## Review checklist

- [ ] ESPHome devices have API encryption key and unique OTA password
- [ ] `secrets.yaml` is in `.gitignore` (never committed)
- [ ] HA accessible remotely via Nabu Casa or VPN (never bare port 8123)
- [ ] Zigbee mesh has mains-powered router devices (not battery-only mesh)
- [ ] Critical automations don't require cloud/internet to function
- [ ] USB Zigbee dongle uses persistent udev symlink (not `/dev/ttyUSB0`)
- [ ] mmWave radar used for occupancy (not PIR-only) where stationary detection matters
- [ ] Long-lived access tokens generated for machine-to-machine access only

## Standards

Home Assistant Developer Docs: developers.home-assistant.io
ESPHome: esphome.io
Zigbee2MQTT: zigbee2mqtt.io
Wyoming Protocol (local voice): github.com/rhasspy/wyoming
