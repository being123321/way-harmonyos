import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';
import { ensureXrayDir, xrayDir } from './Xray';

// GeoSite/GeoIP databases feeding the built-in routing rules. Downloaded at
// runtime (the HAP does not bundle ~15 MB of rule data) and refreshed in the
// background when older than REFRESH_MS.
export interface GeodataMeta {
  updatedAt: number;
  geositeBytes: number;
  geoipBytes: number;
  source: string;
}

const REFRESH_MS: number = 7 * 24 * 3600 * 1000;
const GEOSITE_MIN_BYTES: number = 200 * 1024;
const GEOIP_MIN_BYTES: number = 50 * 1024;

export interface GeodataPreset {
  id: string;
  name: string;
  endpoints: string[][];
}

// Selectable rule-data sources. jsDelivr endpoints come first for the China
// default because GitHub release assets are often unreachable before the tunnel
// is up; each preset keeps its own ordered fallbacks.
export const GEODATA_PRESETS: GeodataPreset[] = [
  {
    id: 'loyalsoldier',
    name: 'Loyalsoldier',
    endpoints: [
      [
        'https://gcore.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat',
        'https://gcore.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat'
      ],
      [
        'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat',
        'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat'
      ],
      [
        'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat',
        'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
      ]
    ]
  },
  {
    id: 'metacubex',
    name: 'MetaCubeX',
    endpoints: [
      [
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
        'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat'
      ]
    ]
  }
];

const GEO_SOURCE_KEY: string = 'geoSource';

export function selectedPreset(context: common.Context): GeodataPreset {
  let id: string = 'loyalsoldier';
  try {
    const store = preferences.getPreferencesSync(context, { name: 'way' });
    id = store.getSync(GEO_SOURCE_KEY, 'loyalsoldier') as string;
  } catch (error) {
  }
  for (const preset of GEODATA_PRESETS) {
    if (preset.id === id) {
      return preset;
    }
  }
  return GEODATA_PRESETS[0];
}

export function selectPreset(context: common.Context, id: string): GeodataPreset {
  try {
    const store = preferences.getPreferencesSync(context, { name: 'way' });
    store.putSync(GEO_SOURCE_KEY, id);
    store.flush();
  } catch (error) {
  }
  for (const preset of GEODATA_PRESETS) {
    if (preset.id === id) {
      return preset;
    }
  }
  return GEODATA_PRESETS[0];
}

const SOURCES: string[][] = [
  [
    'https://gcore.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat',
    'https://gcore.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat'
  ],
  [
    'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat',
    'https://fastly.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat'
  ],
  [
    'https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat',
    'https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat'
  ],
  [
    'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat',
    'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat'
  ]
];

export function geodataDir(context: common.Context): string {
  return xrayDir(context) + '/geodata';
}

function ensureGeodataDir(context: common.Context): string {
  ensureXrayDir(context);
  const dir: string = geodataDir(context);
  if (!fs.accessSync(dir)) {
    fs.mkdirSync(dir, true);
  }
  return dir;
}

function fileSize(path: string): number {
  try {
    if (!fs.accessSync(path)) {
      return 0;
    }
    return fs.statSync(path).size;
  } catch (error) {
    return 0;
  }
}

export function geodataReady(context: common.Context): boolean {
  const dir: string = geodataDir(context);
  return fileSize(dir + '/geosite.dat') >= GEOSITE_MIN_BYTES &&
    fileSize(dir + '/geoip.dat') >= GEOIP_MIN_BYTES;
}

export function readGeodataMeta(context: common.Context): GeodataMeta | null {
  const path: string = geodataDir(context) + '/meta.json';
  try {
    if (!fs.accessSync(path)) {
      return null;
    }
    return JSON.parse(fs.readTextSync(path)) as GeodataMeta;
  } catch (error) {
    return null;
  }
}

export function geodataStale(context: common.Context): boolean {
  const meta: GeodataMeta | null = readGeodataMeta(context);
  if (meta === null) {
    return true;
  }
  return Date.now() - meta.updatedAt > REFRESH_MS;
}

async function download(url: string, target: string): Promise<number> {
  const request = http.createHttp();
  try {
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: { 'User-Agent': 'way-harmony/0.10.1', 'Accept': '*/*' },
      connectTimeout: 20000,
      readTimeout: 60000,
      expectDataType: http.HttpDataType.ARRAY_BUFFER
    };
    const response: http.HttpResponse = await request.request(url, options);
    if (response.responseCode !== 200) {
      throw new Error('HTTP ' + response.responseCode);
    }
    const body: ArrayBuffer = response.result as ArrayBuffer;
    if (body === undefined || body === null || body.byteLength === 0) {
      throw new Error('空响应');
    }
    const tmp: string = target + '.tmp';
    const file = fs.openSync(tmp, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, body);
    fs.closeSync(file);
    if (fs.accessSync(target)) {
      fs.unlinkSync(target);
    }
    fs.renameSync(tmp, target);
    return body.byteLength;
  } finally {
    request.destroy();
  }
}

// Tries each source in order and keeps the previous files if every attempt
// fails, so a bad network never leaves the app without rule data.
export async function updateGeodata(context: common.Context): Promise<GeodataMeta> {
  const dir: string = ensureGeodataDir(context);
  const geosite: string = dir + '/geosite.dat';
  const geoip: string = dir + '/geoip.dat';
  let lastError: string = '更新失败';
  for (const source of selectedPreset(context).endpoints) {
    try {
      const geositeBytes: number = await download(source[0], geosite);
      if (geositeBytes < GEOSITE_MIN_BYTES) {
        throw new Error('geosite.dat 体积异常: ' + geositeBytes);
      }
      const geoipBytes: number = await download(source[1], geoip);
      if (geoipBytes < GEOIP_MIN_BYTES) {
        throw new Error('geoip.dat 体积异常: ' + geoipBytes);
      }
      const meta: GeodataMeta = {
        updatedAt: Date.now(),
        geositeBytes: geositeBytes,
        geoipBytes: geoipBytes,
        source: source[0]
      };
      const file = fs.openSync(dir + '/meta.json',
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(meta));
      fs.closeSync(file);
      return meta;
    } catch (error) {
      const err = error as Error;
      lastError = err.message ?? '更新失败';
    }
  }
  throw new Error(lastError);
}

