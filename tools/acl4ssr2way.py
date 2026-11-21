#!/usr/bin/env python3
"""Convert the ACL4SSR Clash rule lists into a way rule set (JSON).

Mirrors the `RULES` mapping of the subscription-forge project in
``C:\\Users\\Administrator\\Documents\\Codex\\2026-10-17\\https-github-com-acl4ssr-acl4ssr-https``
(its ``app.py`` downloads these lists, its ``converter.py`` turns them into
sing-box rule_sets):

    Tencent          (blackmatrix7/ios_rule_script) -> direct
    LocalAreaNetwork                                -> direct
    UnBan                                           -> direct
    BanAD                                           -> block
    BanProgramAD                                    -> block
    ChinaDomain                                     -> direct
    GoogleCN                                        -> direct
    Telegram                                        -> proxy
    Netflix                                         -> proxy
    Microsoft                                       -> direct   (source selector defaults DIRECT)
    Apple                                           -> direct
    ChinaCompanyIp                                  -> direct
    ChinaIp                                         -> direct
    ProxyLite                                       -> proxy

The order is the source's route-rule order: way evaluates routing rules in
order, so the emitted lists must stay in this sequence.

Output is the HAP's bundled rawfile by default (seeded to
filesDir/xray/rules.json on first launch); --out writes it elsewhere.

    {"version":1,"name":"ACL4SSR","generatedAt":...,"source":...,
     "lists":[{"name":..., "target":"direct|block|proxy",
               "domains":["domain:qq.com","full:example.com","keyword:ads"],
               "ip":["1.2.3.0/24","2001:db8::/32"]}],
     "stats":{"rules":N,"domains":N,"ip":N,"skipped":N}}

Usage:
    python acl4ssr2way.py                     # fetch GitHub, write the bundled rawfile
    python acl4ssr2way.py --cache-dir cache   # reuse downloaded .list files
    python acl4ssr2way.py --from-dir lists    # offline: read <name>.list from a dir
    python acl4ssr2way.py --stdout            # print to stdout
"""

import argparse
import datetime
import json
import os
import sys
import urllib.request

ACL4SSR = "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash"
ACL4SSR_CDN = "https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash"
TENCENT = ("https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/"
           "rule/Clash/Tencent/Tencent.list")
TENCENT_CDN = ("https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/"
               "rule/Clash/Tencent/Tencent.list")

# (list name, way target, direct url, cdn url) in the source's route order.
RULES = [
    ("Tencent", "direct", TENCENT, TENCENT_CDN),
    ("LocalAreaNetwork", "direct", f"{ACL4SSR}/LocalAreaNetwork.list", f"{ACL4SSR_CDN}/LocalAreaNetwork.list"),
    ("UnBan", "direct", f"{ACL4SSR}/UnBan.list", f"{ACL4SSR_CDN}/UnBan.list"),
    ("BanAD", "block", f"{ACL4SSR}/BanAD.list", f"{ACL4SSR_CDN}/BanAD.list"),
    ("BanProgramAD", "block", f"{ACL4SSR}/BanProgramAD.list", f"{ACL4SSR_CDN}/BanProgramAD.list"),
    ("ChinaDomain", "direct", f"{ACL4SSR}/ChinaDomain.list", f"{ACL4SSR_CDN}/ChinaDomain.list"),
    ("GoogleCN", "direct", f"{ACL4SSR}/GoogleCN.list", f"{ACL4SSR_CDN}/GoogleCN.list"),
    ("Telegram", "proxy", f"{ACL4SSR}/Telegram.list", f"{ACL4SSR_CDN}/Telegram.list"),
    ("Netflix", "proxy", f"{ACL4SSR}/Netflix.list", f"{ACL4SSR_CDN}/Netflix.list"),
    ("Microsoft", "direct", f"{ACL4SSR}/Microsoft.list", f"{ACL4SSR_CDN}/Microsoft.list"),
    ("Apple", "direct", f"{ACL4SSR}/Apple.list", f"{ACL4SSR_CDN}/Apple.list"),
    ("ChinaCompanyIp", "direct", f"{ACL4SSR}/ChinaCompanyIp.list", f"{ACL4SSR_CDN}/ChinaCompanyIp.list"),
    ("ChinaIp", "direct", f"{ACL4SSR}/ChinaIp.list", f"{ACL4SSR_CDN}/ChinaIp.list"),
    ("ProxyLite", "proxy", f"{ACL4SSR}/ProxyLite.list", f"{ACL4SSR_CDN}/ProxyLite.list"),
]

UA = "way-rules/1.0 (ACL4SSR to xray)"


def fetch(url, cache_path):
    if cache_path and os.path.exists(cache_path) and os.path.getsize(cache_path) > 0:
        with open(cache_path, encoding="utf-8-sig") as handle:
            return handle.read()
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=45) as response:
        text = response.read().decode("utf-8-sig", "replace")
    if cache_path:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
    return text


def convert(text, skipped):
    """Clash classical rules -> (domains, ips) in Xray matcher syntax."""
    domains, ips = set(), set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";") or line.startswith("//"):
            continue
        parts = [part.strip() for part in line.split(",")]
        kind = parts[0].upper()
        if len(parts) < 2 or not parts[1]:
            skipped[kind or "EMPTY"] = skipped.get(kind or "EMPTY", 0) + 1
            continue
        value = parts[1].strip()
        if kind in ("DOMAIN-SUFFIX", "DOMAIN"):
            value = value.lower().rstrip(".")
        if kind == "DOMAIN-SUFFIX":
            domains.add("domain:" + value)
        elif kind == "DOMAIN":
            domains.add("full:" + value)
        elif kind == "DOMAIN-KEYWORD":
            domains.add("keyword:" + value)
        elif kind in ("IP-CIDR", "IP-CIDR6", "IP6-CIDR"):
            ips.add(value)
        elif kind == "GEOIP":
            ips.add("geoip:" + value.lower())
        else:
            # PROCESS-NAME / URL-REGEX / RULE-SET / AND ... have no Xray equivalent.
            skipped[kind] = skipped.get(kind, 0) + 1
    return sorted(domains), sorted(ips)


def build(from_dir=None, cache_dir=None):
    lists, skipped, rules = [], {}, 0
    for name, target, url, cdn in RULES:
        if from_dir:
            path = os.path.join(from_dir, name + ".list")
            if not os.path.exists(path):
                raise SystemExit(f"missing {path}")
            with open(path, encoding="utf-8-sig") as handle:
                text = handle.read()
        else:
            cache_path = os.path.join(cache_dir, name + ".list") if cache_dir else None
            try:
                text = fetch(url, cache_path)
            except Exception as error:  # GitHub blocked: try the jsDelivr mirror
                print(f"  {name}: GitHub failed ({type(error).__name__}), trying CDN", file=sys.stderr)
                text = fetch(cdn, cache_path)
        domains, ips = convert(text, skipped)
        rules += len(domains) + len(ips)
        lists.append({"name": name, "target": target, "domains": domains, "ip": ips})
        print(f"  {name:<16} {target:<6} domains={len(domains):<5} ip={len(ips)}", file=sys.stderr)
    rule_set = {
        "version": 1,
        "name": "ACL4SSR",
        "generatedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "source": "ACL4SSR/ACL4SSR@master + blackmatrix7/ios_rule_script (Tencent)",
        "lists": lists,
        "stats": {
            "rules": rules,
            "domains": sum(len(item["domains"]) for item in lists),
            "ip": sum(len(item["ip"]) for item in lists),
            "skipped": skipped,
        },
    }
    return rule_set


def main():
    root = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description="ACL4SSR lists -> way rule set")
    parser.add_argument("--out", default=os.path.join(root, "..", "app", "entry", "src", "main",
                                                      "resources", "rawfile", "acl4ssr-way-rules.json"))
    parser.add_argument("--cache-dir", default=os.path.join(root, "cache"))
    parser.add_argument("--from-dir", default=None)
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args()

    rule_set = build(from_dir=args.from_dir, cache_dir=args.cache_dir)
    text = json.dumps(rule_set, ensure_ascii=False, separators=(",", ":"))
    if args.stdout:
        print(text)
        return
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text + "\n")
    stats = rule_set["stats"]
    print(f"wrote {args.out} ({len(text) + 1} bytes)")
    print(f"  lists={len(rule_set['lists'])} rules={stats['rules']} "
          f"domains={stats['domains']} ip={stats['ip']} skipped={stats['skipped']}")


if __name__ == "__main__":
    main()
