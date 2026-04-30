resource "iosxe_vlan" "marisol" {
  vlan_id = 2
  name    = "Marisol"
}

resource "iosxe_vlan" "marisol_iot" {
  vlan_id = 3
  name    = "Marisol-IOT"
}

resource "iosxe_vlan" "marisol_work" {
  vlan_id = 4
  name    = "Marisol-Work"
}

resource "iosxe_vlan" "kirkwood" {
  vlan_id = 5
  name    = "Kirkwood"
}
