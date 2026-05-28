---
skill: apex-homelab
backend: deepseek
mode: coding
version: 1.0.0
last_updated: 2026-05-28
---

# Home Lab / Home Automation — Coding Patterns

## NEVER / ALWAYS

NEVER:
- Commit `secrets.yaml` to git — it contains WiFi passwords, API keys, OTA passwords
- Use the same OTA password across multiple ESPHome devices
- Skip API encryption on ESPHome devices
- Expose Home Assistant port 8123 directly to the internet
- Use AsyncStorage for sensitive tokens in companion apps — use SecureStore
- Hardcode device IPs in automations — use entity IDs

ALWAYS:
- Use `!secret` references in ESPHome YAML for all credentials
- Set `api: reboot_timeout: 0s` for devices that must never lose their connection
- Add `.gitignore` entries for `secrets.yaml` and `*.pem` in ESPHome projects
- Use Long-Lived Access Tokens for machine-to-machine HA API calls
- Test automations in the HA trace debugger before deploying to production
- Use entity areas and labels for organisation — makes bulk targeting easier

## ESPHome — minimal secure device config

```yaml
# secrets.yaml (NEVER commit this file)
wifi_ssid: "HomeNetwork"
wifi_password: "your-wifi-password"
api_key: "BASE64_ENCODED_32_BYTE_KEY"       # openssl rand -base64 32
ota_password_living_room: "unique-per-device-password"
fallback_password: "fallback-ap-password"

# living-room-sensor.yaml
esphome:
  name: living-room-sensor
  friendly_name: "Living Room Sensor"

esp32:
  board: esp32dev
  framework:
    type: arduino

logger:
  level: WARN   # reduce serial noise in production

api:
  encryption:
    key: !secret api_key
  reboot_timeout: 0s   # never reboot on API loss (critical for always-on devices)

ota:
  - platform: esphome
    password: !secret ota_password_living_room

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  fast_connect: true   # skip WiFi scan, connect directly
  ap:
    ssid: "Living Room Fallback"
    password: !secret fallback_password

captive_portal:

# BME280 temperature/humidity/pressure via I2C
i2c:
  sda: GPIO21
  scl: GPIO22

sensor:
  - platform: bme280_i2c
    temperature:
      name: "Temperature"
      filters:
        - offset: -1.5  # calibration offset if needed
    humidity:
      name: "Humidity"
    pressure:
      name: "Pressure"
    address: 0x76
    update_interval: 60s

  - platform: uptime
    name: "Uptime"

binary_sensor:
  - platform: status
    name: "Online"
```

## ESPHome — mmWave radar (LD2450 occupancy)

```yaml
# Requires external component
external_components:
  - source: github://esphome-components/ld2450
    components: [ld2450]

uart:
  tx_pin: GPIO17
  rx_pin: GPIO16
  baud_rate: 256000
  parity: NONE
  stop_bits: 1

ld2450:

binary_sensor:
  - platform: ld2450
    has_target:
      name: "Presence"
    has_moving_target:
      name: "Motion"
    has_still_target:
      name: "Stationary Presence"   # detects people sitting still — PIR misses this

sensor:
  - platform: ld2450
    target_count:
      name: "People Count"
```

## Home Assistant automation (YAML)

```yaml
# automations.yaml — presence-based lighting
- alias: "Turn off lights when room empty"
  id: lights_off_no_presence
  mode: single
  triggers:
    - trigger: state
      entity_id: binary_sensor.living_room_presence
      to: "off"
      for: "00:05:00"   # 5 minutes of no presence
  conditions:
    - condition: state
      entity_id: light.living_room
      state: "on"
  actions:
    - action: light.turn_off
      target:
        entity_id: light.living_room

# Template sensor — combine multiple sensors
- platform: template
  sensors:
    home_occupied:
      friendly_name: "Home Occupied"
      value_template: >
        {{ is_state('binary_sensor.living_room_presence', 'on') or
           is_state('binary_sensor.kitchen_presence', 'on') or
           is_state('binary_sensor.bedroom_presence', 'on') }}
      device_class: occupancy
```

## HA REST API — Python client pattern

```python
import httpx
import os

HA_URL = os.environ["HA_URL"]          # http://homeassistant.local:8123
HA_TOKEN = os.environ["HA_TOKEN"]      # Long-Lived Access Token

headers = {
    "Authorization": f"Bearer {HA_TOKEN}",
    "Content-Type": "application/json",
}

async def get_state(entity_id: str) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{HA_URL}/api/states/{entity_id}", headers=headers)
        r.raise_for_status()
        return r.json()

async def call_service(domain: str, service: str, data: dict) -> None:
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"{HA_URL}/api/services/{domain}/{service}",
            headers=headers,
            json=data,
        )
        r.raise_for_status()

# Example: turn on a light
await call_service("light", "turn_on", {
    "entity_id": "light.living_room",
    "brightness": 200,
    "color_temp": 4000,
})
```

## HA WebSocket — real-time state subscription (JavaScript)

```typescript
import WebSocket from 'ws';

const ws = new WebSocket('ws://homeassistant.local:8123/api/websocket');
const token = process.env.HA_TOKEN!;
let msgId = 1;

ws.on('message', (data) => {
  const msg = JSON.parse(data.toString());

  if (msg.type === 'auth_required') {
    ws.send(JSON.stringify({ type: 'auth', access_token: token }));
  }

  if (msg.type === 'auth_ok') {
    // Subscribe to state changes
    ws.send(JSON.stringify({
      id: msgId++,
      type: 'subscribe_events',
      event_type: 'state_changed',
    }));
  }

  if (msg.type === 'event') {
    const { entity_id, new_state } = msg.event.data;
    if (entity_id.startsWith('binary_sensor.')) {
      console.log(`${entity_id}: ${new_state?.state}`);
    }
  }
});
```

## ESPHome CLI commands

```bash
# Compile and flash over USB (first time)
esphome run living-room-sensor.yaml

# OTA update (subsequent flashes over WiFi)
esphome run living-room-sensor.yaml --device 192.168.1.50

# View logs from device
esphome logs living-room-sensor.yaml --device 192.168.1.50

# Compile only (check for errors)
esphome compile living-room-sensor.yaml

# Clean build cache
esphome clean living-room-sensor.yaml

# List all devices in directory
esphome list
```

## .gitignore for ESPHome projects

```gitignore
secrets.yaml
.esphome/
*.pem
*.key
```

## Verification checklist

- [ ] `secrets.yaml` is in `.gitignore` — not committed
- [ ] Each device has a unique OTA password
- [ ] API encryption key set on every ESPHome device
- [ ] `reboot_timeout: 0s` set for always-on devices
- [ ] HA accessible remotely via Nabu Casa or Tailscale (not raw port 8123)
- [ ] Long-Lived Access Token used for external API calls (not user password)
- [ ] mmWave radar used for occupancy where stationary detection matters
- [ ] IoT devices on separate VLAN from trusted LAN
- [ ] Automations tested with HA trace debugger
- [ ] ESPHome devices show as "Online" in HA after flash
