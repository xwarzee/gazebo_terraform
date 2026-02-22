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

  # Mise à jour DNS
  # Installation auto des drivers NVIDIA
  # Installation Gazebo Fortress et outils de compilation pour le plugin C++ (bridge REST pour l'app UAV)
  user_data = <<EOF
#!/bin/bash
set -x  # Mode debug

# ===== CONFIGURATION DU LOGGING =====
LOG_FILE="/var/log/user-data-gazebo.log"

# Créer le fichier de log avec les bonnes permissions
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Rediriger stdout et stderr vers le fichier ET la console
exec > >(tee -a "$LOG_FILE") 2>&1

echo "======================================"
echo "User-data script started at $(date)"
echo "======================================"

# Fonction pour logger avec timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Fonction pour vérifier et attendre que le DNS fonctionne
wait_for_dns() {
  log "Vérification DNS..."
  local max_attempts=30
  local attempt=1

  while [ $attempt -le $max_attempts ]; do
    if nslookup google.com > /dev/null 2>&1; then
      log "DNS opérationnel (tentative $attempt/$max_attempts)"
      return 0
    fi
    log "DNS non fonctionnel, tentative $attempt/$max_attempts"
    sleep 2
    attempt=$((attempt + 1))
  done

  log "ERREUR: DNS toujours non fonctionnel après $max_attempts tentatives"
  return 1
}

# Fonction pour exécuter une commande avec retry
retry_command() {
  local max_attempts=3
  local attempt=1
  local cmd="$*"

  while [ $attempt -le $max_attempts ]; do
    log "Exécution: $cmd (tentative $attempt/$max_attempts)"
    if eval "$cmd"; then
      log "Succès: $cmd"
      return 0
    fi
    log "Échec: $cmd (tentative $attempt/$max_attempts)"
    sleep 5
    attempt=$((attempt + 1))
  done

  log "ERREUR: Échec définitif après $max_attempts tentatives: $cmd"
  return 1
}

# ===== CONFIGURATION DNS PERSISTANTE =====
log "Configuration DNS persistante via resolved.conf.d..."

# Créer le répertoire s'il n'existe pas
mkdir -p /etc/systemd/resolved.conf.d

# Créer un fichier de configuration DNS persistant
cat > /etc/systemd/resolved.conf.d/custom-dns.conf << 'DNSCONF'
[Resolve]
DNS=8.8.8.8 8.8.4.4 1.1.1.1
FallbackDNS=1.0.0.1
Domains=~.
DNSCONF

log "Configuration DNS créée dans /etc/systemd/resolved.conf.d/custom-dns.conf"
log "Redémarrage de systemd-resolved..."
systemctl restart systemd-resolved

sleep 5

# Vérifier que le DNS fonctionne avant de continuer
if ! wait_for_dns; then
  log "ERREUR CRITIQUE: Impossible de configurer le DNS"
  exit 1
fi

# ===== INSTALLATION DES DRIVERS NVIDIA =====
log "Installation des drivers NVIDIA..."
retry_command "apt-get update"
retry_command "apt-get install -y ubuntu-drivers-common"
retry_command "ubuntu-drivers install"

# ===== INSTALLATION DES OUTILS DE BASE =====
log "Installation des outils de base..."
retry_command "apt-get update"
retry_command "apt-get install -y wget curl lsb-release gnupg"

# ===== INSTALLATION GAZEBO FORTRESS =====
log "Installation de Gazebo Fortress..."
retry_command "curl https://packages.osrfoundation.org/gazebo.gpg --output /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg"

echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] \
  https://packages.osrfoundation.org/gazebo/ubuntu-stable $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/gazebo-stable.list > /dev/null

retry_command "apt-get update"
retry_command "apt-get install -y ignition-fortress"

log "Installation des bibliothèques Gazebo..."
retry_command "apt-get install -y libignition-gazebo6-dev libignition-transport11-dev libignition-math6-dev"

# ===== INSTALLATION XFCE ET NOMACHINE =====
log "Installation de XFCE..."
retry_command "apt-get install -y xfce4 xfce4-goodies dbus-x11"

log "Installation de NoMachine..."
retry_command "wget https://download.nomachine.com/download/9.3/Linux/nomachine_9.3.7_1_amd64.deb"
sudo dpkg -i nomachine_9.3.7_1_amd64.deb || log "Erreur dpkg NoMachine (normal, résolution des dépendances...)"
retry_command "apt-get install -f -y"

# ===== CONFIGURATION FIREWALL =====
log "Configuration firewall..."

# Ports SSH et services
sudo ufw allow 22/tcp
sudo ufw allow 4000/tcp    # NoMachine
sudo ufw allow 8092/tcp    # Application custom

# Ports Gazebo Fortress / Ignition Transport
sudo ufw allow 11345/tcp   # Ignition Transport discovery
sudo ufw allow 11345/udp   # Ignition Transport discovery (UDP)
sudo ufw allow 11346:11355/tcp  # Ignition Transport communication range
sudo ufw allow 11346:11355/udp  # Ignition Transport communication range (UDP)

# Autoriser tout le trafic sur localhost (nécessaire pour Gazebo)
sudo ufw allow in on lo
sudo ufw allow out on lo

# Activer le firewall avec les ports Gazebo
# sudo ufw --force enable
# log "Firewall activé avec ports Gazebo"
# le firewall n'est pas activé => trouver les places de ports nécessaires à Gazebo (ports dynamiques)
sudo ufw disable

# ===== SÉCURITÉ SSH =====
log "Installation de fail2ban (protection contre bruteforce SSH)..."
retry_command "apt-get install -y fail2ban"

# Configuration SSH durcie
log "Durcissement de la configuration SSH..."
cat >> /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHCONF'
# Désactiver authentification par mot de passe (seules les clés SSH sont autorisées)
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
MaxAuthTries 3
SSHCONF

systemctl restart sshd
log "SSH durci : authentification par clés uniquement"

# ===== INSTALLATION OUTILS DE COMPILATION =====
log "Installation des outils de compilation..."
retry_command "apt-get install -y cmake g++ make git"


# ==== ROS2 INSTALLATION ====
log "Installation ROS2..."
apt install software-properties-common curl
curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
  -o /usr/share/keyrings/ros-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) \
  signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
  http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" \
  | sudo tee /etc/apt/sources.list.d/ros2.list

apt update
apt install ros-humble-desktop -y     # ou ros-humble-ros-base (sans GUI)

# ==== Ignition ↔ ROS2 Bridge INSTALLATION ====
log "Installation Ignition ↔ ROS2 Bridge..."
apt install -y \
  ros-humble-ros-gz-bridge \
  ros-humble-ros-gz-sim \
  ros-humble-ros-gz-interfaces \
  ros-humble-tf2-msgs

# ==== colon INSTALLATION ====
log "Installation python3-colcon..."
apt install python3-colcon-core
apt install python3-colcon-common-extensions

# ===== FIN =====
log "======================================"
log "User-data script terminé avec succès"
log "Redémarrage du serveur..."
log "======================================"

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
