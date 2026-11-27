import type { common } from '@kit.AbilityKit';
import { SplitOptions, applyBootstrapHosts, applyBuiltInRules } from './Rules';
import { ConfigEntry, readStore } from './Store';
import { isHelperOutbound, outboundEndpoint, outboundTag, saveConfig } from './Xray';

// The tunnel config carries every saved node as an outbound, each tagged with
// its entry id, so the node list can ask the core to measure one node's real
// delay (`xray_core_probe_outbound_url`) without switching the tunnel.
//
// The selected node stays the default outbound (outbounds[0]) and keeps its
// routing rules, so the tunnel behaves exactly like the single-node config it
// replaces; the extra outbounds are only reachable through the probe API.

export interface TunnelNode {
  id: string;
  json: string;
}

export interface TunnelConfigResult {
  text: string;
  // Single-node variant, used to retry when the core refuses the big config.
  single: string;
  count: number;
  multi: boolean;
}

function outboundList(root: Record<string, Object>): Object[] {
  const value: Object | undefined = root['outbounds'] as Object | undefined;
  if (value === undefined || value === null) {
    return [];
  }
  return value as Object[];
}

// The proxy outbound of one saved node (the first non-helper with a server).
export function proxyOutbound(json: string): Record<string, Object> | null {
  try {
    const root: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    for (const item of outboundList(root)) {
      const outbound: Record<string, Object> = item as Record<string, Object>;
      if (isHelperOutbound(outbound)) {
        continue;
      }
      if (outboundEndpoint(outbound) === null) {
        continue;
      }
      return outbound;
    }
    return null;
  } catch (error) {
    return null;
  }
}

// Renames the node outbound to the entry id (and repoints routing rules that
// referenced the old tag) so the probe API can address it by id.
function retagProxy(json: string, entryId: string): string {
  let root: Record<string, Object>;
  try {
    root = JSON.parse(json) as Record<string, Object>;
  } catch (error) {
    return json;
  }
  let target: Record<string, Object> | null = null;
  for (const item of outboundList(root)) {
    const outbound: Record<string, Object> = item as Record<string, Object>;
    if (isHelperOutbound(outbound)) {
      continue;
    }
    if (outboundEndpoint(outbound) === null) {
      continue;
    }
    target = outbound;
    break;
  }
  if (target === null) {
    return json;
  }
  const oldTag: string = outboundTag(target);
  target['tag'] = entryId;
  if (oldTag.length > 0 && oldTag !== entryId) {
    const routingValue: Object | undefined = root['routing'] as Object | undefined;
    if (routingValue !== undefined && routingValue !== null) {
      const routing: Record<string, Object> = routingValue as Record<string, Object>;
      const rulesValue: Object | undefined = routing['rules'] as Object | undefined;
      const rules: Object[] = (rulesValue === undefined || rulesValue === null) ? [] : rulesValue as Object[];
      for (const item of rules) {
        const rule: Record<string, Object> = item as Record<string, Object>;
        if (rule['outboundTag'] === oldTag) {
          rule['outboundTag'] = entryId;
        }
      }
      routing['rules'] = rules;
      root['routing'] = routing;
    }
  }
  return JSON.stringify(root);
}

// Builds a lean single-node tunnel config (selected node + direct/block helpers)
// instead of loading all saved subscription nodes into the live VPN core.
// Speed tests run in an isolated short-lived probe core (`probeProfiles`), so
// keeping unused nodes out of the live core cuts steady-state RAM and prevents
// startup/reload stalls when a user imports 50-500 subscription nodes.
export function buildTunnelConfig(baseJson: string, selectedId: string, _nodes: TunnelNode[],
  options: SplitOptions): TunnelConfigResult {
  const tagged: string = retagProxy(baseJson, selectedId);
  const single: string = applyBuiltInRules(tagged, options);
  const result: TunnelConfigResult = { text: single, single: single, count: 1, multi: false };
  return result;
}

// Builds the lean single-node tunnel config and writes it as config.json.
export function buildAndSaveTunnel(context: common.Context, entry: ConfigEntry,
  options: SplitOptions): TunnelConfigResult {
  const tunnel: TunnelConfigResult = buildTunnelConfig(entry.json, entry.id, [], options);
  const text: string = applyBootstrapHosts(tunnel.text, options.bootstrapHosts);
  const single: string = applyBootstrapHosts(tunnel.single, options.bootstrapHosts);
  const result: TunnelConfigResult = {
    text: text, single: single, count: tunnel.count, multi: tunnel.multi
  };
  saveConfig(context, text);
  return result;
}
