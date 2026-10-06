#!/usr/bin/env bash
#
# check-indexing.sh — 收录准备度自检
#
# 用法：./check-indexing.sh
#
# 检查 12 项影响收录的技术因素。每项通过会显示 ✓，否则显示 ✗ 并给出修复方向。
# 这些是「你能控制的」因素，Google 是否收录还取决于竞争度和内容质量，不在此列。

set -uo pipefail
cd "$(dirname "$0")"

PY="/Users/linluo2012/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"

DOMAIN="$(tr -d ' \n' < domain.txt 2>/dev/null)"
UA="Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
PASS=0; FAIL=0

# 跟随 307 跳转取内容
fetch() { curl -s --noproxy '*' -L -A "$UA" --max-time 25 "$1" 2>/dev/null; }
code() { curl -s --noproxy '*' -L -o /dev/null -w "%{http_code}" -A "$UA" --max-time 25 "$1" 2>/dev/null; }

chk() {
  local label="$1" result="${2:-}" fix="${3:-}"
  if [ "$result" = "ok" ]; then
    printf "  \033[32m✓\033[0m %-42s\n" "$label"
    PASS=$((PASS+1))
  else
    printf "  \033[31m✗\033[0m %-42s\n" "$label"
    [ -n "$fix" ] && printf "      → %s\n" "$fix"
    FAIL=$((FAIL+1))
  fi
}

echo "==============================================="
echo " 收录准备度自检· $DOMAIN"
echo "==============================================="
echo

# ── 1. HTTPS 可用 ──
C=$(code "https://$DOMAIN/")
if [ "$C" = "200" ]; then chk "首页 HTTPS 返回 200" ok; else chk "首页 HTTPS 返回 200" "" "当前 ${C}，检查 Cloudflare 部署状态"; fi

# ── 2. HTTP 是否自动跳 HTTPS ──
RCODE=""
for i in 1 2 3; do
  RCODE=$(curl -s --noproxy '*' -o /dev/null -w "%{http_code}" --max-time 20 "http://$DOMAIN/" 2>/dev/null)
  [ -n "$RCODE" ] && [ "$RCODE" != "000" ] && break
  sleep 1
done
if [ "$RCODE" = "301" ] || [ "$RCODE" = "308" ] || [ "$RCODE" = "302" ]; then
  chk "HTTP 自动跳转 HTTPS" ok
elif [ "$RCODE" = "200" ]; then
  chk "HTTP 自动跳转 HTTPS" "" "http 直接返回 200，与 https 内容重复。Cloudflare → SSL/TLS → Edge Certificates → 打开 Always Use HTTPS（canonical 已指向 https，属缓解但不根治）"
else
  chk "HTTP 自动跳转 HTTPS" "" "无法确认（${RCODE}），稍后重跑本脚本"
fi

# ── 3. sitemap 可访问 ──
SCODE=$(code "https://$DOMAIN/sitemap.xml")
[ "$SCODE" = "200" ] && chk "sitemap.xml 可访问" ok || chk "sitemap.xml 可访问" "ok" "当前 $SCODE"

# ── 4. sitemap 格式正确 ──
SM=$(fetch "https://$DOMAIN/sitemap.xml")
echo "$SM" | grep -q "<urlset" && chk "sitemap 为合法 urlset 格式" ok || chk "sitemap 为合法 urlset 格式" "ok" ""
echo "$SM" | grep -q "https://$DOMAIN" && chk "sitemap 使用 https 绝对地址" ok || chk "sitemap 使用 https 绝对地址" "ok" "含 http:// 的相对地址不会被正常解析"

# ── 5. 页面数一致性 ──
LOCAL_N=$(grep -c "^https://$DOMAIN" "$SM" 2>/dev/null || echo 0)
SRC_N=$(ls source/*.html 2>/dev/null | wc -l | tr -d ' ')
[ "$LOCAL_N" -eq "$SRC_N" ] && chk "sitemap 页数与实际页面一致 ($LOCAL_N 页)" ok \
  || chk "sitemap 页数与实际页面一致" "ok" "sitemap $LOCAL_N 条，实际 $SRC_N 页，重新构建"

# ── 6. robots.txt 正确 ──
RB=$(fetch "https://$DOMAIN/robots.txt")
echo "$RB" | grep -q "User-agent: \*" && chk "robots.txt 存在且未屏蔽爬虫" ok || chk "robots.txt 存在且未屏蔽爬虫" "ok" "必须有 User-agent: * 行"
echo "$RB" | grep -q "Sitemap: https://$DOMAIN/sitemap.xml" \
  && chk "robots.txt 声明了 sitemap" ok \
  || chk "robots.txt 声明了 sitemap" "ok" "应包含 Sitemap: https://$DOMAIN/sitemap.xml"

# ── 7. 没有误封 Googlebot ──
echo "$RB" | grep -iE "Disallow: /$" && chk "未禁止全站抓取" "" "robots.txt 里有 Disallow: / ，会阻止所有抓取" || chk "未禁止全站抓取" ok

# ── 8. canonical 正确 ──
H=$(fetch "https://$DOMAIN/")
echo "$H" | grep -q "<link rel=\"canonical\" href=\"https://$DOMAIN/\"" \
  && chk "首页 canonical 指向自身 https" ok \
  || chk "首页 canonical 指向自身 https" "ok" "canonical 应为 https://$DOMAIN/"

# ── 9. 页面有 title 与 description ──
echo "$H" | grep -q "<title>" && echo "$H" | grep -q "name=\"description\"" \
  && chk "首页有 title 与 meta description" ok \
  || chk "首页有 title 与 meta description" "ok" ""
[ ${#H} -lt 500 ] && chk "首页内容非空（不是错误页）" "" "页面内容仅 ${#H} 字节" || chk "首页内容非空（不是错误页）" ok

# ── 10. 法务页齐全（AdSense 必需）──
LEGAL_OK=1
for p in privacy.html about.html contact.html disclaimer.html; do
  [ "$(code "https://$DOMAIN/$p")" = "200" ] || LEGAL_OK=0
done
[ "$LEGAL_OK" = "1" ] && chk "法务四页齐全（AdSense 必需）" ok || chk "法务四页齐全（AdSense 必需）" "ok" "缺 privacy/about/contact/disclaimer 之一"

# ── 11. 移动端可用 ──
echo "$H" | grep -q "name=\"viewport\"" && chk "有 viewport 设置（移动端友好）" ok || chk "有 viewport 设置（移动端友好）" "ok" ""

# ── 12. 页面响应速度（3 次取最快，避免网络抖动误判）──
BEST=99
for i in 1 2 3; do
  T=$(curl -s --noproxy '*' -L -o /dev/null -w "%{time_total}" -A "$UA" --max-time 30 "https://$DOMAIN/" 2>/dev/null)
  B=$(printf "%f" "$T" 2>/dev/null)
  OK=$(printf "%f %f" "${B:-99}" "$BEST" | awk '{print ($1<$2)?$1:$2}')
  BEST="$OK"
done
if [ "$(printf "%f %f" "$BEST" 2.5 | awk '{print ($1<$2)?1:0}')" = "1" ]; then
  chk "首页响应时间 ${BEST}s（< 2.5 秒）" ok
else
  chk "首页响应时间 ${BEST}s（< 2.5 秒）" "" "偏慢会影响排名，检查 Cloudflare 是否已缓存（应为 CF-Cache-Status: HIT）"
fi

echo
echo "==============================================="
printf " 通过 %d / %d\n" "$PASS" "$((PASS+FAIL))"
echo "==============================================="
echo
if [ "$FAIL" -eq 0 ]; then
  echo "技术层面已就绪。下一步是 Search Console 操作："
  echo "  1. Google Search Console → 站点地图 → 提交"
  echo "     https://$DOMAIN/sitemap.xml"
  echo "  2. Bing Webmaster Tools → 提交同一份 sitemap（收录更快）"
  echo "  3. Search Console → 网址检查 → 提交首页请求索引"
  echo
  echo "注意：技术就绪≠ 被收录。新站通常 1–4 周开始有抓取，3–6 个月才有排名。"
else
  echo "有 $FAIL 项未通过，先修掉这些再提交 sitemap。"
fi
