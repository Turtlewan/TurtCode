# Home Assistant API clients & automations

Load when writing code that talks to HA, or HA YAML automations. Two client languages shown as
illustrations — use whichever the consuming app is in. Always authenticate with a Long-Lived
Access Token (not a user password).

## REST API — Python client (httpx)

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

## WebSocket API — real-time state subscription (TypeScript)

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
    ws.send(JSON.stringify({ id: msgId++, type: 'subscribe_events', event_type: 'state_changed' }));
  }
  if (msg.type === 'event') {
    const { entity_id, new_state } = msg.event.data;
    if (entity_id.startsWith('binary_sensor.')) {
      console.log(`${entity_id}: ${new_state?.state}`);
    }
  }
});
```

## HA automation (YAML — HA 2025.12+ plural syntax)

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
