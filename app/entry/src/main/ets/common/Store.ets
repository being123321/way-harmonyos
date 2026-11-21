import { fileIo as fs } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';
import { xrayDir, ensureXrayDir } from './Xray';

// One saved profile. `json` is the full Xray config produced by the offline
// importer (or pasted by the user), so connecting never needs the network.
//
// `subId` keeps the two kinds of profile apart: a node imported by hand has no
// subscription id, while every node that came out of a subscription carries the
// id of that subscription and is owned (and replaced) by it.
export interface ConfigEntry {
  id: string;
  name: string;
  type: string;
  server: string;
  json: string;
  createdAt: number;
  subId?: string;
}

export interface ConfigStore {
  selectedId: string;
  items: ConfigEntry[];
}

const STORE_FILE: string = 'configs.json';
const MAX_ENTRIES: number = 500;

export function subIdOf(entry: ConfigEntry): string {
  const value: Object | undefined = entry.subId as Object | undefined;
  if (value === undefined || value === null) {
    return '';
  }
  return entry.subId as string;
}

function storePath(context: common.Context): string {
  ensureXrayDir(context);
  return xrayDir(context) + '/' + STORE_FILE;
}

export function readStore(context: common.Context): ConfigStore {
  const path: string = storePath(context);
  try {
    if (fs.accessSync(path)) {
      const text: string = fs.readTextSync(path);
      const parsed: ConfigStore = JSON.parse(text) as ConfigStore;
      if (parsed.items === undefined || parsed.items === null) {
        parsed.items = [];
      }
      return parsed;
    }
  } catch (error) {
  }
  const empty: ConfigStore = { selectedId: '', items: [] };
  return empty;
}

export function writeStore(context: common.Context, store: ConfigStore): void {
  const path: string = storePath(context);
  const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, JSON.stringify(store));
  fs.closeSync(file);
}

export function findById(items: ConfigEntry[], id: string): ConfigEntry | null {
  for (const item of items) {
    if (item.id === id) {
      return item;
    }
  }
  return null;
}

function hasId(items: ConfigEntry[], id: string): boolean {
  return findById(items, id) !== null;
}

// Newest first, ids and duplicate payloads collapsed, then the list is capped.
function collapse(input: ConfigEntry[]): ConfigEntry[] {
  const seenIds: Set<string> = new Set();
  const seenJson: Set<string> = new Set();
  const items: ConfigEntry[] = [];
  for (const item of input) {
    if (seenIds.has(item.id) || seenJson.has(item.json)) {
      continue;
    }
    seenIds.add(item.id);
    seenJson.add(item.json);
    items.push(item);
    if (items.length >= MAX_ENTRIES) {
      break;
    }
  }
  return items;
}

export function addEntry(context: common.Context, entry: ConfigEntry): ConfigStore {
  const store: ConfigStore = readStore(context);
  const items: ConfigEntry[] = [entry];
  for (const item of store.items) {
    if (item.id !== entry.id) {
      items.push(item);
    }
  }
  store.items = items;
  if (store.selectedId.length === 0) {
    store.selectedId = entry.id;
  }
  writeStore(context, store);
  return store;
}

// Batch insert (multi-link paste). New entries first, then the existing ones.
export function addMany(context: common.Context, entries: ConfigEntry[]): ConfigStore {
  const store: ConfigStore = readStore(context);
  const merged: ConfigEntry[] = [];
  for (const entry of entries) {
    merged.push(entry);
  }
  for (const item of store.items) {
    merged.push(item);
  }
  const items: ConfigEntry[] = collapse(merged);
  store.items = items;
  if (!hasId(items, store.selectedId)) {
    store.selectedId = items.length > 0 ? items[0].id : '';
  }
  writeStore(context, store);
  return store;
}

// Swaps the whole node set of one subscription: the new list replaces the old
// one, nodes that were imported by hand are untouched.
export function replaceSubEntries(context: common.Context, subId: string,
  entries: ConfigEntry[]): ConfigStore {
  const store: ConfigStore = readStore(context);
  const previous: ConfigEntry | null = findById(store.items, store.selectedId);
  const merged: ConfigEntry[] = [];
  for (const entry of entries) {
    merged.push(entry);
  }
  for (const item of store.items) {
    if (subIdOf(item) !== subId) {
      merged.push(item);
    }
  }
  const items: ConfigEntry[] = collapse(merged);
  store.items = items;
  if (!hasId(items, store.selectedId)) {
    // Keep the user on the same node name when a refresh re-minted the ids.
    let restored: string = '';
    if (previous !== null && subIdOf(previous) === subId) {
      for (const item of items) {
        if (subIdOf(item) === subId && item.name === previous.name) {
          restored = item.id;
          break;
        }
      }
    }
    store.selectedId = restored.length > 0 ? restored : (items.length > 0 ? items[0].id : '');
  }
  writeStore(context, store);
  return store;
}

export function removeEntry(context: common.Context, id: string): ConfigStore {
  const store: ConfigStore = readStore(context);
  const items: ConfigEntry[] = [];
  for (const item of store.items) {
    if (item.id !== id) {
      items.push(item);
    }
  }
  store.items = items;
  if (store.selectedId === id) {
    store.selectedId = items.length > 0 ? items[0].id : '';
  }
  writeStore(context, store);
  return store;
}

export function removeEntriesOfSub(context: common.Context, subId: string): ConfigStore {
  const store: ConfigStore = readStore(context);
  const items: ConfigEntry[] = [];
  for (const item of store.items) {
    if (subIdOf(item) !== subId) {
      items.push(item);
    }
  }
  store.items = items;
  if (!hasId(items, store.selectedId)) {
    store.selectedId = items.length > 0 ? items[0].id : '';
  }
  writeStore(context, store);
  return store;
}

export function selectEntry(context: common.Context, id: string): ConfigStore {
  const store: ConfigStore = readStore(context);
  store.selectedId = id;
  writeStore(context, store);
  return store;
}

export function selectedEntry(context: common.Context): ConfigEntry | null {
  const store: ConfigStore = readStore(context);
  for (const item of store.items) {
    if (item.id === store.selectedId) {
      return item;
    }
  }
  if (store.items.length > 0) {
    return store.items[0];
  }
  return null;
}

export function manualEntries(items: ConfigEntry[]): ConfigEntry[] {
  const out: ConfigEntry[] = [];
  for (const item of items) {
    if (subIdOf(item).length === 0) {
      out.push(item);
    }
  }
  return out;
}

export function entriesOfSub(items: ConfigEntry[], subId: string): ConfigEntry[] {
  const out: ConfigEntry[] = [];
  for (const item of items) {
    if (subIdOf(item) === subId) {
      out.push(item);
    }
  }
  return out;
}

export function newId(): string {
  return Date.now().toString(36) + Math.floor(Math.random() * 100000).toString(36);
}

// `https://host/path?query` -> `host`, used as the default subscription name.
export function hostOf(url: string): string {
  const cleaned: string = url.replace('https://', '').replace('http://', '');
  const slash: number = cleaned.indexOf('/');
  const host: string = slash >= 0 ? cleaned.substring(0, slash) : cleaned;
  return host.length > 0 ? host : url;
}

// A subscription keeps the traffic quota the server reported in
// `subscription-userinfo`, next to the URL and the last refresh time.
export interface SubscriptionRecord {
  id: string;
  url: string;
  name: string;
  host: string;
  updatedAt: number;
  upload: number;
  download: number;
  total: number;
  expire: number;
  count: number;
}

const SUBS_FILE: string = 'subs.json';

function subsPath(context: common.Context): string {
  ensureXrayDir(context);
  return xrayDir(context) + '/' + SUBS_FILE;
}

export function readSubs(context: common.Context): SubscriptionRecord[] {
  const path: string = subsPath(context);
  try {
    if (fs.accessSync(path)) {
      const parsed: SubscriptionRecord[] = JSON.parse(fs.readTextSync(path)) as SubscriptionRecord[];
      if (parsed !== null && parsed !== undefined) {
        return parsed;
      }
    }
  } catch (error) {
  }
  return [];
}

export function writeSubs(context: common.Context, subs: SubscriptionRecord[]): void {
  const file = fs.openSync(subsPath(context), fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  fs.writeSync(file.fd, JSON.stringify(subs));
  fs.closeSync(file);
}

export function subById(context: common.Context, id: string): SubscriptionRecord | null {
  for (const item of readSubs(context)) {
    if (item.id === id) {
      return item;
    }
  }
  return null;
}

export function subByUrl(context: common.Context, url: string): SubscriptionRecord | null {
  for (const item of readSubs(context)) {
    if (item.url === url) {
      return item;
    }
  }
  return null;
}

// Insert or replace by id; a record with the same URL is replaced too so
// re-importing the same address never produces two rows.
export function saveSub(context: common.Context, record: SubscriptionRecord): SubscriptionRecord[] {
  const subs: SubscriptionRecord[] = readSubs(context);
  const next: SubscriptionRecord[] = [record];
  for (const item of subs) {
    if (item.id === record.id || item.url === record.url) {
      continue;
    }
    next.push(item);
  }
  writeSubs(context, next);
  return next;
}

// Rename and/or re-point a subscription in place, keeping its quota and id.
export function updateSub(context: common.Context, id: string, url: string,
  name: string): SubscriptionRecord[] {
  const subs: SubscriptionRecord[] = readSubs(context);
  const next: SubscriptionRecord[] = [];
  for (const item of subs) {
    if (item.id === id) {
      item.url = url;
      item.name = name.length > 0 ? name : hostOf(url);
      item.host = hostOf(url);
    }
    next.push(item);
  }
  writeSubs(context, next);
  return next;
}

export function removeSub(context: common.Context, id: string): SubscriptionRecord[] {
  const subs: SubscriptionRecord[] = readSubs(context);
  const next: SubscriptionRecord[] = [];
  for (const item of subs) {
    if (item.id !== id) {
      next.push(item);
    }
  }
  writeSubs(context, next);
  removeEntriesOfSub(context, id);
  return next;
}
