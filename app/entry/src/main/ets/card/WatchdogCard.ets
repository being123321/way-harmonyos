// 1x1 invisible watchdog widget. It paints only a fully transparent surface;
// its purpose is the FormExtensionAbility lifecycle, not the visuals.
@Entry
@Component
struct WatchdogCard {
  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#01000000')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#01000000')
  }
}
