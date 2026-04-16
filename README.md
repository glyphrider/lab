# lab

Ansible automation for a home lab network.

## Hosts

| Host | IP | OS | Role |
|------|----|----|------|
| lab | 192.168.1.3 | Fedora 43 | Primary server — containers, VMs, NFS client |
| gateway | 192.168.1.1 | OpenBSD | Router — DHCP, DNS, firewall |
| unifi | 192.168.1.2 | Ubuntu 24.04 VM | UniFi OS Server |
| nas | 192.168.1.4 | TrueNAS Scale | NFS file server _(not automated)_ |
| switch | 192.168.1.253 | Cisco Catalyst WS-C3650-48PS | 48-port PoE switch _(not automated)_ |
| pihole2 | 192.168.1.251 | Raspberry Pi OS (Bookworm) | Secondary DNS — pihole redundancy |

## Networks

| Network | Subnet | Purpose |
|---------|--------|---------|
| management | 192.168.1.0/24 | Primary LAN |
| marisol | 10.47.2.0/24 | Guest/media VLAN |
| iot | 10.47.3.0/24 | IoT VLAN |
| marisol-work | 10.47.4.0/24 | Work VLAN — isolated, gateway only |

### Network Overview

```mermaid
graph TB
    inet([Internet])
    ont[ONT\nFrontier Fiber]
    switch[Cisco Catalyst\nWS-C3650-48PS\n192.168.1.253]

    inet -->|fiber| ont -->|2.5Gb — igc0| gateway -->|4x1Gb LACP — aggr0| switch

    subgraph gateway [Gateway 192.168.1.1]
        vlan2[vlan2 — 10.47.2.1]
        vlan3[vlan3 — 10.47.3.1]
        vlan4[vlan4 — 10.47.4.1]
    end

    subgraph management [Management — 192.168.1.0/24]
        lab[lab\n192.168.1.3]
        nas[nas\n192.168.1.4]
        unifi[unifi VM\n192.168.1.2]
        pihole_mgmt[pihole-management\n192.168.1.5]
        pihole2[pihole2\n192.168.1.251]
    end

    subgraph marisol [Marisol — 10.47.2.0/24]
        pihole_marisol[pihole-marisol\n10.47.2.5]
        pihole2_marisol[pihole2\n10.47.2.251]
        jellyfin[jellyfin\n10.47.2.6]
    end

    subgraph iot [IoT — 10.47.3.0/24]
        pihole_iot[pihole-iot\n10.47.3.5]
        pihole2_iot[pihole2\n10.47.3.251]
    end

    subgraph work [Marisol-Work — 10.47.4.0/24\nisolated — gateway only]
        work_note[DHCP + DNS\nfrom gateway]
    end

    switch <--> management
    switch -->|vlan2| vlan2 <--> marisol
    switch -->|vlan3| vlan3 <--> iot
    switch -->|vlan4| vlan4 <--> work
```

### Lab Server — Network Configuration

```mermaid
graph TB
    nic[Physical NIC]

    nic --> management0

    subgraph bridges [Linux Bridges]
        management0[management0\n192.168.1.3/24]
        marisol0[marisol0\n10.47.2.3/24]
        iot0[iot0\n10.47.3.3/24]
    end

    management0 -->|vlan2| marisol0
    management0 -->|vlan3| iot0

    management0 --> mv_mgmt
    marisol0    --> mv_marisol
    iot0        --> mv_iot

    subgraph macvlans [Podman Macvlan Networks]
        mv_mgmt[lab-management0-macvlan\n192.168.1.0/24]
        mv_marisol[lab-marisol0-macvlan\n10.47.2.0/24]
        mv_iot[lab-iot0-macvlan\n10.47.3.0/24]
    end

    mv_mgmt    --> pihole_mgmt[pihole-management\n192.168.1.5]
    mv_marisol --> pihole_marisol[pihole-marisol\n10.47.2.5]
    mv_marisol --> jellyfin[jellyfin\n10.47.2.6]
    mv_iot     --> pihole_iot[pihole-iot\n10.47.3.5]

    subgraph unifi_vm [KVM VM — unifi]
        unifi[UniFi OS Server\n192.168.1.2]
    end

    management0 --> unifi_vm

    nas[nas\n192.168.1.4\nTrueNAS Scale]
    management0 -->|NFS| nas
```

### pihole2 (Raspberry Pi) — Network Configuration

```mermaid
graph TB
    nic[Physical NIC — eth0]

    nic -->|untagged| eth0[eth0\n192.168.1.251/24]
    nic -->|vlan2| eth0_2[eth0.2\n10.47.2.251/24]
    nic -->|vlan3| eth0_3[eth0.3\n10.47.3.251/24]

    eth0   -->|192.168.1.251:53| pihole_mgmt[pihole-management\npihole2.marisol.home]
    eth0_2 -->|10.47.2.251:53| pihole_marisol[pihole-marisol\npihole2.marisol.home]
    eth0_3 -->|10.47.3.251:53| pihole_iot[pihole-iot\npihole2.marisol.home]

    subgraph containers [Podman containers — bridge network]
        pihole_mgmt
        pihole_marisol
        pihole_iot
    end
```

### Gateway — Network & Services

```mermaid
graph TB
    ont[ONT\nFrontier Fiber]
    igc0[igc0\n2.5Gb — WAN\nautoconf / autoconf6]
    ont -->|2.5Gb| igc0

    subgraph trunk [LACP Trunk — aggr0]
        bge0 & bge1 & bge2 & bge3
    end

    aggr0[aggr0\n4x1Gb LACP]
    bge0 & bge1 & bge2 & bge3 --> aggr0
    switch[Cisco Catalyst\nWS-C3650-48PS\n192.168.1.253]
    aggr0 <-->|trunk| switch

    aggr0 -->|untagged| mgmt[aggr0\n192.168.1.1/24\nManagement]
    aggr0 -->|vnetid 2| vlan2[vlan2\n10.47.2.1/24\nMarisol]
    aggr0 -->|vnetid 3| vlan3[vlan3\n10.47.3.1/24\nIoT]
    aggr0 -->|vnetid 4| vlan4[vlan4\n10.47.4.1/24\nMarisol-Work]

    mgmt   --> dhcpd[dhcpd\ndns: .5 + .251]
    vlan2  --> dhcpd
    vlan3  --> dhcpd
    vlan4  --> dhcpd

    subgraph unbound [unbound — split-horizon DNS]
        view_mgmt[management view\n192.168.1.0/24 + 127.0.0.0/8\nfull internal records]
        view_marisol[marisol view\n10.47.2.0/24\ngateway + pihole + pihole2 + jellyfin]
        view_iot[iot view\n10.47.3.0/24\ngateway + pihole + pihole2]
        view_work[work view\n10.47.4.0/24\ngateway only]
    end

    mgmt  --> view_mgmt
    vlan2 --> view_marisol
    vlan3 --> view_iot
    vlan4 --> view_work

    igc0 --> ont2[ONT\nFrontier Fiber] --> inet([Internet])
    view_mgmt & view_marisol & view_iot -->|recursive resolution| inet
```

## Prerequisites

- Ansible with `community.general` collection
- A vault password for encrypted secrets
- SSH access to all hosts

## Usage

```bash
# Run full configuration
ansible-playbook lab.yml --ask-vault-pass
ansible-playbook gateway.yml --ask-vault-pass
ansible-playbook pi.yml --ask-vault-pass

# Run a single role
ansible-playbook lab.yml --tags <role> --ask-vault-pass
ansible-playbook pi.yml --tags <role> --ask-vault-pass

# Dry run
ansible-playbook lab.yml --check --ask-vault-pass
```

Available tags match role names: `system-setup`, `user-setup`, `bridge-networking`, `podman`, `podman-macvlan`, `pihole`, `nfs-media`, `va-api`, `jellyfin`, `virtualization`, `unifi`, `gateway-network`, `dhcpd`, `unbound`, `rpi-network`.

## Secrets

Secrets are managed with ansible-vault:

```bash
# Edit vault
ansible-vault edit group_vars/lab/vault.yml
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
| Jellyfin | lab | 10.47.2.6 |
| UniFi OS Server | unifi | 192.168.1.2 |
