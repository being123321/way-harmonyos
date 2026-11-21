import { fileIo as fs } from '@kit.CoreFileKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { vpnExtension } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import type { Want } from '@kit.AbilityKit';
import native from 'libentry.so';

export interface Insets {
  top: number;
  bottom: number;
}

// Safe-area insets in vp. With the window in full-screen layout the page paints
// behind the status and navigation bars, so content needs these paddings.
export async function pageInsets(context: common.Context): Promise<Insets> {
  try {
    const win: window.Window = await window.getLastWindow(context);
    const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    const insets: Insets = {
      top: px2vp(system.topRect.height),
      bottom: px2vp(nav.bottomRect.height)
    };
    return insets;
  } catch (error) {
    const fallback: Insets = { top: 0, bottom: 0 };
    return fallback;
  }
}

// Cross-process probe RPC between the node list (UI process) and the VPN
// extension (its own process, owner of the core handle).
export const PROBE_REQUEST_EVENT: string = 'com.way.app.PROBE';
// Live routing swap (mode switch) request/answer between UI and extension.
export const RELOAD_REQUEST_EVENT: string = 'com.way.app.RELOAD_ROUTING';
export const RELOAD_RESULT_EVENT: string = 'com.way.app.RELOAD_ROUTING_RESULT';
// Live connection inventory request/answer between UI and extension.
export const CONN_REQUEST_EVENT: string = 'com.way.app.CONNECTIONS';
export const CONN_RESULT_EVENT: string = 'com.way.app.CONNECTIONS_RESULT';
export const PROBE_RESULT_EVENT: string = 'com.way.app.PROBE_RESULT';
// Cancels the probes already in flight (ABI 1.15): the UI sends this when a new
// run starts or the node page closes, so stale probes stop early instead of
// occupying workers until their timeout.
export const PROBE_CANCEL_EVENT: string = 'com.way.app.PROBE_CANCEL';

export const BUNDLE_NAME: string = 'com.way.app';
export const VPN_ABILITY: string = 'XrayVpnAbility';
const XRAY_DIR: string = 'xray';

export interface TunnelStatus {
  state: string;
  message: string;
  startedAt: number;
  updatedAt: number;
  up: number;
  down: number;
  tcpFlows: number;
  udpFlows: number;
  restartCount: number;
  probeMs: number;
  pssKb?: number;
  cpuPercent?: number;
}

interface ImportedProfile {
  config: string;
  name: string;
  server: string;
}

export function xrayDir(context: common.Context): string {
  return context.filesDir + '/' + XRAY_DIR;
}

export function ensureXrayDir(context: common.Context): string {
  const dir: string = xrayDir(context);
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  return dir;
}

export function configPath(context: common.Context): string {
  return ensureXrayDir(context) + '/config.json';
}

export function statusPath(context: common.Context): string {
  return xrayDir(context) + '/status.json';
}

export function saveConfig(context: common.Context, config: string): string {
  const path: string = configPath(context);
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, config);
  fs.closeSync(file);
  return path;
}

export function loadConfig(context: common.Context): string {
  const path: string = configPath(context);
  try {
    if (fs.accessSync(path)) {
      return fs.readTextSync(path);
    }
  } catch (error) {
  }
  return '';
}

export function readStatus(context: common.Context): TunnelStatus | null {
  const path: string = statusPath(context);
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    const text: string = fs.readTextSync(path);
    return JSON.parse(text) as TunnelStatus;
  } catch (error) {
    return null;
  }
}

export function clearStatus(context: common.Context): void {
  const path: string = statusPath(context);
  try {
    if (fs.accessSync(path)) {
      fs.unlinkSync(path);
    }
  } catch (error) {
  }
}

export function detectFormat(link: string): string {
  const text: string = link.trim().toLowerCase();
  if (text.startsWith('vless://')) {
    return 'vless';
  }
  if (text.startsWith('vmess://')) {
    return 'vmess';
  }
  if (text.startsWith('ss://')) {
    return 'shadowsocks2022';
  }
  if (text.startsWith('trojan://') || text.startsWith('trojan-go://')) {
    return 'trojan';
  }
  if (text.startsWith('hysteria2://') || text.startsWith('hy2://')) {
    return 'hysteria2';
  }
  if (text.startsWith('socks://')) {
    return 'socks';
  }
  if (text.startsWith('http://') || text.startsWith('https://')) {
    return 'http';
  }
  if (text.startsWith('wireguard://') || text.startsWith('[interface]')) {
    return 'wireguard';
  }
  return '';
}

// Uses the core's offline importer: share link -> full Xray JSON config.
// Runs in the UI process; no core and no network is created by this call.
export function importShareLink(link: string): ImportedProfile {
  const format: string = detectFormat(link);
  if (format.length === 0) {
    throw new Error('无法识别的链接类型');
  }
  // No "name" key: the importer validates it as 1..128 bytes, so an empty
  // string is rejected with "invalid profile name". The profile name comes
  // from the link fragment instead.
  const request: Record<string, Object> = {
    'format': format,
    'text': link.trim(),
    'dnsServers': ['1.1.1.1', '8.8.8.8']
  };
  const response: string = native.importProfile(JSON.stringify(request));
  const parsed: Record<string, Object> = JSON.parse(response) as Record<string, Object>;
  const config: string = parsed['configJSON'] as string;
  const name: string = parsed['name'] as string;
  const server: string = parsed['serverAddress'] as string;
  return { config: config, name: name, server: server };
}

export interface NodeEndpoint {
  host: string;
  port: number;
}

// Outbound helpers shared by the importer (which splits a JSON config per
// outbound) and the node list (which shows/measures one outbound per node).
export function outboundTag(outbound: Record<string, Object>): string {
  const value: Object | undefined = outbound['tag'] as Object | undefined;
  if (typeof value === 'string' && (value as string).length > 0) {
    return value as string;
  }
  return '';
}

// Xray calls it `protocol`, sing-box calls it `type`; accept both so a config
// pasted from either ecosystem still yields names and endpoint probes.
export function outboundProtocol(outbound: Record<string, Object>): string {
  const protocol: Object | undefined = outbound['protocol'] as Object | undefined;
  if (typeof protocol === 'string' && (protocol as string).length > 0) {
    return (protocol as string).toLowerCase();
  }
  const type: Object | undefined = outbound['type'] as Object | undefined;
  if (typeof type === 'string' && (type as string).length > 0) {
    return (type as string).toLowerCase();
  }
  return '';
}

// Outbounds that carry no server of their own: they are kept next to the
// selected node so routing rules that reference them stay valid.
export function isHelperOutbound(outbound: Record<string, Object>): boolean {
  const protocol: string = outboundProtocol(outbound);
  return protocol === 'freedom' || protocol === 'blackhole' || protocol === 'dns';
}

function textOf(value: Object | undefined): string {
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

function portOf(value: Object | undefined): number {
  if (typeof value === 'number') {
    const port: number = value as number;
    return Number.isFinite(port) ? port : 0;
  }
  if (typeof value === 'string') {
    const parsed: number = Number(value as string);
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function endpointFrom(address: Object | undefined, port: Object | undefined): NodeEndpoint | null {
  const host: string = textOf(address).trim();
  const value: number = portOf(port);
  if (host.length === 0 || value <= 0 || value > 65535) {
    return null;
  }
  const endpoint: NodeEndpoint = { host: host, port: value };
  return endpoint;
}

// WireGuard peers carry "host:port", including bracketed IPv6 literals.
function hostPortEndpoint(value: string): NodeEndpoint | null {
  const text: string = value.trim();
  if (text.length === 0) {
    return null;
  }
  if (text.startsWith('[')) {
    const close: number = text.indexOf(']');
    if (close > 1) {
      const host: string = text.substring(1, close);
      const rest: string = text.substring(close + 1);
      if (rest.startsWith(':')) {
        const endpoint: NodeEndpoint = { host: host, port: Number(rest.substring(1)) };
        return endpoint.port > 0 ? endpoint : null;
      }
    }
    return null;
  }
  const colon: number = text.lastIndexOf(':');
  if (colon <= 0 || colon === text.length - 1) {
    return null;
  }
  const endpoint: NodeEndpoint = {
    host: text.substring(0, colon),
    port: Number(text.substring(colon + 1))
  };
  return endpoint.port > 0 ? endpoint : null;
}

// The server an outbound dials, whatever shape its settings use.
export function outboundEndpoint(outbound: Record<string, Object>): NodeEndpoint | null {
  const rawSettings: Object | undefined = outbound['settings'] as Object | undefined;
  const settings: Record<string, Object> =
    (rawSettings === undefined || rawSettings === null) ? {} : rawSettings as Record<string, Object>;
  let endpoint: NodeEndpoint | null = endpointFrom(settings['address'], settings['port']);
  if (endpoint !== null) {
    return endpoint;
  }
  const vnext: Object[] | undefined = settings['vnext'] as Object[] | undefined;
  if (vnext !== undefined && vnext.length > 0) {
    const first: Record<string, Object> = vnext[0] as Record<string, Object>;
    endpoint = endpointFrom(first['address'], first['port']);
    if (endpoint !== null) {
      return endpoint;
    }
  }
  const servers: Object[] | undefined = settings['servers'] as Object[] | undefined;
  if (servers !== undefined && servers.length > 0) {
    const first: Record<string, Object> = servers[0] as Record<string, Object>;
    endpoint = endpointFrom(first['address'], first['port']);
    if (endpoint !== null) {
      return endpoint;
    }
  }
  const peers: Object[] | undefined = settings['peers'] as Object[] | undefined;
  if (peers !== undefined && peers.length > 0) {
    const first: Record<string, Object> = peers[0] as Record<string, Object>;
    endpoint = hostPortEndpoint(textOf(first['endpoint']));
    if (endpoint !== null) {
      return endpoint;
    }
  }
  return endpointFrom(outbound['server'], outbound['server_port']);
}

export function nodeEndpoint(configJson: string): NodeEndpoint | null {
  try {
    const root: Record<string, Object> = JSON.parse(configJson) as Record<string, Object>;
    const outbounds: Object[] = (root['outbounds'] as Object[]) ?? [];
    if (outbounds.length === 0) {
      return null;
    }
    // Skip freedom/blackhole first: a WireGuard profile starts with `direct`,
    // and its real server lives in the second outbound.
    for (const item of outbounds) {
      const outbound: Record<string, Object> = item as Record<string, Object>;
      if (isHelperOutbound(outbound)) {
        continue;
      }
      const endpoint: NodeEndpoint | null = outboundEndpoint(outbound);
      if (endpoint !== null) {
        return endpoint;
      }
    }
    for (const item of outbounds) {
      const endpoint: NodeEndpoint | null = outboundEndpoint(item as Record<string, Object>);
      if (endpoint !== null) {
        return endpoint;
      }
    }
    return null;
  } catch (error) {
    return null;
  }
}

// Compact protocol badge for the node list; the raw protocol names are too long
// for the 54 vp tag (SHADOWSOCKS2022, HYSTERIA...).
export function nodeTypeLabel(type: string): string {
  const value: string = type.trim().toLowerCase();
  if (value === 'vless') {
    return 'VLESS';
  }
  if (value === 'vmess') {
    return 'VMESS';
  }
  if (value === 'trojan') {
    return 'TROJAN';
  }
  if (value === 'shadowsocks' || value === 'shadowsocks2022' || value === 'ss') {
    return 'SS';
  }
  if (value === 'hysteria' || value === 'hysteria2' || value === 'hy2') {
    return 'HY2';
  }
  if (value === 'wireguard') {
    return 'WG';
  }
  if (value === 'socks') {
    return 'SOCKS';
  }
  if (value === 'http') {
    return 'HTTP';
  }
  if (value === 'json' || value.length === 0) {
    return 'CFG';
  }
  const upper: string = value.toUpperCase();
  return upper.length > 7 ? upper.substring(0, 7) : upper;
}

// True while the VPN extension is alive and heart-beating. The node list uses
// it to switch the delay test to the v2rayNG "through the tunnel" mode.
export function tunnelUp(context: common.Context): boolean {
  const status: TunnelStatus | null = readStatus(context);
  if (status === null) {
    return false;
  }
  if (status.state !== 'running') {
    return false;
  }
  return Date.now() - status.updatedAt < 6000;
}

export interface OutboundProbeResult {
  status: number;
  delayMs: number;
  failureKind: number;
  httpStatus: number;
  message: string;
}

function numberOf(value: Object | undefined, fallback: number): number {
  if (typeof value === 'number') {
    const parsed: number = value as number;
    return Number.isFinite(parsed) ? parsed : fallback;
  }
  return fallback;
}

// Ask the extension to cancel the probes already running. Fire-and-forget: the
// caller does not wait for an answer, a cancelled probe just resolves as a
// failure in whichever worker still awaits it.
export function cancelProbes(): void {
  const data: commonEventManager.CommonEventPublishData = { parameters: {} };
  try {
    commonEventManager.publish(PROBE_CANCEL_EVENT, data, () => {
    });
  } catch (error) {
  }
}

// HTTP(S) GET through one named outbound of the running core: the node's real
// delay, measured by the proxy itself (v2rayNG's "real delay").
//
// The core lives in the VPN extension's process, so this process cannot call the
// FFI directly: the request goes to `com.way.app.PROBE`, the extension runs the
// probe as NAPI async work and answers on `com.way.app.PROBE_RESULT`. `status`
// is the FFI status: non-zero means the probe did not run at all (the tag is not
// part of the running config, or the core is down), and the caller should fall
// back to a direct TCP/UDP probe.
export async function probeOutbound(url: string, timeoutMs: number,
  tag: string): Promise<OutboundProbeResult> {
  const requestId: string = Date.now().toString(36) + Math.floor(Math.random() * 1000000).toString(36);
  let subscriber: commonEventManager.CommonEventSubscriber | null = null;
  try {
    subscriber = await commonEventManager.createSubscriber({ events: [PROBE_RESULT_EVENT] });
  } catch (error) {
    return probeFailure('probe: cannot subscribe');
  }
  const pending = subscriber;
  return new Promise<OutboundProbeResult>((resolve) => {
    let settled: boolean = false;
    let timer: number = -1;
    const finish = (value: OutboundProbeResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer !== -1) {
        clearTimeout(timer);
      }
      try {
        commonEventManager.unsubscribe(pending);
      } catch (error) {
      }
      resolve(value);
    };
    timer = setTimeout(() => {
      finish(probeFailure('probe: extension did not answer'));
    }, timeoutMs + 2000);
    try {
      commonEventManager.subscribe(pending, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (params === undefined || params === null) {
          return;
        }
        if ((params['requestId'] as string) !== requestId) {
          return;
        }
        const result: OutboundProbeResult = {
          status: numberOf(params['status'], -1),
          delayMs: numberOf(params['delayMs'], 0),
          failureKind: numberOf(params['failureKind'], 0),
          httpStatus: numberOf(params['httpStatus'], 0),
          message: textOf(params['message'])
        };
        finish(result);
      });
      const payload: Record<string, Object> = {
        'requestId': requestId,
        'tag': tag,
        'url': url,
        'timeoutMs': timeoutMs
      };
      const data: commonEventManager.CommonEventPublishData = { parameters: payload };
      commonEventManager.publish(PROBE_REQUEST_EVENT, data, () => {
      });
    } catch (error) {
      finish(probeFailure('probe: cannot publish'));
    }
  });
}

function probeFailure(message: string): OutboundProbeResult {
  const failed: OutboundProbeResult = {
    status: -1,
    delayMs: 0,
    failureKind: 0,
    httpStatus: 0,
    message: message
  };
  return failed;
}

// Live routing swap: the UI rewrites config.json, then asks the extension (which
// owns the core) to apply its routing table through
// xray_core_replace_routing_policy_json. Resolves false when the extension did
// not answer or the core refused, so the caller can fall back to a restart.
export interface ReloadResult {
  ok: boolean;
  reason: string;
}

export async function reloadRouting(context: common.Context): Promise<ReloadResult> {
  const requestId: string = Date.now().toString(36) + Math.floor(Math.random() * 1000000).toString(36);
  let subscriber: commonEventManager.CommonEventSubscriber | null = null;
  try {
    subscriber = await commonEventManager.createSubscriber({ events: [RELOAD_RESULT_EVENT] });
  } catch (error) {
    const failed: ReloadResult = { ok: false, reason: 'subscribe failed' };
    return failed;
  }
  const pending = subscriber;
  return new Promise<ReloadResult>((resolve) => {
    let settled: boolean = false;
    let timer: number = -1;
    const finish = (value: ReloadResult): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer !== -1) {
        clearTimeout(timer);
      }
      try {
        commonEventManager.unsubscribe(pending);
      } catch (error) {
      }
      resolve(value);
    };
    timer = setTimeout(() => {
      const expired: ReloadResult = { ok: false, reason: 'extension timeout' };
      finish(expired);
    }, 2500);
    try {
      commonEventManager.subscribe(pending, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (params === undefined || params === null) {
          return;
        }
        if ((params['requestId'] as string) !== requestId) {
          return;
        }
        const ok: boolean = params['ok'] === 1 || params['ok'] === '1';
        const result: ReloadResult = {
          ok: ok,
          reason: textOf(params['message'])
        };
        finish(result);
      });
      const payload: Record<string, Object> = { 'requestId': requestId };
      const data: commonEventManager.CommonEventPublishData = { parameters: payload };
      commonEventManager.publish(RELOAD_REQUEST_EVENT, data, () => {
      });
    } catch (error) {
      const failed: ReloadResult = { ok: false, reason: 'publish failed' };
      finish(failed);
    }
  });
}

export interface ConnectionRow {
  id: number;
  state: string;
  inboundTag: string;
  outboundTag: string;
  network: string;
  address: string;
  port: number;
  // ruleTag of the matched routing rule (ACL4SSR list name), '' when none.
  ruleTag: string;
  // Domain sniffing recognized, '' when the flow was never sniffed.
  sniffedDomain: string;
  startedUnixMs: number;
}

interface ConnectionReply {
  ok: boolean;
  payload: string;
}

async function askConnections(params: Record<string, Object>): Promise<ConnectionReply> {
  const requestId: string = Date.now().toString(36) + Math.floor(Math.random() * 1000000).toString(36);
  let subscriber: commonEventManager.CommonEventSubscriber | null = null;
  try {
    subscriber = await commonEventManager.createSubscriber({ events: [CONN_RESULT_EVENT] });
  } catch (error) {
    return { ok: false, payload: 'cannot subscribe' };
  }
  const pending = subscriber;
  return new Promise<ConnectionReply>((resolve) => {
    let settled: boolean = false;
    let timer: number = -1;
    const finish = (value: ConnectionReply): void => {
      if (settled) {
        return;
      }
      settled = true;
      if (timer !== -1) {
        clearTimeout(timer);
      }
      try {
        commonEventManager.unsubscribe(pending);
      } catch (error) {
      }
      resolve(value);
    };
    timer = setTimeout(() => {
      finish({ ok: false, payload: 'extension did not answer' });
    }, 4000);
    try {
      commonEventManager.subscribe(pending, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (params === undefined || params === null || (params['requestId'] as string) !== requestId) {
          return;
        }
        const reply: ConnectionReply = {
          ok: params['ok'] === 1,
          payload: (params['json'] as string) ?? ''
        };
        finish(reply);
      });
      const payload: Record<string, Object> = {
        'requestId': requestId
      };
      for (const key of Object.keys(params)) {
        payload[key] = params[key];
      }
      const data: commonEventManager.CommonEventPublishData = { parameters: payload };
      commonEventManager.publish(CONN_REQUEST_EVENT, data, () => {
      });
    } catch (error) {
      finish({ ok: false, payload: 'publish failed' });
    }
  });
}

// Live connection inventory of the running core (empty when the tunnel is down).
export async function fetchConnections(): Promise<ConnectionRow[]> {
  const reply: ConnectionReply = await askConnections({ 'op': 'list', 'id': 0 });
  if (!reply.ok || reply.payload.length === 0) {
    return [];
  }
  try {
    const doc: Record<string, Object> = JSON.parse(reply.payload) as Record<string, Object>;
    const raw: Object[] = (doc['connections'] as Object[]) ?? [];
    const rows: ConnectionRow[] = [];
    for (const item of raw) {
      const row: Record<string, Object> = item as Record<string, Object>;
      const entry: ConnectionRow = {
        id: Number(row['id'] ?? 0),
        state: (row['state'] as string) ?? '',
        inboundTag: (row['inboundTag'] as string) ?? '',
        outboundTag: (row['outboundTag'] as string) ?? '',
        network: (row['network'] as string) ?? '',
        address: (row['address'] as string) ?? '',
        port: Number(row['port'] ?? 0),
        ruleTag: (row['ruleTag'] as string) ?? '',
        sniffedDomain: (row['sniffedDomain'] as string) ?? '',
        startedUnixMs: Number(row['startedUnixMs'] ?? 0)
      };
      rows.push(entry);
    }
    return rows;
  } catch (error) {
    return [];
  }
}

// Drops one live connection by id.
export async function closeConnection(id: number): Promise<boolean> {
  const reply: ConnectionReply = await askConnections({ 'op': 'close', 'id': id });
  return reply.ok;
}

// Real TCP round-trip time to a node server, measured inside the protected VPN
// process (a socket from the UI process would be routed back into the tunnel).
export async function measureLatency(host: string, port: number,
  timeoutMs: number): Promise<number> {
  const reply: ConnectionReply = await askConnections({
    'op': 'latency',
    'host': host,
    'port': port,
    'timeout': timeoutMs
  });
  const value: number = Number(reply.payload);
  return Number.isFinite(value) ? value : -1;
}

// Outbound tags of the config the tunnel is actually running: the node list
// only asks for a core-side probe when the node is part of it.
export function tunnelOutboundTags(context: common.Context): string[] {
  const tags: string[] = [];
  const text: string = loadConfig(context);
  if (text.length === 0) {
    return tags;
  }
  try {
    const root: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const outbounds: Object[] = (root['outbounds'] as Object[]) ?? [];
    for (const item of outbounds) {
      const tag: string = outboundTag(item as Record<string, Object>);
      if (tag.length > 0) {
        tags.push(tag);
      }
    }
  } catch (error) {
  }
  return tags;
}

export function coreVersion(): string {
  return native.version();
}

export function vpnWant(context: common.Context, notify: boolean, rebind: boolean,
  taskNotificationId: number = -1, nodeName: string = ''): Want {
  const want: Want = {
    bundleName: BUNDLE_NAME,
    abilityName: VPN_ABILITY,
    parameters: {
      'configPath': configPath(context),
      'notify': notify,
      'rebindOnNetChange': rebind,
      'geodataDir': xrayDir(context) + '/geodata',
      'taskNotificationId': taskNotificationId,
      'nodeName': nodeName
    }
  };
  return want;
}

export async function startVpn(want: Want): Promise<void> {
  await vpnExtension.startVpnExtensionAbility(want);
}

export async function stopVpn(want: Want): Promise<void> {
  await vpnExtension.stopVpnExtensionAbility(want);
}

export function formatBytes(value: number): string {
  if (value < 1024) {
    return value.toFixed(0) + ' B';
  }
  if (value < 1024 * 1024) {
    return (value / 1024).toFixed(1) + ' KB';
  }
  if (value < 1024 * 1024 * 1024) {
    return (value / (1024 * 1024)).toFixed(1) + ' MB';
  }
  return (value / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

export function formatDuration(seconds: number): string {
  if (seconds <= 0) {
    return '--';
  }
  const h: number = Math.floor(seconds / 3600);
  const m: number = Math.floor((seconds % 3600) / 60);
  const s: number = Math.floor(seconds % 60);
  if (h > 0) {
    return h + ':' + m.toString().padStart(2, '0') + ':' + s.toString().padStart(2, '0');
  }
  return m + ':' + s.toString().padStart(2, '0');
}

export function formatSpeed(bytesPerSecond: number): string {
  if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) {
    return '0 B/s';
  }
  if (bytesPerSecond < 1024) {
    return bytesPerSecond.toFixed(0) + ' B/s';
  }
  if (bytesPerSecond < 1024 * 1024) {
    return (bytesPerSecond / 1024).toFixed(1) + ' KB/s';
  }
  return (bytesPerSecond / (1024 * 1024)).toFixed(2) + ' MB/s';
}

export function formatTime(ts: number): string {
  if (ts <= 0) {
    return '--';
  }
  const date = new Date(ts);
  const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
  return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
    ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes());
}

export function readLogs(context: common.Context, limit: number): string {
  // Only the ArkTS logs are shown: the core's xray-access.log/xray-error.log
  // are debug dumps (tens of KB per minute) and would drown the view.
  const dir: string = xrayDir(context);
  try {
    if (!fs.accessSync(dir)) {
      return '';
    }
    const names: string[] = ['ability.log', 'app.log'];
    const budget: number = limit > 2000 ? limit / 2 : 1000;
    const parts: string[] = [];
    for (const name of names) {
      const path: string = dir + '/' + name;
      if (!fs.accessSync(path)) {
        continue;
      }
      try {
        const text: string = fs.readTextSync(path);
        const tail: string = text.length > budget ? text.substring(text.length - budget) : text;
        parts.push('== ' + name + ' ==\n' + tail);
      } catch (error) {
      }
    }
    return parts.join('\n');
  } catch (error) {
    return '';
  }
}








