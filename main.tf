terraform {
  required_providers {
    ovh = {
      source = "ovh/ovh"
      version = ">= 2.3.0"  # Required for floating_ip fix
    }
    openstack = {
      source = "terraform-provider-openstack/openstack"
      version = "~> 1.54.0"
    }
  }
}

variable project_id_var {
  type = string
}

variable application_key_var {
  type = string
}
variable application_secret_var {
  type = string
}
variable consumer_key_var {
  type = string
}

provider "ovh" {
  endpoint           = "ovh-eu"
  application_key    = var.application_key_var
  application_secret = var.application_secret_var
  consumer_key       = var.consumer_key_var
}

# Provider OpenStack pour gérer les Floating IPs
# Utilise les credentials OpenStack de votre projet OVH Cloud
# Voir: https://docs.ovh.com/fr/public-cloud/charger-les-variables-denvironnement-openstack/
provider "openstack" {
  auth_url    = "https://auth.cloud.ovh.net/v3/"
  domain_name = "default"
  region      = "GRA11"
}

# 0. Debug : Liste des régions disponibles
data "ovh_cloud_project_regions" "available" {
  service_name = var.project_id_var
  has_services_up = ["instance"]
}

/*
output "available_regions" {
  value = data.ovh_cloud_project_regions.available.names
}
*/

# 1. Recherche automatique de l'ID de l'image Ubuntu 22.04
data "ovh_cloud_project_images" "ubuntu_latest" {
  service_name = var.project_id_var
  region       = "GRA11"
  os_type      = "linux"
}

# 2. Recherche automatique de l'ID du flavor 'l4-90' dans region 'GRA11' ou flavor 'rtx5000-56' dans région 'GRA9'
data "ovh_cloud_project_flavors" "l4_flavor" {
  service_name = var.project_id_var
  region       = "GRA11"
}

/*
output "available_flavors" {
  value = [for flavor in data.ovh_cloud_project_flavors.l4_flavor.flavors : {
    name = flavor.name
    id = flavor.id
    type = flavor.type
  }]
}
*/


locals {
  # On récupère l'ID de l'image Ubuntu 22.04
  ubuntu_id = [for img in data.ovh_cloud_project_images.ubuntu_latest.images : img.id if img.name == "Ubuntu 22.04"][0]

  # On récupère l'ID du flavor l4-90 (on cherche un flavor contenant "l4-90")
  l4_flavor_id = try(
    [for flavor in data.ovh_cloud_project_flavors.l4_flavor.flavors : flavor.id if flavor.name == "l4-90"][0],
    null
  )
}

# 1. Définition de la clé SSH
resource "ovh_cloud_project_ssh_key" "my_key" {
  service_name = var.project_id_var # projet Gazebo
  name         = "gazebo_key_ed25519"
  public_key   = file("${path.module}/id_ed25519.pub")

  lifecycle {
    ignore_changes = [public_key]
  }
}

# 🌐 Réseau privé pour permettre l'usage de Floating IP
resource "ovh_cloud_project_network_private" "private_net" {
  service_name = var.project_id_var
  name         = "gazebo_private_net"
  regions      = ["GRA11"]
  vlan_id      = 0
}

# 📡 Sous-réseau
resource "ovh_cloud_project_network_private_subnet" "private_subnet" {
  service_name = var.project_id_var
  network_id   = ovh_cloud_project_network_private.private_net.id
  region       = "GRA11"
  start        = "192.168.1.2"
  end          = "192.168.1.254"
  network      = "192.168.1.0/24"
  dhcp         = true
  no_gateway   = false
}

# 🚪 Gateway vers le réseau externe (nécessaire pour Floating IP)
resource "ovh_cloud_project_gateway" "gateway" {
  service_name = var.project_id_var
  name         = "gazebo_gateway"
  model        = "s"
  region       = "GRA11"
  network_id   = tolist(ovh_cloud_project_network_private.private_net.regions_attributes)[0].openstackid
  subnet_id    = ovh_cloud_project_network_private_subnet.private_subnet.id
}

# 🔹 IP PUBLIQUE RÉSERVÉE (Floating IP via OpenStack)
resource "openstack_networking_floatingip_v2" "fip" {
  pool   = "Ext-Net"
  region = "GRA11"

  lifecycle {
    prevent_destroy = true
  }
}


# 2. Création de l'instance GPU L4
resource "ovh_cloud_project_instance" "gazebo_instance" {
  service_name = var.project_id_var
  name         = "gazebo-fortress-node"
  region       = "GRA11" # Vérifiez la région où les L4 sont dispos
  billing_period = "hourly"

  flavor {
    flavor_id = local.l4_flavor_id
  }

  ssh_key {
    name = ovh_cloud_project_ssh_key.my_key.name
  }

  # 1. Spécification du disque de démarrage
  boot_from {
    image_id = local.ubuntu_id
  }

  # 2. Spécification du réseau privé avec gateway (pour Floating IP)
  network {
    public = false
    private {
      network {
        id = tolist(ovh_cloud_project_network_private.private_net.regions_attributes[*].openstackid)[0]
        subnet_id = ovh_cloud_project_network_private_subnet.private_subnet.id
      }
      gateway {
        id = ovh_cloud_project_gateway.gateway.id
      }
    }
  }

  depends_on = [
    ovh_cloud_project_gateway.gateway,
    ovh_cloud_project_network_private_subnet.private_subnet
  ]

  # Installation auto des drivers NVIDIA
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y ubuntu-drivers-common
              ubuntu-drivers install
              apt-get update
              apt-get install -y wget curl lsb-release gnupg
              curl https://packages.osrfoundation.org/gazebo.gpg \
                --output /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg
              echo "deb [arch=$(dpkg --print-architecture) \
                signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] \
                https://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | \
                sudo tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null
              apt-get update
              apt-get install -y ignition-fortress 
              # For ignition-fortress, check https://github.com/gazebosim/gz-fortress/blob/main/CMakeLists.txt
              apt-get install -y \
                libignition-gazebo6-dev \
                libignition-transport11-dev \
                libignition-math6-dev
              apt-get install -y xfce4 xfce4-goodies dbus-x11
              wget https://download.nomachine.com/download/9.3/Linux/nomachine_9.3.7_1_amd64.deb    
              sudo dpkg -i nomachine_9.3.7_1_amd64.deb                                         
              sudo apt-get install -f -y
              sudo ufw allow 22/tcp
              sudo ufw allow 4000/tcp
              sudo ufw allow 8092/tcp
              # sudo ufw enable
              # ufw disable to use ign gazebo
              sudo ufw disable
              # install CMake and compilers
              apt-get install -y \
                cmake \
                g++ \
                make \
                git
              reboot
              EOF
}

# 🔹 Récupération du port de l'instance via OpenStack
data "openstack_networking_port_ids_v2" "instance_port" {
  device_id = ovh_cloud_project_instance.gazebo_instance.id
  region    = "GRA11"

  depends_on = [ovh_cloud_project_instance.gazebo_instance]
}

# 🔹 Association de la Floating IP à l'instance
resource "openstack_networking_floatingip_associate_v2" "fip_associate" {
  floating_ip = openstack_networking_floatingip_v2.fip.address
  port_id     = tolist(data.openstack_networking_port_ids_v2.instance_port.ids)[0]
  region      = "GRA11"

  depends_on = [data.openstack_networking_port_ids_v2.instance_port]
}

output "instance_info" {
  value = {
    instance_id = ovh_cloud_project_instance.gazebo_instance.id
    instance_name = ovh_cloud_project_instance.gazebo_instance.name
    floating_ip = openstack_networking_floatingip_v2.fip.address
  }
}

output "floating_ip_address" {
  description = "IP publique réutilisable de l'instance"
  value       = openstack_networking_floatingip_v2.fip.address
}
