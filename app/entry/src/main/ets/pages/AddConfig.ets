import { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { promptAction, router } from '@kit.ArkUI';
import { Insets, pageInsets } from '../common/Xray';
import { ConfigEntry, SubscriptionRecord, addMany, replaceSubEntries, saveSub } from '../common/Store';
import { prepareSubscription } from '../common/Subscription';
import { ImportResult, SubscriptionFetch, SubscriptionUserInfo, fetchSubscription, importText } from '../common/Import';
import { appLog } from '../common/AppLog';
import { AppTheme, THEME_DARK, loadSavedThemeId, syncWindowBars, themeById } from '../common/Theme';

const METHOD_NONE: string = '';
const METHOD_QR: string = 'qr';
const METHOD_LINK: string = 'link';
const METHOD_JSON: string = 'json';

@Entry
@Component
struct AddConfig {
  @State selectedMethod: string = METHOD_LINK;
  @State linkText: string = '';
  @State subNameText: string = '';
  @State jsonText: string = '';
  @State clipboardHint: string = '';
  @State error: string = '';
  @State busy: boolean = false;
  @State busyText: string = '导入中…';
  @State insets: Insets = { top: 0, bottom: 0 };
  @State theme: AppTheme = THEME_DARK;

  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    let shouldAutoScan: boolean = false;
    const params: Object | undefined = router.getParams() as Object | undefined;
    if (params !== undefined && params !== null) {
      const map: Record<string, Object> = params as Record<string, Object>;
      const mode: Object | undefined = map['mode'];
      if (typeof mode === 'number') {
        const m: number = mode as number;
        this.selectedMethod = m === 2 ? METHOD_JSON : METHOD_LINK;
      }
      const autoScan: Object | undefined = map['autoScan'];
      if (typeof autoScan === 'boolean' && (autoScan as boolean)) {
        this.selectedMethod = METHOD_QR;
        shouldAutoScan = true;
      }
    }
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
    loadSavedThemeId(this.ctx).then((id: string) => {
      this.theme = themeById(id);
      if (this.ctx !== null) {
        syncWindowBars(this.ctx, this.theme);
      }
    });
    if (shouldAutoScan) {
      setTimeout(() => {
        this.scanQrCode();
      }, 150);
    } else if (this.selectedMethod === METHOD_LINK) {
      this.checkClipboard(true);
    }
  }

  private log(message: string): void {
    const context = this.ctx;
    if (context !== null) {
      appLog(context, 'import', message);
    }
  }

  private selectMethod(method: string): void {
    if (this.busy) {
      return;
    }
    this.error = '';
    this.selectedMethod = method;
    if (method === METHOD_LINK && this.linkText.trim().length === 0) {
      this.checkClipboard(true);
    }
  }

  private looksLikeProxyOrSub(raw: string): boolean {
    const s: string = raw.trim();
    if (s.length === 0) {
      return false;
    }
    const lower: string = s.toLowerCase();
    const prefixes: string[] = [
      'vless://', 'vmess://', 'ss://', 'trojan://', 'hysteria2://', 'hy2://',
      'socks://', 'socks5://', 'http://', 'https://'
    ];
    for (const p of prefixes) {
      if (lower.startsWith(p)) {
        return true;
      }
    }
    return false;
  }

  private async checkClipboard(autoOnly: boolean): Promise<void> {
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      const text: string = (data.getPrimaryText() ?? '').trim();
      if (text.length === 0) {
        if (!autoOnly) {
          promptAction.showToast({ message: '剪贴板为空' });
        }
        return;
      }
      if (this.selectedMethod === METHOD_JSON) {
        if (!autoOnly || (text.startsWith('{') && text.endsWith('}'))) {
          this.jsonText = text;
          this.error = '';
          this.clipboardHint = '已从剪贴板填入';
        }
        return;
      }
      if (!autoOnly || this.looksLikeProxyOrSub(text)) {
        this.linkText = text;
        this.error = '';
        this.clipboardHint = autoOnly ? '已自动读取剪贴板内容' : '已粘贴剪贴板内容';
      }
    } catch (error) {
      if (!autoOnly) {
        promptAction.showToast({ message: '无法读取剪贴板' });
      }
    }
  }

  private isSingleHttpUrl(text: string): boolean {
    const trimmed: string = text.trim();
    if (trimmed.indexOf('\n') >= 0 || trimmed.indexOf(' ') >= 0) {
      return false;
    }
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  private isContinueDisabled(): boolean {
    if (this.busy || this.selectedMethod === METHOD_NONE) {
      return true;
    }
    if (this.selectedMethod === METHOD_LINK) {
      return this.linkText.trim().length === 0;
    }
    if (this.selectedMethod === METHOD_JSON) {
      return this.jsonText.trim().length === 0;
    }
    return false;
  }

  private primaryButtonLabel(): string {
    if (this.busy) {
      return this.busyText;
    }
    if (this.selectedMethod === METHOD_QR) {
      return '开始扫描二维码';
    }
    if (this.selectedMethod === METHOD_LINK) {
      return this.isSingleHttpUrl(this.linkText) ? '导入订阅' : '导入节点';
    }
    if (this.selectedMethod === METHOD_JSON) {
      return '导入 JSON 配置';
    }
    return '继续';
  }

  private handleContinue(): void {
    if (this.isContinueDisabled()) {
      return;
    }
    if (this.selectedMethod === METHOD_QR) {
      this.scanQrCode();
      return;
    }
    if (this.selectedMethod === METHOD_LINK) {
      this.importPayload(this.linkText.trim(), this.subNameText.trim(), false);
      return;
    }
    if (this.selectedMethod === METHOD_JSON) {
      this.importPayload(this.jsonText.trim(), '', true);
    }
  }

  private async scanQrCode(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.busy) {
      return;
    }
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: true
    };
    try {
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, options);
      const raw: string = (result.originalValue ?? '').trim();
      if (raw.length === 0) {
        promptAction.showToast({ message: '未识别到有效二维码内容' });
        return;
      }
      this.log('qr scanned len=' + raw.length);
      if (raw.startsWith('{') && raw.endsWith('}')) {
        this.selectedMethod = METHOD_JSON;
        this.jsonText = raw;
        await this.importPayload(raw, '', true);
      } else {
        this.selectedMethod = METHOD_LINK;
        this.linkText = raw;
        await this.importPayload(raw, '', false);
      }
    } catch (error) {
      const err = error as BusinessError;
      if (err.code === 1000500002) {
        return;
      }
      const msg: string = err.message ?? '扫码失败';
      this.log('qr scan error: ' + err.code + ' ' + msg);
      this.error = '扫码失败：' + msg;
    }
  }

  private buildSubRecord(record: SubscriptionRecord, info: SubscriptionUserInfo | null, count: number): SubscriptionRecord {
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

  private async importPayload(raw: string, customSubName: string, forceJson: boolean): Promise<void> {
    const context = this.ctx;
    if (context === null || this.busy) {
      return;
    }
    const text: string = raw.trim();
    if (text.length === 0) {
      this.error = '请输入或粘贴有效内容';
      return;
    }
    this.busy = true;
    this.error = '';
    const isSub: boolean = !forceJson && this.isSingleHttpUrl(text);
    this.busyText = isSub ? '正在拉取订阅…' : '正在解析导入…';
    try {
      let payload: string = text;
      let subRecord: SubscriptionRecord | null = null;
      let subInfo: SubscriptionUserInfo | null = null;

      if (isSub) {
        const fetched: SubscriptionFetch = await fetchSubscription(text);
        payload = fetched.body;
        subInfo = fetched.userinfo;
        subRecord = prepareSubscription(context, text, customSubName);
      }

      if (payload.length === 0) {
        this.error = isSub ? '订阅返回内容为空' : '内容为空';
        return;
      }

      const result: ImportResult = importText(payload);
      this.log('import parsed entries=' + result.entries.length + ' failed=' + result.failed);
      if (result.entries.length === 0) {
        if (forceJson) {
          this.error = 'JSON 格式无效或缺少可用 outbounds';
        } else {
          this.error = result.errors.length > 0
            ? ('导入失败：' + result.errors[0])
            : (result.failed > 0 ? ('未识别到有效节点（' + result.failed + ' 行失败）') : '未识别到有效节点');
        }
        return;
      }

      const entries: ConfigEntry[] = result.entries;
      const count: number = entries.length;
      if (isSub && subRecord !== null) {
        for (const entry of entries) {
          entry.subId = subRecord.id;
        }
        replaceSubEntries(context, subRecord.id, entries);
        saveSub(context, this.buildSubRecord(subRecord, subInfo, count));
        this.log('subscription saved: ' + subRecord.url + ' nodes=' + count);
        promptAction.showToast({ message: '已导入订阅（' + count + ' 个节点）' });
      } else {
        addMany(context, entries);
        this.log('saved ' + count + ' nodes');
        promptAction.showToast({
          message: result.failed > 0
            ? ('已导入 ' + count + ' 个节点（跳过 ' + result.failed + ' 行）')
            : ('已导入 ' + count + ' 个节点')
        });
      }
      router.back();
    } catch (error) {
      const err = error as BusinessError;
      this.error = err.message ?? '导入失败，请检查内容或网络连接';
      this.log('import failed: ' + this.error);
    } finally {
      this.busy = false;
      this.busyText = '导入中…';
    }
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme.bg)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        this.headerBar()

        Scroll() {
          Column({ space: 14 }) {
            Column() {
              this.methodOption(
                METHOD_QR,
                $r('sys.symbol.qrcode'),
                this.theme.success,
                this.theme.successSoft,
                '扫描二维码',
                '扫节点或订阅二维码，支持相册选图'
              )
              Divider().color(this.theme.divider).margin({ left: 60 })
              this.methodOption(
                METHOD_LINK,
                $r('sys.symbol.link'),
                this.theme.accent,
                this.theme.accentSoft,
                '链接 / 订阅',
                '自动识别节点链接、多行、Base64 与订阅 URL'
              )
              Divider().color(this.theme.divider).margin({ left: 60 })
              this.methodOption(
                METHOD_JSON,
                $r('sys.symbol.doc_text'),
                '#8B5CF6',
                '#1A8B5CF6',
                'JSON 配置',
                '粘贴完整 Xray JSON 配置文件'
              )
            }
            .width('100%')
            .backgroundColor(this.theme.surface)
            .border({ width: 0.5, color: this.theme.border })
            .borderRadius(20)

            if (this.selectedMethod === METHOD_LINK) {
              this.linkInputSection()
            } else if (this.selectedMethod === METHOD_JSON) {
              this.jsonInputSection()
            }

            if (this.error.length > 0) {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.info_circle_fill'))
                  .fontSize(15)
                  .fontColor([this.theme.danger])
                Text(this.error)
                  .fontSize(12)
                  .fontColor(this.theme.danger)
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 10, bottom: 10 })
              .backgroundColor(this.theme.dangerSoft)
              .borderRadius(14)
            }
          }
          .width('100%')
          .padding({ left: 18, right: 18, top: 6, bottom: 20 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)

        Column() {
          Button() {
            Row({ space: 8 }) {
              if (this.busy) {
                LoadingProgress()
                  .width(18)
                  .height(18)
                  .color(this.theme.accentOn)
              } else if (this.selectedMethod === METHOD_QR) {
                SymbolGlyph($r('sys.symbol.qrcode'))
                  .fontSize(18)
                  .fontColor([this.theme.accentOn])
              }
              Text(this.primaryButtonLabel())
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isContinueDisabled() ? this.theme.textTertiary : this.theme.accentOn)
            }
            .justifyContent(FlexAlign.Center)
          }
          .width('100%')
          .height(50)
          .borderRadius(25)
          .backgroundColor(this.isContinueDisabled() ? this.theme.surfaceMuted : this.theme.accent)
          .enabled(!this.isContinueDisabled())
          .onClick(() => {
            this.handleContinue();
          })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 10, bottom: 14 })
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.insets.top, bottom: this.insets.bottom })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bg)
  }

  @Builder
  headerBar() {
    Row() {
      Text('添加节点')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textPrimary)
        .layoutWeight(1)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor([this.theme.textSecondary])
      }
      .width(34)
      .height(34)
      .borderRadius(17)
      .backgroundColor(this.theme.surface)
      .border({ width: 0.5, color: this.theme.border })
      .onClick(() => {
        router.back();
      })
    }
    .width('100%')
    .padding({ left: 20, right: 18, top: 14, bottom: 12 })
  }

  @Builder
  methodOption(method: string, symbol: Resource, iconFg: string, iconBg: string, title: string, subtitle: string) {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(symbol)
          .fontSize(18)
          .fontColor([iconFg])
      }
      .width(36)
      .height(36)
      .borderRadius(10)
      .backgroundColor(iconBg)

      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
        Text(subtitle)
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.selectedMethod === method) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill_1'))
          .fontSize(22)
          .fontColor([this.theme.accent])
      } else {
        Circle()
          .width(20)
          .height(20)
          .fill(Color.Transparent)
          .stroke(this.theme.borderStrong)
          .strokeWidth(1.5)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 14, bottom: 14 })
    .onClick(() => {
      this.selectMethod(method);
    })
  }

  @Builder
  linkInputSection() {
    Column({ space: 10 }) {
      Row() {
        Text(this.isSingleHttpUrl(this.linkText) ? '已识别为订阅地址' : '链接内容')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.isSingleHttpUrl(this.linkText) ? this.theme.success : this.theme.textSecondary)
        Blank()
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.text_clipboard'))
            .fontSize(13)
            .fontColor([this.theme.accent])
          Text('粘贴')
            .fontSize(12)
            .fontColor(this.theme.accent)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(12)
        .backgroundColor(this.theme.accentSoft)
        .onClick(() => {
          this.checkClipboard(false);
        })
      }
      .width('100%')

      TextArea({
        text: this.linkText,
        placeholder: '粘贴 vless:// / vmess:// / trojan:// / ss:// / hysteria2:// 或 https:// 订阅地址'
      })
        .height(128)
        .fontSize(13)
        .fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textTertiary)
        .backgroundColor(this.theme.surfaceMuted)
        .border({ width: 0.5, color: this.theme.border })
        .borderRadius(14)
        .padding(12)
        .onChange((value: string) => {
          this.linkText = value;
          this.clipboardHint = '';
          this.error = '';
        })

      if (this.isSingleHttpUrl(this.linkText)) {
        TextInput({ text: this.subNameText, placeholder: '订阅名称（可选，默认使用域名）' })
          .height(44)
          .fontSize(13)
          .fontColor(this.theme.textPrimary)
          .placeholderColor(this.theme.textTertiary)
          .backgroundColor(this.theme.surfaceMuted)
          .border({ width: 0.5, color: this.theme.border })
          .borderRadius(14)
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => {
            this.subNameText = value;
          })
      }

      if (this.clipboardHint.length > 0) {
        Text(this.clipboardHint)
          .fontSize(11)
          .fontColor(this.theme.success)
          .width('100%')
      } else {
        Text('支持单个或多个节点链接、Base64 订阅内容及 http(s) 订阅地址')
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  @Builder
  jsonInputSection() {
    Column({ space: 10 }) {
      Row() {
        Text('Xray JSON')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
        Blank()
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.text_clipboard'))
            .fontSize(13)
            .fontColor([this.theme.accent])
          Text('粘贴')
            .fontSize(12)
            .fontColor(this.theme.accent)
        }
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .borderRadius(12)
        .backgroundColor(this.theme.accentSoft)
        .onClick(() => {
          this.checkClipboard(false);
        })
      }
      .width('100%')

      TextArea({
        text: this.jsonText,
        placeholder: '{ "outbounds": [ ... ] }'
      })
        .height(190)
        .fontSize(12)
        .fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textTertiary)
        .backgroundColor(this.theme.surfaceMuted)
        .border({ width: 0.5, color: this.theme.border })
        .borderRadius(14)
        .padding(12)
        .onChange((value: string) => {
          this.jsonText = value;
          this.clipboardHint = '';
          this.error = '';
        })

      Text('完整配置中的每个代理 outbound 将自动拆分为独立节点')
        .fontSize(11)
        .fontColor(this.theme.textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }
}
