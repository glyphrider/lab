# lab

Ansible automation for a home lab network.

Implementation-level detail for individual roles (DNS split-horizon, pihole's two
deployment modes, VM provisioning, jellyfin's IPv6 quirk, etc.) lives in
[`docs/architecture.md`](docs/architecture.md) rather than here.

## Hosts

| Host | IP | OS | Role |
|------|----|----|------|
| lab | 192.168.1.3 | Fedora 43 | Primary server — containers, VMs, NFS client |
| gateway | 192.168.1.1 | OpenBSD | Router — DHCP, DNS, firewall |
| unifi | 192.168.1.2 | Ubuntu 24.04 VM | UniFi OS Server |
| pihole2 | 192.168.1.251 | Raspberry Pi OS (Bookworm) | Secondary DNS — pihole redundancy |
| rhel8 | 192.168.1.35 | RHEL 8 KVM VM | Subscribed RHEL host |
| rhel9 | 192.168.1.36 | RHEL 9 KVM VM | Subscribed RHEL host |
| ol9 | 192.168.1.39 | Oracle Linux 9 KVM VM | Unsubscribed RHEL-compatible host |
| nas | 192.168.1.4 | TrueNAS Scale | NFS file server _(not automated)_ |
| switch | 192.168.1.253 | Cisco Catalyst WS-C3650-48PS | 48-port PoE switch — managed via Terraform, not Ansible (see `terraform/switch/README.md`) |

## Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| management | 192.168.1.0/24 | Primary LAN |
| marisol | 10.47.2.0/24 | Guest/media VLAN |
| iot | 10.47.3.0/24 | IoT VLAN |
| marisol-work | 10.47.4.0/24 | Work VLAN — isolated, gateway only |

### Network Overview

```
Internet
    |
Frontier ONT
    |
igc0 (2.5Gb)
    |
+---+------------------------------+
|   Gateway  192.168.1.1           |
|   dhcpd + unbound (split-horizon)|
+---+----------+--------+----------+
    |          |        |          |
    |        vlan2    vlan3      vlan4
    |          |        |          |
    |       Marisol    IoT       Work
    |                          (isolated)
    |
Management 192.168.1.0/24
    lab            192.168.1.3
    unifi VM       192.168.1.2
    nas            192.168.1.4
    pihole         192.168.1.5   (primary DNS)
    pihole2        192.168.1.251 (secondary DNS)
    unbound        192.168.1.254 (backup resolver)
    rhel8          192.168.1.35
    rhel9          192.168.1.36
    ol9            192.168.1.39

Marisol 10.47.2.0/24
    pihole-marisol  10.47.2.5   (primary DNS)
    pihole2         10.47.2.251 (secondary DNS)
    unbound         10.47.2.254 (backup resolver)
    jellyfin        10.47.2.6

IoT 10.47.3.0/24
    pihole-iot      10.47.3.5   (primary DNS)
    pihole2         10.47.3.251 (secondary DNS)
    unbound         10.47.3.254 (backup resolver)

Work 10.47.4.0/24
    (isolated — gateway only, no containers)
```

### Lab Server — Network Configuration

```
Physical NIC
    |
+---+-----------------------------+
|  management0   192.168.1.3/24  |
+---+----+-------------+---------+
    |    |             |
  vlan2 vlan3        KVM + macvlan
    |    |             |
    |    |             +-- unifi VM      192.168.1.2
    |    |             +-- lab-management0-macvlan
    |    |                   pihole-management  192.168.1.5
    |    |                   unbound            192.168.1.254
    |    |
    |  iot0  10.47.3.3/24
    |    |
    |    +-- lab-iot0-macvlan
    |          pihole-iot   10.47.3.5
    |          unbound      10.47.3.254
    |
  marisol0  10.47.2.3/24
    |
    +-- lab-marisol0-macvlan
          pihole-marisol  10.47.2.5
          jellyfin        10.47.2.6
          unbound         10.47.2.254
```

### pihole2 (Raspberry Pi) — Network Configuration

```
Physical NIC (eth0)
    |
    +-- untagged --> eth0     192.168.1.251/24
    |                  port 53 --> pihole-management
    |
    +-- vlan2   --> eth0.2   10.47.2.251/24
    |                  port 53 --> pihole-marisol
    |
    +-- vlan3   --> eth0.3   10.47.3.251/24
                       port 53 --> pihole-iot

Containers (podman bridge, port-published):
    pihole-management   192.168.1.251:53
    pihole-marisol      10.47.2.251:53
    pihole-iot          10.47.3.251:53
```

### Gateway — Network & Services

```
Frontier ONT
    |
igc0  WAN  2.5Gb  (autoconf / autoconf6)
    |
aggr0  LACP  4x1Gb  (bge0 + bge1 + bge2 + bge3)
    |
    +<--> trunk <--> Cisco Catalyst WS-C3650-48PS  192.168.1.253
    |
    +-- untagged --> aggr0   192.168.1.1/24  management
    +-- vnetid 2 --> vlan2   10.47.2.1/24    marisol
    +-- vnetid 3 --> vlan3   10.47.3.1/24    iot
    +-- vnetid 4 --> vlan4   10.47.4.1/24    work

dhcpd  (all VLANs):
    management  dns: 192.168.1.5   + 192.168.1.251
    marisol     dns: 10.47.2.5     + 10.47.2.251
    iot         dns: 10.47.3.5     + 10.47.3.251
    work        dns: 10.47.4.5     + 10.47.4.251

unbound  (split-horizon, recursive):
    management view  192.168.1.0/24 + 127.0.0.0/8   full internal records
    marisol view     10.47.2.0/24                    gateway + pihole + pihole2 + jellyfin
    iot view         10.47.3.0/24                    gateway + pihole + pihole2
    work view        10.47.4.0/24                    gateway only
```

## Prerequisites

- Ansible with `community.general` collection
- `pass` and `gpg`, with the private key for this repo's `.password-store/.gpg-id` imported — `vault_pass.sh` scopes `pass` to that store (see [Secrets](#secrets)) so the vault password is supplied automatically via `ansible.cfg`
- SSH access to all hosts

Alternatively, run `nix develop` to drop into a shell with Ansible, Terraform, and the
other tools this repo needs already on `PATH` (see `flake.nix`).

## Usage

```bash
# Run full configuration
ansible-playbook lab.yml
ansible-playbook gateway.yml
ansible-playbook pi.yml

# Run a single role
ansible-playbook lab.yml --tags <role>
ansible-playbook pi.yml --tags <role>

# Dry run
ansible-playbook lab.yml --check
```

Available tags match role names: `system-setup`, `user-setup`, `bridge-networking`, `podman`, `podman-macvlan`, `pihole`, `nfs-media`, `va-api`, `jellyfin`, `virtualization`, `node-exporter`, `monitoring`, `unbound-container`, `rhel-vms`, `unifi`, `gateway-network`, `gateway-services`, `dhcpd`, `unbound`, `rpi-network`, `rhel-setup`, `ol-setup`.

## Updating UniFi OS Server

The installer bundle lives under `roles/unifi/files/`, managed as a symlink so old
downloads can be kept around without renaming anything:

- `roles/unifi/files/unifi-os-server.downloads/` — versioned installer downloads
- `roles/unifi/files/unifi-os-server.installer` — symlink to the version currently in use

Neither the symlink nor the downloads directory is committed to git (both are
gitignored) — they're large binaries that change per-install. On a fresh clone,
download the latest UniFi OS Server installer for Linux from
[ui.com](https://ui.com) into `roles/unifi/files/unifi-os-server.downloads/` and
create the `unifi-os-server.installer` symlink pointing at it before running the
`unifi` role for the first time.

To upgrade:

1. Download the new UniFi OS Server installer into `roles/unifi/files/unifi-os-server.downloads/`.
2. Repoint the `unifi-os-server.installer` symlink at the new file.
3. Run `ansible-playbook lab.yml --tags unifi`.

The `unifi` role copies the installer to the VM and only re-runs it when the file's
checksum differs from what's already there, so this is safe to run repeatedly —
it's a no-op unless the symlink points at a new/different installer.

## Secrets

Secrets are managed with ansible-vault:

```bash
# Edit vault
ansible-vault edit group_vars/lab/vault.yml
ansible-vault edit group_vars/rhel/vault.yml
ansible-vault edit group_vars/pi/vault.yml

# Encrypt a new file
ansible-vault encrypt roles/<role>/files/<file>.key
```

## Services

| Service | Host | IP |
|---------|------|----|
| PiHole (management) | lab | 192.168.1.5 |
| PiHole (marisol) | lab | 10.47.2.5 |
| PiHole (iot) | lab | 10.47.3.5 |
| PiHole 2 (management) | pihole2 | 192.168.1.251 |
| PiHole 2 (marisol) | pihole2 | 10.47.2.251 |
| PiHole 2 (iot) | pihole2 | 10.47.3.251 |
| Unbound (management) | lab | 192.168.1.254 |
| Unbound (marisol) | lab | 10.47.2.254 |
| Unbound (iot) | lab | 10.47.3.254 |
| Jellyfin | lab | 10.47.2.6 |
| Grafana | lab | 192.168.1.7 |
| Prometheus | lab | 192.168.1.8 |
| UniFi OS Server | unifi | 192.168.1.2 |
