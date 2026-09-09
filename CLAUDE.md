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
| nas | 192.168.1.4 | TrueNAS Scale | _(not automated)_ |
| switch | 192.168.1.253 | Cisco Catalyst WS-C3650-48PS | Terraform, not Ansible — see `terraform/switch/README.md` |

Deep architecture (network layout, DNS split-horizon, pihole, unbound, VM provisioning, jellyfin, monitoring, gateway) lives in [`docs/architecture.md`](docs/architecture.md) rather than here, to keep this file a quick reference.

## Dev environment

`flake.nix` / `flake.lock` provide a Nix dev shell (`nix develop`) with the tools this repo needs (ansible, terraform, etc.).

## Running playbooks

```bash
# Full run
ansible-playbook lab.yml
ansible-playbook gateway.yml
ansible-playbook pi.yml

# Single role (all roles are tagged with their name)
ansible-playbook lab.yml --tags pihole
ansible-playbook gateway.yml --tags unbound
ansible-playbook pi.yml --tags pihole

# Provision RHEL/OL VMs (two steps — provision then configure)
ansible-playbook lab.yml --tags rhel-vms --limit lab
ansible-playbook lab.yml --tags rhel-setup,ol-setup,node-exporter --limit rhel,ol

# Dry run
ansible-playbook gateway.yml --check
```

## Secrets

Secrets are managed with ansible-vault. Encrypted files:
- `group_vars/lab/vault.yml` — contains `pihole_password`, `vm_console_password`
- `group_vars/rhel/vault.yml` — contains `rhsm_username`, `rhsm_password`
- `group_vars/pi/vault.yml` — contains `pihole_password` for pihole2
- `roles/pihole/files/pihole.key` — TLS private key for lab pihole
- `roles/pihole/files/pihole2.key` — TLS private key for pihole2 pihole
- `roles/jellyfin/files/jellyfin.key` — TLS private key
- `roles/unifi/files/unifi.key` — TLS private key
- `roles/monitoring/files/grafana.key` — TLS private key

To edit an encrypted file: `ansible-vault edit <file>`
To encrypt a new file: `ansible-vault encrypt <file>`

Available role tags: `system-setup`, `user-setup`, `bridge-networking`, `podman`, `podman-macvlan`, `pihole`, `nfs-media`, `va-api`, `jellyfin`, `virtualization`, `node-exporter`, `monitoring`, `unbound-container`, `rhel-vms`, `unifi`, `gateway-network`, `gateway-services`, `dhcpd`, `unbound`, `rpi-network`, `rhel-setup`, `ol-setup`
