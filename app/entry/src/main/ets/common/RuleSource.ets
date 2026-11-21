import { http } from '@kit.NetworkKit';
import { ORIGIN_UPDATE, RuleList, TARGET_BLOCK, TARGET_DIRECT, TARGET_PROXY, WayRuleSet } from './RuleSet';

// Downloads the ACL4SSR Clash lists and converts them into a way rule set,
// mirroring tools/acl4ssr2way.py (and the subscription-forge project it was
// modelled on): same fourteen lists, same target mapping, same order.

interface RuleSource {
  name: string;
  target: string;
  // GitHub raw first, jsDelivr mirror second (same fallback the geodata
  // downloader uses, since raw.githubusercontent.com is often blocked here).
  urls: string[];
}

const USER_AGENT: string = 'way-rules/1.0 (ACL4SSR to xray)';
const ACL4SSR: string = 'https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash';
const ACL4SSR_CDN: string = 'https://cdn.jsdelivr.net/gh/ACL4SSR/ACL4SSR@master/Clash';
const TENCENT: string = 'https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Tencent/Tencent.list';
const TENCENT_CDN: string = 'https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Tencent/Tencent.list';

// Order matters: way emits one routing rule per list in this sequence, so the
// first match wins exactly as in the source configuration.
const SOURCES: RuleSource[] = [
  { name: 'Tencent', target: TARGET_DIRECT, urls: [TENCENT, TENCENT_CDN] },
  { name: 'LocalAreaNetwork', target: TARGET_DIRECT, urls: [ACL4SSR + '/LocalAreaNetwork.list', ACL4SSR_CDN + '/LocalAreaNetwork.list'] },
  { name: 'UnBan', target: TARGET_DIRECT, urls: [ACL4SSR + '/UnBan.list', ACL4SSR_CDN + '/UnBan.list'] },
  { name: 'BanAD', target: TARGET_BLOCK, urls: [ACL4SSR + '/BanAD.list', ACL4SSR_CDN + '/BanAD.list'] },
  { name: 'BanProgramAD', target: TARGET_BLOCK, urls: [ACL4SSR + '/BanProgramAD.list', ACL4SSR_CDN + '/BanProgramAD.list'] },
  { name: 'ChinaDomain', target: TARGET_DIRECT, urls: [ACL4SSR + '/ChinaDomain.list', ACL4SSR_CDN + '/ChinaDomain.list'] },
  { name: 'GoogleCN', target: TARGET_DIRECT, urls: [ACL4SSR + '/GoogleCN.list', ACL4SSR_CDN + '/GoogleCN.list'] },
  { name: 'Telegram', target: TARGET_PROXY, urls: [ACL4SSR + '/Telegram.list', ACL4SSR_CDN + '/Telegram.list'] },
  { name: 'Netflix', target: TARGET_PROXY, urls: [ACL4SSR + '/Netflix.list', ACL4SSR_CDN + '/Netflix.list'] },
  { name: 'Microsoft', target: TARGET_DIRECT, urls: [ACL4SSR + '/Microsoft.list', ACL4SSR_CDN + '/Microsoft.list'] },
  { name: 'Apple', target: TARGET_DIRECT, urls: [ACL4SSR + '/Apple.list', ACL4SSR_CDN + '/Apple.list'] },
  { name: 'ChinaCompanyIp', target: TARGET_DIRECT, urls: [ACL4SSR + '/ChinaCompanyIp.list', ACL4SSR_CDN + '/ChinaCompanyIp.list'] },
  { name: 'ChinaIp', target: TARGET_DIRECT, urls: [ACL4SSR + '/ChinaIp.list', ACL4SSR_CDN + '/ChinaIp.list'] },
  { name: 'ProxyLite', target: TARGET_PROXY, urls: [ACL4SSR + '/ProxyLite.list', ACL4SSR_CDN + '/ProxyLite.list'] }
];

export interface RuleBuildProgress {
  done: number;
  total: number;
  current: string;
}

async function fetchText(url: string): Promise<string> {
  const request = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': USER_AGENT, 'Accept': '*/*' },
      connectTimeout: 15000,
      readTimeout: 30000,
      expectDataType: http.HttpDataType.STRING
    };
    const response: http.HttpResponse = await request.request(url, options);
    if (response.responseCode !== 200) {
      throw new Error('HTTP ' + response.responseCode);
    }
    const body: string = response.result as string;
    if (body.length === 0) {
      throw new Error('empty body');
    }
    return body;
  } finally {
    request.destroy();
  }
}

// Clash classical rules -> Xray domain matcher entries / IP CIDRs.
function convertList(text: string): RuleList {
  const domains: Set<string> = new Set();
  const ips: Set<string> = new Set();
  for (const raw of text.split('\n')) {
    const line: string = raw.trim();
    if (line.length === 0 || line.startsWith('#') || line.startsWith(';') || line.startsWith('//')) {
      continue;
    }
    const parts: string[] = line.split(',');
    if (parts.length < 2) {
      continue;
    }
    const kind: string = parts[0].trim().toUpperCase();
    let value: string = parts[1].trim();
    if (value.length === 0) {
      continue;
    }
    if (kind === 'DOMAIN-SUFFIX' || kind === 'DOMAIN') {
      value = value.toLowerCase();
      while (value.endsWith('.')) {
        value = value.substring(0, value.length - 1);
      }
    }
    if (kind === 'DOMAIN-SUFFIX') {
      domains.add('domain:' + value);
    } else if (kind === 'DOMAIN') {
      domains.add('full:' + value);
    } else if (kind === 'DOMAIN-KEYWORD') {
      domains.add('keyword:' + value);
    } else if (kind === 'IP-CIDR' || kind === 'IP-CIDR6' || kind === 'IP6-CIDR') {
      ips.add(value);
    } else if (kind === 'GEOIP') {
      ips.add('geoip:' + value.toLowerCase());
    }
    // PROCESS-NAME / URL-REGEX / RULE-SET and friends have no Xray equivalent.
  }
  const domainList: string[] = [];
  for (const item of domains) {
    domainList.push(item);
  }
  domainList.sort();
  const ipList: string[] = [];
  for (const item of ips) {
    ipList.push(item);
  }
  ipList.sort();
  const list: RuleList = { name: '', target: '', domains: domainList, ip: ipList };
  return list;
}

export async function buildRuleSet(onProgress: (progress: RuleBuildProgress) => void): Promise<WayRuleSet> {
  const lists: RuleList[] = [];
  let done: number = 0;
  for (const source of SOURCES) {
    const start: RuleBuildProgress = { done: done, total: SOURCES.length, current: source.name };
    onProgress(start);
    let text: string = '';
    let lastError: string = '';
    for (const url of source.urls) {
      try {
        text = await fetchText(url);
        lastError = '';
        break;
      } catch (error) {
        const failure = error as Error;
        lastError = failure.message === undefined ? 'network error' : failure.message;
      }
    }
    if (text.length === 0) {
      throw new Error(source.name + ': ' + (lastError.length > 0 ? lastError : 'download failed'));
    }
    const converted: RuleList = convertList(text);
    if (converted.domains.length === 0 && converted.ip.length === 0) {
      throw new Error(source.name + ': 没有可识别的规则');
    }
    const list: RuleList = {
      name: source.name,
      target: source.target,
      domains: converted.domains,
      ip: converted.ip
    };
    lists.push(list);
    done++;
    const step: RuleBuildProgress = { done: done, total: SOURCES.length, current: source.name };
    onProgress(step);
  }
  let domains: number = 0;
  let ip: number = 0;
  for (const list of lists) {
    domains += list.domains.length;
    ip += list.ip.length;
  }
  const ruleSet: WayRuleSet = {
    version: 1,
    name: 'ACL4SSR',
    generatedAt: new Date().toISOString(),
    source: 'ACL4SSR/ACL4SSR@master + blackmatrix7/ios_rule_script (Tencent)',
    origin: ORIGIN_UPDATE,
    lists: lists,
    totals: { rules: domains + ip, domains: domains, ip: ip }
  };
  return ruleSet;
}
