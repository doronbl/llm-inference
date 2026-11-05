#!/bin/bash
# Installs and starts the SOCI snapshotter (lazy-loading mode, SOCI index
# manifest v2) on an EKS-optimized AL2023 node at first boot.
#
# Runs as a cloud-init shell part before nodeadm starts containerd and the
# kubelet. The matching containerd/kubelet settings are in nodeconfig.yaml
# (merged into the node's NodeConfig by nodeadm).
#
# Used by:
#   - the system managed node groups (Terraform: infra/envs/region/main.tf)
#   - the Karpenter inference EC2NodeClass (scripts/41-platform-cells.sh)
set -euo pipefail

SOCI_VERSION="0.16.1"
SOCI_SHA256_AMD64="2be9f26ad853455515da69885f8906e6aecc65684cc302f8689c25cad8417bc8"

case "$(uname -m)" in
  x86_64) ARCH="amd64"; SOCI_SHA256="${SOCI_SHA256_AMD64}" ;;
  *) echo "install-soci: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

ARCHIVE="soci-snapshotter-${SOCI_VERSION}-linux-${ARCH}.tar.gz"
URL="https://github.com/awslabs/soci-snapshotter/releases/download/v${SOCI_VERSION}/${ARCHIVE}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

curl --silent --show-error --location --fail --retry 5 --retry-delay 3 \
  --output "${workdir}/${ARCHIVE}" "${URL}"
echo "${SOCI_SHA256}  ${workdir}/${ARCHIVE}" | sha256sum --check --strict -
tar -xzf "${workdir}/${ARCHIVE}" -C /usr/local/bin soci-snapshotter-grpc soci

mkdir -p /etc/soci-snapshotter-grpc /var/lib/soci-snapshotter-grpc
cat >/etc/soci-snapshotter-grpc/config.toml <<'EOF'
# Kubernetes CRI credentials: the snapshotter proxies the CRI image service
# (kubelet imageServiceEndpoint) and caches the ECR credentials the kubelet
# obtains from its credential provider.
[cri_keychain]
enable_keychain = true
image_service_path = "/run/containerd/containerd.sock"

# Lazy loading for SOCI-enabled images (SOCI index manifest v2).
[pull_modes.soci_v2]
enable = true
EOF

cat >/etc/systemd/system/soci-snapshotter.socket <<'EOF'
[Unit]
Description=soci snapshotter containerd plugin (socket)
Documentation=https://github.com/awslabs/soci-snapshotter

[Socket]
ListenStream=/run/soci-snapshotter-grpc/soci-snapshotter-grpc.sock
SocketMode=0660

[Install]
WantedBy=sockets.target
EOF

cat >/etc/systemd/system/soci-snapshotter.service <<'EOF'
[Unit]
Description=soci snapshotter containerd plugin
Documentation=https://github.com/awslabs/soci-snapshotter
After=network.target
Before=containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/soci-snapshotter-grpc --address fd://
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now soci-snapshotter.socket
systemctl enable --now soci-snapshotter.service
