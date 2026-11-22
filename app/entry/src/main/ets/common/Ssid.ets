import { wifiManager } from '@kit.ConnectivityKit';
import { preferences } from '@kit.ArkData';
import type { common } from '@kit.AbilityKit';

// Per-Wi-Fi rules, mirroring the sing-box model: each SSID carries one action,
// "suspend" (drop the VPN) or "direct" (keep the tunnel, route everything
// direct). Leaving the Wi-Fi restores whatever mode was used before.

export const SSID_SUSPEND: string = 'suspend';
export const SSID_DIRECT: string = 'direct';

export interface SsidRule {
  ssid: string;
  action: string;
}

const KEY_RULES: string = 'ssidRules';
const KEY_ENABLED: string = 'onDemand';
const KEY_APPLIED: string = 'appliedSsidAction';
const KEY_SUSPENDED: string = 'ssidSuspended';

export async function currentSsid(): Promise<string> {
  try {
    const info: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
    const ssid: string = info.ssid ?? '';
    return ssid.replace(/^"|"$/g, '');
  } catch (error) {
    return '';
  }
}

function store(context: common.Context) {
  return preferences.getPreferencesSync(context, { name: 'way' });
}

export function ssidRules(context: common.Context): SsidRule[] {
  try {
    const raw: string = store(context).getSync(KEY_RULES, '[]') as string;
    const parsed: SsidRule[] = JSON.parse(raw) as SsidRule[];
    return parsed;
  } catch (error) {
    return [];
  }
}

function saveRules(context: common.Context, rules: SsidRule[]): void {
  try {
    const editor = store(context);
    editor.putSync(KEY_RULES, JSON.stringify(rules));
    editor.flush();
  } catch (error) {
  }
}

export function findRule(context: common.Context, ssid: string): SsidRule | null {
  if (ssid.length === 0) {
    return null;
  }
  for (const rule of ssidRules(context)) {
    if (rule.ssid === ssid) {
      return rule;
    }
  }
  return null;
}

export function setSsidRule(context: common.Context, ssid: string, action: string): SsidRule[] {
  if (ssid.length === 0) {
    return ssidRules(context);
  }
  const rules: SsidRule[] = ssidRules(context);
  const next: SsidRule[] = [{ ssid: ssid, action: action }];
  for (const rule of rules) {
    if (rule.ssid !== ssid) {
      next.push(rule);
    }
  }
  saveRules(context, next);
  return next;
}

export function removeSsidRule(context: common.Context, ssid: string): SsidRule[] {
  const next: SsidRule[] = [];
  for (const rule of ssidRules(context)) {
    if (rule.ssid !== ssid) {
      next.push(rule);
    }
  }
  saveRules(context, next);
  return next;
}

export function clearSsidRules(context: common.Context): void {
  saveRules(context, []);
}

export function onDemandEnabled(context: common.Context): boolean {
  try {
    return store(context).getSync(KEY_ENABLED, false) as boolean;
  } catch (error) {
    return false;
  }
}

export function appliedSsidAction(context: common.Context): string {
  try {
    return store(context).getSync(KEY_APPLIED, '') as string;
  } catch (error) {
    return '';
  }
}

export function setAppliedSsidAction(context: common.Context, action: string): void {
  try {
    const editor = store(context);
    editor.putSync(KEY_APPLIED, action);
    editor.flush();
  } catch (error) {
  }
}

export function ssidSuspended(context: common.Context): boolean {
  try {
    return store(context).getSync(KEY_SUSPENDED, false) as boolean;
  } catch (error) {
    return false;
  }
}

export function setSsidSuspended(context: common.Context, suspended: boolean): void {
  try {
    const editor = store(context);
    editor.putSync(KEY_SUSPENDED, suspended);
    editor.flush();
  } catch (error) {
  }
}

export function suspendOverride(context: common.Context): boolean {
  try {
    return store(context).getSync('suspendOverride', false) as boolean;
  } catch (error) {
    return false;
  }
}

export function setSuspendOverride(context: common.Context, value: boolean): void {
  setFlag(context, 'suspendOverride', value);
}

export function setFlag(context: common.Context, key: string, value: boolean): void {
  try {
    const editor = store(context);
    editor.putSync(key, value);
    editor.flush();
  } catch (error) {
  }
}


