import { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import {
  Insets, NodeBadge, cancelProbes, extractNodeBadges, pageInsets, tunnelOutboundTags, tunnelUp
} from '../common/Xray';
import { initIpcAuth } from '../common/IpcAuth';
import { LatencyEntry, readLatencyCache, recordLatency } from '../common/LatencyStore';
import {
  ConfigEntry, ConfigStore, SubscriptionRecord, entriesOfSub, findById, manualEntries, readStore,
  readSubs, removeEntry, removeSub, selectEntry, subIdOf, updateSub
} from '../common/Store';
import { formatExpire, formatQuota, refreshSubscription } from '../common/Subscription';
import {
  LatencyResult, TEST_CONCURRENCY, TEST_TIMEOUT_MS, latencyText, msOf, resultOf, sortByLatency,
  testNodesRealDelay, testOne
} from '../common/Speedtest';

// Anywhere-style unified Proxies & Subscriptions page:
//   * Single scrollable list: standalone (manual) nodes at the top, followed by
//     collapsible subscription accordion cards (no split tab bar).
//   * Opening the page automatically expands the subscription owning the
//     currently selected node.
//   * Each proxy row renders Anywhere-style protocol/transport/security/flow
//     color badges and a tappable monospaced latency label (<300 green,
//     <500 yellow, >=500 red).
@Entry
@Component
struct Configs {
  @State items: ConfigEntry[] = [];
  @State selectedId: string = '';
  @State subs: SubscriptionRecord[] = [];
  @State insets: Insets = { top: 0, bottom: 0 };
  @State latency: LatencyResult[] = [];
  @State testingIds: string[] = [];
  @State testing: boolean = false;
  @State testDone: number = 0;
  @State testTotal: number = 0;
  @State viaTunnel: boolean = false;
  @State probeTags: string[] = [];
  @State expandedSubId: string = '';
  @State editingSubId: string = '';
  @State editName: string = '';
  @State editUrl: string = '';
  @State updatingSubIds: string[] = [];
  @State sortByDelay: boolean = false;

  private ctx: common.UIAbilityContext | null = null;
  private disposed: boolean = false;
  private initialExpandedDone: boolean = false;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    initIpcAuth(this.ctx);
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
    this.refresh();
    this.loadLatency();
    this.autoExpandSelectedSub();
  }

  onPageShow(): void {
    this.refresh();
    this.loadLatency();
    if (!this.initialExpandedDone) {
      this.autoExpandSelectedSub();
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
    cancelProbes(this.ctx);
  }

  private autoExpandSelectedSub(): void {
    this.initialExpandedDone = true;
    const selected: ConfigEntry | null = findById(this.items, this.selectedId);
    if (selected !== null) {
      const sid: string = subIdOf(selected);
      if (sid.length > 0) {
        this.expandedSubId = sid;
        return;
      }
    }
    if (this.manualCount() === 0 && this.subs.length > 0 && this.expandedSubId.length === 0) {
      this.expandedSubId = this.subs[0].id;
    }
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

  private isUpdatingSub(id: string): boolean {
    return this.updatingSubIds.indexOf(id) >= 0;
  }

  private addUpdatingSub(id: string): void {
    if (!this.isUpdatingSub(id)) {
      const next: string[] = this.updatingSubIds.slice();
      next.push(id);
      this.updatingSubIds = next;
    }
  }

  private removeUpdatingSub(id: string): void {
    const next: string[] = [];
    for (const item of this.updatingSubIds) {
      if (item !== id) {
        next.push(item);
      }
    }
    this.updatingSubIds = next;
  }

  private isTestingNode(id: string): boolean {
    return this.testingIds.indexOf(id) >= 0;
  }

  private markTestingNodes(ids: string[], active: boolean): void {
    const set: Set<string> = new Set(this.testingIds);
    for (const id of ids) {
      if (active) {
        set.add(id);
      } else {
        set.delete(id);
      }
    }
    const next: string[] = [];
    set.forEach((id: string) => {
      next.push(id);
    });
    this.testingIds = next;
  }

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

  private subHasTraffic(id: string): boolean {
    const record: SubscriptionRecord | null = this.findSub(id);
    return record !== null && (record.total > 0 || record.upload > 0 || record.download > 0);
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

  private subContainsSelected(subId: string): boolean {
    if (this.selectedId.length === 0) {
      return false;
    }
    const selected: ConfigEntry | null = findById(this.items, this.selectedId);
    return selected !== null && subIdOf(selected) === subId;
  }

  private manualCount(): number {
    return manualEntries(this.items).length;
  }

  private manualList(): ConfigEntry[] {
    const raw: ConfigEntry[] = manualEntries(this.items);
    return this.sortByDelay ? sortByLatency(raw, this.latency) : raw;
  }

  private subNodes(subId: string): ConfigEntry[] {
    const raw: ConfigEntry[] = entriesOfSub(this.items, subId);
    return this.sortByDelay ? sortByLatency(raw, this.latency) : raw;
  }

  private subNodeCount(subId: string): number {
    return entriesOfSub(this.items, subId).length;
  }

  // Matches Anywhere ProxiesView toolbar test button: tests standalone nodes
  // plus the currently expanded subscription's nodes (or all nodes if nothing
  // is expanded and there are no standalone nodes).
  private visibleTestTargets(): ConfigEntry[] {
    const targets: ConfigEntry[] = [];
    for (const item of manualEntries(this.items)) {
      targets.push(item);
    }
    if (this.expandedSubId.length > 0) {
      for (const item of entriesOfSub(this.items, this.expandedSubId)) {
        targets.push(item);
      }
    }
    if (targets.length === 0) {
      return this.items.slice();
    }
    return targets;
  }

  private add(mode: number, autoScan: boolean = false): void {
    const params: Record<string, Object> = { 'mode': mode, 'autoScan': autoScan };
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

  private copyText(text: string, label: string): void {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        promptAction.showToast({ message: '已复制' + label });
      }).catch(() => {
        promptAction.showToast({ message: '复制失败' });
      });
    } catch (error) {
      promptAction.showToast({ message: '复制失败' });
    }
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
            if (this.expandedSubId === id) {
              this.expandedSubId = '';
            }
            this.refresh();
            promptAction.showToast({ message: '订阅已删除' });
          }
        }
      }
    });
  }

  private latencyLabelText(id: string): string {
    if (this.isTestingNode(id)) {
      return '…';
    }
    const result: LatencyResult | null = resultOf(this.latency, id);
    if (result === null) {
      return '测速';
    }
    return latencyText(result.ms);
  }

  // Matches Anywhere LatencyLabel color thresholds: <300 green, <500 yellow, >=500 red.
  private latencyLabelColor(id: string): string {
    if (this.isTestingNode(id)) {
      return '#54C4FF';
    }
    const result: LatencyResult | null = resultOf(this.latency, id);
    if (result === null) {
      return '#4C5D77';
    }
    const ms: number = result.ms;
    if (ms < 0) {
      return '#5C7192';
    }
    if (ms < 300) {
      return '#3DDC97';
    }
    if (ms < 500) {
      return '#FFC857';
    }
    return '#FF5C7A';
  }

  private pushResult(result: LatencyResult): void {
    if (this.disposed) {
      return;
    }
    const context = this.ctx;
    if (context !== null) {
      recordLatency(context, result.id, result.ms, result.via);
    }
    this.markTestingNodes([result.id], false);
    const next: LatencyResult[] = [result];
    for (const item of this.latency) {
      if (item.id !== result.id) {
        next.push(item);
      }
    }
    this.latency = next;
  }

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
    const ids: string[] = [];
    for (const item of scope) {
      ids.push(item.id);
    }
    this.markTestingNodes(ids, true);
    const via: boolean = this.viaTunnel;
    const tags: string[] = this.probeTags;
    try {
      await testNodesRealDelay(scope, via, tags, null, (result: LatencyResult) => {
        this.pushResult(result);
        this.testDone++;
      }, context);
    } finally {
      this.markTestingNodes(ids, false);
      this.testing = false;
    }
  }

  private async testOneEntry(entry: ConfigEntry): Promise<void> {
    const context = this.ctx;
    if (context === null || this.isTestingNode(entry.id)) {
      return;
    }
    this.markTestingNodes([entry.id], true);
    try {
      const via: boolean = tunnelUp(context);
      this.viaTunnel = via;
      this.probeTags = via ? tunnelOutboundTags(context) : [];
      const liveTag: string = this.probeTags.indexOf(entry.id) >= 0 ? entry.id : '';
      const result: LatencyResult = await testOne(entry, via, liveTag, null, context);
      this.pushResult(result);
    } finally {
      this.markTestingNodes([entry.id], false);
    }
  }

  private beginEdit(id: string): void {
    const record: SubscriptionRecord | null = this.findSub(id);
    if (record === null) {
      return;
    }
    this.editingSubId = id;
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
    this.editingSubId = '';
    this.refresh();
    if (moved) {
      await this.refreshOne(id);
    } else {
      promptAction.showToast({ message: '订阅已保存' });
    }
  }

  private async refreshOne(id: string): Promise<void> {
    const context = this.ctx;
    const record: SubscriptionRecord | null = this.findSub(id);
    if (context === null || record === null || this.isUpdatingSub(id)) {
      return;
    }
    this.addUpdatingSub(id);
    try {
      const next: SubscriptionRecord = await refreshSubscription(context, record);
      this.refresh();
      promptAction.showToast({ message: '已更新 ' + next.count + ' 个节点' });
    } catch (error) {
      const err = error as BusinessError;
      promptAction.showToast({ message: '更新失败: ' + (err.message ?? '网络错误') });
    } finally {
      this.removeUpdatingSub(id);
    }
  }

  private async refreshAllSubs(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.subs.length === 0) {
      promptAction.showToast({ message: '还没有订阅' });
      return;
    }
    let okCount: number = 0;
    let failCount: number = 0;
    const snapshot: SubscriptionRecord[] = this.subs.slice();
    for (const sub of snapshot) {
      if (this.isUpdatingSub(sub.id)) {
        continue;
      }
      this.addUpdatingSub(sub.id);
      try {
        await refreshSubscription(context, sub);
        okCount++;
        this.refresh();
      } catch (error) {
        failCount++;
      } finally {
        this.removeUpdatingSub(sub.id);
      }
    }
    promptAction.showToast({
      message: failCount === 0
        ? ('已更新全部 ' + okCount + ' 个订阅')
        : ('更新完成：成功 ' + okCount + '，失败 ' + failCount)
    });
  }

  private moreMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: this.sortByDelay ? '排序：按延迟（点击切回默认）' : '排序：默认顺序（点击按延迟）',
      action: () => {
        this.sortByDelay = !this.sortByDelay;
      }
    });
    items.push({
      value: '测速全部节点',
      action: () => {
        if (!this.testing) {
          this.runTest(this.items.slice());
        }
      }
    });
    if (this.subs.length > 0) {
      items.push({
        value: '更新全部订阅',
        action: () => {
          this.refreshAllSubs();
        }
      });
    }
    items.push({
      value: '扫描二维码（节点 / 订阅）',
      action: () => {
        this.add(0, true);
      }
    });
    items.push({
      value: '添加订阅',
      action: () => {
        this.add(1);
      }
    });
    items.push({
      value: '导入 JSON 配置',
      action: () => {
        this.add(2);
      }
    });
    return items;
  }

  private nodeContextMenu(entry: ConfigEntry, owned: boolean): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '测速',
      action: () => {
        this.testOneEntry(entry);
      }
    });
    if (entry.server.length > 0) {
      items.push({
        value: '复制服务器地址',
        action: () => {
          this.copyText(entry.server, '服务器地址');
        }
      });
    }
    if (!owned) {
      items.push({
        value: '删除节点',
        action: () => {
          this.confirmDeleteNode(entry);
        }
      });
    }
    return items;
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
        this.hintBar()
        if (this.items.length === 0 && this.subs.length === 0) {
          this.emptyState()
        } else {
          Scroll() {
            Column({ space: 10 }) {
              if (this.manualCount() > 0) {
                ForEach(this.manualList(), (entry: ConfigEntry) => {
                  this.proxyRow(entry, false)
                }, (entry: ConfigEntry) => entry.id)
              }

              ForEach(this.subs, (sub: SubscriptionRecord) => {
                this.subscriptionCard(sub)
              }, (sub: SubscriptionRecord) => sub.id + '|' + sub.updatedAt + '|' + sub.name + '|' + sub.url)

              Row({ space: 10 }) {
                Button('添加节点 / 订阅')
                  .layoutWeight(1)
                  .height(44)
                  .fontSize(14)
                  .fontColor('#54C4FF')
                  .backgroundColor('#101A2E')
                  .borderRadius(14)
                  .margin({ top: 6 })
                  .onClick(() => {
                    this.add(0);
                  })
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 14, right: 14, bottom: 24 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
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
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(20)
          .fontColor(['#9FB0C9'])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor('#161F33')
      .onClick(() => {
        router.back();
      })
      Text('节点')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor('#F1F5FF')
        .layoutWeight(1)
        .textAlign(TextAlign.Start)
        .margin({ left: 2 })
      Row({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.bolt_1'))
          .fontSize(14)
          .fontColor([this.testing ? '#566782' : '#3B9EFF'])
        Text(this.testing ? (this.testDone + '/' + this.testTotal) : '测速')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.testing ? '#566782' : '#3B9EFF')
      }
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor('#161F33')
      .border({ width: 0.5, color: '#14FFFFFF' })
      .onClick(() => {
        if (!this.testing) {
          this.runTest(this.visibleTestTargets());
        }
      })
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(18)
          .fontColor(['#3B9EFF'])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor('#161F33')
      .border({ width: 0.5, color: '#14FFFFFF' })
      .onClick(() => {
        this.add(0);
      })
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(18)
          .fontColor(['#9FB0C9'])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor('#161F33')
      .border({ width: 0.5, color: '#14FFFFFF' })
      .bindMenu(this.moreMenu())
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 8, bottom: 8 })
  }

  @Builder
  hintBar() {
    Row() {
      Text('共 ' + this.items.length + ' 节点 · ' + this.subs.length + ' 订阅')
        .fontSize(11)
        .fontColor('#5C7192')
      Blank()
      Text('预热 HTTP 测速 · 并发 ' + TEST_CONCURRENCY + ' · ' + (this.sortByDelay ? '延迟排序' : '默认顺序'))
        .fontSize(10)
        .fontColor('#4C5D77')
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  proxyRow(entry: ConfigEntry, inContainer: boolean) {
    Row() {
      // Main tap target: select node and switch.
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(entry.name)
            .fontSize(14)
            .fontWeight(entry.id === this.selectedId ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(entry.id === this.selectedId ? '#FFFFFF' : '#E4EEFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '88%' })
          if (entry.id === this.selectedId) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(['#3B9EFF'])
          }
        }
        .width('100%')

        Row({ space: 5 }) {
          ForEach(extractNodeBadges(entry.type, entry.json), (badge: NodeBadge) => {
            Text(badge.text)
              .fontSize(9)
              .fontWeight(FontWeight.Medium)
              .fontColor(badge.fg)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(5)
              .backgroundColor(badge.bg)
          }, (badge: NodeBadge) => badge.text)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        this.choose(entry);
      })

      // Anywhere-style tappable latency badge on the right: tap to re-test only this node.
      Text(this.latencyLabelText(entry.id))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.latencyLabelColor(entry.id))
        .textAlign(TextAlign.End)
        .constraintSize({ minWidth: 56 })
        .padding({ left: 8, right: 2, top: 8, bottom: 8 })
        .onClick(() => {
          this.testOneEntry(entry);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(entry.id === this.selectedId
      ? '#16243D'
      : (inContainer ? '#10182A' : '#131A2C'))
    .border({
      width: entry.id === this.selectedId ? 1 : 0,
      color: '#3D54C4FF'
    })
    .borderRadius(16)
    .bindContextMenu(this.nodeMenuBuilder(entry, inContainer), ResponseType.LongPress)
  }

  @Builder
  nodeMenuBuilder(entry: ConfigEntry, owned: boolean) {
    Menu() {
      MenuItem({ content: '测试延迟' })
        .onClick(() => {
          this.testOneEntry(entry);
        })
      if (entry.server.length > 0) {
        MenuItem({ content: '复制服务器地址' })
          .onClick(() => {
            this.copyText(entry.server, '服务器地址');
          })
      }
      if (!owned) {
        MenuItem({ content: '删除节点' })
          .contentFontColor('#FF5C7A')
          .onClick(() => {
            this.confirmDeleteNode(entry);
          })
      }
    }
  }

  @Builder
  subscriptionCard(sub: SubscriptionRecord) {
    Column() {
      if (this.editingSubId === sub.id) {
        this.subEditor(sub)
      } else {
        // Collapsible subscription header (Anywhere style)
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.worldclock_fill'))
              .fontSize(this.expandedSubId === sub.id ? 18 : 15)
              .fontColor([this.subContainsSelected(sub.id) ? '#3B9EFF' : '#7D8FA9'])
          }
          .width(this.expandedSubId === sub.id ? 34 : 28)
          .height(this.expandedSubId === sub.id ? 34 : 28)
          .borderRadius(10)
          .backgroundColor('#162238')

          Column({ space: 3 }) {
            Row({ space: 8 }) {
              Text(this.subName(sub.id))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor('#F1F5FF')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.isUpdatingSub(sub.id)) {
                Text('更新中…')
                  .fontSize(11)
                  .fontColor('#3B9EFF')
              }
              Text('' + this.subNodeCount(sub.id))
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('#3B9EFF')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(10)
                .backgroundColor('#1A3B9EFF')
              SymbolGlyph(this.expandedSubId === sub.id ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
                .fontSize(14)
                .fontColor(['#6B7E9B'])
            }
            .width('100%')

            if (this.expandedSubId === sub.id) {
              Text(this.subHasTraffic(sub.id)
                ? this.subQuota(sub.id)
                : ('更新于 ' + this.subUpdated(sub.id)))
                .fontSize(11)
                .fontColor('#7C8FA9')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .onClick(() => {
          this.expandedSubId = this.expandedSubId === sub.id ? '' : sub.id;
        })

        if (this.expandedSubId === sub.id) {
          if (this.subHasTraffic(sub.id)) {
            Progress({
              value: this.subUsed(sub.id),
              total: this.subTotal(sub.id),
              type: ProgressType.Linear
            })
              .width('100%')
              .height(5)
              .color('#54C4FF')
              .backgroundColor('#0D1526')
              .margin({ top: 10 })

            Row() {
              Text('到期 ' + this.subExpire(sub.id))
                .fontSize(10)
                .fontColor('#5C7192')
                .layoutWeight(1)
              Text('更新于 ' + this.subUpdated(sub.id))
                .fontSize(10)
                .fontColor('#5C7192')
            }
            .width('100%')
            .margin({ top: 5 })
          }

          Row({ space: 6 }) {
            Text(this.isUpdatingSub(sub.id) ? '更新中…' : '更新')
              .fontSize(11)
              .fontColor(this.isUpdatingSub(sub.id) ? '#4C5D77' : '#54C4FF')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(30)
              .borderRadius(8)
              .backgroundColor('#101A2E')
              .onClick(() => {
                if (!this.isUpdatingSub(sub.id)) {
                  this.refreshOne(sub.id);
                }
              })
            Text('测速')
              .fontSize(11)
              .fontColor(this.testing ? '#4C5D77' : '#3DDC97')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(30)
              .borderRadius(8)
              .backgroundColor('#101A2E')
              .onClick(() => {
                if (!this.testing) {
                  this.runTest(this.subNodes(sub.id));
                }
              })
            Text('编辑')
              .fontSize(11)
              .fontColor('#A9BAD1')
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(30)
              .borderRadius(8)
              .backgroundColor('#101A2E')
              .onClick(() => {
                this.beginEdit(sub.id);
              })
            Text('复制')
              .fontSize(11)
              .fontColor('#A9BAD1')
              .textAlign(TextAlign.Center)
              .width(44)
              .height(30)
              .borderRadius(8)
              .backgroundColor('#101A2E')
              .onClick(() => {
                this.copyText(this.subUrlText(sub.id), '订阅链接');
              })
            Text('删除')
              .fontSize(11)
              .fontColor('#FF5C7A')
              .textAlign(TextAlign.Center)
              .width(44)
              .height(30)
              .borderRadius(8)
              .backgroundColor('#101A2E')
              .onClick(() => {
                this.confirmDeleteSub(sub.id);
              })
          }
          .width('100%')
          .margin({ top: 10 })

          Divider().color('#1C2740').margin({ top: 12, bottom: 10 })

          if (this.subNodeCount(sub.id) === 0) {
            Text('这个订阅还没有节点，点「更新」拉取。')
              .fontSize(12)
              .fontColor('#5C7192')
              .width('100%')
              .padding({ top: 6, bottom: 6 })
          } else {
            Column({ space: 8 }) {
              ForEach(this.subNodes(sub.id), (entry: ConfigEntry) => {
                this.proxyRow(entry, true)
              }, (entry: ConfigEntry) => entry.id)
            }
            .width('100%')
          }
        }
      }
    }
    .width('100%')
    .padding(this.expandedSubId === sub.id ? 14 : 14)
    .backgroundColor(this.expandedSubId === sub.id ? '#0E1526' : '#131A2C')
    .border({
      width: 1,
      color: this.expandedSubId === sub.id ? '#243554' : '#0DFFFFFF'
    })
    .borderRadius(20)
  }

  @Builder
  subEditor(sub: SubscriptionRecord) {
    Column({ space: 8 }) {
      Text('编辑订阅')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E4EEFF')
        .width('100%')
      TextInput({ text: this.editName, placeholder: '订阅名称' })
        .height(36)
        .fontSize(12)
        .fontColor('#E4EEFF')
        .placeholderColor('#5C7192')
        .backgroundColor('#0B1020')
        .borderRadius(10)
        .width('100%')
        .onChange((value: string) => {
          this.editName = value;
        })
      TextInput({ text: this.editUrl, placeholder: 'https://example.com/sub?token=...' })
        .height(36)
        .fontSize(11)
        .fontColor('#E4EEFF')
        .placeholderColor('#5C7192')
        .backgroundColor('#0B1020')
        .borderRadius(10)
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
          .height(34)
          .borderRadius(10)
          .backgroundColor('#101A2E')
          .onClick(() => {
            this.editingSubId = '';
          })
        Text('保存')
          .fontSize(12)
          .fontColor('#06121F')
          .fontWeight(FontWeight.Medium)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(34)
          .borderRadius(10)
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
  emptyState() {
    Column() {
      Text('还没有节点或订阅')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#A9BAD1')
      Text('粘贴分享链接、订阅地址或 JSON 配置即可自动识别导入')
        .fontSize(12)
        .fontColor('#5C7192')
        .margin({ top: 8 })
      Row({ space: 10 }) {
        Button('添加链接 / 订阅')
          .height(44)
          .padding({ left: 22, right: 22 })
          .fontSize(14)
          .fontColor('#06121F')
          .backgroundColor('#54C4FF')
          .borderRadius(12)
          .onClick(() => {
            this.add(0);
          })
      }
      .margin({ top: 20 })
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
