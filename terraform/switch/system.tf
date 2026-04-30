resource "iosxe_system" "this" {
  hostname              = "switch"
  ip_domain_name        = "marisol.home"
  ip_default_gateway    = "192.168.1.1"
}

resource "iosxe_ntp" "this" {
  servers = [
    { ip_address = "192.168.1.1" },
  ]
}

resource "iosxe_logging" "this" {
  ipv4_hosts = [
    { ipv4_host = "192.168.1.1" },
  ]
}

resource "iosxe_interface_vlan" "management" {
  name             = 1
  description      = "Management"
  ipv4_address     = "192.168.1.253"
  ipv4_address_mask = "255.255.255.0"
}
