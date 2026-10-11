#!/usr/bin/env python3
"""Filter an M3U live TV list down to channels that actually play from this machine (called by chi media iptv).

Usage: python3 -I iptv-check.py <input.m3u> <output.m3u>

More than half of public IPTV streams are dead or geo-blocked; handing them straight to Jellyfin gives a screen full
of "playback failed". "Playable" means: fetch the m3u8 -> follow it to a variant playlist -> actually download the
start of one segment.
Standard library only (the python3 that ships with macOS), no dependencies.

Env:
  IPTV_ZH_NAMES  1 (default) = rename well-known channels to their Chinese names; 0 = keep iptv-org's English names
"""
import concurrent.futures as cf
import os
import re
import sys
import urllib.parse
import urllib.request

# iptv-org names channels in English. Viewers of the default China list find them faster on a remote by their
# Chinese names, so the common ones get renamed. Written as \u escapes to keep this file ASCII; the values are
# display names only and never matched against anything remote.
ZH = {
    "Anhui TV": "\u5b89\u5fbd\u536b\u89c6",
    "Beijing Satellite TV": "\u5317\u4eac\u536b\u89c6",
    "Dragon TV International": "\u4e1c\u65b9\u536b\u89c6\u56fd\u9645",
    "Guangdong Satellite TV": "\u5e7f\u4e1c\u536b\u89c6",
    "Hebei TV": "\u6cb3\u5317\u536b\u89c6",
    "Hunan TV": "\u6e56\u5357\u536b\u89c6",
    "Zhejiang International Channel": "\u6d59\u6c5f\u56fd\u9645",
    "Jiangsu TV": "\u6c5f\u82cf\u536b\u89c6",
    "Shenzhen TV": "\u6df1\u5733\u536b\u89c6",
    "Heilongjiang TV": "\u9ed1\u9f99\u6c5f\u536b\u89c6",
    "Guangzhou TV": "\u5e7f\u5dde\u7535\u89c6\u53f0",
    "Nei Monggol TV": "\u5185\u8499\u53e4\u536b\u89c6",
    "Xizang TV Chinese": "\u897f\u85cf\u536b\u89c6",
    "Kangba TV": "\u5eb7\u5df4\u536b\u89c6",
    "Fujian Comprehensive Channel": "\u798f\u5efa\u7efc\u5408",
    "CCTV-Storm Theater": "CCTV \u98ce\u4e91\u5267\u573a",
    "CCTV-The First Theater": "CCTV \u7b2c\u4e00\u5267\u573a",
    "CCTV-Nostalgia Theater": "CCTV \u6000\u65e7\u5267\u573a",
    "CCTV-Storm Music": "CCTV \u98ce\u4e91\u97f3\u4e50",
    "CCTV-Storm Football": "CCTV \u98ce\u4e91\u8db3\u7403",
    "CCTV-World Geography SD": "CCTV \u4e16\u754c\u5730\u7406",
    "CCTV-Weapon & Technology": "CCTV \u5175\u5668\u79d1\u6280",
    "CCTV-Women's Fashion SD": "CCTV \u5973\u6027\u65f6\u5c1a",
    "CCTV-Culture of Quality SD": "CCTV \u592e\u89c6\u6587\u5316\u7cbe\u54c1",
    "CCTV-Golf & Tennis": "CCTV \u9ad8\u5c14\u592b\u7f51\u7403",
    "CCTV-Health": "CCTV \u592e\u89c6\u5065\u5eb7",
    "CCTV-Billiards": "CCTV \u592e\u89c6\u53f0\u7403",
}


def parse(lines):
    entries, inf, opts = [], None, []
    for line in lines:
        if line.startswith("#EXTINF"):
            inf, opts = line, []
        elif line.startswith("#EXTVLCOPT:"):
            opts.append(line)
        elif line and not line.startswith("#") and inf:
            entries.append((inf, opts, line.strip()))
            inf = None
    return entries


def get(url, opts, limit=200_000):
    o = dict(l[11:].partition("=")[::2] for l in opts)
    headers = {"User-Agent": o.get("http-user-agent", "Mozilla/5.0")}
    if "http-referrer" in o:
        headers["Referer"] = o["http-referrer"]
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=8) as r:
        return r.geturl(), r.read(limit)


def alive(entry):
    _, opts, url = entry
    try:
        u, body = get(url, opts)
        for _ in range(3):
            text = body.decode("utf-8", "ignore")
            if "#EXTM3U" not in text:
                return len(body) > 1000  # a raw ts/flv stream
            uris = [l for l in text.splitlines() if l and not l.startswith("#")]
            if not uris:
                return False
            nxt = urllib.parse.urljoin(u, uris[0])
            if "#EXT-X-STREAM-INF" in text:  # master playlist -> follow to a variant
                u, body = get(nxt, opts)
                continue
            return len(get(nxt, opts, 4096)[1]) >= 1000
    except Exception:
        return False
    return False


def rename(inf):
    head, _, name = inf.rpartition(",")
    base = re.sub(r"\s*[\(\[].*$", "", name).strip()
    base = re.sub(r" HD$", "", base)
    if os.environ.get("IPTV_ZH_NAMES", "1") == "0":
        return inf
    zh = ZH.get(base)
    if not zh and re.fullmatch(r"CCTV-\d+\+?", base):
        zh = base.replace("-", "")
    return f"{head},{zh}" if zh else inf


def main(src, dst):
    entries = parse(open(src, encoding="utf-8").read().splitlines())
    with cf.ThreadPoolExecutor(32) as ex:
        good = [e for e, ok in zip(entries, ex.map(alive, entries)) if ok]
    with open(dst, "w", encoding="utf-8") as f:
        f.write("#EXTM3U\n")
        for inf, opts, url in good:
            f.write("\n".join([rename(inf), *opts, url]) + "\n")
    print(f"{len(good)}/{len(entries)}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
