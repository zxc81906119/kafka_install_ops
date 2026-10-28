---
name: bank-role
description: Perform the bank-side preparations in the lab (AD objects, LDAPS cert, CA signing, OS package repo, NTP, load balancer, SSH key distribution, secret hand-over). Use when the user says "你扮演銀行", a step needs something the bank provides, or a CSR must be signed.
---

# Playing the bank in the lab

In production these are done by the bank's OS / AD / CA / network teams. In the lab Claude does them as root
inside the containers. Always say which bank role is acting and keep the production-equivalent in one line.

## Catalogue (containers `lab-<host>-1` in ~/kafka-lab; scripted: `install/lab/bank-sim.sh`)

| Need | Where | How |
|---|---|---|
| Host accounts + SSH public key | every host as root (`bash install/lab/bank-sim.sh prepare`, journey 4.1/4.3) | `groupadd -g 1500 cpuser; useradd -u 1500 -g 1500 -m cpuser` (password stays locked), `/etc/ssh/sshd_config.d/50-cpuser.conf` (`Match User cpuser` / `PasswordAuthentication no` / `AuthenticationMethods publickey`), `/home/cpuser/.ssh/authorized_keys` = `from="<ops02 IP>,127.0.0.1,::1" <pub>` (0700/0600, owner cpuser); same line for `repodeploy` on repo01. The pub key is read from ops02 `/secure/ssh/cpuser_ed25519.pub` (made by install step 04 / journey 4.2) |
| OS package repo (stands in for Satellite) | repo01 `/var/www/repo/os/` | clean `lab-node:96` container (Rocky 9.6) with `--disablerepo=* --enablerepo=vault96-baseos,vault96-appstream,vault96-extras` (the image's default repos would follow the latest 9.x!): **download first, then** install the downloaded RPMs (gets `createrepo_c`), `createrepo_c /out`; result in `~/kafka-lab/bank-os/9.6`; `docker cp` into repo01; `chown -R repodeploy`. `bank-sim.sh os-content` also prepares `9.8-updates` (what a 9.6 host needs for 9.8: `dnf update --downloadonly` against `pub/rocky/9.8`) and `9.8` (merged); `bank-sim.sh os-sync` is the bank syncing repo01 to 9.8 (journey 30.0) |
| Repo definition + bank root trust on every host | each node | `/etc/yum.repos.d/bank-os.repo` (baseurl `https://repo01.poc.lab/os/`, gpgkey Rocky key), root cert → `/etc/pki/ca-trust/source/anchors/`, `update-ca-trust`, `rpm --import` |
| JDK | `landing/bank/` | JDK 21 (baseline) and JDK 25 (migration) tars + `.sha256`; the bank does **not** install them |
| AD | ad01 (`samba-tool`) | OUs `OU=Confluent` + `Users/Groups/Service`; groups `kafka-admins kafka-operators kafka-devs`; `svc-mds-bind` (read-only); users alice/bob/carol; passwords generated into `/root/secrets/*.pass`, handed to ops02 `~/secrets/` as 0600 files |
| LDAPS certificate | ad01 | CSR with SAN + `extendedKeyUsage=serverAuth` → sign → `/var/lib/samba/private/tls/{key,cert,ca}.pem`, `pkill -x samba` (entrypoint restarts it) |
| Certificate signing | Windows: `bash ~/kafka-lab/ca/sign.sh <csr> <out>` (G2 issuing CA: `ca/g2/sign.sh`) | policy: RSA ≥ 2048, CN present, not a CA, EKU **must** be in the CSR and ⊆ {serverAuth, clientAuth}; answer = leaf + issuing CA. Copy CSRs out of ops02 with `docker cp`, answers back into `~/pki/incoming/` (ops02 is root, no chown needed) |
| NTP | repo01 (`chronyd`, `local stratum 10`, `allow 172.35.0.0/24`) | nodes point `server repo01.poc.lab iburst` |
| Load balancer | lb01 `/etc/nginx/stream.d/cp.conf` | L4 passthrough 8082 → rest01/rest02 (`hash $remote_addr consistent`); 9021 → c3-01 only for the Windows port mapping; `nginx -t && nginx -s reload` |
| sudo for cpuser | `/etc/sudoers.d/cpuser` = `cpuser ALL=(ALL) NOPASSWD: ALL` (written with the account in 4.1) | after delivery only `/etc/sudoers.d/cpuser-ops`, every unit and exact command form listed (guide 16.4, 19.5); lab keeps the full rule for later chapters |
| CyberArk (login only) | none | Platform secrets (passphrase, master key, `svc-mds-bind`, test-user passwords, break-glass PEM `~/secrets/opmenu-breakglass.pem`, …) are NOT vaulted: they stay in 0600 files on ops02 (`~/secrets`, `~/pki`), rotated by hand (keep the old value as `.prev`). The only CyberArk relation is person login via PVWA web + PSMP, which cannot be simulated: enter ops02 as root with `docker exec` |

## Rules
- Paths for `docker cp`: container side `name:/path`, host side `"$(cygpath -m ...)"`; never a bare `/c/...` with
  `MSYS_NO_PATHCONV=1` (it becomes `C:\c\...`).
- Secrets are generated with `openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20`, stored in files, passed
  through `-e VAR=...` to `docker exec`; never echo them, never put them in chat.
- After any bank change, tell the user what the bank "delivered" (paths, names, fingerprints) so the user can
  continue with their own commands.
