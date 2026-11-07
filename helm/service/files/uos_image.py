#!/usr/bin/env python3
"""Fetch, verify and extract the UniFi OS Server image from Ubiquiti's official installer.

Never executes the installer. The installer is an ELF binary with a plain ZIP appended
(entries: image.tar, portmap.json, mounts.json, discovery, uosserver, ...). Python's
zipfile finds the ZIP by its end-of-central-directory record, so the prepended ELF is
ignored. image.tar is an OCI layout + docker-archive tarball (ctr/docker can import it).

Usage:
  uos_image.py fetch   <url> <sha256> <installer-out>
  uos_image.py extract <installer> <out-dir>      # writes image.tar, portmap.json, mounts.json; prints image ref
  uos_image.py ref     <image.tar>                # prints io.containerd.image.name from index.json
Stdlib only, so it runs in a stock python image. Run with `python3 -I`.
"""
import hashlib, json, shutil, sys, tarfile, urllib.request, zipfile, os

REQUIRED = ("image.tar",)
OPTIONAL = ("portmap.json", "mounts.json")   # only in installers >= 5.1.15


def fetch(url, sha256, out):
    h = hashlib.sha256()
    tmp = out + ".part"
    req = urllib.request.Request(url, headers={"User-Agent": "unifi-os-server-chart"})  # the default Python-urllib UA gets 403
    with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b:
                break
            h.update(b)
            f.write(b)
    got = h.hexdigest()
    if got != sha256.lower():
        os.remove(tmp)
        sys.exit(f"sha256 mismatch: expected {sha256}, got {got}")
    os.replace(tmp, out)
    print(f"downloaded {out} sha256={got}")


def image_ref(tar_path):
    with tarfile.open(tar_path) as t:
        idx = json.load(t.extractfile("index.json"))
    m = idx["manifests"][0]
    return m["annotations"]["io.containerd.image.name"], m.get("platform", {}).get("architecture")


def extract(installer, out_dir):
    with open(installer, "rb") as f:
        if f.read(4) != b"\x7fELF":
            sys.exit("not an ELF installer")
    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(installer) as z:
        names = z.namelist()
        missing = [n for n in REQUIRED if n not in names]
        if missing:
            sys.exit(f"installer layout changed: missing {missing}; entries: {names}")
        for n in REQUIRED + tuple(o for o in OPTIONAL if o in names):
            with z.open(n) as src, open(os.path.join(out_dir, n), "wb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
    ref, arch = image_ref(os.path.join(out_dir, "image.tar"))
    print(ref)
    print(f"arch={arch} entries={names}", file=sys.stderr)


if __name__ == "__main__":
    cmd, *a = sys.argv[1:] or ["-h"]
    if cmd == "fetch" and len(a) == 3:
        fetch(*a)
    elif cmd == "extract" and len(a) == 2:
        extract(*a)
    elif cmd == "ref" and len(a) == 1:
        print(image_ref(a[0])[0])
    else:
        sys.exit(__doc__)
