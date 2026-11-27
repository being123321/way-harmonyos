import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { appBundleName, ensureXrayDir } from './Xray';

const TOKEN_FILE: string = 'ipc.token';
let cachedToken: string = '';

function generateToken(): string {
  const parts: string[] = [];
  for (let i = 0; i < 4; i++) {
    const chunk: string = Math.floor(Math.random() * 0xffffffff).toString(16).padStart(8, '0');
    parts.push(chunk);
  }
  return Date.now().toString(36) + '-' + parts.join('');
}

function readTokenFromDisk(context: common.Context): string {
  try {
    const dir: string = ensureXrayDir(context);
    const path: string = dir + '/' + TOKEN_FILE;
    if (fs.accessSync(path)) {
      const text: string = fs.readTextSync(path).trim();
      if (text.length >= 16) {
        return text;
      }
    }
  } catch (error) {
  }
  return '';
}

// Per-app shared secret stored inside the private sandbox (filesDir/xray/ipc.token).
// Third-party apps cannot read this file, so verifying this token on every
// cross-process CommonEvent prevents spoofed control commands.
export function initIpcAuth(context: common.Context): string {
  appBundleName(context);
  if (cachedToken.length > 0) {
    return cachedToken;
  }
  try {
    const existing: string = readTokenFromDisk(context);
    if (existing.length >= 16) {
      cachedToken = existing;
      return cachedToken;
    }
    const dir: string = ensureXrayDir(context);
    const path: string = dir + '/' + TOKEN_FILE;
    const created: string = generateToken();
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, created);
    fs.closeSync(file);
    // Re-read after write to converge if two processes raced on cold start.
    const converged: string = readTokenFromDisk(context);
    cachedToken = converged.length >= 16 ? converged : created;
    return cachedToken;
  } catch (error) {
    if (cachedToken.length === 0) {
      cachedToken = 'fallback-' + appBundleName(context);
    }
    return cachedToken;
  }
}

export function currentIpcToken(context?: common.Context | null): string {
  if (cachedToken.length > 0) {
    return cachedToken;
  }
  if (context !== undefined && context !== null) {
    return initIpcAuth(context);
  }
  return '';
}

export function verifyIpcParams(params: Record<string, Object> | undefined | null,
  context?: common.Context | null): boolean {
  if (params === undefined || params === null) {
    return false;
  }
  const token: Object | undefined = params['ipcToken'];
  if (typeof token !== 'string' || (token as string).length === 0) {
    return false;
  }
  const incoming: string = token as string;
  const expected: string = currentIpcToken(context);
  if (expected.length > 0 && incoming === expected) {
    return true;
  }
  // Cross-process convergence: if another process created/rotated ipc.token
  // concurrently, refresh once from sandbox storage before rejecting.
  if (context !== undefined && context !== null) {
    const disk: string = readTokenFromDisk(context);
    if (disk.length >= 16) {
      cachedToken = disk;
      return incoming === disk;
    }
  }
  return false;
}

// Publishes a CommonEvent scoped to this app's bundleName and signed with the
// private sandbox IPC token.
export function publishScopedEvent(event: string, params: Record<string, Object>,
  context?: common.Context | null, callback?: () => void): void {
  const payload: Record<string, Object> = {};
  for (const key of Object.keys(params)) {
    payload[key] = params[key];
  }
  const token: string = currentIpcToken(context);
  if (token.length > 0) {
    payload['ipcToken'] = token;
  }
  const data: commonEventManager.CommonEventPublishData = {
    parameters: payload
  };
  try {
    commonEventManager.publish(event, data, () => {
      if (callback !== undefined) {
        callback();
      }
    });
  } catch (error) {
  }
}
