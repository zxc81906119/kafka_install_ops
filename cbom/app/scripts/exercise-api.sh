#!/usr/bin/env bash
# 把 web app 的每個密碼學端點打一次，讓執行期的錄製（JFR）看得到每個演算法。
#
#: 用法：bash scripts/exercise-api.sh <網址>      例：bash scripts/exercise-api.sh https://localhost:8443
#
# 端點清單不寫死：向 app 的 GET /api/lab 要（它回每個類別有哪些值），所以 app 加了演算法這支不用改。
# 需要：bash、curl。憑證是 lab 的自簽憑證，所以 curl 加 -k。
# curl 的參數：-s 不印進度、-k 不驗證憑證、-m 秒數 最多等多久、-o /dev/null 不要回應內容、
#             -w '%{http_code}' 只印 HTTP 狀態碼、-X 指定方法（GET 或 POST）。
# 誰會叫這支：cbom/webapp/webapp-collect.sh 的 runtime 步驟（app 用映像跑起來之後）。

# 用到沒設定的變數就停（打錯變數名稱時會馬上發現）
set -u

# 1. 讀參數：沒給網址就印出上面「#:」開頭的用法，結束碼 64（用法錯誤）
base=${1:-}
if [ -z "$base" ]; then
  sed -n 's/^#: \{0,1\}//p' "$0"
  exit 64
fi

# 2. 向 app 要端點目錄；連不上就結束
catalog=$(curl -sk -m 10 "$base/api/lab")
if [ -z "$catalog" ]; then
  echo "連不上 $base/api/lab"
  exit 1
fi

# 3. 把目錄切成一個類別一行
#    回應是一行 JSON：{"POST /api/lab/hash/{algorithm}":["sha256","md5"],…}；在每個 ], 後面斷行
lines=$(echo "$catalog" | sed 's/\],/]\n/g')

# 4. 計數器：回 200 的端點數、其他狀態碼的端點數
ok=0
other=0

# 5. 一行一個類別：取出方法、路徑、值的清單，每個值打一次
while read -r line; do
  # 5-1. 只處理值是清單的類別（行裡有 [）；其他的（例如 tls 的說明文字）跳過
  case "$line" in
    *'['*) ;;
    *) continue ;;
  esac

  # 5-2. 第 2 個雙引號欄位是「方法 路徑」，例如 POST /api/lab/hash/{algorithm}
  #      method = 第一個空白之前（POST）；path = 最後一個空白之後；prefix = path 去掉最後一段（/api/lab/hash）
  key=$(echo "$line" | cut -d'"' -f2)
  method=${key%% *}
  path=${key##* }
  prefix=${path%/*}

  # 5-3. [ 與 ] 之間是值的清單："sha256","md5" → sha256 md5
  inside=${line#*[}
  inside=${inside%%]*}
  values=$(echo "$inside" | tr -d '"' | tr ',' ' ')

  # 5-4. 每個值打一次（不帶 body：app 會用預設的示範字串）；不是 200 的印出來
  for value in $values; do
    code=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' -X "$method" "$base$prefix/$value")
    if [ "$code" = 200 ]; then
      ok=$((ok + 1))
    else
      other=$((other + 1))
      echo "  $code $method $prefix/$value"
    fi
  done
done <<EOF
$lines
EOF

# 6. 清單以外的一個端點：TLS 的設定
code=$(curl -sk -m 30 -o /dev/null -w '%{http_code}' "$base/api/lab/tls")
if [ "$code" = 200 ]; then
  ok=$((ok + 1))
else
  other=$((other + 1))
  echo "  $code GET /api/lab/tls"
fi

# 7. 印出結果；一個 200 都沒有才算失敗（結束碼 1）
echo "端點：$ok 個回 200，$other 個其他"

if [ "$ok" -eq 0 ]; then
  exit 1
fi
