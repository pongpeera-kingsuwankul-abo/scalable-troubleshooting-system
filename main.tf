# main.tf - cPouta VM for the Open5GS + k3s + Chaos Mesh PoC.
# Credentials come from OS_* environment variables (see terraform.tfvars.example).

terraform {
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = ">= 1.54.0"
    }
  }
}

provider "openstack" {}

variable "flavor_name" {
  type        = string
  description = "cPouta flavor with 4 vCPU / 8 GB RAM. Copy it from your existing instance (Compute > Instances)."
}

variable "image_name" {
  type    = string
  default = "Ubuntu-22.04"   # check the exact name under Compute > Images
}

variable "network_name" {
  type    = string
  default = "project_2022596"
}

variable "floating_ip_pool" {
  type    = string
  default = "public"
}

variable "instance_name" {
  type    = string
  default = "open5gs-poc-tf"
}

variable "volume_size_gb" {
  type    = number
  default = 30
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/cpouta.pub"
}

variable "ssh_cidr" {
  type        = string
  default     = "0.0.0.0/0"   # you chose key-only SSH from anywhere; narrow it here if that changes
  description = "Who may reach port 22"
}

data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

resource "openstack_compute_keypair_v2" "key" {
  name       = "${var.instance_name}-key"
  public_key = file(pathexpand(var.public_key_path))
}

resource "openstack_networking_secgroup_v2" "ssh" {
  name        = "${var.instance_name}-ssh"
  description = "SSH only"
}

resource "openstack_networking_secgroup_rule_v2" "ssh_in" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.ssh_cidr
  security_group_id = openstack_networking_secgroup_v2.ssh.id
}

resource "openstack_compute_instance_v2" "vm" {
  name            = var.instance_name
  flavor_name     = var.flavor_name
  key_pair        = openstack_compute_keypair_v2.key.name
  security_groups = [openstack_networking_secgroup_v2.ssh.name]
  user_data       = templatefile("${path.module}/cloud-init.yaml.tftpl", { setup_b64 = filebase64("${path.module}/poc-setup.sh") })

  # boot volume, removed together with the VM so nothing is left using quota
  block_device {
    uuid                  = data.openstack_images_image_v2.ubuntu.id
    source_type           = "image"
    destination_type      = "volume"
    volume_size           = var.volume_size_gb
    boot_index            = 0
    delete_on_termination = true
  }

  network {
    name = var.network_name
  }

  # cloud-init only runs at first boot; editing it must not make Terraform replace a running VM
  lifecycle {
    ignore_changes = [user_data]
  }
}

resource "openstack_networking_floatingip_v2" "fip" {
  pool = var.floating_ip_pool
}

# Attach the floating IP to the VM's network port (the old Nova associate resource was removed)
data "openstack_networking_port_v2" "vm_port" {
  device_id  = openstack_compute_instance_v2.vm.id
  network_id = openstack_compute_instance_v2.vm.network[0].uuid
}

resource "openstack_networking_floatingip_associate_v2" "assoc" {
  floating_ip = openstack_networking_floatingip_v2.fip.address
  port_id     = data.openstack_networking_port_v2.vm_port.id
}

output "floating_ip" {
  value = openstack_networking_floatingip_v2.fip.address
}

output "ssh_command" {
  value = "ssh -i <path-to-private-key> ubuntu@${openstack_networking_floatingip_v2.fip.address}"
}
