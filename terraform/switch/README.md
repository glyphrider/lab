# Cisco Switch Terraform Config

Manages the Cisco Catalyst WS-C3650-48PS (`switch`, `192.168.1.253`) via the
[CiscoDevNet/iosxe](https://registry.terraform.io/providers/CiscoDevNet/iosxe/latest)
Terraform provider using NETCONF/RESTCONF.

## What is managed

- **VLANs** — 2 (Marisol), 3 (Marisol-IOT), 4 (Marisol-Work), 5 (Kirkwood)
- **Interface descriptions** — all active trunk and LAG member ports (Gi1/0/1 PiHole2, Gi1/0/2 Lab, Gi1/0/3 Office Uplink, Gi1/0/4 TrueNAS, Gi1/0/13–19 LAG, Gi1/0/14–20 APs)
- **LAG membership** — Gi1/0/13, 15, 17, 19 as LACP active members of Port-channel1
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

## Manual configuration (not managed by Terraform)

These must be configured by hand due to provider/IOS-XE 16.12 limitations.

### Switchport mode (all trunk ports)

```
conf t
interface range GigabitEthernet1/0/1-4, GigabitEthernet1/0/13-20, Port-channel1
 switchport mode trunk
end
```

> `Gi1/0/2` is the lab server.

### Access port VLAN assignment

```
conf t
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
interface range GigabitEthernet1/0/1-4, GigabitEthernet1/0/13, GigabitEthernet1/0/15, GigabitEthernet1/0/17, GigabitEthernet1/0/19
 power inline never

! Enable PoE on AP ports
interface range GigabitEthernet1/0/14, GigabitEthernet1/0/16, GigabitEthernet1/0/18, GigabitEthernet1/0/20
 power inline static
end
```

### Users and SSH access

**1. Create the local user and set the enable secret.**
The user is created at privilege 1 (unprivileged). `enable` will prompt for the enable secret to reach the `#` prompt. Use `secret` (not `password`) for both — it stores a bcrypt hash rather than reversible ciphertext.

```
conf t
username brian privilege 1 secret <login-password>
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

! Save config
write memory
```

Verify RESTCONF is working:
```bash
curl -k -u admin:password https://192.168.1.253/restconf/data/Cisco-IOS-XE-native:native/hostname
```

## Running Terraform

```bash
cd terraform/switch
terraform init
terraform plan  -var="switch_password=yourpassword"
terraform apply -var="switch_password=yourpassword"
```

The password can also be set via environment variable to avoid the prompt:
```bash
export TF_VAR_switch_password=yourpassword
terraform apply
```

## State

Terraform state is local (`terraform.tfstate`). Not committed to git —
`*.tfstate*` should be in `.gitignore`.
