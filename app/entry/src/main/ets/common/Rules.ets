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
const DOH_FOREIGN_IPS: string[] = ['1.1.1.1/32', '1.0.0.1/32'];

function applyDohDns(root: Record<string, Object>, geodata: boolean): void {
  const rawDns: Object | undefined = root['dns'] as Object | undefined;
  const dns: Record<string, Object> =
    (rawDns === undefined || rawDns === null) ? {} : rawDns as Record<string, Object>;
  const servers: Object[] = [];
  const domestic: Record<string, Object> = { 'address': DOH_DOMESTIC };
  const foreign: Record<string, Object> = { 'address': DOH_FOREIGN };
  if (geodata) {
    // CN first with a geosite matcher, foreign as the default for the rest.
    domestic['domains'] = ['geosite:cn'];
    domestic['skipFallback'] = true;
    servers.push(domestic);
    servers.push(foreign);
  } else {
    // Without geodata the first server without matchers is the default one,
    // so put the foreign resolver first and keep the domestic one behind it.
    servers.push(foreign);
    servers.push(domestic);
  }
  dns['servers'] = servers;
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

// Splits DNS like v2rayNG: CN domains are resolved by a domestic resolver so
// they map to domestic CDN addresses and stay on the direct route; everything
// else keeps the profile's own servers (usually overseas).
function applySplitDns(root: Record<string, Object>): void {
  const existing: Object | undefined = root['dns'];
  if (existing === undefined || existing === null) {
    return;
  }
  const dns: Record<string, Object> = existing as Record<string, Object>;
  const servers: Object[] = asArray(dns['servers'] as Object | undefined);
  if (servers.length === 0) {
    return;
  }
  const domestic: Record<string, Object> = {
    'address': '223.5.5.5',
    'domains': ['geosite:cn'],
    'skipFallback': true
  };
  const merged: Object[] = [domestic];
  for (const item of servers) {
    merged.push(item);
  }
  dns['servers'] = merged;
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

function mergeRules(root: Record<string, Object>, rules: Object[]): void {
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
  // Importers write "AsIs"; split routing needs the IP pass so domains that
  // resolve to CN addresses go direct. Explicit IP policies stay untouched.
  const strategy: Object | undefined = routing['domainStrategy'];
  if (strategy === undefined || strategy === 'AsIs') {
    routing['domainStrategy'] = 'IPIfNonMatch';
  }
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

// ACL4SSR policy: the lists' own order is the precedence, the default route is
// still the node (outbounds[0]). Outbounds and DNS were already prepared by the
// caller, so a mode switch can hot-swap this routing table.
function applyRuleSet(root: Record<string, Object>, options: SplitOptions,
  proxy: string): string {
  const rules: Object[] = [];
  if (options.blockQuic) {
    rules.push(quicBlockRule());
  }
  if (options.doh) {
    rules.push(dohRouteRule(proxy));
  }
  rules.push(makeRule('direct', [], PRIVATE_CIDRS, 'Private'));
  if (options.ruleSet !== null) {
    for (const list of options.ruleSet.lists) {
      if (list.domains.length === 0 && list.ip.length === 0) {
        continue;
      }
      if (list.target === TARGET_BLOCK && !options.blockAds) {
        continue;
      }
      rules.push(makeRule(ruleSetTag(list.target, proxy), list.domains, list.ip, list.name));
    }
  }
  mergeRules(root, rules);
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
    const root: Record<string, Object> = JSON.parse(configJson) as Record<string, Object>;
    // Debug routing decisions (sniffed domain + chosen outbound) so the app can
    // mirror them; harmless at runtime and switched off outside diagnostics.
    const logConfig: Record<string, Object> = { 'loglevel': 'debug' };
    root['log'] = logConfig;
    const inbounds: Object[] = asArray(root['inbounds'] as Object | undefined);
    for (const candidate of inbounds) {
      const inbound: Record<string, Object> = candidate as Record<string, Object>;
      if (inbound['protocol'] === 'tun') {
        const destOverride: Object[] = ['http', 'tls', 'quic'];
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
      applyDohDns(root, options.geodata);
    } else if (options.geodata) {
      applySplitDns(root);
    }

    // "Global" wins over everything: no split rules at all, everything through
    // the node. This must stay before the rule-set branch.
    if (options.mode === MODE_GLOBAL) {
      const globalRules: Object[] = [];
      mergeRules(root, globalRules);
      return JSON.stringify(root);
    }

    // An enabled rule set is the whole split policy: it already says what is
    // direct, blocked and proxied, in its own order, so the GFW/bypass lists
    // below do not run.
    if (options.ruleSet !== null && options.ruleSet.lists.length > 0) {
      return applyRuleSet(root, options, proxy);
    }

    const rules: Object[] = [];
    if (options.blockQuic) {
      rules.push(quicBlockRule());
    }
    if (options.doh) {
      // The foreign DoH resolver must leave through the node, including in gfw
      // mode where the default route is direct.
      rules.push(dohRouteRule(proxy));
    }
    if (options.mode === MODE_GFW) {
      rules.push(makeRule(proxy, GFW_SUFFIXES, [], 'GFW'));
      rules.push(makeRule('direct', [], PRIVATE_CIDRS, 'Private'));
      rules.push(catchAllRule('direct'));
      mergeRules(root, rules);
      return JSON.stringify(root);
    }
    // bypass (default): LAN and China direct, everything else through the node.
    rules.push(makeRule('direct', [], PRIVATE_CIDRS, 'Private'));
    if (options.geodata) {
      rules.push(makeRule('direct', ['geosite:cn', 'localhost'], [], 'China'));
      rules.push(makeRule('direct', [], ['geoip:cn'], 'ChinaIP'));
    } else {
      rules.push(makeRule('direct', LOCAL_DOMAINS, [], 'China'));
    }
    mergeRules(root, rules);
    return JSON.stringify(root);
  } catch (error) {
    return configJson;
  }
}
