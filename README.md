# UniFi OS Server

A Helm chart that runs UniFi OS Server (the self-hosted UniFi console: the Network app, device adoption and the site UI) on a single k3s node.

**Not affiliated with, endorsed by or supported by Ubiquiti Inc.** Running UniFi OS Server under Kubernetes is not an install method Ubiquiti supports.

## How it works

The chart contains no Ubiquiti software. It carries only the URL and sha256 of Ubiquiti's official installer for each architecture. When the pod starts on the chosen node:

1. `check-image` looks for `localhost/unifi-os-server:<version>` in the node's containerd. If it's there, the next two steps skip.
2. `fetch` picks the installer for the node's architecture (`uname -m`, or `uos.arch`), downloads it from Ubiquiti (`fw-download.ubnt.com`) onto the node, checks its sha256 and takes `image.tar` out of the ZIP appended to it. The installer is never executed.
3. `import-image` imports the image into the node's containerd, tags it `localhost/unifi-os-server:<version>` and pins it (and the two tool images) so kubelet image garbage collection keeps it.
4. `configure` prepares the data volume: on first run it copies the image's default contents of each persisted directory onto the volume, generates the console's UUID, refuses a downgrade, and writes where devices inform to (`system_ip` and `unifi.http.port`).
5. The main container runs Ubiquiti's image and entrypoint unchanged (systemd inside, privileged).

The UI is served by a Service (ClusterIP, or NodePort for LAN access), optionally behind an Ingress. Device-facing ports (inform `uos.informPort`, default 8080; STUN 3478/udp, ...) are `hostPort`s on the node's IP.

### Licensing

Ubiquiti's terms don't allow redistributing their software. This repository, its CI and the published chart never host, mirror or publish the installer, the image or any part of them: each node downloads the installer from Ubiquiti itself. By installing this chart you download UniFi OS Server from Ubiquiti and **accept Ubiquiti's [Terms of Service](https://www.ui.com/legal/termsofservice/) and [EULA](https://www.ui.com/legal/eula/)**.

## Requirements

- One k3s node, amd64 or arm64, Linux with cgroup v2. The chart talks to k3s's containerd socket (`/run/k3s/containerd/containerd.sock`).
- **Privileged pods** allowed in the namespace (systemd needs a writable cgroup; the image steps use the node's containerd socket). With Pod Security Admission, label the namespace `pod-security.kubernetes.io/enforce=privileged`.
- **Host ports** free on the node: at least the inform port (`uos.informPort`, default 8080/tcp), 3478/udp and 10003/udp (full list in `hostPorts.ports`). No other UniFi controller may run on the host: a hostPort silently takes the port from a host process. CrowdSec's API listens on 8080, so on hosts running CrowdSec set `uos.informPort` to a free port (e.g. 8180).
- **Disk:** at least **5 GB free** on the node for the download and import (about 2.3 GB stays for the image), **plus the PVC** (20 Gi by default, from the default storage class; local-path on k3s).
- **RAM:** at least 4 GB on the node. The pod requests 2 Gi and uses about 1.2 GB once settled; leave the memory limit unset or at 3 Gi or more (the in-memory tmpfs mounts count against it).
- Outbound HTTPS from the node to `fw-download.ubnt.com` and `mirror.gcr.io`.
- Devices must reach the node's IP: on the same L2 segment, or via L3 adoption (`set-inform`, DHCP option 43 or DNS `unifi`). L2 discovery of unadopted devices may not work.

## Quick start

From a checkout, on a k3s node called `my-node`:

```sh
helm install uos helm/service --namespace unifi --create-namespace \
  --set 'nodeSelector.kubernetes\.io/hostname=my-node' \
  --set ui.service.type=NodePort --set ui.service.nodePort=30443
```

The first start takes a few minutes (an 800 MB download plus the import). Then:

```sh
kubectl -n unifi get pod -o wide           # uos-0 Running, 1/1 Ready
kubectl -n unifi logs uos-0 -c fetch       # "detected node architecture ...", "downloaded ... sha256=..."
kubectl -n unifi logs uos-0 -c configure   # "seeded ..." x7, uos_uuid, system_ip, unifi.http.port
```

Open `https://<node-ip>:30443` (a self-signed certificate) for the setup wizard. During setup, turn off application auto-updates: an update installed inside the container is lost when the pod is recreated. Adopt devices with `set-inform http://<node-ip>:<informPort>/inform` (8080 unless `uos.informPort` is set), or set `uos.systemIp`.

Published as `oci://ghcr.io/sjultra/charts/unifi-os-server`:

```sh
helm install uos oci://ghcr.io/sjultra/charts/unifi-os-server --version 0.1.0 --namespace unifi --create-namespace ...
```

## Values

| Value | Default | Description |
|---|---|---|
| `nodeSelector` | `{}` | Pins the pod to one node. `nodeSelector` or `affinity` is required; rendering fails if both are empty. |
| `affinity` | `{}` | Alternative to `nodeSelector`, e.g. a required node affinity on `kubernetes.io/hostname`. |
| `tolerations` | `[]` | Pod tolerations. |
| `uos.version` | `5.1.42` | UniFi OS Server version. Must match the installers below; each chart version carries one. |
| `uos.arch` | `""` | `""` detects the node's architecture at install time; `amd64` or `arm64` forces one. |
| `uos.installers.{amd64,arm64}.{url,sha256}` | 5.1.42 | Ubiquiti's installer URL and sha256 per architecture, from `https://fw-update.ui.com/api/firmware?filter=eq~~product~~unifi-os-server`. |
| `uos.systemIp` | `""` | The address devices inform to. Empty means the node's IP. A hostname or IPv4 address (letters, digits, dots, hyphens). |
| `uos.informPort` | `8080` | TCP port devices inform to. Published on the node and set as UniFi's `unifi.http.port`, so adopted devices keep using it. Choose it before adopting devices: changing it later disconnects them until each is pointed at the new port (`set-inform`). |
| `uos.allowDowngrade` | `false` | Allows starting an older version on newer data. UniFi doesn't support downgrades. |
| `persistence.size` | `20Gi` | Size of the data PVC. |
| `persistence.storageClass` | `""` | Storage class; empty is the cluster default. |
| `resources` | requests 500m CPU, 2Gi | Main container resources. |
| `hostPorts.enabled` | `true` | Publishes the device-facing ports on the node. |
| `hostPorts.ports` | Ubiquiti's 5.1.x port map | `{name, port, protocol}` list. |
| `ui.service.type` | `ClusterIP` | `NodePort` for LAN access to the UI. |
| `ui.service.nodePort` | `null` | Fixed NodePort for the UI (e.g. `30443`); empty lets Kubernetes pick. |
| `ui.ingress.enabled` | `false` | Creates a Traefik Ingress for the UI. Login and WebSockets through it are not verified yet. |
| `ui.ingress.host` | `""` | Required when the Ingress is enabled. |
| `ui.ingress.className` | `traefik` | Ingress class. |
| `ui.ingress.insecureBackend` | `true` | Adds a Traefik `ServersTransport` that accepts the UI's self-signed certificate. |
| `tools.python` | `mirror.gcr.io/library/python:3.13.1-alpine3.21` | Image for the download step. Use a fully qualified ref. |
| `tools.ctr` | `mirror.gcr.io/rancher/k3s:v1.31.4-k3s1` | Image whose `ctr` talks to the node's containerd. Use a fully qualified ref. |
| `containerdSocket` | `/run/k3s/containerd/containerd.sock` | The node's containerd socket. |
| `downloadVolumeSizeLimit` | `3Gi` | Scratch space for the installer and `image.tar`, deleted after the import. |
| `localImage` | `localhost/unifi-os-server` | Local-only name the image is imported under. |

## Upgrade

A new UniFi OS Server release means a new chart version with the new installers. `helm upgrade` replaces the pod once: the old pod stops (a clean systemd halt) before the new one downloads and imports the new version. Data on the PVC is kept. Downgrades are refused unless `uos.allowDowngrade=true`.

After importing the new version, `import-image` unpins and removes the other versions of `localhost/unifi-os-server` on the node, so each upgrade frees the old image (about 2.3 GB). The cleanup is best effort: if it fails, its log says so and the pod starts anyway; remove the leftover on the node with `k3s crictl rmi localhost/unifi-os-server:<old-version>` (not `ctr images rm`, which only removes the tag and frees nothing).

## Uninstall

```sh
helm uninstall uos --namespace unifi
```

That leaves:
- **The data PVC** `data-uos-0`: StatefulSet claims are kept on purpose. Delete it (and with it all console data) with `kubectl -n unifi delete pvc data-uos-0`, or delete the namespace.
- **The current image** on the node, pinned. Remove it on the node with `k3s crictl rmi localhost/unifi-os-server:<version>` (e.g. `k3s crictl rmi localhost/unifi-os-server:5.1.42`), plus the two tool images if nothing else uses them.

Factory-reset any devices you adopted if they move to another controller.

## Troubleshooting

- **Pod Pending:** a host port is taken by another pod, the node lacks resources, or `nodeSelector`/`affinity` matches no node. See `kubectl -n unifi describe pod uos-0`.
- **`Init:Error` in `fetch`:** see its log: a failed download, a sha256 mismatch (the URL and sha256 don't match), an unsupported architecture, or "installer layout changed".
- **`Init:Error` in `configure`:** usually the downgrade refusal; the log says which versions.
- **Running but not Ready, or the UI misbehaves:** the container's stdout is empty, because systemd runs inside. Use the journal, which persists on the PVC:

  ```sh
  kubectl -n unifi exec uos-0 -- systemctl --failed
  kubectl -n unifi exec uos-0 -- systemctl is-system-running
  kubectl -n unifi exec uos-0 -- journalctl -b --no-pager -n 200
  kubectl -n unifi exec uos-0 -- journalctl -u unifi-core -u unifi --no-pager -n 200
  ```

- **Devices don't adopt:** check that they can reach `http://<node-ip>:<informPort>/inform` (it answers 400 to a plain GET), that you used that port in `set-inform`, and that `system_ip` in the `configure` log is an address they can reach.

## Known issues

- Tested only against k3s 1.31 (containerd 1.7). On a node with containerd 2.x, the `ctr`/`crictl` from `tools.ctr` (k3s 1.31) are untested; set `tools.ctr` to the node's k3s version if the image steps fail.
- Rolling back after a failed upgrade (`helm rollback`) needs `uos.allowDowngrade=true`: `configure` records the newer version on the data before the console starts, even if the upgrade then fails, and the downgrade guard refuses the older one.
- Changing only the installer URL/sha256 for the same `uos.version` doesn't re-download: the image for that version is already on the node. Remove it on the node (`k3s crictl rmi localhost/unifi-os-server:<version>`) and restart the pod.
- When installed from the Portal console, only the UI NodePort (30443) is checked for conflicts, not the host ports (inform, 3478/udp, 10003/udp, ...). A clash with another pod leaves the pod Pending; a clash with a host process isn't detected at all (see Requirements).

## Release

To publish a chart version: Releases → "Draft a new release" → tag `vX.Y.Z` → Publish. The workflow lints the chart, refuses a version that's already published, packages it with the version from the tag and pushes it to `oci://ghcr.io/sjultra/charts`.
