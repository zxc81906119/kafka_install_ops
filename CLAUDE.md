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
- `docs/journey-src/` — `journey.md` (the hands-on guide, chapters 0–28, `@only customer|conjur|provider` sections)
  + `diagrams.js` → `docs/Confluent-安裝旅程-手把手.docx`; `tools/run-full.sh <mode> [from] [to]` runs the guide's
  blocks on the lab (`run-chapter.js` extracts them, `scan-log.sh` flags rc=0 output that is really a failure).
- `docs/questions-src/questions.md` → `docs/Confluent-請銀行確認的事項.docx` (`node build.js`).
- `docs/deck-src/install.js` + `install-steps.js` → `docs/Confluent-RPM安裝流程.pptx` (14-page deck for bank managers).
- `install/` — installer that follows the guide one script per chapter (`install.sh`, `steps/01–27`, `conf/site.env`);
  `install/lab/` = lab-only (`bank-sim.sh` plays the bank, `run-customer.sh`, `run-all.sh`, `run-upgrade-drill.sh`).
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
- Enter hosts: `docker exec -it -u cpadmin -w /home/cpadmin lab-ops02-1 bash` (ops),
  `docker exec -it lab-<host>-1 bash` (root, "bank" actions). Prefix docker commands with `MSYS_NO_PATHCONV=1`
  and pass Windows paths through `cygpath -m` (Node is a Windows program: convert paths before handing them over).
- In customer mode cpadmin's private key exists only in ops02's agent `~/.ssh/engineer-agent.sock` (pasted from
  `~/kafka-lab/pvwa/`); after a cold boot re-paste it.
- Bind mounts of Windows folders (9p) are slow for multi-GB reads: download inside the container, then copy out.
- After a Docker Desktop restart check `docker ps --format '{{.Names}}' | cut -d- -f1 | sort | uniq -c`.
- If every container's `timeout 5 ip addr` hangs, the VM's netlink is wedged: restart Docker Desktop, don't debug configs.
- In the lab Claude plays the bank (`install/lab/bank-sim.sh`, or the guide's 銀行 blocks): AD (samba-tool on ad01),
  CA (`~/kafka-lab/ca`), OS repo and NTP on repo01, nginx on lb01, PVWA (`~/kafka-lab/pvwa/`), SSH public keys via
  the shared `authorized_keys.d` volume.

## Design decisions in force (details: redesign/README.md)
- RPM install only; Confluent packages are the only files we bring in; OS packages come from the bank's repo
  (Satellite / Nexus / plain httpd — all look the same to dnf).
- JDK 21 is delivered by the bank as a tar; we install to `/opt/java/<dir>` + `/opt/java/current`, register
  `java`/`keytool` with `alternatives`, set `JAVA_HOME` in `/etc/profile.d/java.sh` and in each systemd drop-in.
- Only Confluent packages and the JDK are version-locked; C3's `cyrus-sasl`/`openssl-devel` follow OS patching.
- Apps connect directly with SCRAM; apps via REST Proxy must use client certificates (REST has no password path).
- Humans use AD accounts; RBAC binds AD groups, never individuals. Platform services use certificates, not AD.
- CyberArk at this customer = PAM only: PSMP for human logins, SSH Key Manager for cpadmin's key (the only SSH key;
  pasted from PVWA into ssh-agent, never on disk), root and `svc-mds-bind` rotated by CPM; platform secrets are
  vaulted in PVWA but rotated manually (Secret Protection master key: PVWA stores it, we rotate it).
- ops02 is both the install host and the operators' login point (OP menu runs there); no separate bastion.
- MDS token key pair is fixed (rotate only on compromise); cpadmin sudo is `NOPASSWD`; CPM's reconcile account is not cpadmin.

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
- Check run logs line by line, not only `scan-log.sh`: an empty value after "：" means the check's precondition was missing.
- Building a package set with `dnf download --resolve`: use a clean container and download **before** installing
  tools, or the tools' dependencies are missed (`createrepo_c-libs`).
