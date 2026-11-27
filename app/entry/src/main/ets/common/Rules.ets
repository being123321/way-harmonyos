import { RuleList, TARGET_BLOCK, TARGET_PROXY, WayRuleSet } from './RuleSet';

// Built-in split-routing policy, applied to the config right before it is
// handed to the core so imported profiles stay untouched on disk.
//
// Three user-selectable modes:
//   gfw     : only the curated blocked-site list goes through the node,
//             everything else is direct
//   bypass  : LAN + CN domains/IPs direct, the rest through the node
//   global  : everything through the node
//
// An imported rule set (ACL4SSR lists, see RuleSet.ets) replaces both built-in
// split modes when it is enabled: its own ordered lists are the policy.
//
// The ad rule set from the reference profile is deliberately not referenced:
// this geosite build has no category-ads-all entry and loading it fails the
// whole config ("geosite contains more than 200000 domains").
export interface SplitOptions {
  split: boolean;
  geodata: boolean;
  mode: string;
  blockQuic: boolean;
  // null = built-in policy; otherwise one ordered routing rule per list.
  ruleSet: WayRuleSet | null;
  // Keep the rule set's block (ad) lists; off = only direct/proxy splitting.
  blockAds: boolean;
  // Domestic DoH (direct) + foreign DoH (through the node) instead of plain UDP.
  doh: boolean;
  // FakeIP domain-first split. When on, both the built-in modes and the rule
  // set use dns.fakeIp: a fake IP maps back to the domain before routing, so a
  // rule set's domain rules no longer depend on TLS/QUIC sniffing.
  fakeDns: boolean;
  // Diagnostic logging: 'debug' writes every routing decision to the core log.
  // Off by default; only for troubleshooting routes, DNS or protocol issues.
  debugLog: boolean;
  // Server addresses resolved by the app before connecting. The core's probe
  // bootstrap resolver otherwise asks the configured DoH through the tunnel for
  // every node's server name, which made each probe look 2-3 s slower.
  bootstrapHosts: Record<string, string[]> | null;
  // 防 DNS 泄露（默认 true）：拦截端口 53/853 逃逸，防止 IPv6 DNS 与海外/全局 DNS 回落本地。
  dnsLeakProtect?: boolean;
  // 防 WebRTC 泄露（默认 true）：阻止常见 STUN/TURN 探测流量泄露真实本地/公网 IP。
  webrtcLeakProtect?: boolean;
}

// Merges pre-resolved node server addresses into `dns.hosts`, so the core (and
// its outbound probe path) never has to resolve them again through the tunnel.
export function applyBootstrapHosts(configJson: string,
  hosts: Record<string, string[]> | null): string {
  if (hosts === null) {
    return configJson;
  }
  try {
    const root: Record<string, Object> = JSON.parse(configJson) as Record<string, Object>;
    const dnsValue: Object | undefined = root['dns'];
    if (dnsValue === undefined || dnsValue === null) {
      return configJson;
    }
    const dns: Record<string, Object> = dnsValue as Record<string, Object>;
    const existing: Object | undefined = dns['hosts'];
    const merged: Record<string, Object> = existing === undefined
      ? {} as Record<string, Object>
      : existing as Record<string, Object>;
    const names: string[] = Object.keys(hosts);
    for (const name of names) {
      merged[name] = hosts[name];
    }
    dns['hosts'] = merged;
    root['dns'] = dns;
    return JSON.stringify(root);
  } catch (error) {
    return configJson;
  }
}

export const MODE_GFW: string = 'gfw';
export const MODE_BYPASS: string = 'bypass';
export const MODE_GLOBAL: string = 'global';
export const MODE_DIRECT: string = 'direct';

const PRIVATE_CIDRS: string[] = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '127.0.0.0/8',
  '169.254.0.0/16',
  '100.64.0.0/10',
  '::1/128',
  'fc00::/7',
  'fe80::/10'
];

const LOCAL_DOMAINS: string[] = ['localhost'];

// Domains that must go through the node in "gfw" mode. Kept as plain suffixes
// instead of geosite categories so a missing category can never break startup.
const GFW_SUFFIXES: string[] = [
  'domain:google.com', 'domain:googleapis.com', 'domain:gstatic.com',
  'domain:googleusercontent.com', 'domain:googlevideo.com', 'domain:google.co.jp',
  'domain:youtube.com', 'domain:youtu.be', 'domain:ytimg.com', 'domain:ggpht.com',
  'domain:twitter.com', 'domain:x.com', 'domain:t.co', 'domain:twimg.com',
  'domain:facebook.com', 'domain:fbcdn.net', 'domain:instagram.com', 'domain:cdninstagram.com',
  'domain:whatsapp.com', 'domain:whatsapp.net',
  'domain:telegram.org', 'domain:t.me', 'domain:telegra.ph', 'domain:tdesktop.com',
  'domain:openai.com', 'domain:chatgpt.com', 'domain:anthropic.com', 'domain:claude.ai',
  'domain:netflix.com', 'domain:nflxvideo.net', 'domain:nflximg.net', 'domain:nflxext.com',
  'domain:wikipedia.org', 'domain:wikimedia.org',
  'domain:github.com', 'domain:githubusercontent.com', 'domain:github.io', 'domain:githubassets.com',
  'domain:reddit.com', 'domain:redd.it', 'domain:discord.com', 'domain:discordapp.com',
  'domain:bbc.com', 'domain:bbc.co.uk', 'domain:nytimes.com', 'domain:medium.com',
  'domain:spotify.com', 'domain:scdn.co', 'domain:twitch.tv', 'domain:ttvnw.net',
  'domain:protonmail.com', 'domain:proton.me', 'domain:signal.org',
  'domain:archive.org', 'domain:duckduckgo.com', 'domain:patreon.com',
  'domain:pinterest.com', 'domain:tumblr.com', 'domain:vimeo.com', 'domain:soundcloud.com'
];

function asArray(value: Object | undefined): Object[] {
  if (value === undefined || value === null) {
    return [];
  }
  return value as Object[];
}

function hasOutboundTag(outbounds: Object[], tag: string): boolean {
  for (const item of outbounds) {
    const outbound: Record<string, Object> = item as Record<string, Object>;
    if (outbound['tag'] === tag) {
      return true;
    }
  }
  return false;
}

function addOutbound(outbounds: Object[], tag: string, protocol: string): void {
  if (hasOutboundTag(outbounds, tag)) {
    return;
  }
  const settings: Record<string, Object> = {};
  const outbound: Record<string, Object> = {
    'tag': tag,
    'protocol': protocol,
    'settings': settings
  };
  outbounds.push(outbound);
}

// `ruleTag` labels the rule for the connection snapshot (`rule_set=...` in the UI).
function makeRule(outboundTag: string, domains: string[], ips: string[],
  ruleTag?: string): Record<string, Object> {
  const rule: Record<string, Object> = { 'type': 'field', 'outboundTag': outboundTag };
  if (ruleTag !== undefined && ruleTag.length > 0) {
    rule['ruleTag'] = ruleTag;
  }
  if (domains.length > 0) {
    rule['domain'] = domains;
  }
  if (ips.length > 0) {
    rule['ip'] = ips;
  }
  return rule;
}

function proxyTag(outbounds: Object[]): string {
  const first: Record<string, Object> = outbounds[0] as Record<string, Object>;
  const tag: Object | undefined = first['tag'];
  if (typeof tag === 'string' && (tag as string).length > 0) {
    return tag as string;
  }
  first['tag'] = 'proxy';
  return 'proxy';
}

// Domestic DoH dialed directly (https+local://) and a foreign DoH dispatched
// through routing, so it leaves via the node. IP endpoints avoid a bootstrap
// lookup: 223.5.5.5 (AliDNS) and 1.1.1.1 (Cloudflare) both carry their IP in the
// TLS certificate.
const DOH_DOMESTIC: string = 'https+local://223.5.5.5/dns-query';
const DOH_FOREIGN: string = 'https://1.1.1.1/dns-query';
const DOH_FOREIGN_SECONDARY: string = 'https://8.8.8.8/dns-query';
const DOH_FOREIGN_IPS: string[] = ['1.1.1.1/32', '1.0.0.1/32', '8.8.8.8/32', '8.8.4.4/32'];
const WEBRTC_PORTS: string = '3478,3479,5349,5350,19302-19309';
const WEBRTC_DOMAINS: string[] = [
  'regexp:^stun[0-9]*\\.',
  'domain:stun.l.google.com',
  'domain:stun.services.mozilla.com',
  'domain:stun.cloudflare.com',
  'domain:stun.stunprotocol.org',
  'domain:global.stun.twilio.com',
  'domain:turn.cloudflare.com'
];

function isDomesticServerEntry(entry: Object): boolean {
  let addr: string = '';
  if (typeof entry === 'string') {
    addr = entry as string;
  } else if (entry !== null && typeof entry === 'object') {
    const rec: Record<string, Object> = entry as Record<string, Object>;
    const rawAddr: Object | undefined = rec['address'];
    if (typeof rawAddr === 'string') {
      addr = rawAddr as string;
    }
  }
  const lower: string = addr.toLowerCase();
  return lower.indexOf('223.5.5.5') >= 0 ||
    lower.indexOf('223.6.6.6') >= 0 ||
    lower.indexOf('114.114.114.114') >= 0 ||
    lower.indexOf('114.114.115.115') >= 0 ||
    lower.indexOf('119.29.29.29') >= 0 ||
    lower.indexOf('180.76.76.76') >= 0 ||
    lower.indexOf('+local://') >= 0 ||
    lower === 'localhost';
}

function makePortRule(outboundTag: string, network: string, port: string,
  inboundTags: string[], ruleTag: string, ips: string[],
  domains: string[]): Record<string, Object> {
  const rule: Record<string, Object> = {
    'type': 'field',
    'outboundTag': outboundTag,
    'ruleTag': ruleTag,
    'network': network
  };
  if (inboundTags.length > 0) {
    rule['inboundTag'] = inboundTags;
  }
  if (port.length > 0) {
    rule['port'] = port;
  }
  if (ips.length > 0) {
    rule['ip'] = ips;
  }
  if (domains.length > 0) {
    rule['domain'] = domains;
  }
  return rule;
}

function pushDnsLeakRules(rules: Object[], tunTags: string[], proxy: string): void {
  // 1) Block DoT/DoQ (port 853) so system/app Private DNS cannot bypass VPN DNS.
  rules.push(makePortRule('block', 'tcp,udp', '853', tunTags, 'DNSLeak-DoT', [], []));
  // 2) Block TUN queries targeting LAN/private DNS (192.168.x.1, fe80::1, etc.)
  //    before Private->direct, forcing quick fallback to 198.18.0.1.
  rules.push(makePortRule('block', 'tcp,udp', '53', tunTags, 'DNSLeak-Local53', PRIVATE_CIDRS, []));
  // 3) Force any remaining external IPv4/IPv6 port 53 probes through the proxy.
  rules.push(makePortRule(proxy, 'tcp,udp', '53', tunTags, 'DNSLeak-Proxy53', [], []));
}

function pushWebrtcLeakRules(rules: Object[], tunTags: string[]): void {
  rules.push(makePortRule('block', 'tcp,udp', WEBRTC_PORTS, tunTags, 'WebRTC-Ports', [], []));
  rules.push(makePortRule('block', 'tcp,udp', '', tunTags, 'WebRTC-Domain', [], WEBRTC_DOMAINS));
}

function applyDohDns(root: Record<string, Object>, geodata: boolean, mode: string,
  dnsLeakProtect: boolean): void {
  const rawDns: Object | undefined = root['dns'] as Object | undefined;
  const dns: Record<string, Object> =
    (rawDns === undefined || rawDns === null) ? {} : rawDns as Record<string, Object>;
  const servers: Object[] = [];
  const domestic: Record<string, Object> = { 'address': DOH_DOMESTIC };
  const foreign: Record<string, Object> = { 'address': DOH_FOREIGN };
  const foreignBackup: Record<string, Object> = { 'address': DOH_FOREIGN_SECONDARY };
  if (dnsLeakProtect && mode === MODE_GLOBAL) {
    servers.push(foreign);
    servers.push(foreignBackup);
  } else if (geodata) {
    // CN first with a geosite matcher, foreign as the default for the rest.
    domestic['domains'] = ['geosite:cn'];
    domestic['skipFallback'] = true;
    servers.push(domestic);
    servers.push(foreign);
    if (dnsLeakProtect) {
      servers.push(foreignBackup);
    }
  } else if (dnsLeakProtect) {
    // Without geodata, keeping domestic in fallback risks leaking overseas DNS
    // on transient timeouts; use remote DoH only when DNS leak guard is on.
    servers.push(foreign);
    servers.push(foreignBackup);
  } else {
    // Without geodata and leak guard, keep foreign first and domestic behind it.
    servers.push(foreign);
    servers.push(domestic);
  }
  dns['servers'] = servers;
  if (dnsLeakProtect) {
    dns['disableFallback'] = true;
    dns['disableFallbackIfMatch'] = true;
  }
  root['dns'] = dns;
}

// Domain-first hybrid: keep the domestic real resolver first for geosite:cn,
// then let fakeDNS hand out fake IPs for domains that will be proxied. The
// TUN reverts a fake IP to the domain before routing, so launching overseas
// apps skips remote DNS lookups altogether.
//
// Pool 198.19.0.0/16 is deliberate (TUN DNS anchor is 198.18.0.1).
// 2048 entries keep FakeIP table RAM tiny (~400 KB) while covering mobile use.
const FAKE_IP_POOL: string = '198.19.0.0/16';
const FAKE_IP_POOL_SIZE: number = 2048;
const FAKE_IP_TTL: number = 300;
// The delay/liveness probe is a hostname; it must not be faked. Give these
// domains a real resolver before fakedns, matching v2rayNG's gstatic target.
const PROBE_DOMAINS: string[] = ['domain:gstatic.com', 'domain:www.gstatic.com', 'domain:google.com'];

function applyFakeDns(root: Record<string, Object>, options: SplitOptions): void {
  // The Rust core implements FakeIP through dns.fakeIp; the Go `fakedns`
  // special DNS server is rejected by this kernel, so never insert it.
  if (!options.fakeDns) {
    return;
  }
  if (options.mode !== MODE_BYPASS && options.mode !== MODE_GFW) {
    return;
  }
  const rawDns: Object | undefined = root['dns'] as Object | undefined;
  if (rawDns === undefined || rawDns === null) {
    return;
  }
  const dns: Record<string, Object> = rawDns as Record<string, Object>;
  const servers: Object[] = asArray(dns['servers'] as Object | undefined);
  if (servers.length === 0) {
    return;
  }
  const dnsLeak: boolean = options.dnsLeakProtect !== false;
  const probeAddress: string = dnsLeak
    ? (options.doh ? DOH_FOREIGN : '1.1.1.1')
    : (options.doh ? DOH_DOMESTIC : '223.5.5.5');
  const probeReal: Record<string, Object> = {
    'address': probeAddress,
    'domains': PROBE_DOMAINS
  };
  if (options.mode === MODE_GFW) {
    servers.unshift(probeReal);
  } else {
    // Keep the domestic real resolver first for geosite:cn; dns.fakeIp drives
    // the fake mapping automatically, so no separate fakedns server is added.
    let insertAt: number = 0;
    for (let i = 0; i < servers.length; i++) {
      const server: Record<string, Object> = servers[i] as Record<string, Object>;
      const domains: Object | undefined = server['domains'] as Object | undefined;
      if (domains !== undefined && domains !== null) {
        insertAt = i + 1;
      }
    }
    servers.splice(insertAt, 0, probeReal);
  }
  dns['servers'] = servers;
  dns['fakeIp'] = {
    'enabled': true,
    'ipv4Pool': FAKE_IP_POOL,
    'poolSize': FAKE_IP_POOL_SIZE,
    'ttl': FAKE_IP_TTL
  } as Record<string, Object>;
  root['dns'] = dns;
}

function dohRouteRule(proxyTag: string): Object {
  return makeRule(proxyTag, [], DOH_FOREIGN_IPS, 'DoH');
}

// The parser rejects a rule without any condition, so "everything else" is
// spelled as a tcp+udp matcher instead of an empty rule.
function catchAllRule(tag: string): Object {
  const rule: Record<string, Object> = {
    'type': 'field',
    'outboundTag': tag,
    'ruleTag': 'Default',
    'network': 'tcp,udp'
  };
  return rule;
}

// Ensures non-CN / global queries never leak or fall back to domestic DNS when
// DoH is off, and guarantees root.dns exists so TUN sends DNS to 198.18.0.1.
function applySplitDns(root: Record<string, Object>, geodata: boolean, mode: string,
  dnsLeakProtect: boolean): void {
  const existing: Object | undefined = root['dns'];
  const dns: Record<string, Object> =
    (existing === undefined || existing === null) ? {} : existing as Record<string, Object>;
  const existingServers: Object[] = asArray(dns['servers'] as Object | undefined);
  if (!geodata && !dnsLeakProtect && existingServers.length === 0) {
    return;
  }
  if (dnsLeakProtect && mode === MODE_GLOBAL) {
    dns['servers'] = ['1.1.1.1', '8.8.8.8'];
    dns['disableFallback'] = true;
    dns['disableFallbackIfMatch'] = true;
    root['dns'] = dns;
    return;
  }
  const filtered: Object[] = [];
  for (const item of existingServers) {
    if (dnsLeakProtect && isDomesticServerEntry(item)) {
      continue;
    }
    filtered.push(item);
  }
  if (filtered.length === 0) {
    filtered.push('1.1.1.1');
    filtered.push('8.8.8.8');
  }
  if (geodata) {
    const domestic: Record<string, Object> = {
      'address': '223.5.5.5',
      'domains': ['geosite:cn'],
      'skipFallback': true
    };
    const merged: Object[] = [domestic];
    for (const item of filtered) {
      merged.push(item);
    }
    dns['servers'] = merged;
  } else {
    dns['servers'] = filtered;
  }
  if (dnsLeakProtect) {
    dns['disableFallback'] = true;
    dns['disableFallbackIfMatch'] = true;
  }
  root['dns'] = dns;
}

// v2rayNG ships "阻断udp443" as its first routing rule: proxies handle QUIC
// badly, and most apps fall back to TCP immediately once it is refused.
function quicBlockRule(): Record<string, Object> {
  const rule: Record<string, Object> = {
    'type': 'field',
    'outboundTag': 'block',
    'ruleTag': 'QUIC',
    'port': '443',
    'network': 'udp'
  };
  return rule;
}

function mergeRules(root: Record<string, Object>, rules: Object[], needIpResolution: boolean): void {
  let routing: Record<string, Object> = {};
  const existingRouting: Object | undefined = root['routing'];
  if (existingRouting !== undefined && existingRouting !== null) {
    routing = existingRouting as Record<string, Object>;
  }
  const original: Object[] = asArray(routing['rules'] as Object | undefined);
  for (const item of original) {
    rules.push(item);
  }
  routing['rules'] = rules;
  // Only enable IPIfNonMatch when an IP/geoip rule genuinely needs domain->IP
  // resolution; otherwise keep AsIs so proxy-bound domains never stall on a
  // redundant local DNS lookup before dialing the node.
  routing['domainStrategy'] = needIpResolution ? 'IPIfNonMatch' : 'AsIs';
  root['routing'] = routing;
}

function ruleSetTag(target: string, proxy: string): string {
  if (target === TARGET_BLOCK) {
    return 'block';
  }
  if (target === TARGET_PROXY) {
    return proxy;
  }
  return 'direct';
}

// User-supplied custom rule set: ordered lists applied directly after Private CIDRs.
function applyRuleSet(root: Record<string, Object>, options: SplitOptions,
  proxy: string, tunTags: string[], dnsLeak: boolean, webrtcLeak: boolean): string {
  const rules: Object[] = [];
  let hasIpRule: boolean = false;
  if (dnsLeak) {
    pushDnsLeakRules(rules, tunTags, proxy);
  }
  if (options.blockQuic) {
    rules.push(quicBlockRule());
  }
  if (options.doh || dnsLeak) {
    rules.push(dohRouteRule(proxy));
  }
  rules.push(makeRule('direct', [], PRIVATE_CIDRS, 'Private'));
  if (webrtcLeak) {
    pushWebrtcLeakRules(rules, tunTags);
  }
  if (options.ruleSet !== null) {
    for (const list of options.ruleSet.lists) {
      if (list.domains.length === 0 && list.ip.length === 0) {
        continue;
      }
      if (list.ip.length > 0) {
        hasIpRule = true;
      }
      rules.push(makeRule(ruleSetTag(list.target, proxy), list.domains, list.ip, list.name));
    }
  }
  mergeRules(root, rules, hasIpRule);
  return JSON.stringify(root);
}

export function applyBuiltInRules(configJson: string, options: SplitOptions): string {
  if (options.split && options.mode === MODE_DIRECT) {
    // Per-SSID "direct" rule: keep the tunnel up but send everything direct.
    try {
      const directRoot: Record<string, Object> = JSON.parse(configJson) as Record<string, Object>;
      const directOutbounds: Object[] = asArray(directRoot['outbounds'] as Object | undefined);
      if (directOutbounds.length === 0) {
        return configJson;
      }
      addOutbound(directOutbounds, 'direct', 'freedom');
      const ordered: Object[] = [];
      let direct: Object | undefined = undefined;
      for (const candidate of directOutbounds) {
        const outbound: Record<string, Object> = candidate as Record<string, Object>;
        if (outbound['tag'] === 'direct') {
          direct = candidate;
        } else {
          ordered.push(candidate);
        }
      }
      if (direct !== undefined) {
        ordered.unshift(direct);
      }
      directRoot['outbounds'] = ordered;
      const directRules: Object[] = [];
      const directRouting: Record<string, Object> = { 'domainStrategy': 'AsIs', 'rules': directRules };
      directRoot['routing'] = directRouting;
      return JSON.stringify(directRoot);
    } catch (error) {
      return configJson;
    }
  }
  if (!options.split) {
    return configJson;
  }
  try {
    const dnsLeak: boolean = options.dnsLeakProtect !== false;
    const webrtcLeak: boolean = options.webrtcLeakProtect !== false;
    const root: Record<string, Object> = JSON.parse(configJson) as Record<string, Object>;
    // Keep normal logging at 'warning' to minimize disk I/O and heap churn;
    // only emit per-connection routing logs when diagnostics are explicitly on.
    const logConfig: Record<string, Object> = { 'loglevel': options.debugLog ? 'debug' : 'warning' };
    root['log'] = logConfig;
    const tunTags: string[] = [];
    const inbounds: Object[] = asArray(root['inbounds'] as Object | undefined);
    for (const candidate of inbounds) {
      const inbound: Record<string, Object> = candidate as Record<string, Object>;
      if (inbound['protocol'] === 'tun') {
        let tagValue: Object | undefined = inbound['tag'];
        if (typeof tagValue !== 'string' || (tagValue as string).length === 0) {
          inbound['tag'] = 'tun-in';
          tagValue = 'tun-in';
        }
        const tagText: string = tagValue as string;
        if (tunTags.indexOf(tagText) < 0) {
          tunTags.push(tagText);
        }
        const fakeDns: boolean = options.fakeDns &&
          (options.mode === MODE_BYPASS || options.mode === MODE_GFW);
        // `fakedns` is a no-op in this kernel; dns.fakeIp restores the domain
        // automatically. Keep it only as a harmless compatibility marker.
        const destOverride: Object[] = fakeDns
          ? ['fakedns', 'http', 'tls', 'quic']
          : ['http', 'tls', 'quic'];
        const sniffing: Record<string, Object> = {
          'enabled': true,
          'destOverride': destOverride
        };
        inbound['sniffing'] = sniffing;
      }
    }
    const outbounds: Object[] = asArray(root['outbounds'] as Object | undefined);
    if (outbounds.length === 0) {
      return configJson;
    }
    // Every split mode shares one outbound set, so a mode switch can be applied
    // by swapping the routing table only (xray_core_replace_routing_policy_json)
    // without restarting the tunnel. The first outbound stays the default route
    // (the node); "global" therefore needs no rules, and "gfw" reaches its
    // direct default through an explicit catch-all rule instead of reordering.
    const proxy: string = proxyTag(outbounds);
    addOutbound(outbounds, 'direct', 'freedom');
    addOutbound(outbounds, 'block', 'blackhole');
    root['outbounds'] = outbounds;
    if (options.doh) {
      applyDohDns(root, options.geodata, options.mode, dnsLeak);
    } else if (options.geodata || dnsLeak) {
      applySplitDns(root, options.geodata, options.mode, dnsLeak);
    }
    applyFakeDns(root, options);

    // "Global" wins over everything: private LAN direct, rest through the node.
    if (options.mode === MODE_GLOBAL) {
      const globalRules: Object[] = [];
      if (dnsLeak) {
        pushDnsLeakRules(globalRules, tunTags, proxy);
      }
      if (options.blockQuic) {
        globalRules.push(quicBlockRule());
      }
      if (options.doh || dnsLeak) {
        globalRules.push(dohRouteRule(proxy));
      }
      globalRules.push(makeRule('direct', [], PRIVATE_CIDRS, 'Private'));
      if (webrtcLeak) {
        pushWebrtcLeakRules(globalRules, tunTags);
      }
      mergeRules(root, globalRules, false);
      return JSON.stringify(root);
    }

    // User custom rule set replaces built-in split when enabled.
    if (options.ruleSet !== null && options.ruleSet.lists.length > 0) {
      return applyRuleSet(root, options, proxy, tunTags, dnsLeak, webrtcLeak);
    }

    const rules: Object[] = [];
    if (dnsLeak) {
      pushDnsLeakRules(rules, tunTags, proxy);
    }
    if (options.blockQuic) {
      rules.push(quicBlockRule());
    }
    if (options.doh || dnsLeak) {
      // The foreign DoH resolver must leave through the node, including in gfw
      // mode where the default route is direct.
      rules.push(dohRouteRule(proxy));
    }
    rules.push(makeRule('direct', [], PRIVATE_CIDRS, 'Private'));
    if (webrtcLeak) {
      pushWebrtcLeakRules(rules, tunTags);
    }
    if (options.mode === MODE_GFW) {
      rules.push(makeRule(proxy, GFW_SUFFIXES, [], 'GFW'));
      rules.push(catchAllRule('direct'));
      mergeRules(root, rules, false);
      return JSON.stringify(root);
    }
    // bypass (default):
    //   1. DNS leak / QUIC / DoH / Private LAN / WebRTC leak guards
    //   2. High-frequency blocked domains fast-path straight to proxy BEFORE
    //      geosite:cn/geoip:cn so launching overseas apps skips redundant DNS
    //      resolution (cuts 150-400 ms on first connect)
    //   3. China domains + China IPs direct (when geodata is installed)
    //   4. Everything else through proxy
    rules.push(makeRule(proxy, GFW_SUFFIXES, [], 'ProxyFast'));
    if (options.geodata) {
      rules.push(makeRule('direct', ['geosite:cn', 'localhost'], [], 'China'));
      rules.push(makeRule('direct', [], ['geoip:cn'], 'ChinaIP'));
      mergeRules(root, rules, true);
    } else {
      rules.push(makeRule('direct', LOCAL_DOMAINS, [], 'China'));
      mergeRules(root, rules, false);
    }
    return JSON.stringify(root);
  } catch (error) {
    return configJson;
  }
}


