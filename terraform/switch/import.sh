#!/usr/bin/env bash
# Run this to reconstruct Terraform state after state loss.
# Requires: switch reachable, TF_VAR_switch_password set (or enter manually per prompt)
#
# Usage: bash import.sh

set -e

cd "$(dirname "$0")"

# VLANs
terraform import iosxe_vlan.marisol      2
terraform import iosxe_vlan.marisol_iot  3
terraform import iosxe_vlan.marisol_work 4
terraform import iosxe_vlan.kirkwood     5

# Trunk interfaces
terraform import iosxe_interface_ethernet.pihole2      "GigabitEthernet 1/0/1"
terraform import iosxe_interface_ethernet.unifi        "GigabitEthernet 1/0/2"
terraform import iosxe_interface_ethernet.office_uplink "GigabitEthernet 1/0/3"
terraform import iosxe_interface_ethernet.truenas      "GigabitEthernet 1/0/4"
terraform import iosxe_interface_ethernet.egress_lag_1 "GigabitEthernet 1/0/13"
terraform import iosxe_interface_ethernet.offices_ap   "GigabitEthernet 1/0/14"
terraform import iosxe_interface_ethernet.egress_lag_2 "GigabitEthernet 1/0/15"
terraform import iosxe_interface_ethernet.sunroom_ap   "GigabitEthernet 1/0/16"
terraform import iosxe_interface_ethernet.egress_lag_3 "GigabitEthernet 1/0/17"
terraform import iosxe_interface_ethernet.library_ap   "GigabitEthernet 1/0/18"
terraform import iosxe_interface_ethernet.egress_lag_4 "GigabitEthernet 1/0/19"
terraform import iosxe_interface_ethernet.cottingly_ap "GigabitEthernet 1/0/20"

# Port-channel
terraform import iosxe_interface_port_channel.egress 1

# Management SVI
terraform import iosxe_interface_vlan.management 1

# System singletons
terraform import iosxe_system.this  "Cisco-IOS-XE-native:native"
terraform import iosxe_ntp.this     "Cisco-IOS-XE-native:native/ntp"
terraform import iosxe_logging.this "Cisco-IOS-XE-native:native/logging"
