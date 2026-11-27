import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { ensureXrayDir } from './Xray';
import { appLog } from './AppLog';

export const APP_VERSION_NAME: string = '0.10.21';
export const CORE_VERSION_NAME: string = '0.10.1';
export const CORE_ID_RUST: string = 'xray-rust';
export const CORE_ID_UPSTREAM: string = 'xray-core';

export const PROJECT_REPO_URL: string = 'https://github.com/being123321/way-harmonyos';
export const CORE_RUST_REPO_URL: string = 'https://github.com/aimalygin/xray-rust';
export const CORE_UPSTREAM_REPO_URL: string = 'https://github.com/XTLS/Xray-core';
export const KERNELS_MANIFEST_URL: string =
  'https://github.com/being123321/way-harmonyos/releases/download/kernels-latest/kernels-manifest.json';

export const DISCLAIMER_TEXT: string =
  'way 是非官方的 HarmonyOS 代理客户端，内核基于开源项目 xray-rust（兼容 Xray 配置协议），并支持对接原版 XTLS/Xray-core GitHub 自动构建内核，未获任何上游项目官方背书。本软件仅用于个人学习、网络调试与技术研究，请严格遵守所在国家与地区的法律法规，切勿用于任何违法违规用途。所有节点与订阅配置仅保存在本机沙箱内，不会上传至第三方服务器。';

export interface ReleaseInfo {
  tag: string;
  name: string;
  url: string;
  publishedAt: string;
  notes: string;
  hasUpdate: boolean;
}

export interface KernelManifestEntry {
  id: string;
  version: string;
  sha256: string;
  assetUrl: string;
  builtAt: string;
}

export interface UpdateCheckResult {
  checkedAt: number;
  app: ReleaseInfo | null;
  coreRust: ReleaseInfo | null;
  coreUpstream: ReleaseInfo | null;
  manifest: KernelManifestEntry[];
  error: string;
}

export interface CoreUpdateState {
  activeCore: string;
  activeVersion: string;
  previousCore: string;
  previousVersion: string;
  pendingCore: string;
  pendingVersion: string;
  lastGoodAt: number;
  lastRollbackAt: number;
  lastRollbackReason: string;
}

const CORE_STATE_FILE: string = 'core-state.json';

function normalizeVersion(raw: string): number[] {
  const cleaned: string = raw.trim().replace(/^[vV]/, '').split('-')[0];
  const parts: string[] = cleaned.split('.');
  const nums: number[] = [];
  for (const p of parts) {
    const n: number = parseInt(p, 10);
    nums.push(isNaN(n) ? 0 : n);
  }
  while (nums.length < 3) {
    nums.push(0);
  }
  return nums;
}

export function isNewerVersion(remoteTag: string, currentVersion: string): boolean {
  const r: number[] = normalizeVersion(remoteTag);
  const c: number[] = normalizeVersion(currentVersion);
  const len: number = Math.max(r.length, c.length);
  for (let i = 0; i < len; i++) {
    const rv: number = i < r.length ? r[i] : 0;
    const cv: number = i < c.length ? c[i] : 0;
    if (rv !== cv) {
      return rv > cv;
    }
  }
  return false;
}

async function fetchLatestRelease(ownerRepo: string, currentVersion: string): Promise<ReleaseInfo | null> {
  const client: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await client.request(
      'https://api.github.com/repos/' + ownerRepo + '/releases/latest',
      {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'way-harmonyos/' + APP_VERSION_NAME
        },
        connectTimeout: 8000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      }
    );
    if (resp.responseCode === 404) {
      return await fetchLatestTag(ownerRepo, currentVersion);
    }
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      return null;
    }
    const text: string = typeof resp.result === 'string' ? resp.result : '';
    const doc: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const tag: string = (doc['tag_name'] as string) ?? '';
    if (tag.length === 0) {
      return null;
    }
    const name: string = ((doc['name'] as string) ?? tag).trim();
    const url: string = (doc['html_url'] as string) ?? ('https://github.com/' + ownerRepo + '/releases');
    const publishedAt: string = ((doc['published_at'] as string) ?? '').substring(0, 10);
    const body: string = ((doc['body'] as string) ?? '').trim();
    const notes: string = body.length > 240 ? (body.substring(0, 240) + '…') : body;
    return {
      tag: tag,
      name: name,
      url: url,
      publishedAt: publishedAt,
      notes: notes,
      hasUpdate: isNewerVersion(tag, currentVersion)
    };
  } catch (error) {
    return null;
  } finally {
    try {
      client.destroy();
    } catch (error) {
    }
  }
}

async function fetchLatestTag(ownerRepo: string, currentVersion: string): Promise<ReleaseInfo | null> {
  const client: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await client.request(
      'https://api.github.com/repos/' + ownerRepo + '/tags?per_page=1',
      {
        method: http.RequestMethod.GET,
        header: {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'way-harmonyos/' + APP_VERSION_NAME
        },
        connectTimeout: 8000,
        readTimeout: 10000,
        expectDataType: http.HttpDataType.STRING
      }
    );
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      return null;
    }
    const text: string = typeof resp.result === 'string' ? resp.result : '';
    const arr: Object[] = JSON.parse(text) as Object[];
    if (arr.length === 0) {
      return null;
    }
    const first: Record<string, Object> = arr[0] as Record<string, Object>;
    const tag: string = (first['name'] as string) ?? '';
    if (tag.length === 0) {
      return null;
    }
    return {
      tag: tag,
      name: tag,
      url: 'https://github.com/' + ownerRepo + '/tags',
      publishedAt: '',
      notes: '',
      hasUpdate: isNewerVersion(tag, currentVersion)
    };
  } catch (error) {
    return null;
  } finally {
    try {
      client.destroy();
    } catch (error) {
    }
  }
}

async function fetchKernelsManifest(): Promise<KernelManifestEntry[]> {
  const client: http.HttpRequest = http.createHttp();
  try {
    const resp: http.HttpResponse = await client.request(KERNELS_MANIFEST_URL, {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'way-harmonyos/' + APP_VERSION_NAME },
      connectTimeout: 6000,
      readTimeout: 8000,
      expectDataType: http.HttpDataType.STRING
    });
    if (resp.responseCode < 200 || resp.responseCode >= 300) {
      return [];
    }
    const text: string = typeof resp.result === 'string' ? resp.result : '';
    const doc: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
    const arr: Object[] = (doc['kernels'] as Object[]) ?? [];
    const list: KernelManifestEntry[] = [];
    for (const item of arr) {
      const m: Record<string, Object> = item as Record<string, Object>;
      const id: string = (m['id'] as string) ?? '';
      if (id.length === 0) {
        continue;
      }
      list.push({
        id: id,
        version: (m['version'] as string) ?? '',
        sha256: (m['sha256'] as string) ?? '',
        assetUrl: (m['assetUrl'] as string) ?? '',
        builtAt: (m['builtAt'] as string) ?? ''
      });
    }
    return list;
  } catch (error) {
    return [];
  } finally {
    try {
      client.destroy();
    } catch (error) {
    }
  }
}

export async function checkAllUpdates(): Promise<UpdateCheckResult> {
  const checkedAt: number = Date.now();
  try {
    const appRelPromise = fetchLatestRelease('being123321/way-harmonyos', APP_VERSION_NAME);
    const rustRelPromise = fetchLatestRelease('aimalygin/xray-rust', CORE_VERSION_NAME);
    const upstreamRelPromise = fetchLatestRelease('XTLS/Xray-core', '0.0.0');
    const manifestPromise = fetchKernelsManifest();
    const appRel: ReleaseInfo | null = await appRelPromise;
    const rustRel: ReleaseInfo | null = await rustRelPromise;
    const upstreamRel: ReleaseInfo | null = await upstreamRelPromise;
    const manifest: KernelManifestEntry[] = await manifestPromise;
    if (appRel === null && rustRel === null && upstreamRel === null) {
      return {
        checkedAt: checkedAt,
        app: null,
        coreRust: null,
        coreUpstream: null,
        manifest: [],
        error: '无法连接 GitHub，请开启代理或检查网络后重试'
      };
    }
    return {
      checkedAt: checkedAt,
      app: appRel,
      coreRust: rustRel,
      coreUpstream: upstreamRel,
      manifest: manifest,
      error: ''
    };
  } catch (error) {
    return {
      checkedAt: checkedAt,
      app: null,
      coreRust: null,
      coreUpstream: null,
      manifest: [],
      error: '检查更新失败，请稍后重试'
    };
  }
}

// ==================== Dual-Core State & Automatic Rollback ====================

export function defaultCoreState(): CoreUpdateState {
  return {
    activeCore: CORE_ID_RUST,
    activeVersion: CORE_VERSION_NAME,
    previousCore: CORE_ID_RUST,
    previousVersion: CORE_VERSION_NAME,
    pendingCore: '',
    pendingVersion: '',
    lastGoodAt: Date.now(),
    lastRollbackAt: 0,
    lastRollbackReason: ''
  };
}

export function readCoreState(context: common.Context): CoreUpdateState {
  try {
    const path: string = ensureXrayDir(context) + '/' + CORE_STATE_FILE;
    if (!fs.accessSync(path)) {
      const init: CoreUpdateState = defaultCoreState();
      writeCoreState(context, init);
      return init;
    }
    const text: string = fs.readTextSync(path);
    const parsed: CoreUpdateState = JSON.parse(text) as CoreUpdateState;
    if (!parsed.activeCore || !parsed.activeVersion) {
      return defaultCoreState();
    }
    return parsed;
  } catch (error) {
    return defaultCoreState();
  }
}

export function writeCoreState(context: common.Context, state: CoreUpdateState): void {
  try {
    const path: string = ensureXrayDir(context) + '/' + CORE_STATE_FILE;
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, JSON.stringify(state));
    fs.closeSync(file);
  } catch (error) {
  }
}

export function isCoreBundled(coreId: string): boolean {
  // Currently xray-rust is statically bundled in libentry.so; upstream xray-core
  // becomes selectable automatically once the GitHub Actions dual-core build
  // ships its native artifact into the package.
  return coreId === CORE_ID_RUST;
}

export function markCoreHealthy(context: common.Context): CoreUpdateState {
  const state: CoreUpdateState = readCoreState(context);
  if (state.pendingCore.length > 0) {
    state.activeCore = state.pendingCore;
    state.activeVersion = state.pendingVersion;
    state.pendingCore = '';
    state.pendingVersion = '';
  }
  state.lastGoodAt = Date.now();
  writeCoreState(context, state);
  try {
    const dir: string = ensureXrayDir(context);
    const cfgPath: string = dir + '/config.json';
    const bakPath: string = dir + '/config.lastgood.json';
    if (fs.accessSync(cfgPath)) {
      const content: string = fs.readTextSync(cfgPath);
      if (content.length > 0) {
        const f = fs.openSync(bakPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, content);
        fs.closeSync(f);
      }
    }
  } catch (error) {
  }
  return state;
}

export function stageCoreUpdate(context: common.Context, candidateCore: string,
  candidateVersion: string): CoreUpdateState {
  const state: CoreUpdateState = readCoreState(context);
  state.previousCore = state.activeCore;
  state.previousVersion = state.activeVersion;
  state.pendingCore = candidateCore;
  state.pendingVersion = candidateVersion;
  writeCoreState(context, state);
  appLog(context, 'core', 'staged core update: ' + candidateCore + ' ' + candidateVersion +
    ' (rollback target: ' + state.previousCore + ' ' + state.previousVersion + ')');
  return state;
}

export function rollbackCoreOnError(context: common.Context, reason: string): CoreUpdateState {
  const state: CoreUpdateState = readCoreState(context);
  const failedLabel: string = state.pendingCore.length > 0
    ? (state.pendingCore + ' ' + state.pendingVersion)
    : (state.activeCore + ' ' + state.activeVersion);
  state.activeCore = state.previousCore.length > 0 ? state.previousCore : CORE_ID_RUST;
  state.activeVersion = state.previousVersion.length > 0 ? state.previousVersion : CORE_VERSION_NAME;
  state.pendingCore = '';
  state.pendingVersion = '';
  state.lastRollbackAt = Date.now();
  state.lastRollbackReason = '切换/更新 ' + failedLabel + ' 失败（' + reason + '），已自动回退至 ' +
    state.activeCore + ' ' + state.activeVersion;
  writeCoreState(context, state);
  try {
    const dir: string = ensureXrayDir(context);
    const cfgPath: string = dir + '/config.json';
    const bakPath: string = dir + '/config.lastgood.json';
    if (fs.accessSync(bakPath)) {
      const backup: string = fs.readTextSync(bakPath);
      if (backup.length > 0) {
        const f = fs.openSync(cfgPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, backup);
        fs.closeSync(f);
      }
    }
  } catch (error) {
  }
  appLog(context, 'core', state.lastRollbackReason);
  return state;
}
