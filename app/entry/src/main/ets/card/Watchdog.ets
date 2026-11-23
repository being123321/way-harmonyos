import { fileIo as fs } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { vpnExtension } from '@kit.NetworkKit';
import type { common, Want } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { cardLog } from './CardLog';

// Invisible desktop widget watchdog.
//
// HarmonyOS does NOT keep a FormExtensionAbility process resident: it is torn
// down about 10 s after the last lifecycle callback (the launcher wakes it for
// periodic updates, at best every 5 minutes via setFormNextRefreshTime). So this
// is an *independent recovery trigger*, not a 5 s daemon:
//   * onAddForm / onUpdateForm / each 5 s tick while the process is alive,
//   * and every launcher refresh (>= 5 min),
// it reads the persisted user intent + status.json and, if the VPN heartbeat is
// gone, starts the VPN extension again from the saved config.
//
// It deliberately does not import Xray/Store/Ssid: those pull in libentry.so or
// other UI-process modules, which the form sandbox should not load.

export const WATCHDOG_FORM_NAME: string = 'way_watchdog';

const FRESH_MS: number = 6000;
const MIN_ATTEMPT_GAP_MS: number = 10000;

interface TunnelSnapshot {
  state: string;
  updatedAt: number;
}

function xrayDir(context: common.Context): string {
  return context.filesDir + '/xray';
}

function readSnapshot(context: common.Context): TunnelSnapshot | null {
  const path: string = xrayDir(context) + '/status.json';
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    const parsed: Record<string, Object> = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
    const state: string = (parsed['state'] as string) ?? '';
    if (state.length === 0) {
      return null;
    }
    const updatedAt: number = Number(parsed['updatedAt'] ?? 0);
    const snapshot: TunnelSnapshot = { state: state, updatedAt: updatedAt };
    return snapshot;
  } catch (error) {
    return null;
  }
}

function hasSavedConfig(context: common.Context): boolean {
  const path: string = xrayDir(context) + '/config.json';
  try {
    return fs.accessSync(path) && fs.readTextSync(path).length > 0;
  } catch (error) {
    return false;
  }
}

export function buildWatchdogWant(context: common.Context): Want {
  const dir: string = xrayDir(context);
  const want: Want = {
    bundleName: 'com.way.app',
    abilityName: 'XrayVpnAbility',
    parameters: {
      'configPath': dir + '/config.json',
      'notify': true,
      'rebindOnNetChange': true,
      'geodataDir': dir + '/geodata',
      'taskNotificationId': -1,
      'nodeName': ''
    }
  };
  return want;
}

// Returns a short human-readable result; every path is also written to
// app.log by the caller, so `[card] watchdog ...` lines are the activity trace.
export async function checkAndRevive(context: common.Context): Promise<string> {
  const now: number = Date.now();
  const snapshot: TunnelSnapshot | null = readSnapshot(context);
  try {
    const store = preferences.getPreferencesSync(context, { name: 'way' });
    const active: boolean = store.getSync('vpnActive', false) as boolean;
    const userOff: boolean = store.getSync('userOff', false) as boolean;
    const suspended: boolean = store.getSync('ssidSuspended', false) as boolean;
    if (!active || userOff) {
      return 'intent off';
    }
    if (suspended) {
      return 'ssid suspended';
    }
    if (snapshot !== null && snapshot.updatedAt > 0 && now - snapshot.updatedAt < FRESH_MS &&
      snapshot.state !== 'stopped' && snapshot.state !== 'error') {
      return 'heartbeat fresh (' + snapshot.state + ')';
    }
    if (!hasSavedConfig(context)) {
      return 'no saved config';
    }
    const last: number = store.getSync('watchdogLastStart', 0) as number;
    if (now - last < MIN_ATTEMPT_GAP_MS) {
      return 'throttled';
    }
    store.putSync('watchdogLastStart', now);
    await store.flush();
  } catch (error) {
    return 'prefs unreadable';
  }
  try {
    await vpnExtension.startVpnExtensionAbility(buildWatchdogWant(context));
    const previous: string = snapshot === null ? 'missing' : snapshot.state;
    cardLog(context, 'watchdog relaunched vpn (previous=' + previous + ')');
    return 'relaunched vpn';
  } catch (error) {
    const err = error as BusinessError;
    const reason: string = err.message ?? 'unknown';
    cardLog(context, 'watchdog relaunch failed: ' + reason);
    return 'relaunch failed: ' + reason;
  }
}
