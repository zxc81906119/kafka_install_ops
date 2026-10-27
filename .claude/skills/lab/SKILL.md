---
name: lab
description: Operate the Docker-based lab (~/kafka-lab, compose project `lab`): start/stop, enter hosts, check cluster health, diagnose slowness. Use when the user asks about the environment state, "幫我看一下目前狀況", or something in the lab hangs.
---

# Lab operations

One lab: compose project `lab` in `~/kafka-lab/` (built by the hands-on guide, chapter 0), 14 containers
`lab-<host>-1` (ops02, repo01, kc01-03, kb01-04, rest01-02, c3-01, ad01, lb01) + download host `dl01`.
Docker Desktop VM has ~10.7 GB RAM: run nothing else alongside.

- Start/stop: `cd ~/kafka-lab && docker compose -f compose.yml up -d|stop`.
- From zero: `bash docs/journey-src/tools/run-full.sh customer` (tears down everything except
  `~/kafka-lab/landing` and `landing-extra`) or `bash install/lab/run-customer.sh`.
- Run logs: `~/kafka-lab-runs/`; check them with `docs/journey-src/tools/scan-log.sh <log>`.

## Entering hosts
- Operator host (as root = what PSMP gives a person): `docker exec -it -w /root lab-ops02-1 bash`. ops02 reaches every host as `cpuser` with
  `/secure/ssh/cpuser_ed25519` (docker volume `ops-secure`, survives restarts; `~/.ssh/config` selects it). Nothing to re-paste after a cold boot;
  check `mountpoint /secure/ssh` if ssh says Permission denied.
- Any host as root ("bank" work): `MSYS_NO_PATHCONV=1 docker exec lab-<host>-1 bash -c '...'`
- Download host: `docker exec -it dl01 bash` (`/out` = landing zone).
- Windows paths for `-v` / `docker cp` / Node: `"$(cygpath -m "$PWD/dir")"`; keep `MSYS_NO_PATHCONV=1`.

## Health checks (from ops02 as root, `export JAVA_HOME=/opt/java/current`)
- Services: `systemctl is-active confluent-server` on kc*/kb*; `confluent-kafka-rest` on rest*;
  `prometheus alertmanager confluent-control-center` on c3-01.
- Quorum: `kafka-metadata-quorum --bootstrap-controller kc01.poc.lab:9093 --command-config ~/conf/client-internal.properties describe --status`
- MDS: `curl -sk -o /dev/null -w %{http_code} https://kbNN.poc.lab:8090/v1/metadata/id` → 200
- REST: legacy cert → 200, other cert → 401, no cert → 000, via `rest.poc.lab` → 200.
- C3: `https://c3-01.poc.lab:9021/` → 200.
- Acceptance: guide chapter 19 / `bash install/steps/19-acceptance.sh`.

## When things are slow or hang
1. `MSYS_NO_PATHCONV=1 timeout 15 docker exec lab-ops02-1 sh -c 'timeout 5 ip addr | wc -l'` — if this hangs in
   every container, the VM kernel's netlink is stuck → Java name resolution blocks → broker listener threads
   queue. Restart Docker Desktop. Do not touch configs.
2. Memory: `docker exec lab-ops02-1 free -m`.
3. Reads over the Windows bind mount are ~2 MB/s: `rpm -K`/`sha256sum` on 3 GB takes long; copy into a docker
   volume first.
4. `pgrep` in Git Bash can't see container processes: check with `docker exec <c> ps -eo etime,args`.
5. Always put a `timeout` on docker exec commands that touch Kafka; never `pkill -f <pattern>` that matches your
   own `bash -c` command line.
6. Transient Internet mirror errors (e.g. 3.2 "Failed to download metadata for repo 'appstream'") are not guide
   bugs: rerun.
