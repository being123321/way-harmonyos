import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import {
  NodeEndpoint, detectFormat, importShareLink, isHelperOutbound, outboundEndpoint, outboundProtocol,
  outboundTag
} from './Xray';
import { ConfigEntry, newId } from './Store';

// Import pipeline modelled on v2rayNG:
//   * one or many share links, one per line
//   * links that were copied with hard line breaks are re-joined
//   * a base64 payload (whole paste, or a single line) that expands to links
//   * a subscription URL whose body is base64, plain links or a JSON config
//   * a full Xray JSON config: every proxy outbound becomes its own node
// Remarks keep the link fragment (#name) because the Rust importer decodes it.

export interface ImportResult {
  entries: ConfigEntry[];
  failed: number;
  total: number;
  errors: string[];
}

const MAX_NODES: number = 500;
const USER_AGENT: string = 'v2rayNG/2.0 (way-harmony)';
// The Rust hysteria importer accepts exactly the parameters it models and fails
// the whole link on any other key, so a single vendor hint cost us the node: the
// reference subscription carried `upmbps`/`downmbps` and v2rayN's
// `allowInsecure` alias, and 4 of its 8 nodes never showed up (v2rayNG shows
// them because it ignores unknown keys). Same fix here: keep the modelled
// parameters and drop the rest, after reporting what was dropped.
const HYSTERIA_PARAMS: string[] = [
  'sni', 'insecure', 'pinsha256', 'fm', 'obfs', 'obfs-password', 'mport'
];

function normalizeBase64(text: string): string {
  let value: string = text.trim().replace(/-/g, '+').replace(/_/g, '/');
  const remainder: number = value.length % 4;
  if (remainder === 2) {
    value += '==';
  } else if (remainder === 3) {
    value += '=';
  }
  return value;
}

export function looksLikeBase64(text: string): boolean {
  const value: string = text.trim();
  if (value.length < 16 || value.length > 1024 * 1024) {
    return false;
  }
  if (value.includes('://') || value.includes('#') || value.includes('\n')) {
    return false;
  }
  return /^[A-Za-z0-9+/=_-]+$/.test(value);
}

export function decodeBase64Text(text: string): string | null {
  try {
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(normalizeBase64(text));
    if (bytes.length === 0) {
      return null;
    }
    const decoded: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
    return decoded.length > 0 ? decoded : null;
  } catch (error) {
    return null;
  }
}

function isHysteria(link: string): boolean {
  const lower: string = link.trim().toLowerCase();
  return lower.startsWith('hysteria2://') || lower.startsWith('hy2://');
}

export interface SanitizedLink {
  text: string;
  dropped: string[];
}

// Drops the query keys the core cannot model (TLS is implied for hysteria2, h3
// is the only ALPN it supports, bandwidth hints are client-side, and
// `allowInsecure` is v2rayN's alias for `insecure`) plus any duplicate key, so
// the importer sees only parameters it understands.
export function sanitizeLink(link: string): SanitizedLink {
  const unchanged: SanitizedLink = { text: link, dropped: [] };
  if (!isHysteria(link)) {
    return unchanged;
  }
  const hashIndex: number = link.indexOf('#');
  const head: string = hashIndex >= 0 ? link.substring(0, hashIndex) : link;
  const fragment: string = hashIndex >= 0 ? link.substring(hashIndex) : '';
  const queryIndex: number = head.indexOf('?');
  if (queryIndex < 0) {
    return unchanged;
  }
  const base: string = head.substring(0, queryIndex);
  const params: string[] = head.substring(queryIndex + 1).split('&');
  const kept: string[] = [];
  const dropped: string[] = [];
  const seen: Set<string> = new Set();
  for (const param of params) {
    if (param.length === 0) {
      continue;
    }
    const eq: number = param.indexOf('=');
    const key: string = (eq >= 0 ? param.substring(0, eq) : param).trim();
    const lower: string = key.toLowerCase();
    let known: boolean = false;
    for (const name of HYSTERIA_PARAMS) {
      if (lower === name) {
        known = true;
        break;
      }
    }
    if (!known || seen.has(lower)) {
      dropped.push(key);
      continue;
    }
    seen.add(lower);
    kept.push(param);
  }
  const query: string = kept.length > 0 ? '?' + kept.join('&') : '';
  const result: SanitizedLink = { text: base + query + fragment, dropped: dropped };
  return result;
}

// Splits a pasted blob into logical links. A line without a scheme that
// follows a link is treated as a wrapped continuation of it, which is what
// happens when a node is copied out of a chat message.
function logicalLines(text: string): string[] {
  const out: string[] = [];
  const lines: string[] = text.split(/\r?\n/);
  for (const raw of lines) {
    const line: string = raw.trim();
    if (line.length === 0) {
      continue;
    }
    if (detectFormat(line).length > 0) {
      out.push(line);
      continue;
    }
    if (out.length > 0 && line.length <= 2048 && /^[@?&=#/A-Za-z0-9._~:%+%-]+$/.test(line)) {
      const last: string = out[out.length - 1];
      if (last.length + line.length <= 8192) {
        out[out.length - 1] = last + line;
        continue;
      }
    }
    out.push(line);
  }
  return out;
}

function collect(text: string, depth: number, out: string[]): void {
  if (depth > 3 || out.length > MAX_NODES) {
    return;
  }
  const trimmed: string = text.trim();
  if (trimmed.length === 0) {
    return;
  }
  if (!trimmed.includes('\n') && looksLikeBase64(trimmed)) {
    const decoded: string | null = decodeBase64Text(trimmed);
    if (decoded !== null) {
      collect(decoded, depth + 1, out);
      return;
    }
    out.push(trimmed);
    return;
  }
  for (const line of logicalLines(trimmed)) {
    if (out.length > MAX_NODES) {
      return;
    }
    if (line.startsWith('//')) {
      continue;
    }
    if (detectFormat(line).length > 0) {
      out.push(line);
      continue;
    }
    if (looksLikeBase64(line)) {
      const decoded: string | null = decodeBase64Text(line);
      if (decoded !== null) {
        collect(decoded, depth + 1, out);
        continue;
      }
    }
    out.push(line);
  }
}

export function expandPayload(text: string): string[] {
  const out: string[] = [];
  collect(text, 0, out);
  return out;
}

function fallbackName(line: string, index: number): string {
  const type: string = detectFormat(line);
  const label: string = type.length > 0 ? type.toUpperCase() : 'NODE';
  return label + ' ' + (index + 1);
}

function outboundList(root: Record<string, Object>): Object[] {
  const value: Object | undefined = root['outbounds'] as Object | undefined;
  if (value === undefined || value === null) {
    return [];
  }
  return value as Object[];
}

// Drops routing rules that point at outbounds the split config no longer has
// (other proxies and balancers), so the extracted node still loads cleanly.
function filterRouting(root: Record<string, Object>, tags: Set<string>): void {
  const raw: Object | undefined = root['routing'] as Object | undefined;
  if (raw === undefined || raw === null) {
    return;
  }
  const routing: Record<string, Object> = raw as Record<string, Object>;
  const rawRules: Object | undefined = routing['rules'] as Object | undefined;
  const rules: Object[] = (rawRules === undefined || rawRules === null) ? [] : rawRules as Object[];
  const kept: Object[] = [];
  for (const item of rules) {
    const rule: Record<string, Object> = item as Record<string, Object>;
    const tag: Object | undefined = rule['outboundTag'];
    const balancer: Object | undefined = rule['balancerTag'];
    if (typeof tag === 'string') {
      if (!tags.has(tag as string)) {
        continue;
      }
    } else if (typeof balancer === 'string') {
      continue;
    }
    kept.push(rule);
  }
  routing['rules'] = kept;
  if (routing['balancers'] !== undefined) {
    routing['balancers'] = [] as Object[];
  }
  root['routing'] = routing;
}

// A config with the chosen outbound as the default route, plus the server-less
// outbounds (direct/block/dns) that its routing rules may still reference.
function singleNodeConfig(text: string, nodeIndex: number): string {
  let root: Record<string, Object>;
  try {
    root = JSON.parse(text) as Record<string, Object>;
  } catch (error) {
    return text;
  }
  const list: Object[] = outboundList(root);
  if (nodeIndex < 0 || nodeIndex >= list.length) {
    return text;
  }
  const node: Record<string, Object> = list[nodeIndex] as Record<string, Object>;
  const nodeTag: string = outboundTag(node);
  const tags: Set<string> = new Set();
  if (nodeTag.length > 0) {
    tags.add(nodeTag);
  }
  const kept: Object[] = [node];
  for (let i = 0; i < list.length; i++) {
    if (i === nodeIndex) {
      continue;
    }
    const other: Record<string, Object> = list[i] as Record<string, Object>;
    if (!isHelperOutbound(other)) {
      continue;
    }
    const tag: string = outboundTag(other);
    if (tag.length > 0 && tags.has(tag)) {
      continue;
    }
    kept.push(other);
    if (tag.length > 0) {
      tags.add(tag);
    }
  }
  const next: Record<string, Object> = {};
  for (const key of Object.keys(root)) {
    next[key] = root[key];
  }
  next['outbounds'] = kept;
  filterRouting(next, tags);
  return JSON.stringify(next);
}

function jsonNodeEntry(configText: string, outbounds: Object[], index: number,
  label: string): ConfigEntry {
  let protocol: string = 'json';
  let name: string = label;
  let server: string = '';
  if (index >= 0 && index < outbounds.length) {
    const outbound: Record<string, Object> = outbounds[index] as Record<string, Object>;
    const tag: string = outboundTag(outbound);
    const value: string = outboundProtocol(outbound);
    if (value.length > 0) {
      protocol = value;
    }
    if (tag.length > 0) {
      name = tag;
    }
    const endpoint: NodeEndpoint | null = outboundEndpoint(outbound);
    if (endpoint !== null) {
      server = endpoint.host;
    }
  }
  if (name.length === 0) {
    name = protocol.toUpperCase() + ' ' + (index + 1);
  }
  const entry: ConfigEntry = {
    id: newId(),
    name: name,
    type: protocol,
    server: server,
    json: configText,
    createdAt: Date.now()
  };
  return entry;
}

// A JSON payload (pasted config or subscription body) is split per outbound:
// every proxy outbound becomes one node whose config routes through it. This is
// what turns a panel's all-in-one JSON subscription into a usable node list.
export function splitJsonEntries(text: string): ConfigEntry[] {
  const trimmed: string = text.trim();
  let root: Record<string, Object>;
  try {
    root = JSON.parse(trimmed) as Record<string, Object>;
  } catch (error) {
    return [];
  }
  const list: Object[] = outboundList(root);
  if (list.length === 0) {
    return [];
  }
  const nodeIndexes: number[] = [];
  for (let i = 0; i < list.length; i++) {
    const outbound: Record<string, Object> = list[i] as Record<string, Object>;
    if (isHelperOutbound(outbound)) {
      continue;
    }
    if (outboundEndpoint(outbound) === null) {
      continue;
    }
    nodeIndexes.push(i);
  }
  if (nodeIndexes.length === 0) {
    // No proxy outbound to pull out (routing-only / custom config): keep whole.
    return [jsonNodeEntry(trimmed, list, 0, '自定义配置')];
  }
  if (nodeIndexes.length === 1) {
    return [jsonNodeEntry(singleNodeConfig(trimmed, nodeIndexes[0]), list, nodeIndexes[0], '')];
  }
  const entries: ConfigEntry[] = [];
  for (const index of nodeIndexes) {
    entries.push(jsonNodeEntry(singleNodeConfig(trimmed, index), list, index, ''));
  }
  return entries;
}

function importJsonDocument(text: string): ImportResult {
  const entries: ConfigEntry[] = splitJsonEntries(text);
  const errors: string[] = [];
  if (entries.length === 0) {
    errors.push('json parse failed or outbounds missing');
  }
  const result: ImportResult = {
    entries: entries,
    failed: entries.length === 0 ? 1 : 0,
    total: 1,
    errors: errors
  };
  return result;
}

export function importText(text: string): ImportResult {
  const trimmed: string = text.trim();
  if (trimmed.startsWith('{')) {
    return importJsonDocument(trimmed);
  }
  // A subscription body may be base64 of a whole config (not just of links),
  // so decode one layer here before the link-by-link expansion.
  if (looksLikeBase64(trimmed)) {
    const decoded: string | null = decodeBase64Text(trimmed);
    if (decoded !== null) {
      const inner: string = decoded.trim();
      if (inner.startsWith('{')) {
        return importJsonDocument(inner);
      }
    }
  }

  const lines: string[] = expandPayload(trimmed);
  const entries: ConfigEntry[] = [];
  const seen: Set<string> = new Set();
  const errors: string[] = [];
  let failed: number = 0;
  let index: number = 0;
  for (const line of lines) {
    if (entries.length >= MAX_NODES) {
      break;
    }
    index++;
    if (detectFormat(line).length === 0) {
      failed++;
      if (errors.length < 8) {
        errors.push('unsupported line: ' + line.substring(0, Math.min(48, line.length)));
      }
      continue;
    }
    const cleaned: SanitizedLink = sanitizeLink(line);
    try {
      const imported = importShareLink(cleaned.text);
      if (seen.has(imported.config)) {
        continue;
      }
      seen.add(imported.config);
      const entry: ConfigEntry = {
        id: newId(),
        name: imported.name.length > 0 ? imported.name : fallbackName(line, index),
        type: detectFormat(line),
        server: imported.server,
        json: imported.config,
        createdAt: Date.now()
      };
      entries.push(entry);
    } catch (error) {
      failed++;
      const err = error as Error;
      const droppedNote: string = cleaned.dropped.length > 0
        ? (' | dropped=' + cleaned.dropped.join(','))
        : '';
      if (errors.length < 8) {
        errors.push(detectFormat(line) + ': ' + (err.message ?? 'import failed') +
          ' | raw=' + line.length + ' sanitized=' + cleaned.text.length + droppedNote +
          ' | ' + cleaned.text.substring(0, Math.min(36, cleaned.text.length)));
      }
    }
  }
  const result: ImportResult = { entries: entries, failed: failed, total: lines.length, errors: errors };
  return result;
}

// sing-box clients read the traffic quota from the subscription-userinfo header
// (`upload=..; download=..; total=..; expire=..`). Same idea here.
export interface SubscriptionUserInfo {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

export interface SubscriptionFetch {
  body: string;
  userinfo: SubscriptionUserInfo | null;
}

export function parseUserInfo(value: string): SubscriptionUserInfo | null {
  if (value.length === 0) {
    return null;
  }
  let upload: number = 0;
  let download: number = 0;
  let total: number = 0;
  let expire: number = 0;
  for (const part of value.split(';')) {
    const pair: string[] = part.trim().split('=');
    if (pair.length !== 2) {
      continue;
    }
    const key: string = pair[0].trim().toLowerCase();
    const raw: number = Number(pair[1].trim());
    if (!Number.isFinite(raw) || raw < 0) {
      continue;
    }
    if (key === 'upload') {
      upload = raw;
    } else if (key === 'download') {
      download = raw;
    } else if (key === 'total') {
      total = raw;
    } else if (key === 'expire') {
      expire = raw;
    }
  }
  if (upload === 0 && download === 0 && total === 0 && expire === 0) {
    return null;
  }
  const info: SubscriptionUserInfo = {
    upload: upload,
    download: download,
    total: total,
    expire: expire
  };
  return info;
}

function headerValue(response: http.HttpResponse, name: string): string {
  const header: Object | undefined = response.header as Object | undefined;
  if (header === undefined || header === null) {
    return '';
  }
  const map: Record<string, Object> = header as Record<string, Object>;
  for (const key of Object.keys(map)) {
    if (key.toLowerCase() === name) {
      const value: Object = map[key];
      if (typeof value === 'string') {
        return value as string;
      }
      return JSON.stringify(value);
    }
  }
  return '';
}

export async function fetchSubscription(url: string): Promise<SubscriptionFetch> {
  const request = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': USER_AGENT, 'Accept': '*/*' },
      connectTimeout: 15000,
      readTimeout: 25000,
      expectDataType: http.HttpDataType.STRING
    };
    const response: http.HttpResponse = await request.request(url, options);
    if (response.responseCode !== 200) {
      throw new Error('HTTP ' + response.responseCode);
    }
    const body: string = response.result as string;
    if (body.length === 0) {
      throw new Error('订阅内容为空');
    }
    const result: SubscriptionFetch = {
      body: body,
      userinfo: parseUserInfo(headerValue(response, 'subscription-userinfo'))
    };
    return result;
  } finally {
    request.destroy();
  }
}


