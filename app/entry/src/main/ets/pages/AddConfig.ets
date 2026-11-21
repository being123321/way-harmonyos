import { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { Insets, nodeTypeLabel, pageInsets } from '../common/Xray';
import { ConfigEntry, SubscriptionRecord, addMany, replaceSubEntries, saveSub } from '../common/Store';
import { prepareSubscription } from '../common/Subscription';
import { ImportResult, SubscriptionFetch, SubscriptionUserInfo, fetchSubscription, importText } from '../common/Import';
import { appLog } from '../common/AppLog';

@Entry
@Component
struct AddConfig {
  @State mode: number = 0; // 0: links, 1: subscription, 2: raw JSON
  @State linkText: string = '';
  @State subText: string = '';
  @State jsonText: string = '';
  @State entries: ConfigEntry[] = [];
  @State failed: number = 0;
  @State error: string = '';
  @State busy: boolean = false;
  @State insets: Insets = { top: 0, bottom: 0 };
  private subUrl: string = '';
  private subInfo: SubscriptionUserInfo | null = null;
  private subRecord: SubscriptionRecord | null = null;

  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    // Opened from the subscription tab: start on that tab instead of links.
    const params: Object | undefined = router.getParams() as Object | undefined;
    if (params !== undefined && params !== null) {
      const map: Record<string, Object> = params as Record<string, Object>;
      const mode: Object | undefined = map['mode'];
      if (typeof mode === 'number') {
        this.mode = mode as number;
      }
    }
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
  }

  private log(message: string): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    appLog(context, 'import', message);
  }

  private resetPreview(): void {
    this.entries = [];
    this.failed = 0;
    this.error = '';
  }

  // Subscription nodes carry their subscription's id, which is what keeps them
  // out of the hand-imported node list (and lets a refresh replace only them).
  private tagWithSub(entries: ConfigEntry[]): ConfigEntry[] {
    const record: SubscriptionRecord | null = this.subRecord;
    if (this.mode !== 1 || record === null) {
      return entries;
    }
    for (const entry of entries) {
      entry.subId = record.id;
    }
    return entries;
  }

  private parseSingleJson(): void {
    const text: string = this.jsonText.trim();
    if (text.length === 0) {
      this.error = '请粘贴完整 JSON 配置';
      return;
    }
    const result: ImportResult = importText(text);
    this.log('json parsed entries=' + result.entries.length);
    if (result.entries.length === 0) {
      this.error = 'JSON 格式错误或缺少 outbounds';
      return;
    }
    this.entries = result.entries;
    this.failed = 0;
  }

  private async parseText(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.resetPreview();
    this.busy = true;
    try {
      if (this.mode === 2) {
        this.parseSingleJson();
        return;
      }
      let payload: string = this.linkText.trim();
      this.log('mode=' + this.mode + ' payloadLen=' + payload.length);
      if (this.mode === 1) {
        const context = this.ctx;
        const url: string = this.subText.trim();
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          this.error = '订阅地址必须是 http(s) 链接';
          return;
        }
        const fetched: SubscriptionFetch = await fetchSubscription(url);
        payload = fetched.body;
        this.subUrl = url;
        this.subInfo = fetched.userinfo;
        if (context !== null) {
          this.subRecord = prepareSubscription(context, url, '');
        }
      }
      if (payload.length === 0) {
        this.error = '内容为空';
        return;
      }
      const result: ImportResult = importText(payload);
      this.log('parsed entries=' + result.entries.length + ' failed=' + result.failed + ' lines=' + result.total);
      for (const detail of result.errors) {
        this.log('detail: ' + detail);
      }
      this.entries = this.tagWithSub(result.entries);
      this.failed = result.failed;
      if (result.entries.length === 0) {
        this.error = result.errors.length > 0
          ? '导入失败: ' + result.errors[0]
          : (result.failed > 0 ? '没有可识别的节点（' + result.failed + ' 行失败）' : '没有可识别的节点');
      }
    } catch (error) {
      const err = error as BusinessError;
      this.error = err.message ?? '解析失败';
      this.log('parse failed: ' + this.error);
    } finally {
      this.busy = false;
    }
  }

  private async save(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.busy) {
      return;
    }
    // Saving without pressing "解析" first must still work: parse on demand.
    if (this.entries.length === 0) {
      await this.parseText();
    }
    const entries: ConfigEntry[] = this.tagWithSub(this.entries);
    if (entries.length === 0) {
      if (this.error.length === 0) {
        this.error = '没有可导入的节点';
      }
      this.log('save aborted: ' + this.error);
      promptAction.showToast({ message: this.error });
      return;
    }
    const count: number = entries.length;
    if (this.mode === 1) {
      const record: SubscriptionRecord | null = this.subRecord;
      if (record === null) {
        this.error = '订阅记录创建失败';
        return;
      }
      // Importing the same URL again replaces that subscription's node set
      // instead of piling a second copy of every node on top of it.
      replaceSubEntries(context, record.id, entries);
      saveSub(context, this.buildSubRecord(record, count));
      this.log('subscription saved: ' + record.url + ' nodes=' + count);
      promptAction.showToast({ message: '已导入订阅：' + count + ' 个节点' });
    } else {
      addMany(context, entries);
      this.log('saved ' + count + ' nodes');
      promptAction.showToast({ message: '已导入 ' + count + ' 个节点' });
    }
    this.entries = [];
    router.back();
  }

  private buildSubRecord(record: SubscriptionRecord, count: number): SubscriptionRecord {
    const info: SubscriptionUserInfo | null = this.subInfo;
    const next: SubscriptionRecord = {
      id: record.id,
      url: record.url,
      name: record.name,
      host: record.host,
      updatedAt: Date.now(),
      upload: info === null ? 0 : info.upload,
      download: info === null ? 0 : info.download,
      total: info === null ? 0 : info.total,
      expire: info === null ? 0 : info.expire,
      count: count
    };
    return next;
  }

  private modeLabel(): string {
    if (this.mode === 0) {
      return '分享链接（可多行）';
    }
    if (this.mode === 1) {
      return '订阅地址（节点归入该订阅）';
    }
    return '完整 JSON（按 outbounds 拆成多个节点）';
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

        Scroll() {
          Column({ space: 12 }) {
            Row() {
              this.modeTab(0, '链接')
              this.modeTab(1, '订阅')
              this.modeTab(2, 'JSON')
            }
            .width('100%')
            .padding(4)
            .backgroundColor('#101A2E')
            .borderRadius(10)

            Text(this.modeLabel())
              .fontSize(12)
              .fontColor('#5C7192')
              .width('100%')

            if (this.mode === 0) {
              TextArea({
                text: this.linkText,
                placeholder: 'vless:// | vmess:// | ss:// | trojan:// | hysteria2://\n每行一个，可整段粘贴（支持 base64 订阅内容）'
              })
                .height(170)
                .fontSize(12)
                .fontColor('#D6E4F7')
                .backgroundColor('#0D1526')
                .borderRadius(10)
                .placeholderColor('#4C5D77')
                .onChange((value: string) => {
                  this.linkText = value;
                  this.resetPreview();
                })
            } else if (this.mode === 1) {
              TextArea({ text: this.subText, placeholder: 'https://example.com/sub?token=...' })
                .height(80)
                .fontSize(12)
                .fontColor('#D6E4F7')
                .backgroundColor('#0D1526')
                .borderRadius(10)
                .placeholderColor('#4C5D77')
                .onChange((value: string) => {
                  this.subText = value;
                  this.subRecord = null;
                  this.resetPreview();
                })
            } else {
              TextArea({ text: this.jsonText, placeholder: '{ "inbounds": [...], "outbounds": [...] }' })
                .height(240)
                .fontSize(11)
                .fontColor('#C8D8EE')
                .backgroundColor('#0D1526')
                .borderRadius(10)
                .placeholderColor('#4C5D77')
                .onChange((value: string) => {
                  this.jsonText = value;
                  this.resetPreview();
                })
            }

            if (this.error.length > 0) {
              Text(this.error)
                .fontSize(12)
                .fontColor('#FF5C7A')
                .width('100%')
            }

            if (this.entries.length > 0) {
              this.previewCard()
            }

            Row({ space: 10 }) {
              Button(this.busy ? '解析中…' : '解析')
                .layoutWeight(1)
                .height(44)
                .fontSize(14)
                .fontColor('#A9BAD1')
                .backgroundColor('#101A2E')
                .borderRadius(12)
                .enabled(!this.busy)
                .onClick(() => {
                  this.parseText();
                })
              Button('保存')
                .layoutWeight(1)
                .height(44)
                .fontSize(14)
                .fontColor('#06121F')
                .backgroundColor('#54C4FF')
                .borderRadius(12)
                .enabled(!this.busy)
                .onClick(() => {
                  this.save();
                })
            }
            .width('100%')
            .margin({ top: 4 })

            Text(this.mode === 1
              ? '订阅和手动导入的节点分开保存：更新或删除订阅只影响它自己的节点，不会覆盖你手动加的节点。订阅可在节点页「订阅」标签里改名、改地址。'
              : '导入后显示在节点列表（手动节点），重复的节点会自动跳过。JSON 里的每个 outbound 会拆成一个独立节点。')
              .fontSize(11)
              .fontColor('#4C5D77')
              .width('100%')
              .margin({ bottom: 20 })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
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
      Text(this.mode === 1 ? '添加订阅' : '添加节点')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor('#E8F1FF')
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
      Text('')
        .width(36)
    }
    .width('100%')
    .padding({ left: 10, right: 16, top: 8, bottom: 10 })
  }

  @Builder
  previewCard() {
    Column() {
      Row() {
        Text('识别到 ' + this.entries.length + ' 个节点')
          .fontSize(13)
          .fontColor('#3DDC97')
          .layoutWeight(1)
        if (this.failed > 0) {
          Text('跳过 ' + this.failed + ' 行')
            .fontSize(11)
            .fontColor('#FFC857')
        }
      }
      .width('100%')

      ForEach(this.entries.slice(0, 6), (entry: ConfigEntry) => {
        Row() {
          Text(nodeTypeLabel(entry.type))
            .fontSize(10)
            .fontColor('#06121F')
            .width(48)
            .height(22)
            .textAlign(TextAlign.Center)
            .borderRadius(6)
            .backgroundColor('#54C4FF')
          Text(entry.name)
            .fontSize(12)
            .fontColor('#D6E4F7')
            .margin({ left: 10 })
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(entry.server)
            .fontSize(10)
            .fontColor('#5C7192')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '40%' })
        }
        .width('100%')
        .margin({ top: 8 })
      }, (entry: ConfigEntry) => entry.id)

      if (this.entries.length > 6) {
        Text('…… 其余 ' + (this.entries.length - 6) + ' 个')
          .fontSize(11)
          .fontColor('#4C5D77')
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#131A2C')
    .borderRadius(12)
  }

  @Builder
  modeTab(index: number, label: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.mode === index ? '#06121F' : '#7C8FA9')
      .height(34)
      .layoutWeight(1)
      .textAlign(TextAlign.Center)
      .borderRadius(8)
      .backgroundColor(this.mode === index ? '#54C4FF' : '#00000000')
      .onClick(() => {
        this.mode = index;
        this.subRecord = null;
        this.resetPreview();
      })
  }
}
