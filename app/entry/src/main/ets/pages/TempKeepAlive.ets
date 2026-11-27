import { common } from '@kit.AbilityKit';

// Subtle transparent fallback page for TempAbility: normally TempAbility moves
// straight to background in ~200 ms, so the user barely notices it. If the
// window ever stays visible, this clear prompt replaces a confusing blank screen.
@Entry
@Component
struct TempKeepAlive {
  private moveBack(): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.moveAbilityToBackground().catch((): void => {
      });
    } catch (error) {
    }
  }

  onBackPress(): boolean {
    this.moveBack();
    return true;
  }

  aboutToAppear(): void {
    setTimeout(() => {
      this.moveBack();
    }, 80);
  }

  build() {
    Column() {
      Column({ space: 10 }) {
        Text('后台保活已开启')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#E4EEFF')
        Text('正在退回后台，请直接返回桌面（不要强制关闭）')
          .fontSize(12)
          .fontColor('#8FA3BF')
          .textAlign(TextAlign.Center)
        Button('返回')
          .fontSize(13)
          .height(34)
          .padding({ left: 24, right: 24 })
          .backgroundColor('#2B6CB0')
          .fontColor('#FFFFFF')
          .borderRadius(10)
          .margin({ top: 4 })
          .onClick(() => {
            this.moveBack();
          })
      }
      .padding({ left: 22, right: 22, top: 18, bottom: 18 })
      .backgroundColor('#D9101827')
      .borderRadius(16)
      .border({ width: 1, color: '#2654C4FF' })
      .margin({ left: 32, right: 32 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#40000000')
    .onClick(() => {
      this.moveBack();
    })
  }
}
