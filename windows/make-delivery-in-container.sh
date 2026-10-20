#!/usr/bin/env bash
# Runs INSIDE a cp-node container: copies the files that go to the bank from /p (packages/) into /d (delivery dir).
#   env: WITH_UPGRADE WITH_TAR WITH_OS_DEPS (0/1)
# Layout of /d mirrors packages/ so the same import and verify steps apply.
set -Eeuo pipefail
set -a
# shellcheck source=/dev/null
source /in/versions.env
set +a

src=/p dst=/d
log() { printf '[delivery] %s\n' "$*"; }
[[ -z $(ls -A "$dst" 2>/dev/null) ]] || { echo "delivery dir is not empty: refusing to mix two deliveries"; exit 1; }
mkdir -p "$dst/rpm/confluent" "$dst/gpg-keys" "$dst/tools"

# --- RPMs, chosen from the download manifest (never by file-name guessing)
python3 - "$src" "$dst" <<'PY'
import json, os, shutil, sys
src, dst = sys.argv[1:3]
env = os.environ
cp, c3 = env["CP_VERSION"], env["C3_VERSION"]
versions = {cp} | ({env["CP_UPGRADE_FROM"]} if env.get("WITH_UPGRADE") == "1" else set())
m = json.load(open(os.path.join(src, "manifest-rpm.json")))
keep = []
for p in m["packages"]:
    v = p["version"].split("-")[0]
    if p["repo"] == "confluent":
        ok = (v == c3) if p["name"] == "confluent-control-center-next-gen" else v in versions
    elif p["repo"] == "os-deps":
        ok = env.get("WITH_OS_DEPS") == "1"
    else:                                   # adoptium: only while JDK_SOURCE=vendor
        ok = env.get("JDK_SOURCE", "vendor") == "vendor"
    if ok:
        d = os.path.join(dst, "rpm", p["repo"])
        os.makedirs(d, exist_ok=True)
        shutil.copy2(os.path.join(src, "rpm", p["repo"], p["file"]), d)
        keep.append(p)
m["packages"] = keep
m["delivery"] = {"cp_version": cp, "c3_version": c3, "upgrade_from": sorted(versions - {cp}),
                 "with_os_deps": env.get("WITH_OS_DEPS") == "1", "with_tar": env.get("WITH_TAR") == "1"}
json.dump(m, open(os.path.join(dst, "manifest-rpm.json"), "w"), indent=2)
print(f"[delivery] RPMs: {len(keep)}")
PY

# --- every confluent-* dependency must be inside the delivery (dnf resolves them from the internal repo)
missing=0
mapfile -t rpms < <(find "$dst/rpm" -name '*.rpm' | sort)
provides=$(rpm -qp --provides "${rpms[@]}" 2>/dev/null | awk '{print $1}' | sort -u)
while read -r req; do
  grep -qxF "$req" <<<"$provides" || { echo "MISSING dependency: $req"; missing=1; }
done < <(rpm -qp --requires "${rpms[@]}" 2>/dev/null | awk '$1 ~ /^confluent-/ {print $1}' | sort -u)
[[ $missing -eq 0 ]] || exit 1
log "all confluent-* dependencies are inside the delivery"

# --- public keys: only those that sign something in the delivery
cp "$src/gpg-keys/confluent.asc" "$src/gpg-keys/confluent-c3.asc" "$dst/gpg-keys/"
if [[ -d $dst/rpm/adoptium ]]; then cp "$src/gpg-keys/adoptium.asc" "$dst/gpg-keys/"; fi
if [[ -d $dst/rpm/os-deps ]]; then cp "$src/gpg-keys/rocky-9.asc" "$dst/gpg-keys/"; fi

# --- tools: monitoring agent + the current OP menu only
cp "$src/tools/$(basename "$JMX_EXPORTER_URL")" "$src/tools/opmenu-$OPMENU_VERSION.tar.gz" "$dst/tools/"

# --- tar.gz strategy (optional)
if [[ ${WITH_TAR:-0} == 1 ]]; then
  mkdir -p "$dst/tar"
  cp "$src/tar/confluent-$CP_VERSION.tar.gz" "$src/tar/confluent-control-center-next-gen-$C3_VERSION.tar.gz" "$dst/tar/"
  cp "$src"/tar/OpenJDK*.tar.gz "$dst/tar/" 2>/dev/null || true
  if [[ -f $src/manifest-tar.json ]]; then cp "$src/manifest-tar.json" "$dst/"; fi
fi

# --- checksums of exactly what is delivered
(cd "$dst" && find rpm tools gpg-keys $([[ -d $dst/tar ]] && echo tar) -type f | LC_ALL=C sort | xargs -r sha256sum > SHA256SUMS)

# --- human-readable list for the ticket
{
  echo "Confluent Platform $CP_VERSION / Control Center $C3_VERSION - delivery list"
  echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  printf '%-70s %12s\n' FILE BYTES
  while read -r _ f; do printf '%-70s %12s\n' "$f" "$(stat -c %s "$dst/$f")"; done < "$dst/SHA256SUMS"
  echo
  echo "total: $(wc -l < "$dst/SHA256SUMS") files, $(du -sh --exclude=report "$dst" | cut -f1)"
  echo
  echo "NOT included (provided by the bank's RHEL repository): JDK ($JDK_PACKAGE), OS packages"
  echo "  C3 prerequisites: $PKGS_C3_OS; baseline: $PKGS_OS_BASELINE"
} > "$dst/DELIVERY.txt"
log "$(wc -l < "$dst/SHA256SUMS") files, $(du -sh "$dst" | cut -f1)"
