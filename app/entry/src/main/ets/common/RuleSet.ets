import { fileIo as fs } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { ensureXrayDir, xrayDir } from './Xray';

// A routing rule set converted from ACL4SSR's Clash lists (see
// tools/acl4ssr2way.py, which mirrors the list order and target mapping of the
// subscription-forge project). way stores it as filesDir/xray/rules.json and
// turns each list into one Xray routing rule, in order: the first match wins,
// exactly like the Clash/sing-box config it was converted from.

export const TARGET_DIRECT: string = 'direct';
export const TARGET_BLOCK: string = 'block';
export const TARGET_PROXY: string = 'proxy';

export interface RuleList {
  name: string;
  target: string;
  // Entries already use the Xray matcher syntax: domain:/full:/keyword:/regexp:
  domains: string[];
  // CIDRs, plus the occasional geoip:cn
  ip: string[];
}

export interface RuleSetTotals {
  rules: number;
  domains: number;
  ip: number;
}

export interface WayRuleSet {
  version: number;
  name: string;
  generatedAt: string;
  source: string;
  // Where this copy came from: bundled | update | backup | custom
  origin: string;
  lists: RuleList[];
  totals: RuleSetTotals;
}

export const ORIGIN_BUNDLED: string = 'bundled';
export const ORIGIN_UPDATE: string = 'update';
export const ORIGIN_BACKUP: string = 'backup';
export const ORIGIN_CUSTOM: string = 'custom';

const RULE_FILE: string = 'rules.json';
// One rolling slot: whatever was active before the last switch, so 备份 can undo
// an online update, a bundled restore or a custom import.
const BACKUP_FILE: string = 'rules-backup.json';
// Converted from ACL4SSR by tools/acl4ssr2way.py and shipped inside the HAP so
// the rule set is usable on first launch, before any download can succeed
// (raw.githubusercontent.com is usually unreachable until the tunnel is up).
const BUNDLED_FILE: string = 'acl4ssr-way-rules.json';
const MAX_LISTS: number = 64;
const MAX_ENTRIES: number = 200000;

export function ruleSetPath(context: common.Context): string {
  ensureXrayDir(context);
  return xrayDir(context) + '/' + RULE_FILE;
}

function textOf(value: Object | undefined): string {
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

function stringArray(value: Object | undefined): string[] {
  const out: string[] = [];
  if (value === undefined || value === null) {
    return out;
  }
  // A hand-edited file may put a string where an array belongs; iterating it
  // would turn every character into a rule.
  if (!Array.isArray(value)) {
    return out;
  }
  const items: Object[] = value as Object[];
  for (const item of items) {
    if (typeof item !== 'string') {
      continue;
    }
    const text: string = (item as string).trim();
    if (text.length > 0) {
      out.push(text);
    }
  }
  return out;
}

// Validates and normalizes a rule set document. Untrusted input only reaches the
// routing config through this function, so a malformed file is refused instead
// of breaking the tunnel.
export function parseRuleSet(text: string): WayRuleSet | null {
  let root: Record<string, Object>;
  try {
    root = JSON.parse(text) as Record<string, Object>;
  } catch (error) {
    return null;
  }
  const rawLists: Object | undefined = root['lists'] as Object | undefined;
  if (rawLists === undefined || rawLists === null) {
    return null;
  }
  const lists: RuleList[] = [];
  for (const item of rawLists as Object[]) {
    const entry: Record<string, Object> = item as Record<string, Object>;
    const name: string = textOf(entry['name']);
    const targetText: string = textOf(entry['target']).toLowerCase();
    let target: string = TARGET_DIRECT;
    if (targetText === TARGET_BLOCK || targetText === TARGET_PROXY) {
      target = targetText;
    }
    const domains: string[] = stringArray(entry['domains'] as Object | undefined);
    const ip: string[] = stringArray(entry['ip'] as Object | undefined);
    if (domains.length === 0 && ip.length === 0) {
      continue;
    }
    const list: RuleList = {
      name: name.length > 0 ? name : ('list-' + (lists.length + 1)),
      target: target,
      domains: domains,
      ip: ip
    };
    lists.push(list);
    if (lists.length >= MAX_LISTS) {
      break;
    }
  }
  if (lists.length === 0) {
    return null;
  }
  let domains: number = 0;
  let ip: number = 0;
  for (const list of lists) {
    domains += list.domains.length;
    ip += list.ip.length;
  }
  if (domains + ip > MAX_ENTRIES) {
    return null;
  }
  const totals: RuleSetTotals = { rules: domains + ip, domains: domains, ip: ip };
  const ruleSet: WayRuleSet = {
    version: 1,
    name: textOf(root['name']).length > 0 ? textOf(root['name']) : 'rules',
    generatedAt: textOf(root['generatedAt']),
    source: textOf(root['source']),
    origin: textOf(root['origin']),
    lists: lists,
    totals: totals
  };
  return ruleSet;
}

export function serializeRuleSet(ruleSet: WayRuleSet): string {
  const lists: Object[] = [];
  for (const list of ruleSet.lists) {
    const entry: Record<string, Object> = {
      'name': list.name,
      'target': list.target,
      'domains': list.domains,
      'ip': list.ip
    };
    lists.push(entry);
  }
  const stats: RuleSetTotals = {
    rules: ruleSet.totals.rules,
    domains: ruleSet.totals.domains,
    ip: ruleSet.totals.ip
  };
  const root: Record<string, Object> = {};
  root['version'] = 1;
  root['name'] = ruleSet.name;
  root['generatedAt'] = ruleSet.generatedAt;
  root['source'] = ruleSet.source;
  root['origin'] = ruleSet.origin;
  root['lists'] = lists;
  root['stats'] = stats;
  return JSON.stringify(root);
}

export function readRuleSet(context: common.Context): WayRuleSet | null {
  const path: string = ruleSetPath(context);
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    return parseRuleSet(fs.readTextSync(path));
  } catch (error) {
    return null;
  }
}

// Stores the normalized document (the UI and the tunnel only ever use the
// parsed form, so what is written here is exactly what will be applied).
export function writeRuleSet(context: common.Context, ruleSet: WayRuleSet): void {
  const file = fs.openSync(ruleSetPath(context), fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, serializeRuleSet(ruleSet));
  fs.closeSync(file);
}

export function clearRuleSet(context: common.Context): void {
  const path: string = ruleSetPath(context);
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (error) {
  }
}

// Built-in ACL4SSR and ad-block rule sets were removed so the app ships with
// minimal base rules only. If an upgrade left an older bundled ACL4SSR file on
// disk, purge it while preserving any user-imported custom rule set.
export function seedRuleSet(context: common.Context, _force: boolean = false): boolean {
  const existing: WayRuleSet | null = readRuleSet(context);
  if (existing !== null && (existing.origin === ORIGIN_BUNDLED || existing.origin === ORIGIN_UPDATE)) {
    clearRuleSet(context);
    return true;
  }
  return false;
}

export function ruleSetCount(ruleSet: WayRuleSet, target: string): number {
  let count: number = 0;
  for (const list of ruleSet.lists) {
    if (list.target === target) {
      count += list.domains.length + list.ip.length;
    }
  }
  return count;
}

export function ruleSetLine(ruleSet: WayRuleSet): string {
  return ruleSet.name + ' · ' + ruleSet.lists.length + ' 组 · 域名 ' + ruleSet.totals.domains +
    ' · IP ' + ruleSet.totals.ip;
}

// Short label for where the active copy came from.
export function originLabel(origin: string): string {
  if (origin === ORIGIN_BUNDLED) {
    return '内置';
  }
  if (origin === ORIGIN_UPDATE) {
    return '在线更新';
  }
  if (origin === ORIGIN_BACKUP) {
    return '备份回滚';
  }
  if (origin === ORIGIN_CUSTOM) {
    return '自定义';
  }
  // Files pushed over hdc or seeded by an older build carry no origin.
  return '本地文件';
}

export function backupPath(context: common.Context): string {
  ensureXrayDir(context);
  return xrayDir(context) + '/' + BACKUP_FILE;
}

export function readBackup(context: common.Context): WayRuleSet | null {
  const path: string = backupPath(context);
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    return parseRuleSet(fs.readTextSync(path));
  } catch (error) {
    return null;
  }
}

export function hasBackup(context: common.Context): boolean {
  return readBackup(context) !== null;
}

// Rolling one-slot backup: called before every switch so 备份 can undo it.
export function backupCurrent(context: common.Context): boolean {
  const current: WayRuleSet | null = readRuleSet(context);
  if (current === null) {
    return false;
  }
  try {
    const file = fs.openSync(backupPath(context), fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, serializeRuleSet(current));
    fs.closeSync(file);
    return true;
  } catch (error) {
    return false;
  }
}

// Swaps the active set with the backup slot, so pressing 备份 twice returns to
// where you started instead of stranding you on the restored copy.
export function swapWithBackup(context: common.Context): WayRuleSet | null {
  const backup: WayRuleSet | null = readBackup(context);
  if (backup === null) {
    return null;
  }
  const current: WayRuleSet | null = readRuleSet(context);
  if (current !== null) {
    backupCurrent(context);
  }
  backup.origin = ORIGIN_BACKUP;
  writeRuleSet(context, backup);
  return backup;
}

// Replaces the active set with the copy bundled in the HAP, keeping the previous
// one in the backup slot.
export function restoreBundled(context: common.Context): WayRuleSet | null {
  backupCurrent(context);
  if (!seedRuleSet(context, true)) {
    return null;
  }
  return readRuleSet(context);
}

// Imports a user-supplied rule set (same JSON format, pasted in pages/AddRules).
export function importCustomRuleSet(context: common.Context, text: string): WayRuleSet | null {
  const parsed: WayRuleSet | null = parseRuleSet(text);
  if (parsed === null) {
    return null;
  }
  backupCurrent(context);
  parsed.origin = ORIGIN_CUSTOM;
  if (parsed.name.length === 0 || parsed.name === 'rules') {
    parsed.name = '自定义规则';
  }
  writeRuleSet(context, parsed);
  return parsed;
}

// The UI keeps its own state; the restart paths (watchdog, per-Wi-Fi mode
// switch, connect) all read the persisted toggle through these helpers.
export function ruleSetEnabled(context: common.Context): boolean {
  try {
    // Same store the home page persists its flags in (PREF_NAME in Index.ets).
    const store = preferences.getPreferencesSync(context, { name: 'xray_prefs' });
    return store.getSync('useRuleSet', false) as boolean;
  } catch (error) {
    return false;
  }
}

// 广告拦截开关（主页「拦截广告」），持久化在同一个 prefs 里。
export function ruleSetAdsEnabled(context: common.Context): boolean {
  try {
    const store = preferences.getPreferencesSync(context, { name: 'xray_prefs' });
    return store.getSync('blockAds', true) as boolean;
  } catch (error) {
    return true;
  }
}

// DoH DNS 开关（主页「DoH DNS」），与其它 UI 开关同一个 prefs。
export function dohEnabled(context: common.Context): boolean {
  try {
    const store = preferences.getPreferencesSync(context, { name: 'xray_prefs' });
    return store.getSync('dohDns', true) as boolean;
  } catch (error) {
    return true;
  }
}

// 防 DNS 泄露开关（主页「防 DNS 泄露」），默认开启，持久化在同一个 prefs 里。
export function dnsLeakProtectEnabled(context: common.Context): boolean {
  try {
    const store = preferences.getPreferencesSync(context, { name: 'xray_prefs' });
    return store.getSync('dnsLeakProtect', true) as boolean;
  } catch (error) {
    return true;
  }
}

// 防 WebRTC 泄露开关（主页「防 WebRTC 泄露」），默认开启，持久化在同一个 prefs 里。
export function webrtcLeakProtectEnabled(context: common.Context): boolean {
  try {
    const store = preferences.getPreferencesSync(context, { name: 'xray_prefs' });
    return store.getSync('webrtcLeakProtect', true) as boolean;
  } catch (error) {
    return true;
  }
}

export function activeRuleSet(context: common.Context): WayRuleSet | null {
  if (!ruleSetEnabled(context)) {
    return null;
  }
  return readRuleSet(context);
}
