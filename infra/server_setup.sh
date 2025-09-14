#!/usr/bin/env bash
# Nomad + Consul + Docker: server node (Nomad server + Consul server + local client)
# Usage:
#   sudo IFACE=wg0 DATACENTER=home1 REGION=global ./server_setup.sh
#   (all variables are optional)

set -euo pipefail

# --- Parameters ---
: "${REGION:=global}"
: "${DATACENTER:=dc1}"
: "${NODE_NAME:=nomad-server-$(hostname -s)}"
: "${IFACE:=}"
: "${CONSUL_BOOTSTRAP_EXPECT:=1}"       # change to 3 for HA cluster
: "${CONSUL_ENCRYPT_KEY:=}"             # gossip encryption key (consul keygen)
: "${NOMAD_ENCRYPT_KEY:=}"              # serf encryption key (nomad operator keygen)
: "${ENABLE_UFW:=false}"                # true = open only required ports
: "${INSTALL_DOCKER_FROM_APT:=true}"    # false = install Docker from official repo

# --- Helpers ---
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

echo "REGION=${REGION}"
echo "DATACENTER=${DATACENTER}"
echo "NODE_NAME=${NODE_NAME}"
echo "IFACE=${IFACE}  ADVERTISE_IP=${ADVERTISE_IP}"

# --- Install dependencies ---
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

# Configure Docker daemon
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

# Add users to docker group
usermod -aG docker ubuntu || true

# Add HashiCorp repo
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update -y
apt-get install -y consul nomad

# Add nomad user to docker group
usermod -aG docker nomad || true

# --- Consul configuration ---
mkdir -p /etc/consul.d
chmod 750 /etc/consul.d

cat >/etc/consul.d/server.hcl <<EOF
datacenter = "${DATACENTER}"
primary_datacenter = "${DATACENTER}"
node_name = "${NODE_NAME}"
server = true
bootstrap_expect = ${CONSUL_BOOTSTRAP_EXPECT}
data_dir = "/var/lib/consul"
client_addr = "0.0.0.0"
bind_addr = "${ADVERTISE_IP}"
advertise_addr = "${ADVERTISE_IP}"
ui_config { enabled = true }

retry_join = []  # for multi-server clusters add other servers' IPs
EOF
if [[ -n "${CONSUL_ENCRYPT_KEY}" ]]; then
  echo "encrypt = \"${CONSUL_ENCRYPT_KEY}\"" >> /etc/consul.d/server.hcl
fi

consul validate /etc/consul.d/server.hcl
systemctl enable consul
systemctl restart consul

# --- Nomad configuration ---
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

# Nomad server role
cat >/etc/nomad.d/server.hcl <<'EOF'
server {
  enabled = true
  bootstrap_expect = 1
}
EOF

# Nomad client role
cat >/etc/nomad.d/client.hcl <<'EOF'
client {
  enabled = true
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
    volumes {
      enabled      = true
      selinuxlabel = "z"
    }
  }
}
EOF

mkdir -p /opt/nomad/shared
chown -R nomad:nomad /opt/nomad

# Optional: Nomad encryption
if [[ -n "${NOMAD_ENCRYPT_KEY}" ]]; then
  echo "encrypt = \"${NOMAD_ENCRYPT_KEY}\"" >> /etc/nomad.d/common.hcl
fi

nomad validate /etc/nomad.d
systemctl enable nomad
systemctl restart nomad

# UFW firewall (optional)
if $ENABLE_UFW; then
  apt-get install -y ufw
  ufw allow 22/tcp
  ufw allow 8300/tcp
  ufw allow 8301/tcp
  ufw allow 8301/udp
  ufw allow 8500/tcp
  ufw allow 4646/tcp
  ufw allow 4647/tcp
  ufw allow 4648/tcp
  ufw allow 4648/udp
  yes | ufw enable
fi

echo "✅ Done. Consul UI: http://${ADVERTISE_IP}:8500 , Nomad UI: http://${ADVERTISE_IP}:4646"
