import type { common } from '@kit.AbilityKit';
import { fetchSubscription, importText, ImportResult, SubscriptionUserInfo } from './Import';
import {
  ConfigEntry, SubscriptionRecord, hostOf, newId, replaceSubEntries, saveSub, subByUrl
} from './Store';

// Refreshes one subscription: fetch, split whatever the server returned into
// nodes, replace exactly this subscription's nodes (hand-imported nodes are
// left alone) and remember upload/download/total/expire for the traffic bar.
export async function refreshSubscription(context: common.Context,
  record: SubscriptionRecord): Promise<SubscriptionRecord> {
  const fetched = await fetchSubscription(record.url);
  const result: ImportResult = importText(fetched.body);
  if (result.entries.length === 0) {
    throw new Error('订阅内容里没有可识别的节点');
  }
  const entries: ConfigEntry[] = [];
  for (const item of result.entries) {
    item.subId = record.id;
    entries.push(item);
  }
  replaceSubEntries(context, record.id, entries);
  const info: SubscriptionUserInfo | null = fetched.userinfo;
  const next: SubscriptionRecord = {
    id: record.id,
    url: record.url,
    name: record.name.length > 0 ? record.name : hostOf(record.url),
    host: hostOf(record.url),
    updatedAt: Date.now(),
    upload: info === null ? 0 : info.upload,
    download: info === null ? 0 : info.download,
    total: info === null ? 0 : info.total,
    expire: info === null ? 0 : info.expire,
    count: entries.length
  };
  saveSub(context, next);
  return next;
}

// Builds the record for a subscription that is being added; re-adding the same
// URL keeps the previous id (and therefore replaces its nodes instead of
// creating a second subscription with the same content).
export function prepareSubscription(context: common.Context, url: string,
  name: string): SubscriptionRecord {
  const existing: SubscriptionRecord | null = subByUrl(context, url);
  const trimmed: string = name.trim();
  const record: SubscriptionRecord = {
    id: existing === null ? newId() : existing.id,
    url: url,
    name: trimmed.length > 0 ? trimmed : (existing === null ? hostOf(url) : existing.name),
    host: hostOf(url),
    updatedAt: 0,
    upload: 0,
    download: 0,
    total: 0,
    expire: 0,
    count: 0
  };
  return record;
}

export function formatQuota(used: number, total: number): string {
  if (total <= 0) {
    return formatBytes(used) + ' / 未知';
  }
  const left: number = total > used ? total - used : 0;
  return formatBytes(used) + ' / ' + formatBytes(total) + '（剩 ' + formatBytes(left) + '）';
}

export function formatExpire(expire: number): string {
  if (expire <= 0) {
    return '长期';
  }
  const date = new Date(expire * 1000);
  const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
  return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate());
}

function formatBytes(value: number): string {
  if (value < 1024) {
    return value.toFixed(0) + ' B';
  }
  if (value < 1024 * 1024) {
    return (value / 1024).toFixed(1) + ' KB';
  }
  if (value < 1024 * 1024 * 1024) {
    return (value / (1024 * 1024)).toFixed(1) + ' MB';
  }
  return (value / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}
