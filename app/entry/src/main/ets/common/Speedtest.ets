import { socket } from '@kit.NetworkKit';
import { ConfigEntry } from './Store';
import { NodeEndpoint, cancelProbes, nodeEndpoint, probeOutbound } from './Xray';
import { udpQuicLatency } from './Latency';

// Delay test, modelled on v2rayNG:
//   * VPN connected -> the core itself performs an HTTP(S) GET through the
//     node's outbound (xray_core_probe_outbound_url), which is the only way to
//     measure "through the proxy" here: protectProcessNet keeps this process
//     outside the tunnel, so the app's own HTTP would just be a direct request.
//     Nodes that are not part of the running config fall back to a direct probe.
//   * not connected -> a TCP handshake (or a UDP/QUIC probe for UDP-only nodes
//     such as Hysteria2) to the node itself, since there is no tunnel to use;
//   * four probes at a time, four seconds each, results ordered by delay.
export const TEST_CONCURRENCY: number = 4;
export const TEST_TIMEOUT_MS: number = 6000;

// Plain HTTP on purpose (mihomo/FlClash's default url-test target): a 204
// over TLS costs two extra round trips that have nothing to do with how the
// node relays traffic, and it made every node look 300-600 ms slower than the
// number users compare against in other clients.
// Anycast IP, no DNS at all: resolving the probe host locally (UDP or DoH)
// hands the node a China-optimised address, which an overseas node then has to
// reach the slow way. A literal needs no resolver on either side.
const TEST_URL: string = 'http://1.1.1.1/';
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
        address: { address: host, port: port, family: 1 },
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
  return connected ? Date.now() - start : -1;
}

export async function testOne(entry: ConfigEntry, viaTunnel: boolean,
  tag: string): Promise<LatencyResult> {
  const at: number = Date.now();
  try {
    if (viaTunnel) {
      if (tag.length === 0) {
        // Connected, but this node is not part of the running config (added or
        // edited after connecting). A direct TCP probe here would resolve the
        // server through the tunnel's fake-IP DNS and "connect" to a local
        // address in a few ms — the row then claims 3 ms. Report "untested"
        // instead; the next connect carries the node and the probe works.
        const untested: LatencyResult = { id: entry.id, ms: -1, via: VIA_NONE, at: at };
        return untested;
      }
      const probe = await probeOutbound(TEST_URL, TEST_TIMEOUT_MS, tag);
      if (probe.status === 0) {
        // failureKind 0 with a delay is a 2xx/3xx answer; every other kind is
        // timeout/transport/TLS/HTTP-status, reported as a failed probe.
        const ok: boolean = probe.failureKind === 0 && probe.delayMs > 0;
        const result: LatencyResult = { id: entry.id, ms: ok ? probe.delayMs : -1, via: VIA_HTTP, at: at };
        return result;
      }
      const failed: LatencyResult = { id: entry.id, ms: -1, via: VIA_HTTP, at: at };
      return failed;
    }
    const endpoint: NodeEndpoint | null = nodeEndpoint(entry.json);
    if (endpoint === null) {
      const missing: LatencyResult = { id: entry.id, ms: -1, via: VIA_NONE, at: at };
      return missing;
    }
    const udp: boolean = isUdpNode(entry);
    const ms: number = udp
      ? await udpQuicLatency(endpoint.host, endpoint.port, TEST_TIMEOUT_MS)
      : await tcpLatency(endpoint.host, endpoint.port, TEST_TIMEOUT_MS);
    const result: LatencyResult = { id: entry.id, ms: ms, via: udp ? VIA_UDP : VIA_TCP, at: at };
    return result;
  } catch (error) {
    // A socket that cannot even be constructed must not abort the whole batch.
    const failed: LatencyResult = { id: entry.id, ms: -1, via: VIA_NONE, at: at };
    return failed;
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






