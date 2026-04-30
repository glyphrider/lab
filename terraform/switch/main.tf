terraform {
  required_providers {
    iosxe = {
      source  = "CiscoDevNet/iosxe"
      version = "~> 0.5"
    }
  }
}

provider "iosxe" {
  host     = "192.168.1.253"
  username = var.switch_username
  password = var.switch_password
  insecure = true
}
