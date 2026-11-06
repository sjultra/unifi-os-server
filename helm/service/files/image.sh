#!/bin/sh
# Runs in the rancher/k3s image (has ctr) against the node's containerd.
#   image.sh check   -> writes /work/present if $TARGET is already in containerd
#   image.sh import  -> imports /work/out/image.tar, tags it $TARGET, pins it against kubelet GC
set -eu
CTR="ctr --address ${CONTAINERD_SOCKET} --namespace k8s.io"

case "$1" in
check)
  if $CTR images ls -q | grep -qx "$TARGET"; then
    echo "image $TARGET already present"; touch /work/present
  else
    echo "image $TARGET not present; will download"
  fi
  ;;
import)
  # Pin this chart's own tool images too: once kubelet GC removes them, a plain pod restart
  # needs registry pulls again (Docker Hub may answer 429) although the UniFi image is present.
  for t in $TOOL_IMAGES; do
    $CTR images label "$t" io.cri-containerd.pinned=pinned >/dev/null 2>&1 \
      && echo "pinned $t" || echo "WARNING: could not pin $t (use a fully qualified tools.* ref)"
  done
  [ -f /work/present ] && { echo "present, nothing to import"; exit 0; }
  SRC=$(cat /work/out/ref)
  # discard compressed layers once unpacked: saves ~0.8 GB per node
  $CTR images import --discard-unpacked-layers /work/out/image.tar
  $CTR images tag --force "$SRC" "$TARGET"
  [ "$SRC" != "$TARGET" ] && $CTR images rm "$SRC" >/dev/null || true
  # pinned images are skipped by kubelet image GC (kubelet >= 1.28 honours the CRI pinned flag)
  $CTR images label "$TARGET" io.cri-containerd.pinned=pinned
  rm -rf /work/out
  echo "imported $TARGET"
  ;;
esac
