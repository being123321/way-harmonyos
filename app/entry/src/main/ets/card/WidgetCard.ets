@Entry
@Component
struct WidgetCard {
  build() {
    Column({ space: 10 }) {
      Text('way').fontSize(16).fontColor('#C7D6EC').fontWeight(FontWeight.Medium)
      Row({ space: 10 }) {
        Button('连接')
          .fontSize(13)
          .height(34)
          .backgroundColor('#2B6CB0')
          .onClick(() => {
            postCardAction(this, {
              action: 'router',
              abilityName: 'EntryAbility',
              params: { op: 'connect' }
            });
          })
        Button('断开')
          .fontSize(13)
          .height(34)
          .backgroundColor('#3A4557')
          .onClick(() => {
            postCardAction(this, {
              action: 'router',
              abilityName: 'EntryAbility',
              params: { op: 'disconnect' }
            });
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#101A2E')
    // FlClash-style trigger: the launcher previews this card in the widget
    // picker before it is added. onAppear fires there too, so merely opening
    // the picker and exiting arms the keepalive ability; the card itself does
    // not need to stay on the desktop. TempAbility checks the "remove from
    // recents" switch (keepAliveOnRemove) before doing anything.
    .onAppear(() => {
      postCardAction(this, {
        action: 'call',
        bundleName: 'com.way.app',
        abilityName: 'TempAbility',
        params: { method: 'keepalive' }
      });
    })
  }
}
