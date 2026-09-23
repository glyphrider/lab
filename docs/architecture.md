# Architecture

Implementation detail for the roles in this repo. See `CLAUDE.md` for the
host list, commands, and secrets inventory.

## Network layout

The lab server has a layered bridge stack:
- `management0` — bridges to physical NIC, VLAN 1 (192.168.1.0/24)
- `marisol0` — VLAN 2 (10.47.2.0/24), guest/media network
- `iot0` — VLAN 3 (10.47.3.0/24), IoT network

Podman containers attach to macvlan networks parented on these bridges (managed by the `podman-macvlan` role). Each macvlan network is created as an external network and shared across compose stacks.

The pihole2 Pi uses VLAN subinterfaces directly on eth0 (no bridges needed — no VMs or macvlan):
- `eth0` — 192.168.1.251/24 (management, untagged)
- `eth0.2` — 10.47.2.251/24 (marisol)
- `eth0.3` — 10.47.3.251/24 (IoT)

## DNS (split-horizon)

Unbound on the gateway uses views to return different records per VLAN:
- `management` view: full internal hostnames for 192.168.1.0/24 and 127.0.0.0/8
- `marisol` view: only marisol-VLAN-relevant hosts for 10.47.2.0/24
- `iot` view: only IoT-VLAN-relevant hosts for 10.47.3.0/24
- `work` view: gateway only for 10.47.4.0/24 (isolated VLAN, no containers)

`unbound_views`, `unbound_local_zone`, and `unbound_access_control` are defined in `group_vars/all/vars.yml` and shared between the gateway `unbound` role and the lab `unbound-container` role.

Each lab pihole instance uses its own VLAN's unbound interface as primary upstream and the backup unbound container (`.254`) as secondary, so DNS views work correctly on both. The pihole2 instances use the gateway unbound plus a local unbound container on the Pi (see below) — nothing on the lab host — so they keep working when lab is down. Pihole containers also set `dns:` in their compose service to the primary upstream, ensuring the gravity update check uses the correct resolver.

DHCP advertises two DNS servers per subnet — primary (`.5`) on lab and secondary (`.251`) on pihole2. The lab piholes use the gateway unbound (`.1`) as primary upstream and the lab unbound container (`.254`) as secondary; pihole2 uses the gateway (`.1`) and its own local unbound.

## Pihole

Two deployments, same role (`roles/pihole`), different `pihole_network_type`:

**Lab (macvlan mode):** Three containers (one per VLAN) each with a dedicated macvlan IP. Defined in a single compose file from `roles/pihole/templates/pihole.yml.j2`. First-run password initialization is gated by a sentinel dotfile at `/var/lab/.{{ name }}-password-initialized`.

**pihole2 / Pi (bridge mode):** Three containers (one per VLAN) using podman port publishing with per-IP binding (`192.168.1.251:53`, `10.47.2.251:53`, `10.47.3.251:53`). No macvlan needed. Requires `FTLCONF_dns_listeningMode: all` since clients arrive with their original source IP after DNAT. Configured via `group_vars/pi/vars.yml`.

TLS cert files are parameterized via `pihole_tls_cert_file` / `pihole_tls_key_file` (defaults: `pihole.crt` / `pihole.key`). The Pi overrides these to `pihole2.crt` / `pihole2.key`.

## Unbound container

The `unbound-container` role runs a custom Alpine+unbound container on the lab host, providing a backup recursive resolver for all three VLANs. It attaches to all three macvlan networks:
- `192.168.1.254` (management)
- `10.47.2.254` (marisol)
- `10.47.3.254` (iot)

**On the Pi:** the same role runs one unbound container attached to three private podman bridge networks (`pi-management-dns` 10.89.1.0/24, `pi-marisol-dns` 10.89.2.0/24, `pi-iot-dns` 10.89.3.0/24; unbound is `.2` on each). Each pihole2 container joins only its VLAN's network and uses that unbound (`.2`) as its second upstream. Because pihole queries arrive from the private network rather than the VLAN, `unbound_container_instances` entries with a `subnet` and `view` map that subnet to the matching view (`access-control-view`). The networks are created by the role, so it must run before `pihole` (`pi.yml` orders it that way).

The container uses the same split-horizon view config as the gateway (shared via `group_vars/all/vars.yml`). The image is built locally from `roles/unbound-container/files/Containerfile` using Alpine + unbound + bind-tools. DNSSEC validation is disabled in the container (no `auto-trust-anchor-file`) — the gateway handles that.

## RHEL/OL VMs

The `rhel-vms` role runs on the lab server and uses Terraform (`dmacvicar/libvirt` provider v0.7.6) to provision KVM VMs via libvirt. Terraform state lives at `/var/lab/terraform/rhel/`. VM definitions are in `roles/rhel-vms/defaults/main.yml`.

Key implementation details:
- RHEL 9+ requires x86-64-v2 CPU — all VMs use `cpu { mode = "host-passthrough" }`
- Cloud-init ISOs use `lifecycle { ignore_changes = all }` to work around a libvirt provider bug with running VMs
- OL9 image is downloaded automatically via `get_url` (public URL, no auth required); RHEL images must be downloaded manually
- Disk overlays use per-VM `disk_size` (currently 48 GiB / 51539607552 bytes for all VMs)

**RHEL VMs** (`roles/rhel-setup`): Bootstrap uses `raw` module to register RHSM subscription (with `no_log: true`, since the command interpolates `rhsm_username`/`rhsm_password`) and install `python39` + `python3-dnf` before facts can be gathered. Also installs and registers `insights-client` with an hourly systemd timer. RHEL 8 requires `ansible_python_interpreter: /usr/bin/python3.9` (set in `group_vars/rhel/vars.yml`).

**OL9 VM** (`roles/ol-setup`): Oracle Linux ships with Python 3, so no bootstrap needed. No subscription required.

## VM (unifi)

The `virtualization` role runs on the lab server and uses Terraform (`dmacvicar/libvirt` provider v0.7.6) to provision a KVM VM via libvirt. Terraform state lives at `/var/lab/terraform/unifi/`. Cloud-init handles static IP config (netplan, interface `enp0s3`), user creation, and SSH key injection. The lab server's own SSH key (`~/.ssh/id_ed25519`) is generated by the role and injected into the VM so Ansible can poll `cloud-init status --wait` after provisioning.

The `unifi` role then runs against the VM directly to install UniFi OS Server.

## Jellyfin

The `jellyfin` role runs on the lab server. `jellyfin-nginx` (TLS termination) has a macvlan IP on `marisol0` (`jellyfin_ip`, 10.47.2.6) plus a private `jellyfin-internal` bridge network (172.16.1.0/24); the `jellyfin` container itself only sits on `jellyfin-internal` (172.16.1.2) and is reached via nginx's `proxy_pass`. The `podman` role puts the `jellyfin-br0` bridge interface in its own firewalld zone (`containers`) with a `containers-to-inet` policy so the bridge's containers get masqueraded internet access.

`jellyfin-internal` is IPv4-only — no AAAA/IPv6 route. Because metadata providers (TMDb, OMDb, etc.) are dual-stack, the jellyfin container needs `DOTNET_SYSTEM_NET_DISABLEIPV6=1` set; otherwise .NET's Happy Eyeballs connection logic races the unreachable IPv6 address and metadata lookups fail with `SocketException: Resource temporarily unavailable` instead of falling back to the working IPv4 path.

The media library is NFS-mounted from the NAS (`nfs-media` role) and bind-mounted into the container at `/media`. The shares are **systemd automounts** (`x-systemd.automount`, `_netdev,nofail`): nothing mounts at boot, the first access triggers the mount, and a failed attempt errors after `nfs_mount_timeout` (30s, `x-systemd.mount-timeout`), so an unreachable NAS can't block boot or the host. Soft mounts with `timeo=50,retrans=3` make I/O on an established mount fail after a few seconds rather than hang.

The mounts use the NAS **IP**, not `nas.marisol.home`: marisol-view DNS is served by pihole/unbound containers on this same host, which start after the mounts are first attempted at boot, so a hostname source can fail to resolve. The jellyfin bind mount of `/media` uses `propagation: rslave`; with the default private propagation the container never sees an NFS mount made on top of the autofs after it started (it gets an empty directory and "Operation not permitted"). `jellyfin.service` is ordered `After=remote-fs.target` so the automount points exist when the container is created. Symptom of a broken mount: jellyfin healthy, libraries empty, `Could not find file '/media/...'` errors; check `findmnt /media/movies` and `systemctl status media-movies.automount` on lab.

`x-systemd.mount-timeout` only takes effect on `/etc/fstab` entries (via the fstab generator), not on transient units made with `systemd-mount`.

Each compose stack in `/var/lab/compose/` (pihole, unbound, monitoring, jellyfin) sets its own top-level `name:`, so each gets its own podman project and pod (`pod_<name>`). Without it podman-compose falls back to the directory basename, so every stack became project `compose` / `pod_compose`: at boot they raced to create the shared pod (`no pod with name or ID pod_compose found`), and one stack's `down` could remove another's freshly created containers. All volumes and networks are explicitly named or `external`, so the project name doesn't change any data or network names.

## CA certificate

`files/marisol.crt` (playbook-level) is the shared internal CA cert. Roles reference it as `src: marisol.crt` (copy module) or `lookup('file', playbook_dir + '/files/marisol.crt')` (pihole). It is deployed to the system trust store on Fedora (`update-ca-trust`), Ubuntu (`update-ca-certificates`), and Raspberry Pi OS (`update-ca-certificates`).

## Monitoring

The `monitoring` role runs Grafana (192.168.1.7) and Prometheus (192.168.1.8) as containers on the lab host. The `node-exporter` role deploys the Prometheus node exporter on all managed Linux hosts (lab, unifi, rhel8, rhel9, ol9).

## Gateway

The `gateway-network` role syncs `/etc/hostname.*` files from `roles/gateway-network/files/` and reboots if anything changed. `become_method` is `doas` (not sudo) for the gateway — set in `group_vars/gateway/vars.yml`.

## Switch

`nas` (TrueNAS Scale, 192.168.1.4) is not automated at all. The switch, however, is
partially automated: `terraform/switch/` manages it directly (VLANs, interface
descriptions, LAG membership, system/NTP/syslog settings, management SVI) via the
`CiscoDevNet/iosxe` Terraform provider over NETCONF/RESTCONF — it isn't run from an
Ansible playbook. See `terraform/switch/README.md` for what's managed, what IOS-XE
16.12/provider limitations force to stay manual (switchport mode, PoE, DNS servers),
and how to run `terraform apply` against it.
