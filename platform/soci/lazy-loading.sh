#!/bin/bash
# Switches the AMI's SOCI snapshotter from parallel pull to lazy loading.
#
# nodeadm (FastImagePull) writes /etc/soci-snapshotter-grpc/config.toml with
# [pull_modes.parallel_pull_unpack] enable = true. In that mode the
# snapshotter never lazy-loads, even for images with a SOCI index. With it
# disabled, SOCI index v2 lazy loading (enabled by default) applies to
# SOCI-enabled images, and other images are pulled by containerd as usual.
#
# Runs as a cloud-init part: after nodeadm-config.service has written the
# file and before nodeadm-run.service starts containerd and the snapshotter.
set -euo pipefail

config=/etc/soci-snapshotter-grpc/config.toml
section='[pull_modes.parallel_pull_unpack]'

if ! grep -qxF "${section}" "${config}" 2>/dev/null; then
  echo "soci lazy-loading: ${config} has no ${section}; leaving it unchanged" >&2
  exit 1
fi

sed -i "/^\[pull_modes\.parallel_pull_unpack\]$/,/^\[/ s/^enable = true$/enable = false/" "${config}"
grep -A1 -xF "${section}" "${config}" | grep -qx 'enable = false'
echo "soci lazy-loading: parallel_pull_unpack disabled in ${config}"
