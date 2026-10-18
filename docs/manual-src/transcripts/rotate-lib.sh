# Manual walkthrough helpers for certificate / CA rotation (ops02, cpadmin). Source after ~/manual.env.
# Every function is a plain sequence of the commands in manual chapter 9; nothing here is cpctl.
. ~/manual.env
set -a; . $S/secrets.env; set +a

# issue <name> <EKU> [SANs]  (same as 3.4.3; archives the previous files first)
issue() {
  local n=$1 eku=$2 sans=${3:-} arch
  ( cd $PKI && umask 077
    if [ -f $n.crt ]; then arch=archive/$(date +%Y%m%d-%H%M%S)-$n; install -d -m 0700 $arch; cp -p $n.* $arch/; fi
    { printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
      printf 'extendedKeyUsage=%s\n' "$eku"
      [ -n "$sans" ] && printf 'subjectAltName=%s\n' "$(tr ',' '\n' <<<"$sans" | sort -u | sed 's/^/DNS:/' | paste -sd, -)"
    } > $n.ext
    openssl genrsa -out $n.key 3072 2>/dev/null
    openssl req -new -key $n.key -out $n.csr -subj "/CN=$n/OU=Confluent/O=PoC Bank/C=TW"
    openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 365 -sha256 -extfile $n.ext -out $n.crt 2>/dev/null
    rm -f $n.ext $n.csr
    openssl pkcs12 -export -name $n -inkey $n.key -in $n.crt -certfile ca.crt -passout env:STORE_PASSWORD -out $n.p12
    cat $n.crt ca.crt > $n.chain.pem
    echo "issued $n serial=$(openssl x509 -in $n.crt -noout -serial | cut -d= -f2) issuer=$(openssl x509 -in $n.crt -noout -issuer | sed 's/.*CN=\([^,]*\).*/\1/')" )
}
SANS_INTERNAL=kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04
SANS_SERVER=ops02.poc.lab,ops02,ad01.poc.lab,ad01,lb01.poc.lab,lb01,kc01.poc.lab,kc01,kc02.poc.lab,kc02,kc03.poc.lab,kc03,kb01.poc.lab,kb01,kb02.poc.lab,kb02,kb03.poc.lab,kb03,kb04.poc.lab,kb04,rest01.poc.lab,rest01,rest02.poc.lab,rest02,c3-01.poc.lab,c3-01,rest.poc.lab,c3.poc.lab,localhost

# request <name> <EKU> [SANs]  (bank CA, 3.4.9.2): new key in pending/ (never leaves this host), CSR in requests/
request() {
  ( cd $PKI && umask 077 && install -d -m 0700 pending && install -d -m 0750 requests incoming
    n=$1; ext=(-addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,digitalSignature,keyEncipherment" -addext "extendedKeyUsage=$2")
    [ -n "${3:-}" ] && ext+=(-addext "subjectAltName=$(tr ',' '\n' <<<"$3" | sort -u | sed 's/^/DNS:/' | paste -sd, -)")
    openssl genrsa -out pending/$n.key 3072 2>/dev/null && chmod 0600 pending/$n.key
    openssl req -new -key pending/$n.key -sha256 -subj "/CN=$n/OU=Confluent/O=PoC Bank/C=TW" "${ext[@]}" -out requests/$n.csr
    echo "request $n: EKU=$2 SANs=$(openssl req -in requests/$n.csr -noout -text | grep -o 'DNS:' | wc -l) -> requests/$n.csr" )
}

# import_signed <name> <EKU> [SANs]  (bank CA, 3.4.9.3): checks incoming/<name>.crt; installs ONLY if every check passes
import_signed() {
  ( cd $PKI && umask 077
    n=$1 eku=$2 want=$(tr ',' '\n' <<<"${3:-}" | sed '/^$/d' | sort -u | paste -sd, -)
    w=$(mktemp -d); awk -v d="$w" '/BEGIN CERTIFICATE/ {k++} {print > (d "/c-" k ".pem")}' incoming/$n.crt
    fail() { echo "REJECTED $n: $* - nothing installed"; rm -rf "$w"; exit 1; }
    kp=$(openssl pkey -in pending/$n.key -pubout); leaf=
    for f in "$w"/c-*.pem; do [ "$(openssl x509 -in $f -noout -pubkey)" = "$kp" ] && leaf=$f; done
    [ -n "$leaf" ] || fail "no certificate in the file matches pending/$n.key"
    cn=$(openssl x509 -in $leaf -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p')
    [ "$cn" = "$n" ] || fail "CN is '$cn'"
    [[ $(openssl x509 -in $leaf -noout -ext basicConstraints 2>/dev/null) == *CA:TRUE* ]] && fail "it is a CA certificate"
    have=$(openssl x509 -in $leaf -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr ',' '\n' | sed 's/^ *DNS://; /^ *$/d' | sort -u | paste -sd, -)
    [ "$have" = "$want" ] || fail "SAN [$have], requested [$want]"
    e=$(openssl x509 -in $leaf -noout -ext extendedKeyUsage 2>/dev/null | tail -n +2 | sed 's/^ *//')
    [[ ,$eku, == *,serverAuth,* && $e != *"Server Authentication"* ]] && fail "extended key usage lacks serverAuth ($e)"
    [[ ,$eku, == *,clientAuth,* && $e != *"Client Authentication"* ]] && fail "extended key usage lacks clientAuth ($e)"
    openssl x509 -in $leaf -noout -checkend $((30 * 86400)) >/dev/null || fail "expires within 30 days"
    cat $leaf > $w/chain.pem
    for f in "$w"/c-*.pem; do
      [ $f = $leaf ] && continue
      [ "$(openssl x509 -in $f -noout -subject_hash)" = "$(openssl x509 -in $f -noout -issuer_hash)" ] && continue
      cat $f >> $w/chain.pem
    done
    cat trust/*.pem > $w/roots.pem
    openssl verify -partial_chain -CAfile $w/roots.pem -untrusted $w/chain.pem $w/chain.pem >/dev/null || fail "does not chain to a root in trust/ (intermediate missing?)"
    arch=archive/$(date +%Y%m%d-%H%M%S)-$n; install -d -m 0700 $arch
    # previous files keep their names; the bank answer and the CSR get their own (an answer named $n.crt would
    # overwrite the archived previous certificate)
    cp -p $n.crt $n.key $n.p12 $n.chain.pem $arch/ 2>/dev/null; mv incoming/$n.crt $arch/$n.bank-answer.pem; mv requests/$n.csr $arch/ 2>/dev/null
    install -m 0600 pending/$n.key $n.key && install -m 0640 $w/chain.pem $n.crt && cp $n.crt $n.chain.pem
    openssl pkcs12 -export -name $n -inkey $n.key -in $n.crt -passout env:STORE_PASSWORD -out $n.p12
    rm -f pending/$n.key; rm -rf "$w"
    echo "imported $n serial=$(openssl x509 -in $n.crt -noout -serial | cut -d= -f2) issuer=$(openssl x509 -in $n.crt -noout -issuer | sed 's/.*CN=\([^,]*\).*/\1/') certs-in-file=$(grep -c BEGIN $n.crt)" )
}

# truststores from the bundle ca.pem (3.4.2 and 6.3): truststore.p12 (STORE_PASSWORD), opmenu-truststore.p12 (own password)
truststores() {
  ( cd $PKI && umask 077
    d=$(mktemp -d); awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' ca.pem
    # build beside the target, then rename: a client starting meanwhile must not load a missing / partial truststore
    rm -f truststore.p12.new opmenu-truststore.p12.new; i=0
    for f in "$d"/ca-*.pem; do i=$((i+1))
      $JAVA_HOME/bin/keytool -importcert -noprompt -alias internal-ca-$i -file "$f" -keystore truststore.p12.new -storetype PKCS12 -storepass:env STORE_PASSWORD >/dev/null
      $JAVA_HOME/bin/keytool -importcert -noprompt -alias internal-ca-$i -file "$f" -keystore opmenu-truststore.p12.new -storetype PKCS12 -storepass:env OPMENU_TRUSTSTORE_PASSWORD >/dev/null
    done; rm -rf "$d"
    mv -f truststore.p12.new truststore.p12 && mv -f opmenu-truststore.p12.new opmenu-truststore.p12
    echo "truststores rebuilt with $i CA(s): $(grep -c 'BEGIN CERT' ca.pem) in ca.pem" )
}

# push_ssl <host> <files...>  -> /etc/confluent/ssl (root:confluent 0640), as in 3.4.7
push_ssl() {
  local h=$1; shift
  ( cd $PKI && scp -q "$@" $h.poc.lab:/tmp/ )
  ssh $h.poc.lab "for f in $*; do sudo install -o root -g confluent -m 0640 /tmp/\$f /etc/confluent/ssl/\$f && rm -f /tmp/\$f; done"
}
push_all_ssl() {  # role-specific file sets (3.4.7)
  local h
  for h in kc01 kc02 kc03; do push_ssl $h ca.pem truststore.p12 kafka-internal.p12; done
  for h in kb01 kb02 kb03 kb04; do push_ssl $h ca.pem truststore.p12 kafka-internal.p12 cp-server.p12; done
  for h in rest01 rest02; do push_ssl $h ca.pem truststore.p12 cp-server.p12; done
  push_ssl c3-01 ca.pem truststore.p12 cp-server.p12 cp-server.crt cp-server.key
  echo "pushed /etc/confluent/ssl to 10 hosts"
}

# trust_all -> OS trust anchor = bundle, JDK cacerts = exactly the bundle's CAs (3.4.8)
trust_all() {
  local h
  for h in ops02 kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 jump01; do
    scp -q $PKI/ca.pem $h.poc.lab:/tmp/cp-internal-ca.pem
    ssh $h.poc.lab 'bash -s' <<'EOS'
set -e
sudo install -o root -g root -m 0644 /tmp/cp-internal-ca.pem /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem; rm -f /tmp/cp-internal-ca.pem
sudo update-ca-trust extract
JH=/usr/lib/jvm/temurin-21-jdk; d=$(mktemp -d); want=""
awk -v d="$d" '/BEGIN CERTIFICATE/ {n++} {print > (d "/ca-" n ".pem")}' /etc/pki/ca-trust/source/anchors/cp-internal-ca.pem
for f in "$d"/ca-*.pem; do
  fp=$(openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr 'A-F' 'a-f' | cut -c1-16); want="$want cp-ca-$fp"
  sudo $JH/bin/keytool -list -cacerts -storepass changeit -alias cp-ca-$fp >/dev/null 2>&1 || sudo $JH/bin/keytool -importcert -noprompt -cacerts -storepass changeit -alias cp-ca-$fp -file "$f" >/dev/null
done; rm -rf "$d"
for a in $(sudo $JH/bin/keytool -list -cacerts -storepass changeit | grep -oE '^cp-ca-[0-9a-f]+'); do case " $want " in *" $a "*) ;; *) sudo $JH/bin/keytool -delete -cacerts -storepass changeit -alias $a ;; esac; done
echo "$(hostname): OS anchors=$(trust list --filter=ca-anchors | grep -c -E 'label: PoC (Internal CA|Bank Root)') JDK=$(sudo $JH/bin/keytool -list -cacerts -storepass changeit | grep -c '^cp-ca-')"
EOS
  done
}

# ad01 LDAPS (4.1.1) and jump01 (6.3 / 6.4) trust material
push_ad() {
  scp -q $PKI/cp-server.key $PKI/cp-server.crt $PKI/ca.pem ad01.poc.lab:/tmp/
  ssh ad01.poc.lab "sudo install -o root -g root -m 0600 /tmp/cp-server.key /var/lib/samba/private/tls/key.pem && sudo install -o root -g root -m 0644 /tmp/cp-server.crt /var/lib/samba/private/tls/cert.pem && sudo install -o root -g root -m 0644 /tmp/ca.pem /var/lib/samba/private/tls/ca.pem && sudo rm -f /tmp/cp-server.key /tmp/cp-server.crt /tmp/ca.pem && sudo pkill -x samba || true"
  local i; for i in $(seq 1 24); do sleep 5; LDAPTLS_CACERT=$PKI/ca.pem ldapsearch -LLL -x -o nettimeout=5 -H ldaps://ad01.poc.lab:636 -s base -b "" namingContexts >/dev/null 2>&1 && { echo "ad01 LDAPS back after ~$((i*5))s"; return 0; }; done; echo "ad01 LDAPS NOT back"
}
push_jump() {
  ( cd $PKI && umask 077 && openssl pkcs12 -export -name opmenu-breakglass -inkey opmenu-breakglass.key -in opmenu-breakglass.crt $([ -f ca.crt ] && echo "-certfile ca.crt") -passout env:OPMENU_BREAKGLASS_STORE_PASSWORD -out opmenu-breakglass.bg.p12 )
  ( cd $PKI && scp -q opmenu-truststore.p12 ca.pem cp-server.crt kafka-internal.crt opmenu-breakglass.bg.p12 opmenu-breakglass.crt opmenu-breakglass.key jump01.poc.lab:/tmp/ )
  ssh jump01.poc.lab 'sudo bash -s' <<'EOS'
set -e
install -o root -g opmenu -m 0640 /tmp/opmenu-truststore.p12 /etc/opmenu/certs/truststore.p12
install -o root -g opmenu -m 0644 /tmp/ca.pem /etc/opmenu/certs/ca.pem
install -o root -g opmenu -m 0644 /tmp/cp-server.crt /etc/opmenu/certs/cp-server.pem
install -o root -g opmenu -m 0644 /tmp/kafka-internal.crt /etc/opmenu/certs/kafka-internal.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-truststore.p12 /etc/opmenu/bootstrap/truststore.p12
install -o opbootstrap -g opbootstrap -m 0644 /tmp/ca.pem /etc/opmenu/bootstrap/ca.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.bg.p12 /etc/opmenu/bootstrap/breakglass.p12
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.crt /etc/opmenu/bootstrap/breakglass.pem
install -o opbootstrap -g opbootstrap -m 0600 /tmp/opmenu-breakglass.key /etc/opmenu/bootstrap/breakglass.key
shred -u /tmp/opmenu-breakglass.key /tmp/opmenu-breakglass.bg.p12 2>/dev/null; rm -f /tmp/opmenu-truststore.p12 /tmp/ca.pem /tmp/cp-server.crt /tmp/kafka-internal.crt /tmp/opmenu-breakglass.crt
echo "jump01: opmenu trust material and break-glass updated"
EOS
}

# push_repo  (3.3.0): the internal repo over HTTPS follows every rotation - repo server certificate = cp-server,
# every node pins ca.pem as cp-repo-ca.pem; then each node must still download the repo metadata
push_repo() {
  ( cd $PKI && sudo install -o root -g root -m 0644 cp-server.crt /etc/pki/tls/certs/cp-repo.crt &&
    sudo install -o root -g root -m 0600 cp-server.key /etc/pki/tls/private/cp-repo.key &&
    sudo httpd -t >/dev/null 2>&1 && sudo systemctl restart httpd && echo "repo server: $(openssl x509 -in cp-server.crt -noout -serial)" )
  local h
  for h in kc01 kc02 kc03 kb01 kb02 kb03 kb04 rest01 rest02 c3-01 jump01; do
    scp -q $PKI/ca.pem $h.poc.lab:/tmp/cp-repo-ca.pem
    ssh $h.poc.lab "sudo install -o root -g root -m 0644 /tmp/cp-repo-ca.pem /etc/pki/tls/certs/cp-repo-ca.pem && rm -f /tmp/cp-repo-ca.pem && sudo dnf -q --refresh --disablerepo='*' --enablerepo='cp-internal-*' makecache >/dev/null 2>&1 && echo \"\$(hostname): repo OK\" || echo \"\$(hostname): REPO FAILED\""
  done
}

# rolling restart of everything that holds keystores/truststores in memory: controllers -> brokers -> REST (drained) -> C3
broker_ok() { local id=$((100 + ${1#kb0})); kafka-broker-api-versions --bootstrap-server $B --command-config $CFG 2>/dev/null | grep -q "(id: $id rack: [a-z-]* isFenced: false)" && [ -z "$(kafka-topics --bootstrap-server $B --command-config $CFG --describe --under-replicated-partitions 2>/dev/null)" ]; }
ctl_ok() { local id=${1#kc0}; kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --replication 2>/dev/null | awk -v id=$id '$1==id && ($NF=="Leader"||$NF=="Follower") && $4+0==0 {ok=1} END {exit !ok}'; }
wait_for() { local i; for i in $(seq 1 60); do "$@" && { echo "  healthy after ~$((i*5))s"; return 0; }; sleep 5; done; echo "  NOT HEALTHY - stop here"; return 1; }
lbconf() {
  { echo 'upstream cp_rest {'; echo '    hash $remote_addr consistent;'
    for r in rest01 rest02; do printf '    server %s.poc.lab:8082 max_fails=2 fail_timeout=10s%s;\n' $r "$([ "$r" = "$1" ] && echo ' down')"; done
    echo '}'; echo 'upstream cp_c3 {'; echo '    server c3-01.poc.lab:9021 max_fails=2 fail_timeout=10s;'; echo '}'
    echo 'server { listen 8082; proxy_pass cp_rest; proxy_connect_timeout 3s; proxy_timeout 10m; }'
    echo 'server { listen 9021; proxy_pass cp_c3;   proxy_connect_timeout 3s; proxy_timeout 1h;  }'; } > $S/manual/cp.conf.new
  scp -q $S/manual/cp.conf.new lb01.poc.lab:/tmp/cp.conf.new
  ssh lb01.poc.lab 'sudo install -o root -g root -m 0644 /tmp/cp.conf.new /etc/nginx/stream.d/cp.conf && rm -f /tmp/cp.conf.new && sudo nginx -t -q && sudo nginx -s reload 2>/dev/null'
}
restart_all() {
  local h L
  L=$(kafka-metadata-quorum --bootstrap-controller $CB --command-config $CFG describe --status | awk '/LeaderId:/ {print $2}')
  for h in $(for c in kc01 kc02 kc03; do [ "${c#kc0}" != "$L" ] && echo $c; done) kc0$L; do echo "restart $h ($(date +%T))"; ssh $h.poc.lab 'sudo systemctl restart confluent-server'; wait_for ctl_ok $h || return 1; done
  for h in kb01 kb02 kb03 kb04; do echo "restart $h ($(date +%T))"; ssh $h.poc.lab 'sudo systemctl restart confluent-server'; sleep 10; wait_for broker_ok $h || return 1; done
  for h in rest01 rest02; do
    echo "restart $h (drained, $(date +%T))"; lbconf $h; sleep 5; ssh $h.poc.lab 'sudo systemctl restart confluent-kafka-rest'
    rok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert $PKI/ca.pem --cert $PKI/app-legacy-billing.crt --key $PKI/app-legacy-billing.key https://$h.poc.lab:8082/v3/clusters)" = 200 ]; }
    wait_for rok || return 1; lbconf ""
  done
  echo "restart c3-01 ($(date +%T))"; ssh c3-01.poc.lab 'for u in prometheus alertmanager confluent-control-center; do sudo systemctl restart $u; done'
  c3ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert $PKI/ca.pem https://c3-01.poc.lab:9021/)" = 200 ]; }
  wait_for c3ok
}

# served -> serial and issuer each TLS endpoint presents right now
served() {
  local ep s
  for ep in kc01:9093 kc02:9093 kc03:9093 kb01:9092 kb01:8090 kb02:8090 kb03:8090 kb04:8090 kb04:9095 rest01:8082 rest02:8082 c3-01:9021 c3-01:9090 ad01:636 kb01:7071 kc01:7071; do
    s=$(openssl s_client -connect ${ep%:*}.poc.lab:${ep#*:} -CAfile $PKI/ca.pem -cert $PKI/kafka-internal.crt -key $PKI/kafka-internal.key </dev/null 2>/dev/null | openssl x509 -noout -serial -issuer 2>/dev/null | sed 's/serial=//; s/issuer=.*CN=\([^,]*\).*/\1/' | paste -sd' ')
    printf '%-14s %s\n' $ep "${s:-no certificate}"
  done
}
