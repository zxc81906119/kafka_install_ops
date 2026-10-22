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
