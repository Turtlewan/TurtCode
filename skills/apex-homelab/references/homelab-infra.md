# Homelab infrastructure — worked snippets

Load when implementing the homelab host layer. Planning-level decisions + trade-offs live in
`../SKILL.md` § Homelab infrastructure; this file is the concrete how.

## HAOS in a Proxmox VE 9.x VM

```bash
# 1. Download the official HAOS image on the Proxmox host
wget https://github.com/home-assistant/operating-system/releases/download/<ver>/haos_ova-<ver>.qcow2.xz
unxz haos_ova-<ver>.qcow2.xz

# 2. Create the VM (q35 + UEFI, no OS disk yet). VMID 110 example.
qm create 110 --name haos --machine q35 --bios ovmf --cpu host --cores 2 --memory 4096 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single --ostype l26
qm set 110 --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0   # Secure Boot OFF

# 3. Import the HAOS disk and attach it
qm importdisk 110 haos_ova-<ver>.qcow2 local-lvm
qm set 110 --scsi0 local-lvm:vm-110-disk-1 --boot order=scsi0

# 4. Pass through the USB Zigbee/Thread coordinator by stable id (NOT /dev/ttyUSB0)
ls -l /dev/serial/by-id/                      # find the dongle's by-id path
qm set 110 --usb0 host=10c4:ea60              # or host=<vendor:product> / spice path
qm start 110
```

## Traefik (Docker Compose, label auto-discovery)

```yaml
# docker-compose.yml
services:
  traefik:
    image: traefik:v3.5
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.dnschallenge=true
      - --certificatesresolvers.le.acme.dnschallenge.provider=cloudflare
      - --certificatesresolvers.le.acme.email=you@example.com
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
    ports: ["443:443"]
    environment:
      CF_DNS_API_TOKEN: ${CF_DNS_API_TOKEN}   # from git-ignored .env
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./letsencrypt:/letsencrypt

  # any service opts in via labels — no central config edit
  whoami:
    image: traefik/whoami
    labels:
      - traefik.enable=true
      - traefik.http.routers.whoami.rule=Host(`whoami.home.example.com`)
      - traefik.http.routers.whoami.entrypoints=websecure
      - traefik.http.routers.whoami.tls.certresolver=le
```

## Caddy (Caddyfile — automatic HTTPS)

```caddyfile
# Caddyfile — internal services behind DNS-01
ha.home.example.com {
    reverse_proxy homeassistant:8123
}
files.home.example.com {
    reverse_proxy nextcloud:80
}
# Caddy provisions + renews certs automatically; use the cloudflare DNS plugin build for DNS-01.
```

## Offsite backup — restic + rclone

```bash
# One-time: configure an rclone remote (e.g. Backblaze B2) named "b2"
rclone config

# Daily backup of HA Supervisor backups + PBS datastore to encrypted restic repo on B2
export RESTIC_REPOSITORY="rclone:b2:my-homelab-restic"
export RESTIC_PASSWORD_FILE="/root/.restic-pass"   # file mode 600, backed up offline separately

restic backup /mnt/ha-backups /mnt/pbs-datastore
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

Run from cron/systemd-timer. Keep `RESTIC_PASSWORD` somewhere offline — losing it = losing the
backups. Pair with on-host Proxmox Backup Server for the local (fast-restore) copy.

## Secrets at rest — SOPS + age (for GitOps)

```bash
age-keygen -o ~/.config/sops/age/keys.txt        # generates a key; note the public key
# .sops.yaml — encrypt only secret files
cat > .sops.yaml <<'YAML'
creation_rules:
  - path_regex: secrets/.*\.ya?ml$
    age: age1<your-public-key>
YAML
sops -e -i secrets/app.yaml                       # encrypts in place — safe to commit
sops -d secrets/app.yaml                          # decrypt locally / at deploy
```
