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
    3. 仅对实际存在的页面生成 sitemap.xml
    4. 生成 robots.txt
    5. 校验产物

域名优先级：
    环境变量 SITE_DOMAIN > 命令行参数 > example.com（回退）
"""
import sys, os, pathlib, shutil, re

ROOT = pathlib.Path(__file__).parent
SRC = ROOT / "source"
OUT = ROOT / "site"
PLACEHOLDER = "example.com"

# Cloudflare Pages 默认输出目录
CF_OUT = ROOT / "dist"


def resolve_domain() -> str:
    """云端用环境变量，本地用命令行参数。"""
    env = os.environ.get("SITE_DOMAIN", "").strip()
    if env:
        return env.lower()
    for a in sys.argv[1:]:
        if not a.startswith("--") and "." in a:
            return a.lower()
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

    # 1. 复制 + 替换
    changed = []
    for f in pages:
        text = f.read_text(encoding="utf-8")
        n = text.count(PLACEHOLDER)
        if n:
            text = text.replace(PLACEHOLDER, domain)
            (outdir / f.name).write_text(text, encoding="utf-8")
            changed.append((f.name, n))
        else:
            shutil.copy(f, outdir / f.name)
        # 附带复制非 html 资源
    for extra in ("robots.txt", "sitemap.xml", "_headers", "_redirects"):
        p = SRC / extra
        if p.exists():
            shutil.copy(p, outdir / extra)

    # 2. sitemap：只列真实存在的页面
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
    leftover = [f.name for f in outdir.glob("*.html")
                 if PLACEHOLDER in f.read_text(encoding="utf-8")]
    if leftover:
        issues.append(f"残留占位域名: {leftover}")

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