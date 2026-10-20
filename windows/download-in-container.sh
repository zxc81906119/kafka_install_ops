#!/usr/bin/env bash
# Runs INSIDE a temporary cp-node container with Internet access (download host).
# Output layout under /out:
#   rpm/confluent/  rpm/adoptium/  rpm/os-deps/   gpg-keys/   manifest-rpm.json
set -Eeuo pipefail
set -a
# shellcheck source=/dev/null
source /in/versions.env
set +a

out=/out
stage=/tmp/stage
mkdir -p "$stage" "$out/gpg-keys" "$out/rpm/confluent" "$out/rpm/adoptium" "$out/rpm/os-deps"

log() { printf '[download] %s\n' "$*"; }

# Public repos for the download host only (target hosts never see these).
sed -i 's/^enabled=0/enabled=1/' /etc/yum.repos.d/rocky*.repo
cat >/etc/yum.repos.d/upstream-confluent.repo <<EOF
[confluent-${CP_RELEASE}]
name=Confluent ${CP_RELEASE}
baseurl=${CONFLUENT_RPM_BASE}/${CP_RELEASE}
gpgcheck=1
gpgkey=${CONFLUENT_GPG_KEY}
enabled=1
[confluent-${CP_UPGRADE_FROM_RELEASE}]
name=Confluent ${CP_UPGRADE_FROM_RELEASE}
baseurl=${CONFLUENT_RPM_BASE}/${CP_UPGRADE_FROM_RELEASE}
gpgcheck=1
gpgkey=${CONFLUENT_GPG_KEY}
enabled=1
[confluent-c3]
name=Confluent Control Center next-gen
baseurl=${C3_RPM_BASE}
gpgcheck=1
gpgkey=${C3_GPG_KEY}
enabled=1
[adoptium]
name=Adoptium
baseurl=${ADOPTIUM_RPM_BASE}
gpgcheck=1
gpgkey=${ADOPTIUM_GPG_KEY}
enabled=1
EOF

log "fetching GPG keys"
curl -fsSL "$CONFLUENT_GPG_KEY" -o "$out/gpg-keys/confluent.asc"
curl -fsSL "$C3_GPG_KEY" -o "$out/gpg-keys/confluent-c3.asc"
curl -fsSL "$ADOPTIUM_GPG_KEY" -o "$out/gpg-keys/adoptium.asc"
cp /etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9 "$out/gpg-keys/rocky-9.asc"
for k in "$out"/gpg-keys/*.asc; do rpm --import "$k"; done

dnf -q makecache

# name-version pairs to download (exact versions, never "latest")
cp_set() { # $1=version
  local v=$1 p
  for p in confluent-server confluent-security confluent-kafka-rest confluent-cli; do printf "%s-%s " "$p" "$v"; done
}
# One resolve per set: two CP versions in one transaction would conflict on their = version deps.
sets=(
  "$(cp_set "$CP_VERSION")"
  "$(cp_set "$CP_UPGRADE_FROM")"
  "confluent-control-center-next-gen-$C3_VERSION $PKGS_C3_OS"
  # JDK_SOURCE=os: the OS repo's OpenJDK (lands in os-deps, standing for the bank's RHEL repo); vendor: Temurin
  "$([[ ${JDK_SOURCE:-vendor} == os ]] && printf '%s' "$JDK_PACKAGE" || printf '%s-%s' "$JDK_PACKAGE" "$JDK_VERSION")"
  "$PKGS_OS_BASELINE"
  "$PKGS_OPS_OS"
)
for s in "${sets[@]}"; do
  log "dnf download --resolve: $s"
  # shellcheck disable=SC2086
  dnf -q download --resolve --arch x86_64 --arch noarch --destdir "$stage" $s
done

# Classify by origin repo so the internal repo mirrors the upstream split.
mapfile -t cp_names < <(dnf -q repoquery --repo "confluent-${CP_RELEASE}" --repo "confluent-${CP_UPGRADE_FROM_RELEASE}" --repo confluent-c3 --qf '%{name}' | sort -u)
mapfile -t ad_names < <(dnf -q repoquery --repo adoptium --qf '%{name}' | sort -u)
declare -A is_cp=() is_ad=()
for n in "${cp_names[@]}"; do is_cp[$n]=1; done
for n in "${ad_names[@]}"; do is_ad[$n]=1; done

moved=0
for f in "$stage"/*.rpm; do
  n=$(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null)
  if [[ -n ${is_cp[$n]:-} ]]; then d=confluent
  elif [[ -n ${is_ad[$n]:-} ]]; then d=adoptium
  else d=os-deps; fi
  if [[ ! -f $out/rpm/$d/$(basename "$f") ]]; then
    mv "$f" "$out/rpm/$d/"
    moved=$((moved + 1))
  fi
done
log "new RPM files: $moved"

log "verifying GPG signatures"
bad=0
while IFS= read -r -d '' f; do
  rpm -K "$f" | grep -q 'digests signatures OK' || { echo "BAD SIGNATURE: $f"; bad=1; }
done < <(find "$out/rpm" -name '*.rpm' -print0)
[[ $bad -eq 0 ]] || exit 1

log "monitoring agent: Prometheus JMX exporter $JMX_EXPORTER_VERSION"
mkdir -p "$out/tools"
jar="$out/tools/$(basename "$JMX_EXPORTER_URL")"
[[ -s $jar ]] || curl -fsSL --retry 3 -o "$jar" "$JMX_EXPORTER_URL"
want=$(curl -fsSL "$JMX_EXPORTER_URL.sha1")
have=$(sha1sum "$jar" | awk '{print $1}')
[[ $have == "$want" ]] || { echo "JMX exporter checksum mismatch ($have != $want)"; exit 1; }
log "ok (Maven Central sha1): $(basename "$jar")"

log "writing manifest-rpm.json"
python3 - "$out" <<'PY'
import json, os, sys, hashlib, subprocess, datetime
out = sys.argv[1]
items = []
for repo in ("confluent", "adoptium", "os-deps"):
    d = os.path.join(out, "rpm", repo)
    for f in sorted(os.listdir(d)):
        if not f.endswith(".rpm"):
            continue
        p = os.path.join(d, f)
        sha = hashlib.sha256()   # in 1 MiB chunks: the C3 RPM alone is over 1 GB
        with open(p, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                sha.update(chunk)
        h = sha.hexdigest()
        nevra = subprocess.check_output(["rpm", "-qp", "--qf", "%{NAME}|%{VERSION}-%{RELEASE}|%{VENDOR}", p],
                                        stderr=subprocess.DEVNULL).decode().split("|")
        items.append({"repo": repo, "file": f, "name": nevra[0], "version": nevra[1],
                      "vendor": nevra[2], "sha256": h, "size": os.path.getsize(p)})
manifest = {
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "downloaded_by": os.environ.get("DOWNLOADED_BY", "unknown"),
    "sources": {k: v for k, v in os.environ.items() if k.endswith(("_RPM_BASE", "_GPG_KEY"))},
    "gpg_verified": True,
    "packages": items,
}
json.dump(manifest, open(os.path.join(out, "manifest-rpm.json"), "w"), indent=2)
print(f"[download] manifest: {len(items)} packages")
PY
