import { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { Insets, pageInsets } from '../common/Xray';
import { RuleList, TARGET_BLOCK, TARGET_DIRECT, TARGET_PROXY, WayRuleSet, importCustomRuleSet, parseRuleSet } from '../common/RuleSet';
import { appLog } from '../common/AppLog';

interface RuleSetDraft {
  name: string;
  lists: RuleList[];
}

function sampleText(): string {
  const direct: RuleList = {
    name: '我的直连',
    target: TARGET_DIRECT,
    domains: ['domain:example.cn', 'full:internal.example.cn'],
    ip: ['223.5.5.5/32']
  };
  const proxy: RuleList = {
    name: '走节点',
    target: TARGET_PROXY,
    domains: ['domain:example.com', 'keyword:github'],
    ip: []
  };
  const block: RuleList = {
    name: '拦掉',
    target: TARGET_BLOCK,
    domains: ['domain:ads.example.com'],
    ip: []
  };
  const draft: RuleSetDraft = { name: '我的规则', lists: [direct, proxy, block] };
  return JSON.stringify(draft);
}

function targetLabel(target: string): string {
  if (target === TARGET_BLOCK) {
    return '拦截';
  }
  if (target === TARGET_PROXY) {
    return '代理';
  }
  return '直连';
}

function targetColor(target: string): string {
  if (target === TARGET_BLOCK) {
    return '#FF5C7A';
  }
  if (target === TARGET_PROXY) {
    return '#54C4FF';
  }
  return '#3DDC97';
}

// Pastes a rule set written by hand (or exported from somewhere else). Same
// document the ACL4SSR converter produces, so the tunnel applies it unchanged;
// the previous active set stays in the backup slot.
@Entry
@Component
struct AddRules {
  @State text: string = '';
  @State preview: WayRuleSet | null = null;
  @State error: string = '';
  @State insets: Insets = { top: 0, bottom: 0 };
  private ctx: common.UIAbilityContext | null = null;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
  }

  private log(message: string): void {
    const context = this.ctx;
    if (context !== null) {
      appLog(context, 'rules', message);
    }
  }

  private parse(): void {
    this.error = '';
    this.preview = null;
    const text: string = this.text.trim();
    if (text.length === 0) {
      this.error = '请粘贴规则集 JSON';
      return;
    }
    const parsed: WayRuleSet | null = parseRuleSet(text);
    if (parsed === null) {
      this.error = '无法解析：需要 {"lists":[{"name","target","domains","ip"}]}，目标只能是 direct/proxy/block';
      this.log('custom rules parse failed');
      return;
    }
    this.preview = parsed;
    this.log('custom rules parsed: ' + parsed.lists.length + ' lists, ' + parsed.totals.rules + ' entries');
  }

  private save(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (this.preview === null) {
      this.parse();
    }
    if (this.preview === null) {
      promptAction.showToast({ message: this.error.length > 0 ? this.error : '规则集无效' });
      return;
    }
    const stored: WayRuleSet | null = importCustomRuleSet(context, this.text.trim());
    if (stored === null) {
      this.error = '保存失败：规则集无效';
      return;
    }
    this.log('custom rules stored: ' + stored.totals.rules + ' entries');
    promptAction.showToast({ message: '已保存自定义规则集（重连后生效）' });
    router.back();
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
            Text('规则集 JSON：lists[].target = direct（直连）/ proxy（走节点）/ block（拦截），domains 用 domain:/full:/keyword: 前缀，ip 用 CIDR。顺序即优先级。')
              .fontSize(11)
              .fontColor('#5C7192')
              .width('100%')

            TextArea({ text: this.text, placeholder: sampleText() })
              .height(260)
              .fontSize(11)
              .fontColor('#C8D8EE')
              .backgroundColor('#0D1526')
              .borderRadius(10)
              .placeholderColor('#4C5D77')
              .onChange((value: string) => {
                this.text = value;
                this.preview = null;
                this.error = '';
              })

            Row({ space: 10 }) {
              Button('示例')
                .layoutWeight(1)
                .height(42)
                .fontSize(13)
                .fontColor('#A9BAD1')
                .backgroundColor('#101A2E')
                .borderRadius(12)
                .onClick(() => {
                  this.text = sampleText();
                  this.preview = null;
                  this.error = '';
                })
              Button('解析')
                .layoutWeight(1)
                .height(42)
                .fontSize(13)
                .fontColor('#A9BAD1')
                .backgroundColor('#101A2E')
                .borderRadius(12)
                .onClick(() => {
                  this.parse();
                })
              Button('保存')
                .layoutWeight(1)
                .height(42)
                .fontSize(13)
                .fontColor('#06121F')
                .backgroundColor('#54C4FF')
                .borderRadius(12)
                .onClick(() => {
                  this.save();
                })
            }
            .width('100%')

            if (this.error.length > 0) {
              Text(this.error)
                .fontSize(12)
                .fontColor('#FF5C7A')
                .width('100%')
            }

            if (this.preview !== null) {
              this.previewCard()
            }

            Text('保存后可在主页「规则 → 使用规则集」里启用；想回到 ACL4SSR，用「内置」或「备份」。整份大规则集也可以直接推到 filesDir/xray/rules.json。')
              .fontSize(10)
              .fontColor('#44536B')
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
      Text('自定义规则集')
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
      Text((this.preview === null ? '' : this.preview.name) + ' · ' +
        (this.preview === null ? 0 : this.preview.lists.length) + ' 组 · 域名 ' +
        (this.preview === null ? 0 : this.preview.totals.domains) + ' · IP ' +
        (this.preview === null ? 0 : this.preview.totals.ip))
        .fontSize(12)
        .fontColor('#3DDC97')
        .width('100%')

      if (this.preview !== null) {
        ForEach(this.preview.lists, (list: RuleList) => {
          Row() {
            Text(targetLabel(list.target))
              .fontSize(10)
              .fontColor('#06121F')
              .width(40)
              .height(20)
              .textAlign(TextAlign.Center)
              .borderRadius(6)
              .backgroundColor(targetColor(list.target))
            Text(list.name)
              .fontSize(12)
              .fontColor('#D6E4F7')
              .margin({ left: 8 })
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('域名 ' + list.domains.length + ' · IP ' + list.ip.length)
              .fontSize(10)
              .fontColor('#5C7192')
          }
          .width('100%')
          .margin({ top: 8 })
        }, (list: RuleList) => list.name + '|' + list.target)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor('#131A2C')
    .borderRadius(12)
  }
}
