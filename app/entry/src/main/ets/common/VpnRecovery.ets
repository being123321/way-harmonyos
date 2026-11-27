import { connection } from '@kit.NetworkKit';

export interface RecoveryBudget {
  windowAt: number;
  attempts: number;
  retryAt: number;
}

const RECOVERY_WINDOW_MS: number = 120000;
const RECOVERY_MAX_ATTEMPTS: number = 3;
const RECOVERY_BACKOFFS_MS: number[] = [5000, 15000, 60000];

export function emptyRecoveryBudget(): RecoveryBudget {
  return { windowAt: 0, attempts: 0, retryAt: 0 };
}

// Bounded crash-recovery budget matching sing-box-for-harmonyos:
// at most 3 restarts in any 120 s sliding window, backed off 5 s / 15 s / 60 s.
// Returns null when still in cooldown or when the budget is exhausted.
export function nextRecoveryAttempt(previous: RecoveryBudget, now: number): RecoveryBudget | null {
  const attempts: number = (previous.windowAt > 0 && now - previous.windowAt >= RECOVERY_WINDOW_MS)
    ? 0 : previous.attempts;
  if (now < previous.retryAt || attempts >= RECOVERY_MAX_ATTEMPTS) {
    return null;
  }
  return {
    windowAt: attempts === 0 ? now : previous.windowAt,
    attempts: attempts + 1,
    retryAt: now + RECOVERY_BACKOFFS_MS[attempts]
  };
}

export function isRecoveryBudgetExhausted(budget: RecoveryBudget, now: number): boolean {
  if (budget.windowAt > 0 && now - budget.windowAt >= RECOVERY_WINDOW_MS) {
    return false;
  }
  return budget.attempts >= RECOVERY_MAX_ATTEMPTS;
}

export type VpnChannelState = 'owned' | 'absent' | 'foreign' | 'unknown';

export interface VpnChannelSample {
  state: VpnChannelState;
  netId: number;
}

// Probes system VPN networks to distinguish our TUN from another VPN app taking
// over the slot (`foreign`). A failed inventory returns `unknown`, never falsely
// claiming the tunnel is gone.
export async function probeVpnChannel(ownedId: number, tunV4: string,
  tunV6: string): Promise<VpnChannelSample> {
  try {
    let vpnCount: number = 0;
    let matched: number = -1;
    let ambiguous: boolean = false;
    const handles: connection.NetHandle[] = await connection.getAllNets();
    for (const handle of handles) {
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(handle);
      if (!caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
        continue;
      }
      vpnCount++;
      const props: connection.ConnectionProperties = await connection.getConnectionProperties(handle);
      const addresses: string[] = [];
      for (const item of props.linkAddresses) {
        const rawAddr: string = item.address.address ?? '';
        const addr: string = rawAddr.split('/')[0].split('%')[0].trim().toLowerCase();
        if (addr.length > 0 && addr !== '0.0.0.0' && addr !== '::') {
          addresses.push(addr);
        }
      }
      if (addresses.length === 0) {
        ambiguous = true;
        continue;
      }
      const ours: boolean = addresses.includes(tunV4.toLowerCase()) || addresses.includes(tunV6.toLowerCase());
      if (ours) {
        if (ownedId === -1 || ownedId === handle.netId) {
          matched = handle.netId;
        } else {
          ambiguous = true;
        }
      }
    }
    if (vpnCount === 0) {
      return { state: 'absent', netId: -1 };
    }
    if (matched >= 0) {
      // As long as our own TUN interface address is actively present, treat the
      // channel as owned even if the OS exposes additional internal VPN handles.
      return { state: 'owned', netId: matched };
    }
    if (ambiguous) {
      return { state: 'unknown', netId: -1 };
    }
    return { state: 'foreign', netId: -1 };
  } catch (error) {
    return { state: 'unknown', netId: -1 };
  }
}
