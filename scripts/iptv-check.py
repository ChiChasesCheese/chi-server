#!/usr/bin/env python3
"""过滤 M3U 直播源：只保留从这台机器真能播的频道（chi media iptv 调用）。

用法: python3 -I iptv-check.py <输入.m3u> <输出.m3u>

公开直播源一半以上是死的或者限大陆 IP，直接丢给 Jellyfin 会满屏“播放失败”。
判定“能播”：拿到 m3u8 → 跟到具体码率的子列表 → 真的下载到一个分片的开头。
只用标准库（macOS 自带 python3），不装依赖。
"""
import concurrent.futures as cf
import re
import sys
import urllib.parse
import urllib.request

# iptv-org 的频道名是英文的，常见的换成中文，遥控器上好找
ZH = {
    "Anhui TV": "安徽卫视", "Beijing Satellite TV": "北京卫视", "Dragon TV International": "东方卫视国际",
    "Guangdong Satellite TV": "广东卫视", "Hebei TV": "河北卫视", "Hunan TV": "湖南卫视",
    "Zhejiang International Channel": "浙江国际", "Jiangsu TV": "江苏卫视", "Shenzhen TV": "深圳卫视",
    "Heilongjiang TV": "黑龙江卫视", "Guangzhou TV": "广州电视台", "Nei Monggol TV": "内蒙古卫视",
    "Xizang TV Chinese": "西藏卫视", "Kangba TV": "康巴卫视", "Fujian Comprehensive Channel": "福建综合",
    "CCTV-Storm Theater": "CCTV 风云剧场", "CCTV-The First Theater": "CCTV 第一剧场",
    "CCTV-Nostalgia Theater": "CCTV 怀旧剧场", "CCTV-Storm Music": "CCTV 风云音乐",
    "CCTV-Storm Football": "CCTV 风云足球", "CCTV-World Geography SD": "CCTV 世界地理",
    "CCTV-Weapon & Technology": "CCTV 兵器科技", "CCTV-Women's Fashion SD": "CCTV 女性时尚",
    "CCTV-Culture of Quality SD": "CCTV 央视文化精品", "CCTV-Golf & Tennis": "CCTV 高尔夫网球",
    "CCTV-Health": "CCTV 央视健康", "CCTV-Billiards": "CCTV 央视台球",
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
                return len(body) > 1000  # 直接是 ts/flv 流
            uris = [l for l in text.splitlines() if l and not l.startswith("#")]
            if not uris:
                return False
            nxt = urllib.parse.urljoin(u, uris[0])
            if "#EXT-X-STREAM-INF" in text:  # 主列表 → 跟到子列表
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
