#!/usr/bin/env python3
"""Unpack a newer x86_64 glibc for Lumen on DroidDeck.

DroidDeck's FEX runtime (SteamLinuxRuntime_sniper) ships glibc 2.31, but
lumen.bin needs >= 2.34. This downloads Debian bookworm's libc6 (2.36),
verifies it against the SHA256 in the signed-by-https Packages index, and
extracts only the shared objects into <dest>/lib so lumen-runner.sh can start
lumen.bin through that ld.so.

usage: fetch-glibc.py <dest-dir>
"""
import hashlib
import io
import lzma
import os
import sys
import tarfile
import urllib.request

MIRROR = "https://deb.debian.org/debian"
SUITES = ("bookworm", "bookworm-updates")
LIB_PREFIX = "./lib/x86_64-linux-gnu/"


def fetch(url, limit=64 * 1024 * 1024):
    req = urllib.request.Request(url, headers={"User-Agent": "luatools-moon-installer"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = resp.read(limit + 1)
    if len(data) > limit:
        raise RuntimeError("download too large: " + url)
    return data


def find_libc6(suite):
    index = lzma.decompress(fetch("%s/dists/%s/main/binary-amd64/Packages.xz" % (MIRROR, suite)))
    for stanza in index.decode("utf-8", "replace").split("\n\n"):
        fields = {}
        for line in stanza.splitlines():
            if ": " in line and not line.startswith(" "):
                key, _, value = line.partition(": ")
                fields[key] = value
        if fields.get("Package") == "libc6":
            return fields["Filename"], fields["SHA256"]
    return None


def deb_data_tar(deb):
    """Return (name, bytes) of the data.tar.* member of an ar archive."""
    if deb[:8] != b"!<arch>\n":
        raise RuntimeError("not a .deb archive")
    pos = 8
    while pos + 60 <= len(deb):
        name = deb[pos:pos + 16].decode().strip().rstrip("/")
        size = int(deb[pos + 48:pos + 58].decode().strip())
        body = deb[pos + 60:pos + 60 + size]
        if name.startswith("data.tar"):
            return name, body
        pos += 60 + size + (size & 1)
    raise RuntimeError("no data.tar member in .deb")


def main(dest):
    found = None
    for suite in SUITES:
        try:
            found = find_libc6(suite)
        except Exception as exc:  # network or index problem: try the next suite
            print("fetch-glibc: %s index failed: %s" % (suite, exc), file=sys.stderr)
            continue
        if found:
            break
    if not found:
        print("fetch-glibc: libc6 not found in any suite", file=sys.stderr)
        return 1

    filename, want = found
    deb = fetch("%s/%s" % (MIRROR, filename))
    if hashlib.sha256(deb).hexdigest() != want:
        print("fetch-glibc: SHA256 mismatch for %s" % filename, file=sys.stderr)
        return 1

    name, body = deb_data_tar(deb)
    mode = "r:xz" if name.endswith(".xz") else "r:*"
    lib_dir = os.path.join(dest, "lib")
    os.makedirs(lib_dir, exist_ok=True)
    count = 0
    with tarfile.open(fileobj=io.BytesIO(body), mode=mode) as tar:
        for member in tar:
            # Top-level shared objects only; refuses links, devices and
            # anything that would land outside lib_dir.
            if not member.isreg() or not member.name.startswith(LIB_PREFIX):
                continue
            base = member.name[len(LIB_PREFIX):]
            if "/" in base or ".so" not in base:
                continue
            target = os.path.join(lib_dir, base)
            with tar.extractfile(member) as src, open(target + ".tmp", "wb") as out:
                out.write(src.read())
            os.chmod(target + ".tmp", 0o755)
            os.replace(target + ".tmp", target)
            count += 1
    ld = os.path.join(lib_dir, "ld-linux-x86-64.so.2")
    if not os.path.isfile(ld):
        print("fetch-glibc: ld-linux-x86-64.so.2 missing from %s" % filename, file=sys.stderr)
        return 1
    print("fetch-glibc: %s -> %s (%d libraries)" % (os.path.basename(filename), lib_dir, count))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
