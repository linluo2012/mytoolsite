#!/usr/bin/env python3
"""
build.py — 站点构建脚本

本地用法（填域名并预览）：
    python3 build.py mysite.com

Cloudflare Pages 云端构建（自动执行）：
    python3 build.py --build

构建流程：
    1. 把 source/ 复制到输出目录
    2. 替换占位域名 example.com → 真实域名
    3. 为含 AFFILIATE_BLOCK 标记的页面注入联盟区块（含样式）
    4. 仅对实际存在的页面生成 sitemap.xml
    5. 生成 robots.txt
    6. 生成 _headers（安全响应头 + 缓存策略）
    7. 校验产物

联盟区块：
    在 source/*.html 中用 <!--AFFILIATE:payroll--> 这样的标记指定区块类型，
    build.py 会自动插入对应内容与样式。链接在 affiliate-config.json 中集中管理。

域名优先级：
    环境变量 SITE_DOMAIN > 命令行参数 > .env > domain.txt > example.com

注意：不要在仓库里放 wrangler.toml。
那个文件会让 Cloudflare 把 Pages 项目误判为 Workers 项目，
导致它尝试执行 `npx wrangler deploy` 并因缺少 Worker 入口而失败。
"""
import sys, os, pathlib, shutil, re, json

ROOT = pathlib.Path(__file__).parent
SRC = ROOT / "source"
OUT = ROOT / "site"
PLACEHOLDER = "example.com"

# Cloudflare Pages 默认输出目录
CF_OUT = ROOT / "dist"

# ── 联盟区块 ──────────────────────────────────────
AFF_CONFIG = ROOT / "affiliate-config.json"
AFF_STYLE_MARK = "<!--AFF_STYLE-->"

AFF_INTRO = {
    "payroll": "Payroll software handles the filing, withholding and deposit schedule for you. "
               "It costs more than doing it yourself in the first month and less than every month after.",
    "cash": "Cash flow problems usually come from missing data rather than missing money. "
            "These tools close that gap automatically.",
    "breakeven": "A break-even figure is only useful if the cost side is accurate. "
                 "These tools track real cost as it happens rather than estimating it after the fact.",
    "margin": "Margins calculated here are estimates based on what you enter. "
              "These tools track the real numbers so the estimate becomes a record.",
}

AFF_HEADINGS = {
    "payroll": "Run payroll without the filing burden",
    "cash": "Track where the cash actually goes",
    "breakeven": "Track the cost side of your break-even",
    "margin": "Track the real numbers behind your margin",
}


def aff_style() -> str:
    return """<style>
  .aff{background:#f7fbf7;border:1px solid #c8e0c8;border-radius:10px;padding:18px 20px;margin:0 0 22px;}
  .aff-h{display:flex;align-items:baseline;gap:8px;margin:0 0 4px;flex-wrap:wrap;}
  .aff-h h3{margin:0;font-size:15px;font-weight:600;color:#1a4a1a;}
  .aff-badge{font-size:11px;background:#e3f2e3;color:#2d6a2d;padding:1px 7px;border-radius:20px;}
  .aff-sub{font-size:13px;color:#3d5c3d;margin:0 0 14px;line-height:1.6;}
  .aff-item{display:block;text-decoration:none;color:inherit;border:1px solid #d5e5d5;
    background:#fff;border-radius:8px;padding:12px 14px;margin-bottom:9px;
    transition:border-color .15s,background .15s;}
  .aff-item:hover{border-color:#4a9a4a;background:#f4faf4;}
  .aff-item:last-child{margin-bottom:0;}
  .aff-t{display:flex;align-items:baseline;gap:8px;margin-bottom:3px;flex-wrap:wrap;}
  .aff-t strong{font-size:14px;font-weight:600;color:#1a4a1a;}
  .aff-d{font-size:13px;color:#4a5c4a;line-height:1.6;margin:0;}
  .aff-dis{margin:14px 0 0;font-size:12px;color:#5a6a5a;line-height:1.6;}
  .aff-dis a{color:#2d6a2d;}
</style>"""


def build_affiliate_block(kind: str) -> str:
    """生成联盟区块 HTML。配置里没有有效链接时返回空串。"""
    if not AFF_CONFIG.exists():
        return ""
    try:
        cfg = json.loads(AFF_CONFIG.read_text(encoding="utf-8"))
    except Exception as e:
        print(f"  警告：affiliate-config.json 解析失败（{e}），跳过联盟区块")
        return ""
    items = [x for x in cfg.get(kind, []) if x.get("url")]
    if not items:
        return ""
    head = AFF_HEADINGS.get(kind, "Recommended tools")
    intro = AFF_INTRO.get(kind, "")
    rows = []
    for it in items:
        badge = f'<span class="aff-badge">{it["badge"]}</span>' if it.get("badge") else ""
        rows.append(
            f'<a class="aff-item" href="{it["url"]}" rel="nofollow sponsored noopener" target="_blank">'
            f'<div class="aff-t"><strong>{it["name"]}</strong>{badge}</div>'
            f'<p class="aff-d">{it["desc"]}</p></a>'
        )
    return (
        f'<div class="aff">'
        f'<div class="aff-h"><h3>{head}</h3></div>'
        f'<p class="aff-sub">{intro}</p>'
        + "".join(rows)
        + '<p class="aff-dis">These are affiliate links. We may earn a commission if you sign up, '
          'at no extra cost to you. Calculations on this page are unaffected by any link.</p>'
        + "</div>"
    )


def inject_affiliates(html: str, domain: str) -> str:
    """把 <!--AFFILIATE:kind--> 标记替换为实际区块，并在有区块时注入样式。"""
    if "<!--AFFILIATE:" not in html:
        return html

    # 先算出所有要注入的区块；若一个都没有，则原样返回（不注入无用的样式）
    blocks = {}
    for m in re.finditer(r"<!--AFFILIATE:(\w+)-->", html):
        kind = m.group(1)
        if kind not in blocks:
            blocks[kind] = build_affiliate_block(kind)
    if not any(blocks.values()):
        return re.sub(r"<!--AFFILIATE:\w+-->", "", html)

    # 有内容才注入样式
    if AFF_STYLE_MARK in html:
        html = html.replace(AFF_STYLE_MARK, aff_style())
    elif "</head>" in html:
        html = html.replace("</head>", aff_style() + "\n</head>", 1)

    def repl(m):
        return blocks.get(m.group(1), "")
    return re.sub(r"<!--AFFILIATE:(\w+)-->", repl, html)


def from_file(name: str) -> str:
    """从单行文本文件读取域名（.env 或 domain.txt）。"""
    p = ROOT / name
    if not p.exists():
        return ""
    t = p.read_text(encoding="utf-8").strip()
    m = re.search(r'^SITE_DOMAIN\s*=\s*(.+)$', t, re.MULTILINE)
    if m:
        return m.group(1).strip().strip('"\'').lower()
    # 纯文本单行
    return t.splitlines()[0].strip().lower() if t else ""


def resolve_domain() -> str:
    """按优先级解析真实域名。"""
    env = os.environ.get("SITE_DOMAIN", "").strip()
    if env:
        return env.lower()
    for a in sys.argv[1:]:
        if not a.startswith("--") and "." in a:
            return a.lower()
    for name in (".env", "domain.txt"):
        v = from_file(name)
        if v:
            return v
    return PLACEHOLDER


def build(domain: str, outdir: pathlib.Path) -> int:
    if not SRC.exists():
        print(f"错误：找不到 {SRC}")
        return 1

    pages = sorted(SRC.glob("*.html"))
    if not pages:
        print(f"错误：{SRC} 里没有 html 文件")
        return 1

    outdir.mkdir(parents=True, exist_ok=True)

    # 1. 复制 + 替换 + 联盟区块注入
    changed = []
    aff_count = 0
    aff_kinds = set()
    for f in pages:
        text = f.read_text(encoding="utf-8")
        n = text.count(PLACEHOLDER)
        if n:
            text = text.replace(PLACEHOLDER, domain)
            changed.append((f.name, n))
        # 联盟区块注入
        if "<!--AFFILIATE:" in text:
            before = text
            text = inject_affiliates(text, domain)
            if 'class="aff"' in text and 'class="aff"' not in before:
                aff_count += 1
                aff_kinds.add(re.search(r"<!--AFFILIATE:(\w+)-->", before).group(1))
        (outdir / f.name).write_text(text, encoding="utf-8")
        # 附带复制非 html 资源
    # 2. 复制 source/ 下的非 HTML 文件（验证文件、_headers 等）
    # 自动发现，避免新增文件时忘记改代码
    for extra in sorted(p for p in SRC.iterdir() if p.is_file() and p.suffix != ".html"):
        shutil.copy(extra, outdir / extra.name)

    # 3. sitemap：只列真实存在的页面
    built = sorted(p.name for p in outdir.glob("*.html"))
    order = ["index.html"] + [n for n in built if n != "index.html"]
    urls = []
    for name in order:
        loc = domain if name == "index.html" else f"{domain}/{name}"
        if "calculator" in name:
            pri, freq = "0.9", "weekly"
        elif name == "index.html" or name == "tools.html":
            pri, freq = "1.0", "weekly"
        else:
            pri, freq = "0.3", "yearly"
        urls.append(f"  <url>\n    <loc>https://{loc}</loc>\n"
                    f"    <changefreq>{freq}</changefreq>\n"
                    f"    <priority>{pri}</priority>\n  </url>")

    (outdir / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "\n".join(urls) + "\n</urlset>\n", encoding="utf-8")

    # 3. robots.txt
    (outdir / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\n\nSitemap: https://{domain}/sitemap.xml\n",
        encoding="utf-8")

    # 4. Cloudflare 缓存与安全响应头
    (outdir / "_headers").write_text(
        "/*\n"
        "  X-Content-Type-Options: nosniff\n"
        "  Referrer-Policy: strict-origin-when-cross-origin\n"
        "  X-Frame-Options: SAMEORIGIN\n"
        "  Permissions-Policy: geolocation=(), microphone=(), camera=()\n"
        "\n"
        "/index.html\n"
        "  Cache-Control: no-cache\n"
        "\n"
        "/tools.html\n"
        "  Cache-Control: no-cache\n",
        encoding="utf-8")

    # 5. 校验
    issues = []

    # 5a. 域名回退检查 —— 这是最常见的失败原因，必须给明确指引
    if domain == PLACEHOLDER:
        issues.append(
            f"域名未配置，构建使用了占位域名 {PLACEHOLDER}，线上所有链接都会失效。\n"
            f"     修复方式（任选其一）：\n"
            f"       1. 在仓库根目录的 domain.txt 里写入你的域名（一行纯文本）\n"
            f"       2. Cloudflare 后台 Settings → Environment variables → Add\n"
            f"          Variable name: SITE_DOMAIN    Value: 你的真实域名"
        )

    # 只检查站内链接（路径以 .html 结尾）是否还指向占位域名。
    # 联盟等第三方链接可能含自己的域名，不参与此检查。
    leftover = []
    for f in outdir.glob("*.html"):
        t = f.read_text(encoding="utf-8")
        for m in re.finditer(rf'href="https://{re.escape(PLACEHOLDER)}/([a-z0-9\-]+\.html)"', t):
            leftover.append(f"{f.name} -> {m.group(1)}")
            break
    if leftover:
        issues.append(f"站内链接仍指向占位域名 {PLACEHOLDER}: {leftover}")

    import json
    for f in sorted(outdir.glob("*.html")):
        t = f.read_text(encoding="utf-8")
        for i, b in enumerate(re.findall(
                r'<script type="application/ld\+json">(.*?)</script>', t, re.S)):
            try:
                json.loads(b)
            except Exception as e:
                issues.append(f"JSON-LD 非法 {f.name}#{i+1}: {e}")
        # 死链检查
        for h in set(re.findall(rf'href="https://{re.escape(domain)}/([a-z0-9\-]+\.html)"', t)):
            if h not in built and h != f.name:
                issues.append(f"死链 {f.name} -> {h}")

    # 报告
    print(f"domain:  {domain}")
    print(f"out:     {outdir}")
    print(f"pages:   {len(built)}")
    for name, n in changed:
        print(f"         {name:38s} {n} 处域名替换")
    # 联盟区块状态
    if aff_count:
        print(f"affiliate: {aff_count} 个页面已注入（区块类型: {', '.join(sorted(aff_kinds))}）")
    else:
        marked = sum(1 for f in SRC.glob("*.html")
                     if "<!--AFFILIATE:" in f.read_text(encoding="utf-8"))
        if marked:
            print(f"affiliate: {marked} 个页面有标记，但 affiliate-config.json 中对应链接为空")
            print("          → 填入推广链接后重新构建即可自动显示")
        else:
            print("affiliate: 未配置")
    if issues:
        print("\n构建完成，但有问题:")
        for i in issues:
            print(f"  ! {i}")
    else:
        print("\n构建完成，无问题")
    return 1 if issues else 0


if __name__ == "__main__":
    cloud = "--build" in sys.argv
    dom = resolve_domain()
    target = CF_OUT if cloud else OUT
    sys.exit(build(dom, target))