---
name: lab
description: Operate the Docker-based lab (cp-poc, cp-man, ~/kafka-lab): start/stop, enter hosts, check cluster health, diagnose slowness. Use when the user asks about the environment state, "幫我看一下目前狀況", or something in the lab hangs.
---

# Lab operations

Two compose projects share one Docker Desktop VM (~10.7 GB RAM). Run one at a time.

| Project | File | Hosts | Purpose |
|---|---|---|---|
| `cp-poc` | `docker/compose.yml` | ops01 (cpctl), repo01, kc01-04, kb01-04, rest01-02, c3-01, ad01, lb01, jump01 | cpctl-driven install |
| `cp-man` | `docker/manual/compose.yml` | ops02 (bare), repo01, kc01-03, kb01-04, rest01-02, c3-01, ad01, lb01 | manual install (the journey) |
| `lab` | `~/kafka-lab/compose.yml` (built by the journey guide) | same as cp-man, containers `lab-<host>-1` | self-contained variant |

Switch: `docker compose -f docker/compose.yml stop` → `docker compose -f docker/manual/compose.yml up -d`
(`down -v` for a clean slate). `cp-poc-kc04-1` may need a separate `docker stop`.

## Entering hosts
- Operator host as cpadmin: `docker exec -it -u cpadmin -w /home/cpadmin cp-man-ops02-1 bash`
- Any host as root ("bank" work): `MSYS_NO_PATHCONV=1 docker exec cp-man-<host>-1 bash -c '...'`
- Download host: `docker exec -it dl01 bash` (`/out` = landing zone).
- Windows paths for `-v` / `docker cp`: `"$(cygpath -m "$PWD/dir")"`; keep `MSYS_NO_PATHCONV=1`.

## Health checks (from ops02 as cpadmin, `export JAVA_HOME=/opt/java/current` or the installed JDK path)
- Services: `systemctl is-active confluent-server` on kc*/kb*; `confluent-kafka-rest` on rest*;
  `prometheus alertmanager confluent-control-center` on c3-01.
- Quorum: `kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status`
- MDS: `curl -s -o /dev/null -w %{http_code} https://kbNN.poc.lab:8090/v1/metadata/id` → 200
- TOKEN listener: `kafka-topics --bootstrap-server kb01.poc.lab:9094 --command-config ~/conf/client-admin.properties --list`
- REST: legacy cert → 200, other cert → 401, no cert → 000, via `rest.poc.lab` → 200.
- C3: `https://c3-01.poc.lab:9021/` → 200 (Windows: `https://localhost:19021`).

## When things are slow or hang
1. `MSYS_NO_PATHCONV=1 timeout 15 docker exec cp-man-ops02-1 sh -c 'timeout 5 ip addr | wc -l'` — if this hangs in
   every container, the VM kernel's netlink is stuck → Java name resolution blocks → broker TOKEN listener
   threads queue (9094 fills with CLOSE-WAIT). Restart Docker Desktop. Do not touch configs.
2. Memory: `docker exec cp-man-ops02-1 free -m`; if MemAvailable is tiny, stop the other project.
3. Reads over the Windows bind mount are ~2 MB/s: `rpm -K`/`sha256sum` on 3 GB takes 20+ minutes; copy into a
   docker volume first (`docker cp` is much faster than reading through the mount).
4. Always put a `timeout` on docker exec commands that touch Kafka; never `pkill -f <pattern>` that matches your
   own `bash -c` command line.

## Memory and cleanup
- `dl01` and leftover `docker run` containers can be removed with `docker rm -f`.
- `packages-manual.old/` (6 GB) and `delivery/` are disposable copies.
