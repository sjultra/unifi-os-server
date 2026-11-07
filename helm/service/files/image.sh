#!/bin/sh
# Runs in the rancher/k3s image (has ctr) against the node's containerd.
#   image.sh check   -> writes /work/present if $TARGET is already in containerd
#   image.sh import  -> imports /work/out/image.tar, tags it $TARGET, pins it against kubelet GC,
#                       then removes other versions of the UniFi image
set -eu
CTR="ctr --address ${CONTAINERD_SOCKET} --namespace k8s.io"
# --config /dev/null: k3s's crictl exits when it finds no config file
CRICTL="crictl --config /dev/null --runtime-endpoint unix://${CONTAINERD_SOCKET} --image-endpoint unix://${CONTAINERD_SOCKET}"

# Old versions stay pinned, so kubelet GC never frees them (~2.3 GB each). Unpin and remove
# them through the CRI: `crictl rmi` frees content and snapshots, `ctr images rm` only drops
# the tag. Best effort: a failure is logged and never blocks startup.
cleanup_old() {
  repo="${TARGET%:*}"
  target_id=$($CRICTL inspecti -o go-template --template '{{.status.id}}' "$TARGET" 2>/dev/null) || target_id=""
  [ -n "$target_id" ] || { echo "WARNING: cannot resolve $TARGET via CRI; skipping cleanup of old versions"; return 0; }
  for old in $($CTR images ls -q | grep "^$repo:" | grep -vx "$TARGET"); do
    old_id=$($CRICTL inspecti -o go-template --template '{{.status.id}}' "$old" 2>/dev/null) || old_id=""
    if [ "$old_id" = "$target_id" ]; then
      # same image: crictl rmi would remove $TARGET too; drop only the extra tag
      $CTR images rm "$old" >/dev/null 2>&1 && echo "removed tag $old (same image as $TARGET)" \
        || echo "WARNING: could not remove tag $old"
      continue
    fi
    $CTR images label "$old" io.cri-containerd.pinned= >/dev/null 2>&1 || echo "WARNING: could not unpin $old"
    if $CRICTL rmi "$old" >/dev/null 2>&1; then
      echo "removed old version $old"
    else
      echo "WARNING: could not remove $old; remove it on the node with: k3s crictl rmi $old"
    fi
  done
}

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
  if [ -f /work/present ]; then
    echo "present, nothing to import"
  else
    SRC=$(cat /work/out/ref)
    # discard compressed layers once unpacked: saves ~0.8 GB per node
    $CTR images import --discard-unpacked-layers /work/out/image.tar
    $CTR images tag --force "$SRC" "$TARGET"
    [ "$SRC" != "$TARGET" ] && $CTR images rm "$SRC" >/dev/null || true
    # pinned images are skipped by kubelet image GC (kubelet >= 1.28 honours the CRI pinned flag)
    $CTR images label "$TARGET" io.cri-containerd.pinned=pinned
    rm -rf /work/out
    echo "imported $TARGET"
  fi
  cleanup_old || echo "WARNING: cleanup of old versions failed"
  ;;
esac
