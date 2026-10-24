# untitled7 — Confluent Platform 8.3 離線安裝 PoC（銀行）

> **語言規則（最優先，每一則都適用）**：所有給使用者看的文字一律用**繁體中文**，英文只用在技術名詞與指令
> （dnf、RPM、versionlock、MDS、CyberArk、`kafka-features` …）。包括：做事過程中的進度說明、背景工作回報、
> 表格、最後的總結、問題選項。不要因為工具輸出或上一則是英文就跟著改用英文。使用者不需要再提醒。

PoC for installing Confluent Platform 8.3.2 + Control Center 2.6.1 fully offline at a bank.
Simulated hosts run in Docker Desktop on Windows 11; everything is driven from Git Bash.
Details of the architecture and every component: @README.md

## Working with the user
- Reply in **繁體中文**; technical terms stay in English (dnf, RPM, versionlock, MDS, CyberArk …).
- Ask decisions as **single/multi-select choices** (AskUserQuestion), not prose.
- The manual is **hand commands first**: `cpctl` is only shown as the "對應 cpctl" reference. New procedures are
  validated by running the raw commands on the lab, never only through the scripts.
- The user drives the design discussion (`redesign/README.md`); record only confirmed decisions and open questions.
- Never print a password, key or token in chat. Secrets live in 0600 files (`~/secrets/*.pass`, `~/pki/store.pass`,
  `docker/manual/secrets.env`) and are read into variables at run time.

## Session start and hand-off (skill `handoff`)
- First: `git branch --show-current` + `git worktree list`, then read `.claude/state/status-<branch>.md` and the
  newest entries in `.claude/state/log/`. Summarise where things stand before doing anything.
- Update the status file at every milestone (step verified, decision made, document produced, lab state changed);
  add a dated log file for each topic. Auto-memory holds only user preferences, never project state.
- One session = one git worktree = one branch. The Docker lab is shared: note "lab 使用中" in the status file.

## Repository map
- `installer/` — the bash installer `cpctl` (steps 00–11, libs, roles, templates). Mounted into ops01 read-only.
- `opmenu/` — OP menu source (the **only** copy; never edit a sibling project such as `untitled6`).
- `windows/` — Git Bash tooling: `poc.sh` (lab control), `download-packages.sh`, `verify-packages.sh`,
  `make-delivery.sh`, `package-opmenu.sh`, `bank-ca.sh` (simulated bank PKI).
- `docker/` — lab images and `compose.yml` (project `cp-poc`); `docker/manual/compose.yml` is the second,
  cpctl-free lab (project `cp-man`: ops02, repo01, kc01-03, kb01-04, rest01-02, c3-01, ad01, lb01).
- `docs/` — **generated** documents; edit the sources, then rebuild (see skill `build-docs`):
  - `deck-src/install.js` + `install-steps.js` → `Confluent-RPM安裝流程.pptx` (14-page deck for bank managers)
  - `deck-src/build.js` → `Confluent-離線安裝PoC-全流程.pptx`
  - `manual-src/guide.md` → `Confluent-手動安裝手冊.docx`
  - `checklist-src/build.js` (reads `installer/conf/versions.env`) → `Confluent-主機準備清單.xlsx`
  - `journey-src/journey.md` + `diagrams.js` → `Confluent-安裝旅程-手把手.docx` (self-contained hands-on guide)
  - `questions-src/questions.md` (built with `manual-src/build.js <md> <docx>`) → `Confluent-請銀行確認的事項.docx`
- `redesign/README.md` — running notes of the installer redesign discussion (decisions, lessons, open questions).
- Not in git: `packages/`, `packages-manual/`, `delivery/`, `bank-ca/`, `*.p12|*.pem|*.key|*.crt`, `secrets.env`.

## Branches
- `main` — last committed state of the PoC (cpctl + docs).
- `redesign` — current work: design notes + journey guide. (The flattened-installer experiment was dropped on
  2026-10-21; the installer will be rewritten from the manual run instead.)
- Commit only when asked; never push unless asked; never commit secrets, licence or packages.

## Lab facts
- Docker Desktop VM has ~10.7 GB: run **either** `cp-poc` (16 containers) **or** `cp-man` (14), not both.
  `docker compose -f docker/compose.yml stop` before `docker compose -f docker/manual/compose.yml up -d`.
- Enter hosts: `docker exec -it -u cpadmin -w /home/cpadmin cp-man-ops02-1 bash` (ops),
  `docker exec -it cp-man-<host>-1 bash` (root, "bank" actions). Prefix docker commands with `MSYS_NO_PATHCONV=1`
  and pass Windows paths through `cygpath -m`.
- Bind mounts of Windows folders (9p) are slow for multi-GB reads: download inside the container, then copy out.
- After a Docker Desktop restart, `restart: unless-stopped` brings every lab that was merely `stop`ped back up: run
  `docker ps --format '{{.Names}}' | cut -d- -f1 | sort | uniq -c` and stop the extra project before doing anything.
- The journey guide lab is a third project (`lab`, 14 containers + `dl01`, subnets 172.35/172.36, built from
  `~/kafka-lab` per `docs/journey-src/journey.md` chapter 0). Same one-lab-at-a-time rule.
- If every container's `timeout 5 ip addr` hangs, the VM's netlink is wedged: restart Docker Desktop, don't debug configs.
- In the lab Claude plays the bank: AD (samba-tool on ad01), CA (`windows/bank-ca.sh sign`), OS repo on
  repo01 `/var/www/repo/os/`, NTP on repo01, nginx on lb01, SSH keys via the shared `authorized_keys.d` volume.

## Design decisions in force (2026-10-20/21)
- RPM install only; Confluent packages are the only files we bring in; OS packages come from the bank's repo
  (Satellite / Nexus / plain httpd — all look the same to dnf).
- JDK 21 is delivered by the bank as a tar; we install to `/opt/java/<dir>` + `/opt/java/current`, register
  `java`/`keytool` with `alternatives`, set `JAVA_HOME` in `/etc/profile.d/java.sh` and in each systemd drop-in.
- Only Confluent packages and the JDK are version-locked; C3's `cyrus-sasl`/`openssl-devel` follow OS patching.
- Apps connect directly with SCRAM; apps via REST Proxy must use client certificates (REST has no password path).
- Humans use AD accounts; RBAC binds AD groups, never individuals. Platform services use certificates, not AD.
- CyberArk: PSMP for human logins, SSH Key Manager for cpadmin's key, root rotated by CPM; platform secrets
  are vaulted but rotated manually (Secret Protection master key: CyberArk stores it, we rotate it).

## Gotchas learned the hard way
- Before `systemctl start` of an RPM service, confirm the drop-in is in effect:
  `systemctl show <unit> -p ExecStart` must point to **our** properties file, else the RPM default config starts
  (REST Proxy came up as plain HTTP that way).
- `systemctl enable --now` does not restart a running service; after config changes use `restart`.
- `/etc/confluent/ssl`, `/var/lib/kafka` are 0750: verification commands need `sudo ls`/`sudo stat`.
- C3 must own `/etc/confluent-control-center/*-generated.yml` (`cp-control-center:confluent`).
- `dnf` metadata is cached 48 h: use `--refresh` right after publishing to the repo.
- Building a package set with `dnf download --resolve`: use a clean container and download **before** installing
  tools, or the tools' dependencies are missed (`createrepo_c-libs`).
