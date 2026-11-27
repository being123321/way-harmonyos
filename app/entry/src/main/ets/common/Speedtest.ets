import { common } from '@kit.AbilityKit';
import { socket } from '@kit.NetworkKit';
import { ConfigEntry } from './Store';
import {
  NodeEndpoint, OutboundProbeResult, OutboundProbeSpec, ProbeProfilesBatchResult,
  cancelProbes, nodeEndpoint, probeOutbound, probeProfiles, probeProfilesLocal
} from './Xray';
import { isFakeOrReservedIp, isIpAddressLiteral, resolveHostIp, udpQuicLatency } from './Latency';
import { proxyOutbound } from './TunnelConfig';
import { appLog } from './AppLog';

// Delay test modelled on v2rayNG + Anywhere:
//   * Uses HTTPS 443 (`https://www.gstatic.com/generate_204`) so proxies that
//     block plain port 80 or require TLS 1.3 (e.g. VLESS Vision) work reliably.
//   * Inside `xray-rust` (`startup_probe.rs`), the system TLS connector is
//     cached globally (`OnceLock`), request #1 warms up the proxy + TLS tunnel
//     with Keep-Alive, and request #2 measures ONLY the pure 1-RTT HTTP delay
//     (strictly bounded inside the remaining budget so Step 1 success can never
//     be turned into a false timeout).
//   * Batches of 6 keep concurrent memory flat and stream UI updates.
export const TEST_CONCURRENCY: number = 6;
export const TEST_TIMEOUT_MS: number = 8000;
export const UDP_TEST_TIMEOUT_MS: number = 10000;
const PROBE_BATCH_SIZE: number = 6;

// Plain HTTP 204 probe matching v2rayNG / sing-box / Anywhere:
// avoids double TLS handshake overhead inside the tunnel and still exercises
// the full proxy transport (VLESS/Reality/Vision/VMess/Trojan/SS/Hysteria2).
const TEST_URL: string = 'http://www.gstatic.com/generate_204';
const FALLBACK_TEST_URL: string = 'http://cp.cloudflare.com/generate_204';
export const TEST_HOST: string = '';

export const VIA_HTTP: string = 'http';
export const VIA_TCP: string = 'tcp';
export const VIA_UDP: string = 'udp';
export const VIA_NONE: string = 'none';

export interface LatencyResult {
  id: string;
  ms: number;
  via: string;
  at: number;
}

export function latencyText(ms: number): string {
  return ms >= 0 ? (ms + ' ms') : '超时';
}

export function viaText(via: string): string {
  if (via === VIA_HTTP) {
    return 'HTTP';
  }
  if (via === VIA_TCP) {
    return 'TCP';
  }
  if (via === VIA_UDP) {
    return 'UDP';
  }
  return '';
}

// Node types that only speak UDP: a TCP handshake would always fail for them.
function isUdpNode(entry: ConfigEntry): boolean {
  const type: string = entry.type.trim().toLowerCase();
  if (type === 'hysteria' || type === 'hysteria2' || type === 'hy2' || type === 'wireguard') {
    return true;
  }
  const json: string = entry.json.toLowerCase();
  return json.indexOf('"hysteria"') >= 0 || json.indexOf('hysteria2') >= 0;
}

// TCP handshake time to the node, with a hard deadline: the platform's own
// connect timeout is not honoured reliably on every network.
export async function tcpLatency(host: string, port: number, timeoutMs: number): Promise<number> {
  const ip: string = await resolveHostIp(host, timeoutMs);
  if (ip.length === 0) {
    return -1;
  }
  const family: number = ip.indexOf(':') >= 0 ? 2 : 1;
  const tcp = socket.constructTCPSocketInstance();
  const start: number = Date.now();
  const connected: boolean = await new Promise<boolean>((resolve) => {
    let settled: boolean = false;
    const finish = (value: boolean): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(value);
    };
    const timer: number = setTimeout(() => {
      finish(false);
    }, timeoutMs);
    try {
      tcp.connect({
        address: { address: ip, port: port, family: family },
        timeout: timeoutMs
      }).then(() => {
        clearTimeout(timer);
        finish(true);
      }).catch(() => {
        clearTimeout(timer);
        finish(false);
      });
    } catch (error) {
      clearTimeout(timer);
      finish(false);
    }
  });
  try {
    tcp.close();
  } catch (error) {
  }
  if (!connected) {
    return -1;
  }
  const elapsed: number = Date.now() - start;
  return elapsed > 0 ? elapsed : 1;
}

function probeDelayMs(probe: OutboundProbeResult | null): number {
  if (probe === null || probe.status !== 0 || probe.failureKind !== 0) {
    return -1;
  }
  return probe.delayMs > 0 ? probe.delayMs : 1;
}

interface BuiltProbeBatch {
  configJson: string;
  validEntries: ConfigEntry[];
  invalidEntries: ConfigEntry[];
}

function probeTimeoutFor(entry: ConfigEntry): number {
  return isUdpNode(entry) ? UDP_TEST_TIMEOUT_MS : TEST_TIMEOUT_MS;
}

// Pre-resolves domain server addresses for a set of entries (preferring IPv4 so
// QUIC/Hysteria2 does not waste 3 s on an unreachable IPv6 AAAA record before
// trying IPv4), bounded to 1.2 s total. When VPN is active (`viaTunnel`), skip
// UI-process lookups so FakeIP (198.19.x.x) never poisons the protected probe
// core running inside XrayVpnAbility.
async function resolveBootstrapHosts(entries: ConfigEntry[],
  existing: Record<string, string[]> | null, viaTunnel: boolean): Promise<Record<string, string[]>> {
  const hosts: Record<string, string[]> = {};
  if (existing !== null) {
    for (const key of Object.keys(existing)) {
      const clean: string[] = [];
      for (const ip of existing[key]) {
        if (!isFakeOrReservedIp(ip)) {
          clean.push(ip);
        }
      }
      if (clean.length > 0) {
        hosts[key] = clean;
      }
    }
  }
  if (viaTunnel) {
    return hosts;
  }
  const pending: string[] = [];
  for (const entry of entries) {
    const endpoint: NodeEndpoint | null = nodeEndpoint(entry.json);
    if (endpoint === null || endpoint.host.length === 0 || isIpAddressLiteral(endpoint.host)) {
      continue;
    }
    if (hosts[endpoint.host] !== undefined || pending.indexOf(endpoint.host) >= 0) {
      continue;
    }
    pending.push(endpoint.host);
  }
  if (pending.length === 0) {
    return hosts;
  }
  const tasks: Promise<void>[] = pending.map((domain: string): Promise<void> => {
    return resolveHostIp(domain, 1500).then((ip: string) => {
      if (ip.length > 0 && !isFakeOrReservedIp(ip)) {
        hosts[domain] = [ip];
      }
    }).catch((): void => {
    });
  });
  const all: Promise<void> = Promise.all(tasks).then((): void => {
  });
  const budget: Promise<void> = new Promise<void>((resolve) => {
    setTimeout((): void => {
      resolve();
    }, 2200);
  });
  await Promise.race([all, budget]);
  return hosts;
}

// Builds a minimal, self-contained, in-memory Xray JSON strictly for probing a
// batch of nodes. Never touches config.json on disk, never includes ACL4SSR
// routing rules or FakeIP, puts `direct` at outbounds[0] with direct IPv4 DNS
// servers supported by xray-rust (never `localhost`, which xray-config rejects),
// and provides a loopback port-0 SOCKS inbound so xray-core-rs starts cleanly.
function buildProbeConfig(entries: ConfigEntry[],
  bootstrapHosts: Record<string, string[]> | null): BuiltProbeBatch {
  const directOutbound: Record<string, Object> = {
    'tag': 'direct',
    'protocol': 'freedom',
    'settings': {} as Record<string, Object>
  };
  const outbounds: Object[] = [directOutbound];
  const validEntries: ConfigEntry[] = [];
  const invalidEntries: ConfigEntry[] = [];
  const seen: Set<string> = new Set();
  for (const entry of entries) {
    if (seen.has(entry.id)) {
      continue;
    }
    const rawOutbound: Record<string, Object> | null = proxyOutbound(entry.json);
    if (rawOutbound === null) {
      invalidEntries.push(entry);
      continue;
    }
    try {
      const copy: Record<string, Object> = JSON.parse(JSON.stringify(rawOutbound)) as Record<string, Object>;
      copy['tag'] = entry.id;
      outbounds.push(copy);
      validEntries.push(entry);
      seen.add(entry.id);
    } catch (error) {
      invalidEntries.push(entry);
    }
  }
  if (validEntries.length === 0) {
    return { configJson: '', validEntries: [], invalidEntries: invalidEntries };
  }
  const socksSettings: Record<string, Object> = {
    'auth': 'noauth',
    'udp': false
  };
  const dummyInbound: Record<string, Object> = {
    'tag': 'probe-in',
    'listen': '127.0.0.1',
    'port': 0,
    'protocol': 'socks',
    'settings': socksSettings
  };
  const dnsConfig: Record<string, Object> = {
    'servers': ['223.5.5.5', '119.29.29.29'],
    'queryStrategy': 'UseIPv4'
  };
  if (bootstrapHosts !== null && Object.keys(bootstrapHosts).length > 0) {
    dnsConfig['hosts'] = bootstrapHosts as Object;
  }
  const logConfig: Record<string, Object> = { 'loglevel': 'none' };
  const doc: Record<string, Object> = {
    'log': logConfig,
    'dns': dnsConfig,
    'inbounds': [dummyInbound],
    'outbounds': outbounds
  };
  return {
    configJson: JSON.stringify(doc),
    validEntries: validEntries,
    invalidEntries: invalidEntries
  };
}

async function runProbeBatch(configJson: string, probes: OutboundProbeSpec[],
  viaTunnel: boolean, context: common.Context | null = null): Promise<ProbeProfilesBatchResult> {
  if (viaTunnel) {
    let maxProbeMs: number = TEST_TIMEOUT_MS;
    for (const spec of probes) {
      if (spec.timeoutMs > maxProbeMs) {
        maxProbeMs = spec.timeoutMs;
      }
    }
    const budgetMs: number = Math.max(20000, maxProbeMs * 3 + 6000);
    return await probeProfiles(configJson, probes, '', budgetMs, context);
  }
  return await probeProfilesLocal(configJson, probes, '');
}

async function directFallback(entry: ConfigEntry): Promise<LatencyResult> {
  const at: number = Date.now();
  const endpoint: NodeEndpoint | null = nodeEndpoint(entry.json);
  if (endpoint === null) {
    return { id: entry.id, ms: -1, via: VIA_NONE, at: at };
  }
  const udp: boolean = isUdpNode(entry);
  const ms: number = udp
    ? await udpQuicLatency(endpoint.host, endpoint.port, TEST_TIMEOUT_MS)
    : await tcpLatency(endpoint.host, endpoint.port, TEST_TIMEOUT_MS);
  return { id: entry.id, ms: ms, via: udp ? VIA_UDP : VIA_TCP, at: at };
}

function logProbeFail(context: common.Context | null, entry: ConfigEntry,
  detail: string): void {
  if (context === null) {
    return;
  }
  appLog(context, 'probe', entry.name + ' (' + entry.type + '): ' + detail);
}

export async function testOne(entry: ConfigEntry, viaTunnel: boolean,
  tag: string, bootstrapHosts: Record<string, string[]> | null = null,
  context: common.Context | null = null): Promise<LatencyResult> {
  const at: number = Date.now();
  const timeoutMs: number = probeTimeoutFor(entry);
  try {
    // If testing the currently active node while VPN is running, probe it
    // directly on the live core (zero temp-core memory overhead, identical
    // 2-step Keep-Alive 1-RTT measurement).
    if (viaTunnel && tag.length > 0) {
      const probe = await probeOutbound(TEST_URL, timeoutMs, tag, context);
      if (probe.status === 0) {
        const ms: number = probeDelayMs(probe);
        if (ms < 0) {
          logProbeFail(context, entry, 'live probe kind=' + probe.failureKind + ' http=' + probe.httpStatus);
        }
        return { id: entry.id, ms: ms, via: VIA_HTTP, at: Date.now() };
      }
      logProbeFail(context, entry, 'live probe status=' + probe.status + ' ' + probe.message);
    }
    const hosts: Record<string, string[]> = await resolveBootstrapHosts([entry], bootstrapHosts, viaTunnel);
    const built: BuiltProbeBatch = buildProbeConfig([entry], hosts);
    if (built.validEntries.length === 1) {
      const specs: OutboundProbeSpec[] = [{
        tag: entry.id,
        url: TEST_URL,
        timeoutMs: timeoutMs
      }];
      const batchRes: ProbeProfilesBatchResult =
        await runProbeBatch(built.configJson, specs, viaTunnel, context);
      if (batchRes.ok && batchRes.results.length > 0) {
        const p: OutboundProbeResult = batchRes.results[0];
        let ms: number = probeDelayMs(p);
        if (ms < 0) {
          logProbeFail(context, entry,
            'temp probe status=' + p.status + ' kind=' + p.failureKind +
            ' http=' + p.httpStatus + (p.message.length > 0 ? ' ' + p.message : ''));
          // Some transit exits block gstatic.com; retry once with Cloudflare 204.
          if (p.status === 0 && (p.failureKind === 5 || p.failureKind === 6 || p.failureKind === 1)) {
            const retrySpecs: OutboundProbeSpec[] = [{
              tag: entry.id,
              url: FALLBACK_TEST_URL,
              timeoutMs: Math.min(timeoutMs, 6000)
            }];
            const retryRes: ProbeProfilesBatchResult =
              await runProbeBatch(built.configJson, retrySpecs, viaTunnel, context);
            if (retryRes.ok && retryRes.results.length > 0) {
              ms = probeDelayMs(retryRes.results[0]);
            }
          }
        }
        return { id: entry.id, ms: ms, via: VIA_HTTP, at: Date.now() };
      }
      logProbeFail(context, entry, 'temp core failed: ' + batchRes.error);
    } else {
      logProbeFail(context, entry, 'no proxy outbound extracted from profile');
    }
    if (viaTunnel) {
      return { id: entry.id, ms: -1, via: VIA_HTTP, at: Date.now() };
    }
    return await directFallback(entry);
  } catch (error) {
    // A socket that cannot even be constructed must not abort the whole batch.
    return { id: entry.id, ms: -1, via: VIA_NONE, at: at };
  }
}

class TestCursor {
  value: number = 0;
}

function tagOf(tags: string[], id: string): string {
  for (const tag of tags) {
    if (tag === id) {
      return tag;
    }
  }
  return '';
}

async function drain(entries: ConfigEntry[], cursor: TestCursor, viaTunnel: boolean,
  probeTags: string[], onResult: (result: LatencyResult) => void): Promise<void> {
  while (cursor.value < entries.length) {
    const index: number = cursor.value;
    cursor.value = index + 1;
    const entry: ConfigEntry = entries[index];
    const result: LatencyResult = await testOne(entry, viaTunnel, tagOf(probeTags, entry.id));
    onResult(result);
  }
}

// Unified real-delay speed test shared by the home node card and the Configs
// page. Runs a true multi-way concurrent worker pool (up to 4 parallel lanes):
// fast nodes report back in ~100-300 ms immediately without waiting for slow
// or timed-out peers in the same batch, while reusing pre-resolved hosts.
const STREAMING_CONCURRENCY: number = 4;

export async function testNodesRealDelay(entries: ConfigEntry[], viaTunnel: boolean,
  liveTags: string[], bootstrapHosts: Record<string, string[]> | null,
  onResult: (result: LatencyResult) => void,
  context: common.Context | null = null): Promise<void> {
  if (entries.length === 0) {
    return;
  }
  const hosts: Record<string, string[]> = await resolveBootstrapHosts(entries, bootstrapHosts, viaTunnel);
  const cursor: TestCursor = new TestCursor();
  const limit: number = Math.min(STREAMING_CONCURRENCY, entries.length);
  const workers: Promise<void>[] = [];
  for (let w = 0; w < limit; w++) {
    workers.push((async (): Promise<void> => {
      while (cursor.value < entries.length) {
        const idx: number = cursor.value;
        cursor.value = idx + 1;
        const item: ConfigEntry = entries[idx];
        const res: LatencyResult =
          await testOne(item, viaTunnel, tagOf(liveTags, item.id), hosts, context);
        onResult(res);
      }
    })());
  }
  await Promise.all(workers);
}

// Legacy wrapper kept for callers passing a pre-built config.
export async function testAllConfig(entries: ConfigEntry[], configJson: string,
  geodataDir: string, onResult: (result: LatencyResult) => void): Promise<void> {
  const probes: OutboundProbeSpec[] = [];
  for (const entry of entries) {
    probes.push({ tag: entry.id, url: TEST_URL, timeoutMs: TEST_TIMEOUT_MS });
  }
  const batchRes: ProbeProfilesBatchResult = await probeProfiles(configJson, probes, geodataDir);
  for (let i = 0; i < entries.length; i++) {
    const entry: ConfigEntry = entries[i];
    const probe: OutboundProbeResult | null = i < batchRes.results.length ? batchRes.results[i] : null;
    const result: LatencyResult = {
      id: entry.id,
      ms: probeDelayMs(probe),
      via: VIA_HTTP,
      at: Date.now()
    };
    onResult(result);
  }
}

// Runs the whole list with a fixed number of workers; `onResult` fires as each
// probe finishes so the list can update while the rest are still in flight.
export async function testAll(entries: ConfigEntry[], viaTunnel: boolean, probeTags: string[],
  onResult: (result: LatencyResult) => void): Promise<void> {
  cancelProbes();
  const cursor: TestCursor = new TestCursor();
  const limit: number = entries.length < TEST_CONCURRENCY ? entries.length : TEST_CONCURRENCY;
  const workers: Promise<void>[] = [];
  for (let i = 0; i < limit; i++) {
    workers.push(drain(entries, cursor, viaTunnel, probeTags, onResult));
  }
  await Promise.all(workers);
}

// Ordering used by the node lists: measured nodes fastest first, then the ones
// that timed out or were never tested, keeping their previous relative order.
export function sortByLatency(entries: ConfigEntry[], results: LatencyResult[]): ConfigEntry[] {
  const measured: ConfigEntry[] = [];
  const rest: ConfigEntry[] = [];
  for (const entry of entries) {
    const ms: number = msOf(results, entry.id);
    if (ms >= 0) {
      measured.push(entry);
    } else {
      rest.push(entry);
    }
  }
  measured.sort((left: ConfigEntry, right: ConfigEntry) => {
    return msOf(results, left.id) - msOf(results, right.id);
  });
  const ordered: ConfigEntry[] = [];
  for (const item of measured) {
    ordered.push(item);
  }
  for (const item of rest) {
    ordered.push(item);
  }
  return ordered;
}

export function msOf(results: LatencyResult[], id: string): number {
  for (const item of results) {
    if (item.id === id) {
      return item.ms;
    }
  }
  return -1;
}

export function resultOf(results: LatencyResult[], id: string): LatencyResult | null {
  for (const item of results) {
    if (item.id === id) {
      return item;
    }
  }
  return null;
}






