#!/usr/bin/env python3
"""查官方 Grafana dashboard 的每個 panel 在我們的 Prometheus 裡有沒有資料。

用法：dashboard-coverage.py <Prometheus URL> <dashboard 目錄> [--detail] [--auth user:pass]

做法：把每個 panel 的 PromQL 取出來，dashboard 變數（$env、$instance …）換成「全部」，
$__rate_interval 等換成固定區間，對 Prometheus 做 instant query；有任何一條 query 回得出序列，這個 panel 就算有資料。
這和 Grafana 畫面上選「All」時的結果一致，但不需要開瀏覽器。只用 Python 標準函式庫。
"""
import base64, glob, json, os, re, sys, urllib.parse, urllib.request

args = [a for a in sys.argv[1:] if not a.startswith("--")]
detail = "--detail" in sys.argv
auth = None
if "--auth" in sys.argv:
    auth = sys.argv[sys.argv.index("--auth") + 1]
    args = [a for a in args if a != auth]
prom, folder = args[0].rstrip("/"), args[1]


def query(expr):
    url = prom + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
    except Exception as e:  # HTTP 400 = PromQL 不合法
        return None, str(e)
    return data["data"]["result"], None


def expand(expr):
    # 變數放在 = 比對的位置時改成 =~，換成 .* 才有意義
    expr = re.sub(r'(\w+)\s*=\s*"(\$\{?[A-Za-z_][\w.]*\}?|\[\[\w+\]\])"', r'\1=~"\2"', expr)
    expr = re.sub(r"\$__rate_interval|\$\{__rate_interval\}", "5m", expr)
    expr = re.sub(r"\$__interval|\$\{__interval\}", "1m", expr)
    expr = re.sub(r"\$__range|\$\{__range\}", "1h", expr)
    expr = re.sub(r"\$\{[A-Za-z_][\w.]*(:[a-z]+)?\}|\$[A-Za-z_]\w*|\[\[\w+\]\]", ".*", expr)
    return expr


def panels(items):
    for p in items:
        yield p
        yield from panels(p.get("panels", []))


total = {"dash": 0, "panels": 0, "data": 0}
print("%-34s %6s %6s  %s" % ("dashboard", "panels", "有資料", "沒資料的 panel"))
for f in sorted(glob.glob(os.path.join(folder, "*.json"))):
    j = json.load(open(f, encoding="utf-8"))
    n = ok = 0
    missing = []
    for p in panels(j.get("panels", [])):
        targets = [t for t in p.get("targets", []) if t.get("expr")]
        if not targets:
            continue
        n += 1
        has = False
        for t in targets:
            res, err = query(expand(t["expr"]))
            if res:
                has = True
                break
        if has:
            ok += 1
        else:
            missing.append(p.get("title", "(無標題)"))
    total["dash"] += 1; total["panels"] += n; total["data"] += ok
    print("%-34s %6d %6d  %s" % (os.path.basename(f), n, ok, ("; ".join(missing[:6]) + (" …" if len(missing) > 6 else "")) if detail else ""))
print("合計 %d 個 dashboard、%d 個 panel、%d 個有資料" % (total["dash"], total["panels"], total["data"]))
