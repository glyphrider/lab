# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Ansible automation for a home lab consisting of managed hosts:

| Host | IP | OS | Playbook |
|------|----|----|----------|
| lab | 192.168.1.3 | Fedora 43 | `lab.yml` |
| gateway | 192.168.1.1 | OpenBSD | `gateway.yml` |
| unifi | 192.168.1.2 | Ubuntu 24.04 VM | `lab.yml` (second play) |
| pihole2 | 192.168.1.251 | Raspberry Pi OS (Bookworm) | `pi.yml` |
| rhel8 | 192.168.1.35 | RHEL 8 KVM VM | `lab.yml` (fourth play) |
| rhel9 | 192.168.1.36 | RHEL 9 KVM VM | `lab.yml` (fourth play) |
| ol9 | 192.168.1.39 | Oracle Linux 9 KVM VM | `lab.yml` (fifth play) |

## Running playbooks

```bash
# Full run
ansible-playbook lab.yml --ask-vault-pass
ansible-playbook gateway.yml --ask-vault-pass
ansible-playbook pi.yml --ask-vault-pass

# Single role (all roles are tagged with their name)
ansible-playbook lab.yml --tags pihole --ask-vault-pass
ansible-playbook gateway.yml --tags unbound --ask-vault-pass
ansible-playbook pi.yml --tags pihole --ask-vault-pass

# Provision RHEL/OL VMs (two steps — provision then configure)
ansible-playbook lab.yml --tags rhel-vms --ask-vault-pass --limit lab
ansible-playbook lab.yml --tags rhel-setup,ol-setup,node-exporter --ask-vault-pass --limit rhel,ol

# Dry run
ansible-playbook gateway.yml --check --ask-vault-pass
```

## Secrets

Secrets are managed with ansible-vault. Encrypted files:
- `group_vars/lab/vault.yml` — contains `pihole_password`, `vm_console_password`, `rhsm_username`, `rhsm_password`
- `group_vars/pi/vault.yml` — contains `pihole_password` for pihole2
- `roles/pihole/files/pihole.key` — TLS private key for lab pihole
- `roles/pihole/files/pihole2.key` — TLS private key for pihole2 pihole
- `roles/jellyfin/files/jellyfin.key` — TLS private key
- `roles/unifi/files/unifi.key` — TLS private key

To encrypt a new file: `ansible-vault encrypt <file>`

## Architecture

### Network layout

The lab server has a layered bridge stack:
- `management0` — bridges to physical NIC, VLAN 1 (192.168.1.0/24)
- `marisol0` — VLAN 2 (10.47.2.0/24), guest/media network
- `iot0` — VLAN 3 (10.47.3.0/24), IoT network

Podman containers attach to macvlan networks parented on these bridges (managed by the `podman-macvlan` role). Each macvlan network is created as an external network and shared across compose stacks.

The pihole2 Pi uses VLAN subinterfaces directly on eth0 (no bridges needed — no VMs or macvlan):
- `eth0` — 192.168.1.251/24 (management, untagged)
- `eth0.2` — 10.47.2.251/24 (marisol)
- `eth0.3` — 10.47.3.251/24 (IoT)

### DNS (split-horizon)

Unbound on the gateway uses views to return different records per VLAN:
- `management` view: full internal hostnames for 192.168.1.0/24 and 127.0.0.0/8
- `marisol` view: only marisol-VLAN-relevant hosts for 10.47.2.0/24
- `iot` view: only IoT-VLAN-relevant hosts for 10.47.3.0/24

`unbound_views`, `unbound_local_zone`, and `unbound_access_control` are defined in `group_vars/all/vars.yml` and shared between the gateway `unbound` role and the lab `unbound-container` role.

Each pihole instance uses its own VLAN's unbound interface as primary upstream and the backup unbound container (`.254`) as secondary, so DNS views work correctly on both. Pihole containers also set `dns:` in their compose service to the primary upstream, ensuring the gravity update check uses the correct resolver.

DHCP advertises two DNS servers per subnet — primary (`.5`) on lab and secondary (`.251`) on pihole2. Both piholes use the gateway unbound (`.1`) as primary upstream and the lab unbound container (`.254`) as secondary.

### Pihole

Two deployments, same role (`roles/pihole`), different `pihole_network_type`:

**Lab (macvlan mode):** Three containers (one per VLAN) each with a dedicated macvlan IP. Defined in a single compose file from `roles/pihole/templates/pihole.yml.j2`. First-run password initialization is gated by a sentinel dotfile at `/var/lab/.{{ name }}-password-initialized`.

**pihole2 / Pi (bridge mode):** Three containers (one per VLAN) using podman port publishing with per-IP binding (`192.168.1.251:53`, `10.47.2.251:53`, `10.47.3.251:53`). No macvlan needed. Requires `FTLCONF_dns_listeningMode: all` since clients arrive with their original source IP after DNAT. Configured via `group_vars/pi/vars.yml`.

TLS cert files are parameterized via `pihole_tls_cert_file` / `pihole_tls_key_file` (defaults: `pihole.crt` / `pihole.key`). The Pi overrides these to `pihole2.crt` / `pihole2.key`.

### Unbound container

The `unbound-container` role runs a custom Alpine+unbound container on the lab host, providing a backup recursive resolver for all three VLANs. It attaches to all three macvlan networks:
- `192.168.1.254` (management)
- `10.47.2.254` (marisol)
- `10.47.3.254` (iot)

The container uses the same split-horizon view config as the gateway (shared via `group_vars/all/vars.yml`). The image is built locally from `roles/unbound-container/files/Containerfile` using Alpine + unbound + bind-tools. DNSSEC validation is disabled in the container (no `auto-trust-anchor-file`) — the gateway handles that.

### RHEL/OL VMs

The `rhel-vms` role runs on the lab server and uses Terraform (`dmacvicar/libvirt` provider v0.7.6) to provision KVM VMs via libvirt. Terraform state lives at `/var/lab/terraform/rhel/`. VM definitions are in `roles/rhel-vms/defaults/main.yml`.

Key implementation details:
- RHEL 9+ requires x86-64-v2 CPU — all VMs use `cpu { mode = "host-passthrough" }`
- Cloud-init ISOs use `lifecycle { ignore_changes = all }` to work around a libvirt provider bug with running VMs
- OL9 image is downloaded automatically via `get_url` (public URL, no auth required); RHEL images must be downloaded manually
- Disk overlays use per-VM `disk_size` (currently 48 GiB / 51539607552 bytes for all VMs)

**RHEL VMs** (`roles/rhel-setup`): Bootstrap uses `raw` module to register RHSM subscription and install `python39` + `python3-dnf` before facts can be gathered. Also installs and registers `insights-client` with an hourly systemd timer. RHEL 8 requires `ansible_python_interpreter: /usr/bin/python3.9` (set in `group_vars/rhel/vars.yml`).

**OL9 VM** (`roles/ol-setup`): Oracle Linux ships with Python 3, so no bootstrap needed. No subscription required.

### VM (unifi)

The `virtualization` role runs on the lab server and uses Terraform (`dmacvicar/libvirt` provider v0.7.6) to provision a KVM VM via libvirt. Terraform state lives at `/var/lab/terraform/unifi/`. Cloud-init handles static IP config (netplan, interface `enp0s3`), user creation, and SSH key injection. The lab server's own SSH key (`~/.ssh/id_ed25519`) is generated by the role and injected into the VM so Ansible can poll `cloud-init status --wait` after provisioning.

The `unifi` role then runs against the VM directly to install UniFi OS Server.

### CA certificate

`files/marisol.crt` (playbook-level) is the shared internal CA cert. Roles reference it as `src: marisol.crt` (copy module) or `lookup('file', playbook_dir + '/files/marisol.crt')` (pihole). It is deployed to the system trust store on Fedora (`update-ca-trust`), Ubuntu (`update-ca-certificates`), and Raspberry Pi OS (`update-ca-certificates`).

### Gateway

The `gateway-network` role syncs `/etc/hostname.*` files from `roles/gateway-network/files/` and reboots if anything changed. `become_method` is `doas` (not sudo) for the gateway — set in `group_vars/gateway/vars.yml`.
