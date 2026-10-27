# untitled7 — Confluent Platform 8.3 離線安裝 PoC（銀行）

> **語言規則（最優先，每一則都適用）**：所有給使用者看的文字一律用**繁體中文**，英文只用在技術名詞與指令
> （dnf、RPM、versionlock、MDS、CyberArk、`kafka-features` …）。包括：做事過程中的進度說明、背景工作回報、
> 表格、最後的總結、問題選項。不要因為工具輸出或上一則是英文就跟著改用英文。使用者不需要再提醒。

PoC for installing Confluent Platform 8.3.2 + Control Center 2.6.1 fully offline at a bank.
Simulated hosts run in Docker Desktop on Windows 11 (project `lab`, built from `~/kafka-lab`); driven from Git Bash.
Details of the architecture and every component: @README.md

## Working with the user
- Reply in **繁體中文**; technical terms stay in English (dnf, RPM, versionlock, MDS, CyberArk …).
- Ask decisions as **single/multi-select choices** (AskUserQuestion), not prose.
- The manual (`docs/journey-src/journey.md`) is **hand commands first**; `install/steps/NN-*.sh` automate the same
  path. New procedures are validated by running the raw commands on the lab, never only through the scripts.
- The user drives the design discussion (`redesign/README.md`); record only confirmed decisions and open questions.
- Never print a password, key or token in chat. Secrets live in 0600 files (`~/secrets/*.pass`, `~/pki/store.pass`,
  `~/kafka-lab/pvwa/`, `~/kafka-lab/secrets.env`) and are read into variables at run time.

## Session start and hand-off (skill `handoff`)
- First: `git branch --show-current` + `git worktree list`, then read `.claude/state/status-<branch>.md` and the
  newest entries in `.claude/state/log/`. Summarise where things stand before doing anything.
- Update the status file at every milestone (step verified, decision made, document produced, lab state changed);
  add a dated log file for each topic. Auto-memory holds only user preferences, never project state.
- One session = one git worktree = one branch. The Docker lab is shared: note "lab 使用中" in the status file.

## Repository map
- `docs/journey-src/` — `journey.md` (the hands-on guide, chapters 0–27, single `customer` mode)
  + `diagrams.js` → `docs/Confluent-安裝旅程-手把手.docx`; `tools/run-full.sh customer [from] [to]` runs the guide's
  blocks on the lab (`run-chapter.js` extracts them, `scan-log.sh` flags rc=0 output that is really a failure).
- `docs/questions-src/questions.md` → `docs/Confluent-請銀行確認的事項.docx` (`node build.js`).
- `docs/deck-src/install.js` + `install-steps.js` → `docs/Confluent-RPM安裝流程.pptx` (14-page deck for bank managers).
- `install/` — installer that follows the guide one script per chapter (`install.sh`, `steps/01–26`, `conf/site.env`);
  `install/lab/` = lab-only (`bank-sim.sh` plays the bank, `run-customer.sh`, `run-upgrade-drill.sh`).
- `opmenu/` — OP menu source (the **only** copy; never edit a sibling project such as `untitled6`).
- `redesign/README.md` — design decisions, lessons, open questions.
- Generated documents: edit the sources, then rebuild (skill `build-docs`).
- Not in git: `*.p12|*.pem|*.key|*.crt`, `secrets.env`, licences, packages (the lab's landing zone is `~/kafka-lab/landing`).

## Branches
- `redesign` — current work. The old cpctl PoC (`installer/`, `docker/` cp-poc/cp-man labs, `windows/` tools, old
  manual, PoC deck, host checklist, bastion jump01 design) was removed on 2026-10-25; it survives only on `main`.
  Don't consult `main` for current design.
- Commit only when asked; never push unless asked; never commit secrets, licence or packages.

## Lab facts
- One lab: project `lab` (14 containers + `dl01`, subnets 172.35/172.36), built from `~/kafka-lab` per journey chapter 0.
  Docker Desktop VM has ~10.7 GB, so never run anything else alongside it.
- Enter hosts: `docker exec -it -w /root lab-ops02-1 bash` (ops02 as **root** = what PSMP gives a person; no PVWA/PSMP in the lab),
  `docker exec -it lab-<host>-1 bash` (root, "bank" actions). Prefix docker commands with `MSYS_NO_PATHCONV=1`
  and pass Windows paths through `cygpath -m` (Node is a Windows program: convert paths before handing them over).
- ops02 → all hosts: user `cpuser` (UID/GID 1500, locked password), one key `/secure/ssh/cpuser_ed25519` (root 0400) on the
  separate file system simulated by docker volume `ops-secure` (no LUKS); `~/.ssh/config` makes plain `ssh kb01.poc.lab` use it.
  It survives restarts (volume), nothing to re-paste. `~/kafka-lab/pvwa/` holds platform secrets only, never an ssh key.
- Bind mounts of Windows folders (9p) are slow for multi-GB reads: download inside the container, then copy out.
- After a Docker Desktop restart check `docker ps --format '{{.Names}}' | cut -d- -f1 | sort | uniq -c`.
- If every container's `timeout 5 ip addr` hangs, the VM's netlink is wedged: restart Docker Desktop, don't debug configs.
- In the lab Claude plays the bank (`install/lab/bank-sim.sh`, or the guide's 銀行 blocks): AD (samba-tool on ad01),
  CA (`~/kafka-lab/ca`), OS repo and NTP on repo01, nginx on lb01, PVWA (`~/kafka-lab/pvwa/`), the OS team (cpuser account, sshd drop-in, public key line with `from=`, install-period sudo on every host incl. ops02; `bank-sim.sh prepare`),
  monitoring (Prometheus, Alertmanager, Grafana, webhook receiver) as four
  `lab-mon-*` containers (`bank-sim.sh monitoring`; remove them with `monitoring-stop` before any `down -v`).

## Design decisions in force (details: redesign/README.md)
- RPM install only; Confluent packages are the only files we bring in; OS packages come from the bank's repo
  (Satellite / Nexus / plain httpd — all look the same to dnf).
- JDK 21 is delivered by the bank as a tar; we install to `/opt/java/<dir>` + `/opt/java/current`, register
  `java`/`keytool` with `alternatives`, set `JAVA_HOME` in `/etc/profile.d/java.sh` and in each systemd drop-in.
- Only Confluent packages and the JDK are version-locked; C3's `cyrus-sasl`/`openssl-devel` follow OS patching.
- Apps connect directly with SCRAM; apps via REST Proxy must use client certificates (REST has no password path).
- Humans use AD accounts; RBAC binds AD groups, never individuals. Platform services use certificates, not AD.
- CyberArk at this customer = PAM only: a person logs in to the PVWA web page (AD + MFA), PSMP logs them in to ops02 as root; root and
  `svc-mds-bind` rotated by CPM; platform secrets are vaulted in PVWA but rotated manually (Secret Protection master key: PVWA stores it, we rotate it).
- One SSH key pair (ed25519), private key only on ops02 in a separate encrypted file system `/secure/ssh` (root 0400), not in CyberArk, not backed up;
  ops02 rebuilt = new pair + OS team redeploys the public key. Public key in each host's `cpuser` authorized_keys with only `from="<ops02 IP>,127.0.0.1,::1"`.
  Rotation is manual (new+old coexist, guide 19.6). `cpuser` sudo: full `NOPASSWD` during install/upgrade, afterwards only `/etc/sudoers.d/cpuser-ops`
  listing every unit and exact command form (sudoers matches the whole argument list; no `confluent-*` wildcard).
- ops02 is both the install host and the operators' login point (OP menu runs there as root); no separate bastion. Because operators are root, the menu's
  host-level permission check is a process control, not a hard barrier; traceability = CyberArk login records + PSMP recording.
- Monitoring (chapter 17): JMX exporter on controllers, brokers, REST Proxy, C3; Prometheus, Alertmanager and Grafana are the bank's, we deliver
  config + Confluent's official jmx-monitoring-stacks files (pinned commit, brought in through chapters 1-2). C3's embedded Prometheus/Alertmanager stay
  untouched and are not used for alerting (no C3 alert triggers/actions).
- MDS token key pair is fixed (rotate only on compromise); cpuser sudo is `NOPASSWD` during install; CPM's reconcile account is not cpuser.

## Gotchas learned the hard way
- Before `systemctl start` of an RPM service, confirm the drop-in is in effect:
  `systemctl show <unit> -p ExecStart` must point to **our** properties file, else the RPM default config starts
  (REST Proxy came up as plain HTTP that way).
- `systemctl enable --now` does not restart a running service; after config changes use `restart`.
- `/etc/confluent/ssl`, `/var/lib/kafka` are 0750: verification commands need `sudo ls`/`sudo stat`.
- C3 must own `/etc/confluent-control-center/*-generated.yml` (`cp-control-center:confluent`).
- `dnf` metadata is cached 48 h: use `--refresh` right after publishing to the repo.
- Confluent CLI v4 `confluent secret … --passphrase` takes the **value** (`"$(cat file)"`); `@file` and `-` are used
  literally as the passphrase (everything "works", but the real passphrase is never used and the next rotate after a
  rename fails). `kafka-configs` echoes the whole config, passwords included, on error: send its output to /dev/null.
- `kafka-configs --add-config-file` rejects SCRAM credentials (reads `SCRAM_SHA_512`); use `--add-config`.
- Windows Git Bash has no real `python3` (it is the Microsoft Store stub: silent, exit 0): run Python inside a container or on ops02.
- Check run logs line by line, not only `scan-log.sh`: an empty value after "：" means the check's precondition was missing.
- Building a package set with `dnf download --resolve`: use a clean container and download **before** installing
  tools, or the tools' dependencies are missed (`createrepo_c-libs`).
