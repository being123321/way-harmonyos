import { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { Insets, cancelProbes, nodeTypeLabel, pageInsets, tunnelOutboundTags, tunnelUp } from '../common/Xray';
import { LatencyEntry, readLatencyCache, recordLatency } from '../common/LatencyStore';
import {
  ConfigEntry, ConfigStore, SubscriptionRecord, entriesOfSub, manualEntries, readStore, readSubs,
  removeEntry, removeSub, selectEntry, updateSub
} from '../common/Store';
import { formatExpire, formatQuota, refreshSubscription } from '../common/Subscription';
import {
  LatencyResult, TEST_CONCURRENCY, TEST_TIMEOUT_MS, latencyText, msOf, resultOf, sortByLatency, testAll,
  testOne, viaText
} from '../common/Speedtest';

const TAB_NODES: number = 0;
const TAB_SUBS: number = 1;

// Two lists that mirror v2rayNG's split: nodes that were imported by hand and
// subscriptions that own their own node set. Nothing is mixed in one list, so a
// refresh can never overwrite a hand-picked profile.
@Entry
@Component
struct Configs {
  @State items: ConfigEntry[] = [];
  @State selectedId: string = '';
  @State subs: SubscriptionRecord[] = [];
  @State tab: number = TAB_NODES;
  @State insets: Insets = { top: 0, bottom: 0 };
  @State latency: LatencyResult[] = [];
  @State testing: boolean = false;
  @State testDone: number = 0;
  @State testTotal: number = 0;
  @State viaTunnel: boolean = false;
  // Outbound tags of the running tunnel config; a node in this list can be
  // measured by the core itself (real delay through the proxy).
  @State probeTags: string[] = [];
  @State expandedId: string = '';
  @State editingId: string = '';
  @State editName: string = '';
  @State editUrl: string = '';
  @State busySubId: string = '';

  private ctx: common.UIAbilityContext | null = null;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
    this.refresh();
    this.loadLatency();
  }

  onPageShow(): void {
    this.refresh();
    this.loadLatency();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    // Leaving the page: stop the probes still in flight for this list.
    cancelProbes();
  }

  private refresh(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const store: ConfigStore = readStore(context);
    this.items = store.items;
    this.selectedId = store.selectedId;
    this.subs = readSubs(context);
    if (!this.testing) {
      this.viaTunnel = tunnelUp(context);
      this.probeTags = this.viaTunnel ? tunnelOutboundTags(context) : [];
    }
  }

  private findSub(id: string): SubscriptionRecord | null {
    for (const item of this.subs) {
      if (item.id === id) {
        return item;
      }
    }
    return null;
  }

  // The card is built from a @Builder parameter, and ArkUI keeps that parameter
  // frozen across re-renders (only `this.*` state is observed). Every mutable
  // field is therefore read back through these helpers, otherwise a refresh
  // showed the new node count next to the old quota/timestamp.
  private subName(id: string): string {
    const record: SubscriptionRecord | null = this.findSub(id);
    return record === null ? '' : record.name;
  }

  private subUrlText(id: string): string {
    const record: SubscriptionRecord | null = this.findSub(id);
    return record === null ? '' : record.url;
  }

  private subQuota(id: string): string {
    const record: SubscriptionRecord | null = this.findSub(id);
    if (record === null) {
      return '';
    }
    return formatQuota(record.upload + record.download, record.total);
  }

  private subUsed(id: string): number {
    const record: SubscriptionRecord | null = this.findSub(id);
    return record === null ? 0 : record.upload + record.download;
  }

  private subTotal(id: string): number {
    const record: SubscriptionRecord | null = this.findSub(id);
    if (record === null || record.total <= 0) {
      return 1;
    }
    return record.total;
  }

  private subExpire(id: string): string {
    const record: SubscriptionRecord | null = this.findSub(id);
    return record === null ? '' : formatExpire(record.expire);
  }

  private subUpdated(id: string): string {
    const record: SubscriptionRecord | null = this.findSub(id);
    if (record === null || record.updatedAt <= 0) {
      return '从未';
    }
    return formatTimeShort(record.updatedAt);
  }

  private manualCount(): number {
    return manualEntries(this.items).length;
  }

  private manualList(): ConfigEntry[] {
    return sortByLatency(manualEntries(this.items), this.latency);
  }

  private subNodes(subId: string): ConfigEntry[] {
    return sortByLatency(entriesOfSub(this.items, subId), this.latency);
  }

  private subNodeCount(subId: string): number {
    return entriesOfSub(this.items, subId).length;
  }

  private allSubNodes(): ConfigEntry[] {
    const all: ConfigEntry[] = [];
    for (const sub of this.subs) {
      for (const entry of entriesOfSub(this.items, sub.id)) {
        all.push(entry);
      }
    }
    return all;
  }

  private add(mode: number): void {
    const params: Record<string, Object> = { 'mode': mode };
    router.pushUrl({ url: 'pages/AddConfig', params: params }).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开添加页失败: ' + error.message });
    });
  }

  private choose(entry: ConfigEntry): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    selectEntry(context, entry.id);
    this.selectedId = entry.id;
    router.back();
  }

  private confirmDeleteNode(entry: ConfigEntry): void {
    AlertDialog.show({
      title: '删除节点',
      message: '确定删除「' + entry.name + '」吗？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#FF5C7A',
        action: () => {
          const context = this.ctx;
          if (context !== null) {
            removeEntry(context, entry.id);
            this.refresh();
          }
        }
      }
    });
  }

  private confirmDeleteSub(id: string): void {
    AlertDialog.show({
      title: '删除订阅',
      message: '删除「' + this.subName(id) + '」及其 ' + this.subNodeCount(id) + ' 个节点？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#FF5C7A',
        action: () => {
          const context = this.ctx;
          if (context !== null) {
            this.subs = removeSub(context, id);
            this.refresh();
            promptAction.showToast({ message: '订阅已删除' });
          }
        }
      }
    });
  }

  private latencyOf(id: string): string {
    const result: LatencyResult | null = resultOf(this.latency, id);
    if (result === null) {
      return '';
    }
    const via: string = viaText(result.via);
    return via.length > 0 ? latencyText(result.ms) + ' · ' + via : latencyText(result.ms);
  }

  private latencyColor(id: string): string {
    const ms: number = msOf(this.latency, id);
    if (ms < 0) {
      return '#5C7192';
    }
    return ms < 500 ? '#3DDC97' : (ms < 1500 ? '#FFC857' : '#FF8A5B');
  }

  private hasLatency(id: string): boolean {
    return resultOf(this.latency, id) !== null;
  }

  private subtitleOf(entry: ConfigEntry): string {
    const base: string = entry.server.length > 0 ? entry.server : nodeTypeLabel(entry.type);
    if (!this.hasLatency(entry.id)) {
      return base;
    }
    return base + ' · ' + this.latencyOf(entry.id);
  }

  private pushResult(result: LatencyResult): void {
    if (this.disposed) {
      return;
    }
    const context = this.ctx;
    if (context !== null) {
      recordLatency(context, result.id, result.ms, result.via);
    }
    const next: LatencyResult[] = [result];
    for (const item of this.latency) {
      if (item.id !== result.id) {
        next.push(item);
      }
    }
    this.latency = next;
  }

  // Rows show the last delay measured anywhere (this page or the dashboard);
  // the "· TCP / · HTTP" suffix keeps the metric visible, and no list probes on
  // its own just because it was opened.
  private loadLatency(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const cache: Map<string, LatencyEntry> = readLatencyCache(context);
    const list: LatencyResult[] = [];
    cache.forEach((value: LatencyEntry, key: string) => {
      const entry: LatencyResult = { id: key, ms: value.ms, via: value.via, at: value.at };
      list.push(entry);
    });
    this.latency = list;
  }

  private async runTest(scope: ConfigEntry[]): Promise<void> {
    const context = this.ctx;
    if (context === null || this.testing) {
      return;
    }
    if (scope.length === 0) {
      promptAction.showToast({ message: '没有可测速的节点' });
      return;
    }
    this.testing = true;
    this.loadLatency();
    this.viaTunnel = tunnelUp(context);
    this.probeTags = this.viaTunnel ? tunnelOutboundTags(context) : [];
    this.testTotal = scope.length;
    this.testDone = 0;
    const via: boolean = this.viaTunnel;
    const tags: string[] = this.probeTags;
    try {
      await testAll(scope, via, tags, (result: LatencyResult) => {
        this.pushResult(result);
        this.testDone++;
      });
    } finally {
      this.testing = false;
    }
  }

  private testVisible(): void {
    if (this.tab === TAB_NODES) {
      this.runTest(this.manualList());
    } else {
      this.runTest(this.allSubNodes());
    }
  }

  private async testOneEntry(entry: ConfigEntry): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const via: boolean = tunnelUp(context);
    this.viaTunnel = via;
    this.probeTags = via ? tunnelOutboundTags(context) : [];
    const tag: string = this.probeTagOf(entry.id);
    const result: LatencyResult = await testOne(entry, via, tag);
    this.pushResult(result);
  }

  // The running config tags every node with its entry id; a node that is not in
  // it (older config, or the single-node fallback) is probed directly instead.
  private probeTagOf(id: string): string {
    for (const tag of this.probeTags) {
      if (tag === id) {
        return tag;
      }
    }
    return '';
  }

  private beginEdit(id: string): void {
    const record: SubscriptionRecord | null = this.findSub(id);
    if (record === null) {
      return;
    }
    this.editingId = id;
    this.editName = record.name;
    this.editUrl = record.url;
  }

  private async commitEdit(id: string): Promise<void> {
    const context = this.ctx;
    const record: SubscriptionRecord | null = this.findSub(id);
    if (context === null || record === null) {
      return;
    }
    const url: string = this.editUrl.trim();
    const name: string = this.editName.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      promptAction.showToast({ message: '订阅地址必须是 http(s) 链接' });
      return;
    }
    const moved: boolean = url !== record.url;
    updateSub(context, id, url, name);
    this.editingId = '';
    this.refresh();
    if (moved) {
      // The address changed, so the node set has to follow it right away.
      await this.refreshOne(id);
    } else {
      promptAction.showToast({ message: '订阅已保存' });
    }
  }

  private async refreshOne(id: string): Promise<void> {
    const context = this.ctx;
    const record: SubscriptionRecord | null = this.findSub(id);
    if (context === null || record === null || this.busySubId.length > 0) {
      return;
    }
    this.busySubId = id;
    try {
      const next: SubscriptionRecord = await refreshSubscription(context, record);
      this.refresh();
      promptAction.showToast({ message: '已更新 ' + next.count + ' 个节点' });
    } catch (error) {
      const err = error as BusinessError;
      promptAction.showToast({ message: '更新失败: ' + (err.message ?? '网络错误') });
    } finally {
      this.busySubId = '';
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#0B1020')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        this.topBar()
        this.segment()
        this.hint()
        if (this.tab === TAB_NODES) {
          this.nodesView()
        } else {
          this.subsView()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.insets.top, bottom: this.insets.bottom })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1020')
  }

  @Builder
  topBar() {
    Row() {
      Text('‹')
        .fontSize(30)
        .fontColor('#A9BAD1')
        .width(36)
        .onClick(() => {
          router.back();
        })
      Text('节点')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E8F1FF')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text(this.testing ? (this.testDone + '/' + this.testTotal) : '测速')
        .fontSize(12)
        .fontColor(this.testing ? '#4C5D77' : '#54C4FF')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(6)
        .backgroundColor('#101A2E')
        .onClick(() => {
          if (!this.testing) {
            this.testVisible();
          }
        })
      Text('＋')
        .fontSize(26)
        .fontColor('#54C4FF')
        .width(36)
        .textAlign(TextAlign.End)
        .onClick(() => {
          this.add(this.tab === TAB_SUBS ? 1 : 0);
        })
    }
    .width('100%')
    .padding({ left: 10, right: 16, top: 8, bottom: 10 })
  }

  @Builder
  segment() {
    Row() {
      Text('节点 ' + this.manualCount())
        .fontSize(13)
        .fontColor(this.tab === TAB_NODES ? '#06121F' : '#7C8FA9')
        .height(34)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.tab === TAB_NODES ? '#54C4FF' : '#00000000')
        .onClick(() => {
          this.tab = TAB_NODES;
        })
      Text('订阅 ' + this.subs.length)
        .fontSize(13)
        .fontColor(this.tab === TAB_SUBS ? '#06121F' : '#7C8FA9')
        .height(34)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.tab === TAB_SUBS ? '#54C4FF' : '#00000000')
        .margin({ left: 4 })
        .onClick(() => {
          this.tab = TAB_SUBS;
        })
    }
    .width('100%')
    .padding(4)
    .backgroundColor('#101A2E')
    .borderRadius(10)
    .margin({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  hint() {
    Text('测速 ' + (this.viaTunnel ? '已连接 · 内核 HTTP（经代理）' : '未连接 · TCP/UDP 探测') +
      ' · 并发 ' + TEST_CONCURRENCY + ' · 超时 ' + (TEST_TIMEOUT_MS / 1000) + ' 秒 · 按延迟排序')
      .fontSize(10)
      .fontColor('#4C5D77')
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  nodesView() {
    if (this.manualCount() === 0) {
      this.emptyNodes()
    } else {
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.manualList(), (entry: ConfigEntry) => {
            this.nodeRow(entry, false)
          }, (entry: ConfigEntry) => entry.id)
          this.addButtons()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
  }

  @Builder
  subsView() {
    if (this.subs.length === 0) {
      this.emptySubs()
    } else {
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.subs, (sub: SubscriptionRecord) => {
            this.subCard(sub)
          }, (sub: SubscriptionRecord) => sub.id + '|' + sub.updatedAt + '|' + sub.name + '|' + sub.url)
          this.addButtons()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
  }

  @Builder
  addButtons() {
    Row({ space: 10 }) {
      Button(this.tab === TAB_SUBS ? '添加订阅' : '添加节点')
        .layoutWeight(1)
        .height(44)
        .fontSize(14)
        .fontColor('#54C4FF')
        .backgroundColor('#101A2E')
        .borderRadius(12)
        .margin({ top: 6 })
        .onClick(() => {
          this.add(this.tab === TAB_SUBS ? 1 : 0);
        })
    }
    .width('100%')
  }

  @Builder
  nodeRow(entry: ConfigEntry, owned: boolean) {
    Row() {
      // Selecting a node lives on this inner row only: with the handler on the
      // outer Row a tap on 「测速」 also fired the row's click, switched the node
      // and left the page before the probe result could be shown.
      Row() {
        Text(nodeTypeLabel(entry.type))
          .fontSize(owned ? 9 : 10)
          .fontColor('#06121F')
          .width(owned ? 42 : 52)
          .height(24)
          .textAlign(TextAlign.Center)
          .borderRadius(7)
          .backgroundColor(entry.id === this.selectedId ? '#54C4FF' : '#2A3550')

        Column() {
          Text(entry.name)
            .fontSize(owned ? 13 : 14)
            .fontColor('#E4EEFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.subtitleOf(entry))
            .fontSize(10)
            .fontColor(this.hasLatency(entry.id) ? this.latencyColor(entry.id) : '#5C7192')
            .margin({ top: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })
        .onClick(() => {
          this.choose(entry);
        })
      }
      .layoutWeight(1)
      .onClick(() => {
        this.choose(entry);
      })
      .gesture(
        LongPressGesture({ repeat: false })
          .onAction(() => {
            if (owned) {
              promptAction.showToast({ message: '订阅节点由订阅管理，请用「更新」刷新' });
            } else {
              this.confirmDeleteNode(entry);
            }
          })
      )

      Text('测速')
        .fontSize(11)
        .fontColor('#54C4FF')
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(6)
        .backgroundColor('#101A2E')
        .margin({ right: 6 })
        .onClick(() => {
          this.testOneEntry(entry);
        })
      if (entry.id === this.selectedId) {
        Text('✓')
          .fontSize(16)
          .fontColor('#3DDC97')
          .margin({ right: 8 })
      }
      Text('›')
        .fontSize(20)
        .fontColor('#4C5D77')
        .padding({ left: 4, right: 2 })
        .onClick(() => {
          this.choose(entry);
        })
    }
    .width('100%')
    .padding({ left: owned ? 22 : 14, right: 14, top: owned ? 9 : 12, bottom: owned ? 9 : 12 })
    .backgroundColor(owned ? '#101A2E' : '#131A2C')
    .borderRadius(owned ? 10 : 14)
  }

  @Builder
  subCard(sub: SubscriptionRecord) {
    Column() {
      if (this.editingId === sub.id) {
        this.subEditor(sub)
      } else {
        Row() {
          Column() {
            Text(this.subName(sub.id))
              .fontSize(14)
              .fontColor('#E4EEFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.subUrlText(sub.id))
              .fontSize(10)
              .fontColor('#4C5D77')
              .margin({ top: 3 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.subQuota(sub.id))
              .fontSize(11)
              .fontColor('#7C8FA9')
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(this.expandedId === sub.id ? '收起' : (this.subNodeCount(sub.id) + ' 个'))
            .fontSize(11)
            .fontColor('#54C4FF')
            .padding({ left: 8, right: 8, top: 5, bottom: 5 })
            .borderRadius(8)
            .backgroundColor('#101A2E')
            .onClick(() => {
              this.expandedId = this.expandedId === sub.id ? '' : sub.id;
            })
        }
        .width('100%')

        Progress({
          value: this.subUsed(sub.id),
          total: this.subTotal(sub.id),
          type: ProgressType.Linear
        })
          .width('100%')
          .height(6)
          .color('#54C4FF')
          .backgroundColor('#101A2E')
          .margin({ top: 10 })

        Row() {
          Text('到期 ' + this.subExpire(sub.id))
            .fontSize(10)
            .fontColor('#4C5D77')
            .layoutWeight(1)
          Text('更新于 ' + this.subUpdated(sub.id))
            .fontSize(10)
            .fontColor('#4C5D77')
        }
        .width('100%')
        .margin({ top: 6 })

        Row({ space: 8 }) {
          Text(this.busySubId === sub.id ? '更新中…' : '更新')
            .fontSize(12)
            .fontColor(this.busySubId === sub.id ? '#4C5D77' : '#54C4FF')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(32)
            .borderRadius(8)
            .backgroundColor('#101A2E')
            .onClick(() => {
              if (this.busySubId.length === 0) {
                this.refreshOne(sub.id);
              }
            })
          Text('编辑')
            .fontSize(12)
            .fontColor('#A9BAD1')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(32)
            .borderRadius(8)
            .backgroundColor('#101A2E')
            .onClick(() => {
              this.beginEdit(sub.id);
            })
          Text('删除')
            .fontSize(12)
            .fontColor('#FF5C7A')
            .textAlign(TextAlign.Center)
            .width(56)
            .height(32)
            .borderRadius(8)
            .backgroundColor('#101A2E')
            .onClick(() => {
              this.confirmDeleteSub(sub.id);
            })
        }
        .width('100%')
        .margin({ top: 10 })
      }

      if (this.expandedId === sub.id) {
        Divider().color('#1C2740').margin({ top: 10, bottom: 8 })
        if (this.subNodeCount(sub.id) === 0) {
          Text('这个订阅还没有节点，点「更新」拉取。')
            .fontSize(11)
            .fontColor('#5C7192')
            .width('100%')
        } else {
          Column({ space: 6 }) {
            ForEach(this.subNodes(sub.id), (entry: ConfigEntry) => {
              this.nodeRow(entry, true)
            }, (entry: ConfigEntry) => entry.id)
          }
          .width('100%')
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#131A2C')
    .borderRadius(14)
  }

  @Builder
  subEditor(sub: SubscriptionRecord) {
    Column({ space: 8 }) {
      Text('编辑订阅')
        .fontSize(12)
        .fontColor('#A9BAD1')
        .width('100%')
      TextInput({ text: this.editName, placeholder: '订阅名称' })
        .height(34)
        .fontSize(12)
        .fontColor('#E4EEFF')
        .placeholderColor('#5C7192')
        .backgroundColor('#0D1526')
        .borderRadius(8)
        .width('100%')
        .onChange((value: string) => {
          this.editName = value;
        })
      TextInput({ text: this.editUrl, placeholder: 'https://example.com/sub?token=...' })
        .height(34)
        .fontSize(11)
        .fontColor('#E4EEFF')
        .placeholderColor('#5C7192')
        .backgroundColor('#0D1526')
        .borderRadius(8)
        .width('100%')
        .onChange((value: string) => {
          this.editUrl = value;
        })
      Row({ space: 8 }) {
        Text('取消')
          .fontSize(12)
          .fontColor('#A9BAD1')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(8)
          .backgroundColor('#101A2E')
          .onClick(() => {
            this.editingId = '';
          })
        Text('保存')
          .fontSize(12)
          .fontColor('#06121F')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(8)
          .backgroundColor('#54C4FF')
          .onClick(() => {
            this.commitEdit(sub.id);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  emptyNodes() {
    Column() {
      Text('还没有节点')
        .fontSize(15)
        .fontColor('#7C8FA9')
      Text('粘贴分享链接或 JSON 配置导入')
        .fontSize(12)
        .fontColor('#4C5D77')
        .margin({ top: 6 })
      Button('添加节点')
        .width(160)
        .height(44)
        .fontSize(14)
        .fontColor('#06121F')
        .backgroundColor('#54C4FF')
        .borderRadius(12)
        .margin({ top: 18 })
        .onClick(() => {
          this.add(0);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  emptySubs() {
    Column() {
      Text('还没有订阅')
        .fontSize(15)
        .fontColor('#7C8FA9')
      Text('订阅和手动导入的节点分开管理，互不覆盖')
        .fontSize(12)
        .fontColor('#4C5D77')
        .margin({ top: 6 })
      Button('添加订阅')
        .width(160)
        .height(44)
        .fontSize(14)
        .fontColor('#06121F')
        .backgroundColor('#54C4FF')
        .borderRadius(12)
        .margin({ top: 18 })
        .onClick(() => {
          this.add(1);
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }
}

function formatTimeShort(ts: number): string {
  const date = new Date(ts);
  const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
  return pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' +
    pad(date.getHours()) + ':' + pad(date.getMinutes());
}



