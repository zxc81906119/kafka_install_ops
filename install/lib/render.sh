# install/lib/render.sh — 範本渲染：範本裡的 ${變數} 由 envsubst 換成目前環境的值
# 只換「列出來的」變數，其他 ${…}（例如之後 Secret Protection 的 ${securepass:…}）原樣保留。

# render <範本> <輸出檔> <變數名…>
render() {
  local tpl=$1 out=$2 v="" x; shift 2
  for x in "$@"; do v+="\${$x} "; done
  (umask 077; envsubst "$v" < "$tpl" > "$out")
  local left; left=$(grep -c '\${[A-Za-z0-9_]*}' "$out" || true)
  [ "$left" = 0 ] || { echo "render: $out 還有 $left 個未解析的 \${…}" >&2; return 1; }
}

# render_cat <輸出檔> <變數名…> -- <範本…>   多個範本接起來（例如 controller.tpl + common.tpl）
render_cat() {
  local out=$1 v="" x; shift
  while [ "$1" != "--" ]; do v+="\${$1} "; shift; done; shift
  (umask 077; : > "$out"; for x in "$@"; do envsubst "$v" < "$x" >> "$out"; echo >> "$out"; done)
  local left; left=$(grep -c '\${[A-Za-z0-9_]*}' "$out" || true)
  [ "$left" = 0 ] || { echo "render: $out 還有 $left 個未解析的 \${…}" >&2; return 1; }
}

# ---- Secret Protection（第 16 站）相關：把渲染好的 properties 變成密文參照 ----
# protect_file <properties> <本機 security.properties> <主機上 security.properties 路徑>
#   加密所有 password／credentials／jaas.config 欄位，但值已是 ${…} 參照（provider）的不碰；需要 CONFLUENT_SECURITY_MASTER_KEY 在環境裡
protect_file() {
  local f=$1 local_sec=$2 remote_sec=$3 keys
  keys=$(grep -E '^[^#].*(password|credentials|jaas.config) *= *[^$ ]' "$f" | sed 's/ *=.*//' | paste -sd,)
  [ -n "$keys" ] || return 0
  confluent secret file encrypt --config-file "$f" --local-secrets-file "$local_sec" --remote-secrets-file "$remote_sec" --config "$keys" >/dev/null
}
# ldap_via_env <properties>   AD 查詢密碼不進密文：改成 ${env:LDAP_BIND_PASSWORD}，providers 加上 Kafka 內建的 env（16.9）
#   在 protect_file 之後呼叫（confluent secret 改寫後的格式是 "key = value"）
ldap_via_env() {
  local f=$1
  sed -i -e 's|^ldap.java.naming.security.credentials *=.*|ldap.java.naming.security.credentials = ${env:LDAP_BIND_PASSWORD}|' \
         -e 's|^config.providers *=.*|config.providers = securepass,env|' -e '/^config.providers.env.class *=/d' "$f"
  grep -q '^config.providers *=' "$f" || printf 'config.providers = securepass,env\n' >> "$f"
  printf 'config.providers.env.class = org.apache.kafka.common.config.provider.EnvVarConfigProvider\n' >> "$f"
}
# plaintext_count <properties>   還有幾個明文密碼欄位（驗證用；0 才對）
plaintext_count() { grep -cE '^[^#].*(password|credentials|jaas.config) *= *[^$ ]' "$1" || true; }
