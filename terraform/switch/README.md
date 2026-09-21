# Cisco Switch Terraform Config

Manages the Cisco Catalyst WS-C3650-48PS (`switch`, `192.168.1.253`) via the
[CiscoDevNet/iosxe](https://registry.terraform.io/providers/CiscoDevNet/iosxe/latest)
Terraform provider using NETCONF/RESTCONF.

## What is managed

- **VLANs** — 2 (Marisol), 3 (Marisol-IOT), 4 (Marisol-Work), 5 (Kirkwood)
- **Interface descriptions** — all active trunk, access and LAG member ports (Gi1/0/1 PiHole2, Gi1/0/2 Lab, Gi1/0/3 Office Uplink, Gi1/0/4 TrueNAS, Gi1/0/5–6 Proxmox, Gi1/0/13–16 LAG, Gi1/0/21–24 APs)
- **LAG membership** — Gi1/0/13–16 as LACP active members of Port-channel1
- **System** — hostname, domain name, default gateway
- **NTP** — gateway (192.168.1.1)
- **Syslog** — gateway (192.168.1.1)
- **Management SVI** — Vlan1 (192.168.1.253/24)

## Known limitations (IOS-XE 16.12 / provider v0.17)

- **Switchport mode** (`switchport mode trunk/access`) — `iosxe_interface_switchport`
  is not compatible with IOS-XE 16.12. Configure manually.
- **PoE** (`power inline never/static`) — not in the provider schema. Configure manually.
- **DNS name servers** (`ip name-server`) — YANG path incompatible with IOS-XE 16.12.
  Configure manually: `ip name-server 192.168.1.5 192.168.1.251`
- **VLANs need VTP transparent mode** — in VTP server mode (the IOS default) VLANs
  live in `vlan.dat`, not the running config, and the native YANG model returns no
  `vlan-list`, so Terraform can't read them (`terraform import` reports "non-existent
  remote object"). Set `vtp mode transparent`; see the prerequisites below.
- **Don't `terraform import` these resources** — on import the provider fills every
  boolean attribute with `false`, but the config leaves them null, so `plan` shows ~60
  `false -> null` changes per interface. Applying them fails on 16.12 with
  `unknown-element` errors (`vpn-id`, `recursive`, `periodic`, `count`). Adopt existing
  switch config with `apply` instead — see [State](#state).

## Manual configuration (not managed by Terraform)

These must be configured by hand due to provider/IOS-XE 16.12 limitations.

### Switchport mode (all trunk ports)

```
conf t
interface range GigabitEthernet1/0/1-4, GigabitEthernet1/0/13-16, GigabitEthernet1/0/21-24, Port-channel1
 switchport mode trunk
end
```

> `Gi1/0/2` is the lab server.

### Access port VLAN assignment

```
conf t
! Proxmox: one NIC per VLAN, separate cables
interface GigabitEthernet1/0/5
 switchport mode access
 switchport access vlan 1

interface GigabitEthernet1/0/6
 switchport mode access
 switchport access vlan 2

interface range GigabitEthernet1/0/25-28
 switchport mode access
 switchport access vlan 2

interface range GigabitEthernet1/0/29-32
 switchport mode access
 switchport access vlan 3

interface range GigabitEthernet1/0/33-36
 switchport mode access
 switchport access vlan 4
end
```

### PoE settings

```
conf t
! Disable PoE on non-AP trunk ports and LAG members
interface range GigabitEthernet1/0/1-4, GigabitEthernet1/0/13-16
 power inline never

! Enable PoE on AP ports
interface range GigabitEthernet1/0/21-24
 power inline static
end
```

### Spanning tree (PortFast on host-facing trunk ports)

The switch runs rapid-pvst with PortFast off by default. Hosts that don't speak STP never answer the switch's rapid-PVST handshake (`show spanning-tree interface ... detail` shows `BPDU: received 0`), so the port fell back to the 30s listening/learning timers after every host reboot or link-up. The lab server's Linux bridges have STP disabled (`stp=false` in the `bridge-networking` role); the Pi has no bridge on `eth0` at all. During that window containers couldn't reach the gateway's DNS (pihole's NTP lookup failed at startup and retried 10 minutes later) and the host was unreachable for ~30s after its link came up.

```
conf t
interface GigabitEthernet1/0/2
 spanning-tree portfast trunk
interface GigabitEthernet1/0/1
 spanning-tree portfast trunk
interface GigabitEthernet1/0/4
 spanning-tree portfast trunk
end
write memory
```

`Gi1/0/2` is `lab`, `Gi1/0/1` is PiHole2 and `Gi1/0/4` is TrueNAS. Only safe because each is a single host's uplink: PortFast on a port that can bridge back into the switch risks a loop. Verify with `show spanning-tree interface Gi1/0/2 portfast`. After enabling it on `Gi1/0/2`, the piholes on `lab` resolved and synced NTP on their first attempt at startup; on `Gi1/0/1`, SSH to the Pi came back at 25s of uptime instead of ~45s and pihole's startup DNS lookups succeeded. `Gi1/0/4` (TrueNAS) was enabled the same way but its effect after a NAS reboot hasn't been measured.

The Pi has no RTC, so its clock is stepped by `systemd-timesyncd` ~70s after boot; a pihole whose NTP samples straddle that step logs `Standard deviation of time offset is too large` and retries 10 minutes later. Harmless (DNS is unaffected), and separate from the network delay above.

### Trunk allowed VLANs (TrueNAS)

The NAS is deliberately reachable only on VLANs 1 (management) and 2 (Marisol), and must not be reachable from VLANs 3–5. It has interfaces on VLANs 1 and 2 only, so hosts on those VLANs reach it directly at layer 2 (`192.168.1.4` on VLAN 1). The gateway's `pf.conf` blocks routing between VLANs, so there is no routed path to it either. Restricting the trunk makes the rule switch-enforced: even if a NAS interface were ever added on VLAN 3, 4 or 5, the switch would drop those frames.

```
conf t
interface GigabitEthernet1/0/4
 switchport trunk allowed vlan 1,2
end
write memory
```

Keep VLAN 1: it's the native VLAN and carries the NAS's management address. Use the replace form above, not `allowed vlan add`, which would leave the port unrestricted. Verify with `show interfaces trunk` (`Gi1/0/4` should show `1-2`). All other trunks are left at the default allow-all.

### Manual settings are invisible to Terraform

PortFast and trunk allowed VLANs are not in the `.tf` files, and the provider ignores attributes that aren't configured, so these hand-applied settings don't show up as drift and `terraform apply` won't remove them (`terraform plan` reports `No changes` with all of the above applied). After any manual switch edit, run `terraform plan` and expect `No changes`.

### Users and SSH access

**1. Create the local user and set the enable secret.**
The user is created at privilege 15: Terraform logs in as this user over NETCONF/RESTCONF, and IOS-XE expects privilege 15 for both. Use `secret` (not `password`) for both the user and the enable secret — it stores a hash rather than reversible ciphertext.

```
conf t
username brian privilege 15 secret <login-password>
enable secret <enable-password>
end
```

**2. Generate the RSA host key and enable SSHv2.**

```
conf t
crypto key generate rsa modulus 2048
ip ssh version 2
line vty 0 15
 login local
 transport input ssh
end
```

**3. Upload the RSA public key.**
Strip the `ssh-rsa ` prefix and trailing comment from the public key — paste the base64 body only. IOS accepts at most 254 characters per line; split the key across two lines at any character boundary.

```
conf t
ip ssh pubkey-chain
 username brian
  key-string
   <public-key-string-line-1>
   <public-key-string-line-2>
  exit
 exit
end
```

**4. Verify the key was accepted.**
IOS silently discards a malformed key, so always check:

```
show running-config | section pubkey-chain
```

The output should show the key-string lines you entered. If the section is empty, the key was rejected — re-enter it.

```
write memory
```

## Prerequisites for a new switch

Before running `terraform apply`, the switch needs to be bootstrapped manually:

```
! Enable HTTPS (required for RESTCONF)
ip http secure-server

! Enable RESTCONF
restconf

! Enable NETCONF (required by the iosxe Terraform provider)
netconf-yang

! Set DNS servers (not manageable via Terraform on IOS-XE 16.12)
ip name-server 192.168.1.5 192.168.1.251

! Keep VLANs in the running config so Terraform can see them (default is
! server mode, which keeps them in vlan.dat only)
vtp mode transparent

! Save config
write memory
```

Verify RESTCONF is working (prompts for the password; expect `200 OK`):
```bash
curl -ksSi -u brian https://192.168.1.253/restconf/data/Cisco-IOS-XE-native:native/hostname \
  -H 'Accept: application/yang-data+json'
```

## Running Terraform

The login is the `brian` account (privilege 15). The username defaults to `brian`;
set the password without echoing it, so it stays out of shell history:

```bash
cd terraform/switch
read -rs TF_VAR_switch_password; export TF_VAR_switch_password
terraform init
terraform plan
terraform apply
```

## State

Terraform state is local (`terraform.tfstate`). Not committed to git — state files,
backups and saved plans (`tfplan`, which embeds the switch password) are in `.gitignore`.

### Rebuilding state after loss

Adopt the existing switch config with `apply`, not `terraform import` (see the
limitations above). A create sends only the attributes set in the `.tf` files, as a
merge onto config that already matches, so it's a no-op on the switch.

1. Check the config actually matches the switch before creating anything — a create
   *adds* whatever the `.tf` files say, so drift becomes a real change. In particular
   compare `trunks.tf` with `show etherchannel summary` (LAG members) and
   `show interfaces status` (descriptions, port roles).
2. Confirm VTP is transparent (`show vtp status`) and Terraform can log in
   (`TF_VAR_switch_username` / `TF_VAR_switch_password`).
3. Read `terraform plan` — it should be all `create`, with only `type`, `name` and
   the attributes you set. Then apply in small `-target` batches, LAG members first
   and one at a time, checking `show etherchannel summary` between them.
4. Run `terraform plan` again; expect `No changes`.

If a resource's port (`name`) changes in the config, remove it from state first
(`terraform state rm <addr>`): otherwise the provider plans a replace, which deletes
the old port's config.
