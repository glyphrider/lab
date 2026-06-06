# Base interface config (descriptions, LAG membership)

resource "iosxe_interface_ethernet" "pihole2" {
  type        = "GigabitEthernet"
  name        = "1/0/1"
  description = "PiHole2"
}

resource "iosxe_interface_ethernet" "lab" {
  type        = "GigabitEthernet"
  name        = "1/0/2"
  description = "Lab"
}

resource "iosxe_interface_ethernet" "office_uplink" {
  type        = "GigabitEthernet"
  name        = "1/0/3"
  description = "Office Uplink"
}

resource "iosxe_interface_ethernet" "truenas" {
  type        = "GigabitEthernet"
  name        = "1/0/4"
  description = "TrueNAS Scale"
}

resource "iosxe_interface_ethernet" "egress_lag_1" {
  type                = "GigabitEthernet"
  name                = "1/0/13"
  description         = "Egress LAG (Port 1 of 4)"
  channel_group_number = 1
  channel_group_mode  = "active"
}

resource "iosxe_interface_ethernet" "offices_ap" {
  type        = "GigabitEthernet"
  name        = "1/0/14"
  description = "Offices AP"
}

resource "iosxe_interface_ethernet" "egress_lag_2" {
  type                = "GigabitEthernet"
  name                = "1/0/15"
  description         = "Egress LAG (Port 2 of 4)"
  channel_group_number = 1
  channel_group_mode  = "active"
}

resource "iosxe_interface_ethernet" "sunroom_ap" {
  type        = "GigabitEthernet"
  name        = "1/0/16"
  description = "Sunroom AP"
}

resource "iosxe_interface_ethernet" "egress_lag_3" {
  type                = "GigabitEthernet"
  name                = "1/0/17"
  description         = "Egress LAG (Port 3 of 4)"
  channel_group_number = 1
  channel_group_mode  = "active"
}

resource "iosxe_interface_ethernet" "library_ap" {
  type        = "GigabitEthernet"
  name        = "1/0/18"
  description = "Library AP"
}

resource "iosxe_interface_ethernet" "egress_lag_4" {
  type                = "GigabitEthernet"
  name                = "1/0/19"
  description         = "Egress LAG (Port 4 of 4)"
  channel_group_number = 1
  channel_group_mode  = "active"
}

resource "iosxe_interface_ethernet" "cottingly_ap" {
  type        = "GigabitEthernet"
  name        = "1/0/20"
  description = "Cottingly AP"
}

resource "iosxe_interface_port_channel" "egress" {
  name        = "1"
  description = "Gateway"
}
