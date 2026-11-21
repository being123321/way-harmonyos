import { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { promptAction, router } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import {
  ConnectionRow, Insets, closeConnection, fetchConnections, formatDuration, pageInsets, tunnelUp
} from '../common/Xray';

// Live connection inventory of the running core. Polls once a second while the
// page is visible and lets a row be closed. Search matches the address or the
// resolved outbound name.
interface HistoryEntry {
  id: number;
  network: string;
  host: string;
  port: number;
  ruleTag: string;
  startedUnixMs: number;
  endedUnixMs: number;
}

const TAB_ACTIVE: number = 0;
const TAB_HISTORY: number = 1;
const HISTORY_FILE: string = 'conn-history.json';
const HISTORY_MAX: number = 200;

@Entry
@Component
struct Connections {
  @State rows: ConnectionRow[] = [];
  @State query: string = '';
  @State running: boolean = false;
  @State errorText: string = '';
  @State insets: Insets = { top: 0, bottom: 0 };
  // Finished connections, newest first, capped and persisted across launches.
  @State history: HistoryEntry[] = [];
  @State tab: number = TAB_ACTIVE;
  private timer: number = -1;
  private ctx: common.UIAbilityContext | null = null;
  // Rows of the previous poll, to spot the flows that just finished.
  private seen: Map<number, ConnectionRow> = new Map<number, ConnectionRow>();

  aboutToAppear(): void {
    this.ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
    this.loadHistory();
    this.running = tunnelUp(this.ctx);
    this.refresh();
    this.timer = setInterval(() => {
      this.refresh();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private historyPath(): string {
    const context = this.ctx;
    return context === null ? '' : (context.filesDir + '/xray/' + HISTORY_FILE);
  }

  private loadHistory(): void {
    const path: string = this.historyPath();
    if (path.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const text: string = fs.readTextSync(path);
      const parsed: HistoryEntry[] = JSON.parse(text) as HistoryEntry[];
      this.history = parsed;
    } catch (error) {
      this.history = [];
    }
  }

  private saveHistory(): void {
    const path: string = this.historyPath();
    if (path.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(path,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(this.history));
      fs.closeSync(file);
    } catch (error) {
    }
  }

  // A flow that was in the previous poll and is gone now has finished: keep it,
  // newest first, capped so the file stays small.
  private recordFinished(list: ConnectionRow[]): void {
    const alive: Map<number, ConnectionRow> = new Map<number, ConnectionRow>();
    for (const row of list) {
      alive.set(row.id, row);
    }
    const finished: HistoryEntry[] = [];
    this.seen.forEach((row: ConnectionRow) => {
      if (alive.has(row.id)) {
        return;
      }
      const entry: HistoryEntry = {
        id: row.id,
        network: row.network,
        host: row.sniffedDomain.length > 0 ? row.sniffedDomain : row.address,
        port: row.port,
        ruleTag: row.ruleTag,
        startedUnixMs: row.startedUnixMs,
        endedUnixMs: Date.now()
      };
      finished.push(entry);
    });
    this.seen = alive;
    if (finished.length === 0) {
      return;
    }
    const merged: HistoryEntry[] = finished.concat(this.history);
    this.history = merged.length > HISTORY_MAX ? merged.slice(0, HISTORY_MAX) : merged;
    this.saveHistory();
  }

  private async refresh(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const up: boolean = tunnelUp(context);
    this.running = up;
    if (!up) {
      this.rows = [];
      this.seen = new Map<number, ConnectionRow>();
      this.errorText = '';
      return;
    }
    try {
      const list: ConnectionRow[] = await fetchConnections();
      this.rows = list;
      this.recordFinished(list);
      this.errorText = '';
    } catch (error) {
      const failure = error as BusinessError;
      this.errorText = failure.message === undefined ? '读取连接失败' : failure.message;
    }
  }

  private clearHistory(): void {
    this.history = [];
    this.saveHistory();
  }

  private historyTarget(entry: HistoryEntry): string {
    return entry.network.toUpperCase() + '  ' + entry.host + ':' + entry.port;
  }

  private historyTime(entry: HistoryEntry): string {
    const seconds: number = Math.max(0, (entry.endedUnixMs - entry.startedUnixMs) / 1000);
    return formatDuration(seconds) + ' · 结束于 ' + this.clock(entry.endedUnixMs);
  }

  private clock(ms: number): string {
    const date = new Date(ms);
    const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
    return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
  }

  private visibleRows(): ConnectionRow[] {
    const query: string = this.query.trim().toLowerCase();
    if (query.length === 0) {
      return this.rows;
    }
    const filtered: ConnectionRow[] = [];
    for (const row of this.rows) {
      const haystack: string = (row.address + ':' + row.port).toLowerCase();
      if (haystack.indexOf(query) >= 0) {
        filtered.push(row);
      }
    }
    return filtered;
  }

  // Prefer the domain sniffing found; the address is the dial target (often an IP).
  private targetText(row: ConnectionRow): string {
    const host: string = row.sniffedDomain.length > 0 ? row.sniffedDomain : row.address;
    return host + ':' + row.port;
  }

  private durationText(row: ConnectionRow): string {
    if (row.startedUnixMs <= 0) {
      return '';
    }
    return formatDuration(Math.max(0, (Date.now() - row.startedUnixMs) / 1000));
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#101A2E', 0.0], ['#0B1020', 0.42], ['#090E1A', 1.0]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        Row() {
          Text('‹')
            .fontSize(26)
            .fontColor('#E8F1FF')
            .width(40)
            .onClick(() => {
              router.back();
            })
          Text('连接')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor('#E8F1FF')
          Blank()
          Text(this.rows.length + ' 条')
            .fontSize(12)
            .fontColor('#7C8FA9')
        }
        .width('100%')
        .padding({ left: 12, right: 18, top: this.insets.top + 12, bottom: 12 })

        TextInput({ placeholder: '搜索域名或地址', text: this.query })
          .height(40)
          .fontSize(13)
          .fontColor('#E4EEFF')
          .placeholderColor('#7C8FA9')
          .backgroundColor('#101827')
          .borderRadius(20)
          .padding({ left: 16, right: 16 })
          .margin({ left: 16, right: 16 })
          .onChange((value: string) => {
            this.query = value;
          })

        Row() {
          Text('活动 ' + this.rows.length)
            .fontSize(12)
            .fontColor(this.tab === TAB_ACTIVE ? '#0B1020' : '#7C8FA9')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(32)
            .borderRadius(9)
            .backgroundColor(this.tab === TAB_ACTIVE ? '#54C4FF' : '#101827')
            .onClick(() => {
              this.tab = TAB_ACTIVE;
            })
          Text('历史 ' + this.history.length)
            .fontSize(12)
            .fontColor(this.tab === TAB_HISTORY ? '#0B1020' : '#7C8FA9')
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height(32)
            .borderRadius(9)
            .backgroundColor(this.tab === TAB_HISTORY ? '#54C4FF' : '#101827')
            .margin({ left: 8 })
            .onClick(() => {
              this.tab = TAB_HISTORY;
            })
          if (this.tab === TAB_HISTORY && this.history.length > 0) {
            Text('清空')
              .fontSize(12)
              .fontColor('#FF5C7A')
              .textAlign(TextAlign.Center)
              .width(56)
              .height(32)
              .margin({ left: 8 })
              .onClick(() => {
                this.clearHistory();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ top: 12 })

        Text(this.tab === TAB_ACTIVE
          ? (this.running
            ? ('活动连接 ' + this.visibleRows().length + ' · 最多显示 100 条')
            : '隧道未连接')
          : ('最近结束的 ' + this.history.length + ' 条，最多保留 200 条'))
          .fontSize(11)
          .fontColor('#5C7192')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 10, bottom: 4 })

        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize(11)
            .fontColor('#FF5C7A')
            .width('100%')
            .padding({ left: 16, right: 16 })
        }

        List({ space: 10 }) {
          if (this.tab === TAB_ACTIVE) {
            ForEach(this.visibleRows().slice(0, 100), (row: ConnectionRow) => {
            ListItem() {
              Column() {
                Row() {
                  Text(row.network.toUpperCase() + '  ' + this.targetText(row))
                    .fontSize(13)
                    .fontColor('#E4EEFF')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('关闭')
                    .fontSize(12)
                    .fontColor('#0B1020')
                    .padding({ left: 14, right: 14, top: 5, bottom: 5 })
                    .backgroundColor('#54C4FF')
                    .borderRadius(16)
                    .onClick(() => {
                      this.drop(row);
                    })
                }
                .width('100%')

                Text(this.durationText(row) + (row.state === 'opening' ? ' · 建立中' : ''))
                  .fontSize(11)
                  .fontColor('#5C7192')
                  .width('100%')
                  .margin({ top: 6 })

                if (row.ruleTag.length > 0) {
                  Text('rule_set=' + row.ruleTag)
                    .fontSize(11)
                    .fontColor('#7C8FA9')
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                }
              }
              .width('100%')
              .padding(14)
              .backgroundColor('#101827')
              .borderRadius(18)
              .border({ width: 1, color: '#07FFFFFF' })
            }
          }, (row: ConnectionRow) => row.id.toString())
          }

          if (this.tab === TAB_HISTORY) {
            ForEach(this.history, (entry: HistoryEntry) => {
              ListItem() {
                Column() {
                  Text(this.historyTarget(entry))
                    .fontSize(13)
                    .fontColor('#C7D6EC')
                    .width('100%')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.historyTime(entry))
                    .fontSize(11)
                    .fontColor('#5C7192')
                    .width('100%')
                    .margin({ top: 6 })
                  if (entry.ruleTag.length > 0) {
                    Text('rule_set=' + entry.ruleTag)
                      .fontSize(11)
                      .fontColor('#7C8FA9')
                      .width('100%')
                      .margin({ top: 4 })
                  }
                }
                .width('100%')
                .padding(14)
                .backgroundColor('#0D1424')
                .borderRadius(18)
                .border({ width: 1, color: '#07FFFFFF' })
              }
            }, (entry: HistoryEntry) => entry.id.toString() + ':' + entry.endedUnixMs.toString())
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: this.insets.bottom + 12 })
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1020')
  }

  private async drop(row: ConnectionRow): Promise<void> {
    const ok: boolean = await closeConnection(row.id);
    if (!ok) {
      promptAction.showToast({ message: '关闭失败' });
      return;
    }
    this.rows = this.rows.filter((item: ConnectionRow) => item.id !== row.id);
  }
}
