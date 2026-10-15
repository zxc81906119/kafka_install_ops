#!/usr/bin/env bash
# Runs INSIDE a temporary cp-node container with Internet access (download host) - tar.gz strategy.
# Output: /out/tar/*.tar.gz  +  /out/manifest-tar.json
# Official checksums are verified where the vendor publishes them (Temurin);
# Confluent Platform / Control Center archives have no published checksum -> sha256 recorded on download.
set -Eeuo pipefail
set -a
# shellcheck source=/dev/null
source /in/versions.env
set +a
out=/out/tar
mkdir -p "$out"
log() { printf '[download-tar] %s\n' "$*"; }

fetch() { # <url> <file>
  local url=$1 f=$out/$2
  if [[ -s $f ]]; then log "exists: $2"; return 0; fi
  log "downloading $url"
  curl -fsSL --retry 3 -o "$f.part" "$url"
  mv "$f.part" "$f"
}

declare -A official=()

# Confluent Platform (all components incl. security plugins) and Control Center next-gen
fetch "$CONFLUENT_TAR_BASE/$CP_RELEASE/confluent-$CP_VERSION.tar.gz" "confluent-$CP_VERSION.tar.gz"
fetch "https://packages.confluent.io/confluent-control-center-next-gen/archive/confluent-control-center-next-gen-$C3_VERSION.tar.gz" \
  "confluent-control-center-next-gen-$C3_VERSION.tar.gz"

# Temurin JDK 21 (latest GA of the major) - checksum from the Adoptium API
log "resolving Temurin ${JDK_TAR_MAJOR} via api.adoptium.net"
meta=$(curl -fsSL "https://api.adoptium.net/v3/assets/latest/${JDK_TAR_MAJOR}/hotspot?os=linux&architecture=x64&image_type=jdk&vendor=eclipse")
read -r jdk_url jdk_file jdk_sha jdk_release < <(python3 -c '
import json,sys
a=json.load(sys.stdin)[0]
p=a["binary"]["package"]
print(p["link"], p["name"], p["checksum"], a["release_name"])' <<<"$meta")
fetch "$jdk_url" "$jdk_file"
official[$jdk_file]=$jdk_sha

# Older CP archive kept in the internal repo for the upgrade / rollback drill
# (the Confluent CLI is part of the CP archive: bin/confluent - no separate download needed)
fetch "$CONFLUENT_TAR_BASE/$CP_UPGRADE_FROM_RELEASE/confluent-$CP_UPGRADE_FROM.tar.gz" "confluent-$CP_UPGRADE_FROM.tar.gz"

log "verifying vendor checksums"
for f in "${!official[@]}"; do
  have=$(sha256sum "$out/$f" | awk '{print $1}')
  [[ $have == "${official[$f]}" ]] || { echo "CHECKSUM MISMATCH $f: $have != ${official[$f]}"; exit 1; }
  log "ok (vendor checksum): $f"
done

log "writing manifest-tar.json"
python3 - "$out" "$jdk_release" <<'PY'
import json, os, sys, hashlib, datetime
out, jdk_release = sys.argv[1], sys.argv[2]
items = []
for f in sorted(os.listdir(out)):
    if not f.endswith((".tar.gz", ".tgz")):
        continue
    p = os.path.join(out, f)
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    items.append({"file": f, "sha256": h.hexdigest(), "size": os.path.getsize(p)})
json.dump({
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "downloaded_by": os.environ.get("DOWNLOADED_BY", "unknown"),
    "jdk_release": jdk_release,
    "note": "Temurin verified against the vendor checksum; CP/C3 archives have no published checksum",
    "packages": items,
}, open(os.path.join(os.path.dirname(out), "manifest-tar.json"), "w"), indent=2)
print(f"[download-tar] manifest: {len(items)} archives")
PY
