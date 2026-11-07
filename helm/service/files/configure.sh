#!/bin/bash
# Runs in the UniFi OS Server image itself, before it starts, with the whole data volume at /pvc.
# Only writes files on the data volume; Ubiquiti's software is not modified.
set -euo pipefail

# 0. seed each persisted directory from the image the first time (what Docker/podman named
#    volumes do on their own: Ubiquiti's launcher relies on it). A Kubernetes subPath mount of an
#    empty directory hides the image's content and ownership instead, e.g. /var/log/nginx missing
#    (nginx fails) and /var/lib/mongodb not owned by mongodb (mongod fails).
#    SEED_DIRS: "subPath:/image/path ..."; a marker per subPath makes this run once.
for m in $SEED_DIRS; do
  sub=${m%%:*}; src=${m#*:}; dst=/pvc/$sub
  [ -e "/pvc/.seeded-$sub" ] && continue
  mkdir -p "$dst"
  if [ -d "$src" ]; then
    cp -a "$src/." "$dst/"
    chown --reference="$src" "$dst"; chmod --reference="$src" "$dst"
  fi
  touch "/pvc/.seeded-$sub"
  echo "seeded $sub from $src"
done

# 1. one stable console identity (Ubiquiti's entrypoint keeps /data/uos_uuid once written)
if [ ! -s /pvc/data/uos_uuid ]; then
  sed 's/./5/15' /proc/sys/kernel/random/uuid > /pvc/data/uos_uuid   # version-5 style, as the installer generates
  echo "generated uos_uuid"
fi
echo "uos_uuid=$(cat /pvc/data/uos_uuid)"

# 2. refuse a downgrade on existing data unless allowed (UniFi does not support downgrades)
marker=/pvc/data/.chart-uos-version
if [ -s "$marker" ]; then
  prev=$(cat "$marker")
  if [ "$prev" != "$UOS_VERSION" ] && [ "$(printf '%s\n%s\n' "$prev" "$UOS_VERSION" | sort -V | head -1)" = "$UOS_VERSION" ]; then
    if [ "${ALLOW_DOWNGRADE:-false}" != "true" ]; then
      echo "refusing to start $UOS_VERSION on data last run by $prev (set uos.allowDowngrade=true to override)"; exit 1
    fi
    echo "WARNING: downgrading $prev -> $UOS_VERSION (allowed by uos.allowDowngrade)"
  fi
fi
echo "$UOS_VERSION" > "$marker"

# 3. where devices inform to: address and port (keep the file's owner: unifi)
props=/pvc/var-lib-unifi/system.properties
set_prop() {
  if [ -f "$props" ] && grep -q "^$1=" "$props"; then
    sed -i "s|^$1=.*|$1=$2|" "$props"
  else
    echo "$1=$2" >> "$props"
    chown --reference=/pvc/var-lib-unifi "$props"
  fi
  echo "$1=$2"
}
set_prop system_ip "${SYSTEM_IP:-$HOST_IP}"
case "${INFORM_PORT:-}" in ''|*[!0-9]*) echo "INFORM_PORT must be a number, got '${INFORM_PORT:-}'"; exit 1 ;; esac
set_prop unifi.http.port "$INFORM_PORT"
