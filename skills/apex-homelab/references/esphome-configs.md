# ESPHome configs & CLI

Load when authoring ESPHome device firmware. As of **ESPHome 2026.1, ESP-IDF is the default
framework** — do not set `framework: type: arduino` unless a component requires it. **API
`password:` auth was removed in 2026.1** — use `api: encryption: key:` only.

## Minimal secure device config

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
  # framework defaults to esp-idf since ESPHome 2026.1; add `framework: { type: arduino }`
  # ONLY if a component you use still requires Arduino.

logger:
  level: WARN   # reduce serial noise in production

api:
  encryption:
    key: !secret api_key     # encryption key only — `api: password:` was removed in 2026.1
  reboot_timeout: 0s         # never reboot on API loss (critical for always-on devices)

ota:
  - platform: esphome
    password: !secret ota_password_living_room   # SHA256-authenticated since 2026.5

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

## mmWave radar (LD2450 occupancy)

```yaml
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

## ESPHome CLI commands

```bash
esphome run living-room-sensor.yaml                          # compile + flash over USB (first time)
esphome run living-room-sensor.yaml --device 192.168.1.50    # OTA update over WiFi
esphome logs living-room-sensor.yaml --device 192.168.1.50   # view device logs
esphome compile living-room-sensor.yaml                      # compile only (check errors)
esphome clean living-room-sensor.yaml                        # clean build cache
esphome list                                                 # list devices in directory
```

## .gitignore for ESPHome projects

```gitignore
secrets.yaml
.esphome/
*.pem
*.key
```
