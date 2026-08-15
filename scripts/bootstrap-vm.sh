#!/usr/bin/env bash
#
# Rebuild the single-node Kubernetes lab from a bare Ubuntu 24.04 install.
#
# Written after a host restore wiped the VM: doing this by hand the first time cost an
# afternoon, and nothing about it was recorded. It is idempotent, so it can be re-run to
# repair a partial environment rather than only to build a fresh one.
#
#   usage:  ./bootstrap-vm.sh
#
set -euo pipefail

# Pinned so a rebuild six months from now produces the same cluster rather than
# whatever happens to be latest.
K3S_VERSION="v1.36.3+k3s1"
NODE_MAJOR="22"
# Recorded from the first successful run rather than guessed: chart 10.3.3 ships
# ArgoCD v3.5.1. Clear this to take the latest, then re-pin to whatever it reports.
ARGOCD_CHART_VERSION="10.3.3"
# Recorded from the first successful run, same as ArgoCD above.
MONITORING_CHART_VERSION="88.3.0"

HOSTONLY_IP="192.168.56.101"
HOSTONLY_IFACE="enp0s8"
TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if [[ $EUID -eq 0 ]]; then
  echo "Run as a normal user with sudo rights, not as root: sudo is called where needed." >&2
  exit 1
fi

# ---------------------------------------------------------------------------------
log "Pinning the host-only interface to a static address"
# The VirtualBox host-only DHCP lease was 545s and expired, which took the interface
# down and broke SSH, the Ingress hostname and every screenshot URL. A static address
# removes that dependency entirely.
if ! ip -4 addr show "$HOSTONLY_IFACE" 2>/dev/null | grep -q "$HOSTONLY_IP"; then
  sudo tee /etc/netplan/99-hostonly.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    $HOSTONLY_IFACE:
      addresses: [$HOSTONLY_IP/24]
EOF
  sudo chmod 600 /etc/netplan/99-hostonly.yaml
  sudo netplan apply
  sleep 3
fi
ip -br addr show "$HOSTONLY_IFACE"

# ---------------------------------------------------------------------------------
log "Adding apt repositories"
sudo install -m 0755 -d /etc/apt/keyrings
export DEBIAN_FRONTEND=noninteractive

add_key() { # add_key <name> <url>
  [[ -f "/etc/apt/keyrings/$1.gpg" ]] && return 0
  curl -fsSL "$2" | sudo gpg --batch --yes --dearmor -o "/etc/apt/keyrings/$1.gpg"
}

add_key docker     https://download.docker.com/linux/ubuntu/gpg
add_key trivy      https://get.trivy.dev/deb/public.key
add_key nodesource https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key

CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $CODENAME stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/trivy.gpg] https://get.trivy.dev/deb generic main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null

log "Installing packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  ca-certificates curl git jq openssh-server \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
  trivy "nodejs=${NODE_MAJOR}.*"

# Lets the user run docker without sudo. Takes effect on next login, hence newgrp below.
sudo usermod -aG docker "$TARGET_USER"
sudo systemctl enable --now docker ssh

# ---------------------------------------------------------------------------------
log "Installing static binaries (helm, yq, argocd)"
have helm   || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
if ! have yq; then
  sudo curl -fsSL -o /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo chmod +x /usr/local/bin/yq
fi
if ! have argocd; then
  sudo curl -fsSL -o /usr/local/bin/argocd \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo chmod +x /usr/local/bin/argocd
fi

# ---------------------------------------------------------------------------------
log "Installing k3s"
# Traefik, metrics-server (needed by the HPA) and local-path storage ship with k3s, so
# there is nothing further to install for Ingress or autoscaling.
if ! systemctl is-active --quiet k3s; then
  curl -fsSL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server \
    --write-kubeconfig-mode 600 \
    --tls-san "$HOSTONLY_IP"
fi
sudo systemctl enable --now k3s

log "Wiring kubeconfig for $TARGET_USER"
# /usr/local/bin/kubectl is k3s's shim and defaults to the root-owned
# /etc/rancher/k3s/k3s.yaml, so KUBECONFIG has to be set explicitly. It goes in
# /etc/environment rather than .bashrc because PAM reads that for NON-interactive SSH
# too - .bashrc is skipped there, which silently breaks `ssh host kubectl ...`.
sudo install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 700 "$USER_HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
sudo chown "$TARGET_USER:$TARGET_USER" "$USER_HOME/.kube/config"
sudo chmod 600 "$USER_HOME/.kube/config"
grep -q '^KUBECONFIG=' /etc/environment 2>/dev/null \
  || echo "KUBECONFIG=$USER_HOME/.kube/config" | sudo tee -a /etc/environment >/dev/null
export KUBECONFIG="$USER_HOME/.kube/config"

log "Waiting for the node to become Ready"
for _ in $(seq 1 60); do
  kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
  sleep 5
done
kubectl get nodes -o wide

# ---------------------------------------------------------------------------------
log "Installing ArgoCD"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

# A values file rather than a pile of --set flags: `configs.params."server\.insecure"`
# needs awkward escaping on the command line and is easy to get silently wrong.
ARGOCD_VALUES="$(mktemp)"
trap 'rm -f "$ARGOCD_VALUES"' EXIT
cat > "$ARGOCD_VALUES" <<EOF
configs:
  params:
    # Terminate TLS at Traefik instead of in ArgoCD. Without this, reaching the UI over
    # plain HTTP through the Ingress produces a redirect loop.
    server.insecure: true

server:
  ingress:
    enabled: true
    ingressClassName: traefik
    hostname: argocd.${HOSTONLY_IP//./-}.nip.io

# Neither is used here. Together they were ~160Mi, which mattered on the original 4GB VM
# and is still pointless to run.
dex:
  enabled: false
notifications:
  enabled: false
EOF

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  ${ARGOCD_CHART_VERSION:+--version "$ARGOCD_CHART_VERSION"} \
  -f "$ARGOCD_VALUES" \
  --wait --timeout 15m

log "Installed ArgoCD chart version (pin this in ARGOCD_CHART_VERSION for reproducibility)"
helm list -n argocd -o json | jq -r '.[] | "chart=\(.chart)  app_version=\(.app_version)"'

# ---------------------------------------------------------------------------------
log "Installing kube-prometheus-stack"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  ${MONITORING_CHART_VERSION:+--version "$MONITORING_CHART_VERSION"} \
  -f "$(dirname "$0")/monitoring-values.yaml" \
  --wait --timeout 15m

log "Scraping Traefik for request rate, error rate and latency"
# k3s already starts Traefik with --metrics.prometheus=true and a named "metrics" port, so
# this needs no change to the Traefik deployment - which matters, because k3s manages it
# through a HelmChart CR that would overwrite a manual edit.
#
# Traefik is the source of RED metrics for the application: the app itself instruments no
# request duration and no status codes, so rate/errors/latency have to come from the proxy
# in front of it.
kubectl apply -f - <<'PODMON'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: traefik
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames: [kube-system]
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
  podMetricsEndpoints:
    - port: metrics
PODMON

log "Cluster state"
kubectl get pods -A
cat <<EOF

Bootstrap complete.

  ArgoCD UI    http://argocd.${HOSTONLY_IP//./-}.nip.io
  Grafana      http://grafana.${HOSTONLY_IP//./-}.nip.io   (admin / admin)
  admin password
               kubectl -n argocd get secret argocd-initial-admin-secret \\
                 -o jsonpath='{.data.password}' | base64 -d; echo

Log out and back in (or run 'newgrp docker') before using docker without sudo.
EOF
