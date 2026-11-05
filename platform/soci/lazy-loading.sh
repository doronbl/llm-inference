#!/bin/bash
# Configures the AMI's SOCI snapshotter for lazy loading.
#
# nodeadm (FastImagePull) writes /etc/soci-snapshotter-grpc/config.toml with
# two settings that this script changes:
#
#   [pull_modes.parallel_pull_unpack] enable = true -> false
#     In parallel pull mode the snapshotter never lazy-loads, even for images
#     with a SOCI index. With it disabled, SOCI index v2 lazy loading (enabled
#     by default) applies to SOCI-enabled images, and other images are pulled
#     by containerd as usual.
#
#   [content_store] type = 'containerd' -> 'soci'
#     With the containerd content store, a lazy mount that runs while
#     containerd unpacks another image can deadlock the two daemons on a
#     node's first boot, and every later pull on the node hangs
#     (awslabs/soci-snapshotter#2037, open for v0.16.1). The SOCI content
#     store keeps SOCI indexes and zTOCs in the snapshotter's own store.
#
# Runs as a cloud-init part: after nodeadm-config.service has written the
# file and before nodeadm-run.service starts containerd and the snapshotter.
set -euo pipefail

config=/etc/soci-snapshotter-grpc/config.toml

# Replaces the line "<key> = <old>" with "<key> = <new>" inside one TOML
# section (exact string matches, no regular expressions) and fails unless the
# section then contains "<key> = <new>".
set_in_section() {
  local section="$1" key="$2" old="$3" new="$4"
  if ! grep -qxF "${section}" "${config}" 2>/dev/null; then
    echo "soci lazy-loading: ${config} has no ${section}; leaving it unchanged" >&2
    exit 1
  fi
  awk -v sec="${section}" -v from="${key} = ${old}" -v to="${key} = ${new}" '
    /^\[/ { in_sec = ($0 == sec) }
    in_sec && $0 == from { $0 = to }
    { print }
  ' "${config}" >"${config}.tmp"
  mv "${config}.tmp" "${config}"
  awk -v sec="${section}" -v want="${key} = ${new}" '
    /^\[/ { in_sec = ($0 == sec) }
    in_sec && $0 == want { found = 1 }
    END { exit !found }
  ' "${config}" || {
    echo "soci lazy-loading: could not set ${key} = ${new} in ${section}" >&2
    exit 1
  }
}

set_in_section '[pull_modes.parallel_pull_unpack]' enable true false
echo "soci lazy-loading: parallel_pull_unpack disabled in ${config}"

set_in_section '[content_store]' type "'containerd'" "'soci'"
echo "soci lazy-loading: content_store set to soci in ${config}"
