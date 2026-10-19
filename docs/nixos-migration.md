# Lab host: Fedora → NixOS migration plan

_Status: proposed, 2026-10-19._

## Summary and scope

Replace Fedora 44 on the lab host (192.168.1.3) with NixOS, declared as `nixosConfigurations.lab` in this repo's existing `flake.nix`, with secrets in sops-nix. Only the base OS under the VMs changes. Every VM keeps its OS, IP and MAC, and keeps being configured by its current Ansible play.

**Changes:** the first play in `lab.yml` (`hosts: lab`, 15 roles) gets smaller. Twelve roles become NixOS modules, deployed with `nixos-rebuild switch --flake .#lab --target-host lab`. `virtualization`, `rhel-vms` and `ubuntu-vms` stay in Ansible. Only `virtualization` loses tasks (its package installs); the other two run unchanged.

**Stays as-is:**

- `lab.yml` plays 2–5 (unifi, rhel, ol, ubuntu). They SSH straight to the VMs and don't care what lab runs.
- `gateway.yml`, `pi.yml`, and ansible-vault for those hosts.
- The Terraform definitions for the unifi, RHEL/OL and Ubuntu VMs.

**Done when:**

- All three VLAN bridges (`management0`, `marisol0`, `iot0`) and the `mgmt0-shim` come up on boot.
- Pihole (×3), unbound (×3), jellyfin + nginx, grafana, prometheus and pihole-exporter answer on their current IPs.
- `/media/*` automounts from the NAS, and jellyfin transcodes with VA-API.
- All six VMs boot, keep their IPs, and `terraform plan` shows no changes.
- `ansible-playbook lab.yml --limit unifi,rhel,ol,ubuntu` runs clean.
- A rebuild from a clean checkout reproduces the host.
- Terraform state is copied to the NAS every night.

## Target design

Nix owns the host: packages, network, services and containers. A slimmed Ansible play keeps the VM provisioning roles, because they template Terraform with vault secrets and wait on cloud-init, and they work the same against NixOS.

```
                   nixos-rebuild + sops-nix   ┌──────────────────────────────────────┐
              ┌──────────────────────────────▶│ lab (NixOS)                          │
              │                               │ network, podman containers, NFS,     │
┌───────────────────────┐                     │ libvirtd, terraform, node-exporter   │
│ Controller (this repo)│                     └──────────────────┬───────────────────┘
│ flake.nix, sops       │                                        ┆ runs on
│ playbooks, ans-vault  │  Ansible: Terraform, plays 2–5  ┌──────┴───────────────────────┐
└───────────────────────┘────────────────────────────────▶│ Six KVM VMs                  │
              │                                           │ unifi, rhel8/9, ol9,         │
              │                                           │ bionic, focal                │
              │                                           └──────────────────────────────┘
              │   Ansible + vault (unchanged)             ┌──────────────────────────────┐
              └──────────────────────────────────────────▶│ gateway (OpenBSD), pihole2   │
                                                          └──────────────────────────────┘
```

**Flake layout** (added to the existing `flake.nix`; the dev shell stays as it is):

```
flake.nix                  # + nixosConfigurations.lab; inputs: nixpkgs (stable), sops-nix, disko
.sops.yaml                 # age recipients: your key + lab's host key
hosts/lab/
  default.nix              # imports, users, ssh, CA cert, auto-upgrade policy
  hardware-configuration.nix
  disko.nix                # disk layout for nixos-anywhere
  networking.nix           # bridges, VLANs, mgmt0-shim, nftables
  podman.nix               # podman, macvlan networks, jellyfin-internal bridge
  containers/
    pihole.nix  unbound.nix  jellyfin.nix  monitoring.nix
  media.nix                # NFS automounts, VA-API
  virtualization.nix       # libvirtd, terraform, node-exporter
  backup.nix               # nightly Terraform state copy to the NAS
secrets/lab.yaml           # sops-encrypted
```

**Pin the host to a stable channel** (e.g. `nixos-26.05`), not the dev shell's `nixos-unstable`. That way updates land when you bump `flake.lock`, not every time you rebuild.

**Deploys:** run `nixos-rebuild switch --flake .#lab --target-host lab --use-remote-sudo` from the controller. One NixOS host doesn't need colmena or deploy-rs. Add one later if pihole2 moves to NixOS too.

**Secrets:**

- Move `pihole_password` and the pihole, jellyfin and grafana TLS keys into `secrets/lab.yaml`.
- They're decrypted at activation to `/run/secrets/*` (mode 0400, owned by the service that needs them).
- Containers get them through `environmentFiles` or bind mounts of `config.sops.secrets.<name>.path`. Never use a `./file` path literal, which would copy the secret into the world-readable `/nix/store`.
- The age recipient for lab is its SSH host key (`ssh-to-age`). Because nixos-anywhere regenerates that key, pre-generate it and pass it with `--extra-files`.
- `vm_console_password` stays in ansible-vault, since only the Terraform templates use it.

**Remaining Ansible play on lab** (`hosts: lab`): `virtualization`, `rhel-vms`, `ubuntu-vms` (see [VM provisioning flow](architecture.md#vm-provisioning-flow)). Remove the dnf, HashiCorp-repo and libvirtd-enable tasks from `virtualization`, which Nix now owns; `rhel-vms` and `ubuntu-vms` have no package tasks and need no changes. Set `ansible_python_interpreter: /run/current-system/sw/bin/python3` in `host_vars/lab`.

**Terraform state backup (new).** Keeping VM state on lab is deliberate: any controller can run the playbooks, and the state can never drift away from the libvirt it describes. But today it's a single unbacked copy, and if it's lost, Terraform tries to recreate VMs that already exist. `backup.nix` adds:

- A `fileSystems` NFS automount of a NAS backup share (same options as the media mounts, by IP).
- A `lab-state-backup` oneshot service that `rsync -a`s `/var/lab/terraform/` into a dated directory on that share and keeps the last 14.
- A `systemd.timers.lab-state-backup` running nightly with `Persistent = true`, so a missed run catches up after a reboot.

It covers only Terraform state. VM disks and podman volumes are too large for a nightly copy, and the repo regenerates everything else.

## Role mapping

Twelve of the 15 roles in the lab play map directly onto NixOS options. Most of the work is in networking and the four container stacks. `pi.yml` and the VM plays still use `system-setup`, `podman`, `pihole`, `unbound-container` and `node-exporter`, so those roles stay in the repo.

| Role | NixOS replacement | Module | Effort | Notes |
| --- | --- | --- | --- | --- |
| `system-setup` | `security.pki.certificateFiles = [ ../../files/marisol.crt ]`; updates by bumping `flake.lock` | `default.nix` | Low | The CA cert is public, so a path literal is fine. Reboots after kernel updates are manual or via `system.autoUpgrade.allowReboot` |
| `user-setup` | `users.users.<you>` with SSH keys; `programs.tmux.extraConfig`, vim config from `_tmux.conf`/`_vimrc` | `default.nix` | Low | |
| `bridge-networking` | `systemd.network`: netdevs `management0`, `vlan2`, `marisol0`, `vlan3`, `iot0`, `mgmt0-shim` (macvlan, 192.168.1.10); static IPs .3 on each VLAN | `networking.nix` | High | Hard-code the NIC name, which removes the keyfile-sniffing logic. Set `networking.useNetworkd = true` and disable NetworkManager |
| `podman` | `virtualisation.podman`; `containers.registries` | `podman.nix` | Medium | Rewrite the firewalld `containers` zone and `containers-to-inet` policy as nftables masquerade for `jellyfin-br0` (172.16.1.0/24) |
| `podman-macvlan` | oneshot `systemd.services.podman-net-*` running `podman network create -d macvlan` for the three networks; `Before=` the container units | `podman.nix` | Medium | Same subnets, gateways and parents as `roles/podman-macvlan/defaults/main.yml` |
| `pihole` | 3× `virtualisation.oci-containers.containers.pihole-*` with `--network=lab-*-macvlan --ip=` .5 on each VLAN | `containers/pihole.nix` | Medium | The password comes from sops via `environmentFiles`. The first-run sentinel can go if the password is set through the env var |
| `nfs-media` | `fileSystems."/media/{movies,shows,home-movies}"` with the same NFS options incl. `x-systemd.automount` | `media.nix` | Low | Keep the NAS IP (192.168.1.4), not the hostname |
| `va-api` | `hardware.graphics.enable = true` (mesa VA-API drivers included); `libva-utils` in `systemPackages` | `media.nix` | Low | Pass `/dev/dri` into the jellyfin container |
| `jellyfin` | oci-containers `jellyfin` (172.16.1.2 on `jellyfin-internal`) + `jellyfin-nginx` (10.47.2.6 marisol, 192.168.1.6 management) | `containers/jellyfin.nix` | Medium | Keep `rslave` on `/media` and `After=remote-fs.target`. The TLS key comes from sops |
| `virtualization` | `virtualisation.libvirtd.enable`; `terraform` + `genisoimage` in `systemPackages`; user in `libvirtd` group | `virtualization.nix` | Low | The Terraform/cloud-init tasks stay in Ansible |
| `node-exporter` | `services.prometheus.exporters.node.enable` | `virtualization.nix` | Low | Same port (9100) so prometheus scrape config is unchanged |
| `monitoring` | oci-containers `grafana` (192.168.1.7), `prometheus` (.8), `pihole-exporter` (.9) | `containers/monitoring.nix` | Medium | Render `prometheus.yml` and the datasource file with `pkgs.writeText`; the Grafana TLS key comes from sops |
| `unbound-container` | Build the Alpine image from `Containerfile` with a oneshot `podman build`, or replace it with `dockerTools.buildImage`; 3× containers at .254 | `containers/unbound.nix` | Medium | Native `services.unbound` doesn't fit, since it needs three macvlan IPs |
| `rhel-vms` | stays Ansible | | None | No changes; Terraform still runs on lab via Ansible |
| `ubuntu-vms` | stays Ansible | | None | No changes; Terraform still runs on lab via Ansible |

**Containers: oci-containers vs. compose.** `oci-containers` gives each container its own systemd unit and makes the config fully declarative. The cheaper first pass is to keep the four compose files (rendered with `pkgs.writeText`) and wrap them in the same oneshot units you have now, using `podman-compose` from nixpkgs. That's a good stepping stone if you want the host up quickly.

## State to back up and restore

The reinstall wipes the disk. Copy the following off the host (to the NAS) before Phase 3. Nothing else on lab holds state that the repo can't regenerate.

| Item | Path / source | Backup command | Restore | If lost |
| --- | --- | --- | --- | --- |
| Terraform state (unifi, rhel, ubuntu) | `/var/lab/terraform/` | `rsync -a` | Copy back to the same path before any Ansible run | Terraform would try to recreate all six VMs. **Critical** |
| VM disks + base images | `/var/lib/libvirt/images/` | Shut VMs down, then `rsync -aS` (sparse) | Copy back to the same path; same pool name `default` | VMs must be rebuilt from scratch |
| libvirt domain definitions | `virsh dumpxml <vm>` for all six | dump to files | Let `terraform apply` recreate the domains over the existing volumes (see Risks) | Recoverable via Terraform |
| Pihole config (×3) | podman volumes `pihole-{management,marisol,iot}-etc` | `podman volume export` | `podman volume import` before first container start | Lose gravity lists, local DNS entries, settings |
| Jellyfin config | podman volume `jellyfin-config` | `podman volume export` | `podman volume import` | Lose libraries, users, watch history |
| Grafana data | podman volume `grafana-data` | `podman volume export` | `podman volume import` | Lose dashboards not provisioned from the repo |
| Prometheus TSDB | podman volume `prometheus-data` | `podman volume export` (optional) | `podman volume import` | Lose metric history only |
| SSH host keys | `/etc/ssh/ssh_host_*` | copy | Pass to nixos-anywhere via `--extra-files` | Every client sees a host-key warning, and the sops recipient changes |
| Lab user's SSH key | `~/.ssh/id_ed25519*` | copy | Restore to the same path | The `virtualization` role makes a new one; the existing VMs won't trust it |

You don't need to back up the jellyfin cache volume, `/var/lab/{compose,conf,certs,unbound}` (all generated), or the pihole password sentinels. With volume names unchanged, the restored data just works.

## Phases

Six phases. Only Phase 3 means downtime, and everything before it happens on a branch while Fedora keeps running.

1. **Write the config (branch `nixos-lab`).**
    - Add `sops-nix` and `disko` inputs plus `nixosConfigurations.lab`. Create `.sops.yaml` with your age key and a pre-generated lab host key.
    - On Fedora, record the facts you'll hard-code: NIC name (`ip -br link`), disk (`lsblk`), GPU render node (`ls /dev/dri`), and the current macvlan MAC for `jellyfin-nginx` (`02:42:c0:a8:01:06`).
    - Port modules in this order: `default.nix` → `networking.nix` → `podman.nix` → containers → `media.nix` → `virtualization.nix`.
    - Move `pihole_password` and the three TLS keys into `secrets/lab.yaml` (`ansible-vault view` → `sops`).
    - **Exit:** `nix flake check` passes and `nixos-rebuild build --flake .#lab` succeeds.
2. **Test in a VM.**
    - `nixos-rebuild build-vm --flake .#lab` is good for checking eval, users, sops decryption and unit ordering. It can't exercise the real VLAN trunk.
    - For networking, make a throwaway libvirt VM on lab attached to `management0`, deploy the config with interface names overridden, and check that the bridges, VLANs and a macvlan container come up.
    - **Exit:** every systemd unit active, pihole answers on a test IP, sops secrets present with correct modes.
3. **Back up and install (downtime starts).**
    - Do the cutover prep (below), then shut down all six VMs.
    - Take every backup in the table above and verify you can read them on the NAS.
    - Run `nixos-anywhere --flake .#lab --generate-hardware-config nixos-generate-config hosts/lab/hardware-configuration.nix --extra-files <dir with ssh host keys> root@192.168.1.3`. Commit the generated hardware config.
    - **Exit:** lab boots NixOS and you can SSH in at 192.168.1.3.
4. **Restore and first deploy.**
    - Restore `/var/lab/terraform`, `/var/lib/libvirt/images`, the lab user's SSH key, and the podman volumes. Import the volumes before the container units first start, or stop them, import, then start.
    - `nixos-rebuild switch --flake .#lab --target-host lab`.
    - `ansible-playbook lab.yml --limit lab` (only the three VM roles are left). `terraform plan` should show no changes, then apply.
    - **Exit:** all six VMs running at their IPs.
5. **Verify (downtime ends).**
    - Work through the "Done when" list in Summary and scope.
    - Spot checks: `dig @192.168.1.5`, `@10.47.2.5`, `@10.47.3.5` and the three `.254` unbound IPs; jellyfin playback with a transcode (`vainfo` on the host); Grafana dashboards populated; `findmnt /media/movies`.
    - Reboot lab once, and confirm everything returns with no manual steps.
    - Run `systemctl start lab-state-backup` and confirm the copy landed on the NAS. `systemctl list-timers` should show the next run.
    - Run `ansible-playbook lab.yml --limit unifi,rhel,ol,ubuntu` clean.
6. **Repo cleanup (squash-merge `nixos-lab`).**
    - Delete roles only the lab play used: `bridge-networking`, `podman-macvlan`, `nfs-media`, `va-api`, `jellyfin`, `monitoring`, `user-setup`. Keep `podman`, which `pi.yml` still uses.
    - Remove the lab entries from `group_vars/lab/vault.yml` that moved to sops. Delete `roles/pihole/files/pihole.key`, `roles/jellyfin/files/jellyfin.key` and `roles/monitoring/files/grafana.key`.
    - Update the `CLAUDE.md` host table, run commands and tag list, and the network/jellyfin/monitoring/VM sections of `docs/architecture.md`.

## Cutover and rollback

DNS keeps working through the cutover, because DHCP already hands out pihole2 as the second resolver on each VLAN (`roles/dhcpd/defaults/main.yml`). Everything else hosted on lab is down from VM shutdown in Phase 3 until Phase 4 is done.

**Down during the window:**

- Primary pihole (.5 on all three VLANs) and the backup unbound (.254). Clients fall back to pihole2 (.251), but some stall for a few seconds per lookup first.
- Jellyfin, Grafana, Prometheus (a gap in metrics).
- UniFi controller. APs and switches keep forwarding traffic; you just can't manage them.
- rhel8, rhel9, ol9, bionic, focal.

The gateway's unbound and dhcpd don't depend on any lab IP, so routing and DHCP stay up.

**Prep, the day before:**

- [ ] Optional: put pihole2 first in `roles/dhcpd/defaults/main.yml` and run `ansible-playbook gateway.yml --tags dhcpd`, so clients that renew leases skip the stall. Revert after Phase 5.
- [ ] Confirm pihole2 has the same local DNS records as lab's pihole.
- [ ] Take a UniFi backup (`.unf`) from the controller UI, as a backup for the VM disk backup.
- [ ] Have a NixOS installer USB on hand.

**Rollback:**

- **Before Phase 3:** nothing to roll back. Fedora is untouched.
- **After install, config problem:** fix it and redeploy, or boot an earlier generation from the boot menu.
- **After install, unrecoverable** (hardware or network won't come up): reinstall Fedora 44 from USB, restore `/var/lab/terraform` and `/var/lib/libvirt/images`, and run `ansible-playbook lab.yml` from `main`. Every Fedora role still exists on `main` until Phase 6 merges, so `main` stays the rollback path. Keep the backups until the NixOS host has run cleanly for at least two weeks.

## Risks and open questions

The biggest risk is a networking change that locks you out of a headless host. Use `nixos-rebuild test` for any change to `networking.nix`: it activates without making the new config the boot default, so a reboot recovers.

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Bad bridge/VLAN config cuts SSH | Host unreachable | `nixos-rebuild test` first; keep a monitor and keyboard (or IPMI) available during Phase 3–4 |
| Restored libvirt XML points at Fedora's `/usr/bin/qemu-kvm` | VMs won't start | Don't `virsh define` the old XML. Let `terraform apply` recreate the domains over the restored disks, since NixOS uses its own emulator path |
| UEFI VMs reference Fedora OVMF paths | VMs won't boot | Check `virsh dumpxml` for `<loader>`. Set `virtualisation.libvirtd.qemu.ovmf` and recreate via Terraform |
| netavark and the NixOS nftables firewall conflict | Containers lose outbound or macvlan traffic | Use `networking.nftables.enable = true` with netavark's nftables driver; test in Phase 2 |
| Macvlan networks drift (created imperatively) | Container units fail on boot | Oneshot units guarded by `podman network exists`, ordered `Before=` every container unit |
| sops can't decrypt on the new host | Pihole, jellyfin and grafana fail to start | Pre-generate the host key; pass it with `--extra-files`; check in Phase 2 |
| Terraform is unfree in nixpkgs | Build fails | Use the same `allowUnfreePredicate` as the dev shell in the host's nixpkgs config |
| Jellyfin role's SELinux tasks | None on NixOS | Drop them; `:Z` mount flags are harmless with no SELinux |

**Open questions:**

- [ ] Is the VM image store on its own disk or partition? If so, `disko` can leave it alone, which saves the `rsync` and a restore step.
- [ ] Which GPU does lab have? `mesa-va-drivers` suggests AMD (radeonsi); Intel would need `intel-media-driver`.
- [ ] First pass with oci-containers, or keep compose files wrapped in systemd units and convert later?
- [ ] Do you have console access (monitor/keyboard or IPMI) for the install window?
- [ ] Should updates be manual (`nix flake update` + deploy) or `system.autoUpgrade` from the repo?
- [ ] Which NAS share should the Terraform state backup go to? It needs a dataset exported to 192.168.1.3 with write access, e.g. `/mnt/tank/backups/lab`.
- [ ] Should the three VM-provisioning roles stay in Ansible long term, or should Terraform move into Nix too?

## Alternative considered: GNU Guix

Guix System was considered and rejected. It is declarative like NixOS, so the plan's shape carries over, but most of the pieces this host needs are missing or less mature. Expect roughly twice the effort, most of it in hand-written Scheme services. Findings as of 2026-10-19:

| Area | Guix situation | Effect on this plan |
| --- | --- | --- |
| Init | Shepherd, not systemd. No oneshot units, `Before=`/`After=` ordering, systemd timers or automounts | Every custom unit, the macvlan network setup and the backup timer become Scheme services or mcron jobs. The NFS automounts and `After=remote-fs.target` ordering need rework |
| Networking | `static-networking` documents VLANs and bonds. In 2023, bridges weren't supported by guile-netlink, the library underneath ([help-guix](https://lists.nongnu.org/archive/html/help-guix/2023-03/msg00236.html)); there's also a VLAN hang bug ([#68595](https://issues.guix.gnu.org/68595)) | The three bridges, two VLANs and `mgmt0-shim` likely need a custom service running `ip link`. This is the riskiest piece |
| Containers | The older container service is Docker-only. A proposed replacement handles podman, networks and volumes, but only rootless podman ([design](https://fishinthecalculator.me/blog/declarative-transactional-cloud-native-oci-provisioning-with-guix.html), [#76081](https://issues.guix.gnu.org/76081)) | Rootful podman with macvlan IPs means hand-written services that call `podman` |
| Secrets | [sops-guix](https://fishinthecalculator.me/blog/secrets-management-with-sops-guix.html), a third-party add-on modelled on sops-nix | Workable; it's maintained by one person |
| Firmware | Kernel ships with non-free firmware removed; non-free packages are excluded | NIC and GPU firmware (VA-API) likely need the unofficial [nonguix](https://gitlab.com/nonguix/nonguix) channel |
| Terraform | Not packaged (BSL licence isn't free software); OpenTofu packaging unconfirmed | Install a binary by hand or run it in a container. State can still live on lab |
| Install | No `nixos-anywhere`/`disko` equivalent; installer + `guix system init`, then `guix deploy` | Manual install; the controller also needs Guix installed |

Guix becomes worth revisiting if its rootful podman support, bridge networking and Terraform/OpenTofu packaging mature, or if a fully free system becomes a goal in its own right.
