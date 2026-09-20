variable "switch_username" {
  type    = string
  default = "brian"
}

variable "switch_password" {
  type      = string
  sensitive = true
}
