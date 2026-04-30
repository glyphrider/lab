variable "switch_username" {
  type    = string
  default = "admin"
}

variable "switch_password" {
  type      = string
  sensitive = true
}
