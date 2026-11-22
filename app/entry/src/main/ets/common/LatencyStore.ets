import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

// Last delay measured per node, kept across page switches and app restarts.
//
// The value is deliberately not tied to where it was measured: the dashboard's
// expanded node list and the node page write here, and every node row reads
// from here, so a node tested once keeps showing its number instead of being
// probed again just because a list was opened.

export interface LatencyEntry {
  ms: number;
  via: string;
  at: number;
}

function cachePath(context: common.Context): string {
  return context.filesDir + '/latency.json';
}

export function readLatencyCache(context: common.Context): Map<string, LatencyEntry> {
  const cache: Map<string, LatencyEntry> = new Map<string, LatencyEntry>();
  try {
    const path: string = cachePath(context);
    if (!fs.accessSync(path)) {
      return cache;
    }
    const root: Record<string, Object> = JSON.parse(fs.readTextSync(path)) as Record<string, Object>;
    for (const key of Object.keys(root)) {
      const item: Record<string, Object> = root[key] as Record<string, Object>;
      if (item === undefined || item === null) {
        continue;
      }
      const entry: LatencyEntry = {
        ms: (item['ms'] as number) ?? -1,
        via: (item['via'] as string) ?? '',
        at: (item['at'] as number) ?? 0
      };
      cache.set(key, entry);
    }
  } catch (error) {
  }
  return cache;
}

// Serialised by hand: ArkTS rejects object literals typed only by Record.
export function writeLatencyCache(context: common.Context, cache: Map<string, LatencyEntry>): void {
  try {
    const parts: string[] = [];
    cache.forEach((value: LatencyEntry, key: string) => {
      parts.push(JSON.stringify(key) + ':{' +
        '"ms":' + Math.round(value.ms) + ',' +
        '"via":' + JSON.stringify(value.via) + ',' +
        '"at":' + Math.round(value.at) + '}');
    });
    const text: string = '{' + parts.join(',') + '}';
    const file = fs.openSync(cachePath(context),
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  } catch (error) {
  }
}

export function recordLatency(context: common.Context, id: string, ms: number, via: string): void {
  if (id.length === 0) {
    return;
  }
  const cache: Map<string, LatencyEntry> = readLatencyCache(context);
  const entry: LatencyEntry = { ms: ms, via: via, at: Date.now() };
  cache.set(id, entry);
  writeLatencyCache(context, cache);
}
