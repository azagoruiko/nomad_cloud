#!/usr/bin/env bash
# Nomad + Consul + Docker: client node
# Usage:
#   sudo SERVER_IP=10.8.0.1 IFACE=wg0 DATACENTER=home1 REGION=global ./client_setup.sh

set -euo pipefail

: "${SERVER_IP:?Provide SERVER_IP=... (IP of Consul/Nomad server)}}"
: "${REGION:=global}"
: "${DATACENTER:=dc1}"
: "${NODE_NAME:=nomad-client-$(hostname -s)}"
: "${IFACE:=}"
: "${CONSUL_ENCRYPT_KEY:=}"
: "${NOMAD_ENCRYPT_KEY:=}"
: "${INSTALL_DOCKER_FROM_APT:=true}"

get_default_iface() {
  ip route show default | awk '/default/ {print $5; exit}'
}
get_iface_ip() {
  local iface="$1"
  ip -4 addr show dev "$iface" | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
}

if [[ -z "${IFACE}" ]]; then
  IFACE="$(get_default_iface || true)"
fi
if [[ -z "${IFACE}" ]]; then
  echo "Cannot detect network interface. Provide IFACE=..." >&2
  exit 1
fi

ADVERTISE_IP="$(get_iface_ip "$IFACE")"
if [[ -z "${ADVERTISE_IP}" ]]; then
  echo "Cannot get IP for interface ${IFACE}" >&2
  exit 1
fi

echo "SERVER_IP=${SERVER_IP}"
echo "REGION=${REGION}"
echo "DATACENTER=${DATACENTER}"
echo "NODE_NAME=${NODE_NAME}"
echo "IFACE=${IFACE}  ADVERTISE_IP=${ADVERTISE_IP}"

apt-get update -y
apt-get install -y curl gnupg lsb-release ca-certificates jq unzip

# Install Docker
if $INSTALL_DOCKER_FROM_APT; then
  apt-get install -y docker.io
else
  apt-get install -y apt-transport-https
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io
fi

mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  cat >/etc/docker/daemon.json <<'JSON'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "storage-driver": "overlay2"
}
JSON
fi
systemctl enable --now docker

# Add HashiCorp repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update -y
apt-get install -y consul nomad

# Add users to docker group
usermod -aG docker nomad || true
usermod -aG docker ubuntu || true

# --- Consul agent (client mode) ---
mkdir -p /etc/consul.d
chmod 750 /etc/consul.d

cat >/etc/consul.d/client.hcl <<EOF
datacenter = "${DATACENTER}"
node_name  = "${NODE_NAME}"
server     = false
data_dir   = "/var/lib/consul"
client_addr = "0.0.0.0"
bind_addr   = "${ADVERTISE_IP}"
advertise_addr = "${ADVERTISE_IP}"
retry_join = ["${SERVER_IP}"]
EOF
if [[ -n "${CONSUL_ENCRYPT_KEY}" ]]; then
  echo "encrypt = \"${CONSUL_ENCRYPT_KEY}\"" >> /etc/consul.d/client.hcl
fi

consul validate /etc/consul.d/client.hcl
systemctl enable consul
systemctl restart consul

# --- Nomad client ---
mkdir -p /etc/nomad.d
chmod 750 /etc/nomad.d

cat >/etc/nomad.d/common.hcl <<EOF
log_level = "INFO"
data_dir  = "/var/lib/nomad"
bind_addr = "0.0.0.0"

advertise {
  http = "${ADVERTISE_IP}:4646"
  rpc  = "${ADVERTISE_IP}:4647"
  serf = "${ADVERTISE_IP}:4648"
}

region     = "${REGION}"
datacenter = "${DATACENTER}"

consul {
  address = "127.0.0.1:8500"
  auto_advertise = true
  server_service_name = "nomad"
  client_service_name = "nomad-client"
}
EOF

cat >/etc/nomad.d/client.hcl <<EOF
server { enabled = false }

client {
  enabled = true
  servers = ["${SERVER_IP}:4647"]

  options = {
    "driver.raw_exec.enable" = "1"
  }

  host_volume "shared-tmp" {
    path      = "/opt/nomad/shared"
    read_only = false
  }
}

plugin "docker" {
  config {
    volumes { enabled = true }
  }
}
EOF

mkdir -p /opt/nomad/shared
chown -R nomad:nomad /opt/nomad

if [[ -n "${NOMAD_ENCRYPT_KEY}" ]]; then
  echo "encrypt = \"${NOMAD_ENCRYPT_KEY}\"" >> /etc/nomad.d/common.hcl
fi

nomad validate /etc/nomad.d
systemctl enable nomad
systemctl restart nomad

echo "✅ Client ready. Should be connected to server ${SERVER_IP}."
