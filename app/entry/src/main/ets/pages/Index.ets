import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { formInfo, formProvider } from '@kit.FormKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import type { Want } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { promptAction, router } from '@kit.ArkUI';
import { connection, socket } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import {
  Insets, ReloadResult, TunnelStatus, clearStatus, coreVersion, formatBytes, formatDuration, formatTime,
  reloadRouting, tunnelUp,
  NodeEndpoint, formatSpeed, measureLatency, nodeEndpoint, nodeTypeLabel, outboundEndpoint, pageInsets, probeOutbound, readLogs,
  readStatus, saveConfig, startVpn, stopVpn, vpnWant, loadConfig
} from '../common/Xray';
import { ConfigEntry, SubscriptionRecord, readStore, readSubs, selectEntry, selectedEntry } from '../common/Store';
import { refreshSubscription } from '../common/Subscription';
import { TEST_HOST } from '../common/Speedtest';
import { resolveUdp } from '../common/UdpDns';
import { LatencyEntry, readLatencyCache, recordLatency } from '../common/LatencyStore';
import { appLog } from '../common/AppLog';
import { PipManager } from '../common/PipManager';
import { MODE_BYPASS, MODE_GFW, MODE_GLOBAL, SplitOptions } from '../common/Rules';
import { TunnelConfigResult, buildAndSaveTunnel, proxyOutbound } from '../common/TunnelConfig';
import { SSID_DIRECT, SSID_SUSPEND, SsidRule, clearSsidRules, currentSsid, findRule, onDemandEnabled, removeSsidRule, setAppliedSsidAction, setFlag, setSsidRule, setSsidSuspended, setSuspendOverride, ssidRules, ssidSuspended, suspendOverride } from '../common/Ssid';
import { GEODATA_PRESETS, GeodataMeta, geodataReady, geodataStale, readGeodataMeta, selectedPreset, selectPreset, updateGeodata } from '../common/Geodata';
import {
  ORIGIN_UPDATE, TARGET_BLOCK, WayRuleSet, activeRuleSet, backupCurrent, hasBackup, originLabel,
  readRuleSet, restoreBundled, ruleSetCount, ruleSetLine, seedRuleSet, swapWithBackup, writeRuleSet
} from '../common/RuleSet';
import { RuleBuildProgress, buildRuleSet } from '../common/RuleSource';

const PREF_NAME: string = 'xray_prefs';
const POLL_MS: number = 1000;
// The extension writes status.json once per second. Five missed beats means
// the extension process is gone (or its JS thread is wedged), so the UI
// supervisor relaunches it instead of leaving the user with a dead switch.
const HEARTBEAT_STALE_MS: number = 5000;
// A Wi-Fi/cellular switch makes the extension call native.rebind(), which can
// block its JS thread for several seconds (DNS + socket setup). During that
// window the heartbeat looks stale even though the extension is alive, and
// relaunching/stopping it was what turned a switch into a full VPN drop.
const NETWORK_GRACE_MS: number = 20000;
// Bounded relaunch budget: attempts are spaced 1s, 2s, 4s, 8s (the next wait
// would be 15s, but the budget stops at five). It uses the saved config, so
// this is a relaunch, not a rebuild/restart of the tunnel.
const RECOVERY_MAX_ATTEMPTS: number = 5;
// connect(): notification/task first, then up to three start requests, each
// verified against status.json (the "third tap finally works" failure).
const CONNECT_ATTEMPTS: number = 3;
const CONNECT_WATCHDOG_MS: number = 45000;
// The continuous task is suspected to make the system tear down the VPN
// extension a few seconds after it starts, so it is off until proven safe.
const ENABLE_CONTINUOUS_TASK: boolean = true;
// Floating title bar: the scroll content starts below it while the bar itself
// blurs whatever slides underneath (frosted glass).
const HEADER_BLUR: number = 28;
// Fallback probe target for nodes that speak UDP only: a TCP handshake to such a
// server is usually dropped, so measure the real request instead.
const NODE_TEST_URL: string = 'https://www.gstatic.com/generate_204';

@Entry
@Component
struct Index {
  @State state: string = 'stopped';
  @State message: string = '断开';
  @State up: number = 0;
  @State down: number = 0;
  @State flows: number = 0;
  @State seconds: number = 0;
  @State logs: string = '';
  @State busy: boolean = false;
  @State notifyMe: boolean = true;
  @State rebindOnNetChange: boolean = true;
  @State splitOn: boolean = true;
  @State routeMode: string = MODE_BYPASS;
  @State geoSourceName: string = 'Loyalsoldier';
  @State onDemand: boolean = false;
  @State currentWifi: string = '';
  @State manualSsid: string = '';
  @State rules: SsidRule[] = [];
  @State isOn: boolean = false;
  // Code-side isOn changes also fire Toggle.onChange; without this guard the
  // suspension path ran disconnect() and froze the app in userOff=true.
  private switchProgrammatic: boolean = false;
  @State coreInfo: string = coreVersion();
  @State entryName: string = '';
  @State entryType: string = '';
  @State entryServer: string = '';
  @State hasEntry: boolean = false;
  @State insets: Insets = { top: 0, bottom: 0 };
  @State showLogs: boolean = false;
  @State statusAge: number = -1;
  @State probeMs: number = 0;
  @State pssKb: number = 0;
  @State cpuPercent: number = 0;
  @State blockQuic: boolean = false;
  // Diagnostic logging is off by default: the core otherwise writes one debug
  // line per routed connection.
  @State debugLog: boolean = false;
  private lastStartedAt: number = 0;
  private lastNotifRefreshAt: number = 0;
  @State upSpeed: number = 0;
  @State downSpeed: number = 0;
  private lastEventAt: number = 0;
  private prevUp: number = 0;
  private prevDown: number = 0;
  private prevStamp: number = 0;
  private trafficSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private takeoverSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  // 连接前解析好的节点服务器地址（写进 config 的 dns.hosts）。
  private bootstrapHosts: Record<string, string[]> | null = null;
  private usedFallback: boolean = false;
  private keepAliveStarted: boolean = false
  // True while the widget-preview TempAbility owns the continuous task; the UI
  // must not request a second task (that produced two notifications).
  private keepAliveOwnedByTemp: boolean = false;
  // Watchdog for the extension heartbeat: lastBeatAt is the extension's own
  // status.updatedAt, lastStartRequestAt is when this UI last asked the system
  // to launch it. Recovery is bounded (RECOVERY_MAX_ATTEMPTS) with backoff.
  private lastBeatAt: number = 0;
  private lastStartRequestAt: number = 0;
  private recoveryAttempts: number = 0;
  private nextRecoveryAt: number = 0;
  private recovering: boolean = false;
  private intentOn: boolean = false;
  private connectWatchdog: number = -1;
  // Network-change suppression: after netLost/netAvailable the extension gets
  // NETWORK_GRACE_MS to rebind before the heartbeat supervisor may relaunch it.
  private netConn: connection.NetConnection | null = null;
  private networkSwitchAt: number = 0;
  private sawNetEvent: boolean = false;
  private reviveFailures: number = 0;
  // Simulated PiP keepalive: when enabled, EntryAbility enables PiP auto-start
  // in onBackground, so the system keeps a small window (and the process)
  // after the main task is swiped away.
  @State pipKeepAlive: boolean = true;
  // Reconnect when the app is opened again after a manual swipe-away. This is
  // the FlClash "auto-connect on launch" behaviour: the manual swipe is still a
  // full stop (no background resurrection), but the next launch restores it.
  @State autoConnect: boolean = true;
  private autoConnectTried: boolean = false;
  private taskId: number = -1;
  private taskNotificationId: number = -1;
  private taskWatchRegistered: boolean = false;
  @State geoText: string = '未下载';
  @State hasRuleSet: boolean = false;
  @State ruleSetText: string = '未导入（使用内置规则）';
  @State useRuleSet: boolean = false;
  @State ruleBusy: boolean = false;
  @State ruleProgress: string = '';
  @State hasBackup: boolean = false;
  @State blockAds: boolean = true;
  // 规则卡默认收起，只显示「规则 + 模式名」。
  @State rulesExpanded: boolean = false;
  @State nodeExpanded: boolean = false;
  @State nodeList: ConfigEntry[] = [];
  // Node id -> measured delay (ms) for the list shown inside the node card.
  @State nodeLatency: Map<string, number> = new Map<string, number>();
  @State nodeProbing: boolean = false;
  @State selectedId: string = '';
  @State ssidExpanded: boolean = false;
  // Measured height of the floating title bar; used as the scroll's top spacer
  // so the first card never hides underneath it.
  @State headerHeight: number = 72;
  @State dohDns: boolean = true;
  @State blockAdText: string = '0';
  @State geoBusy: boolean = false;

  private ctx: common.UIAbilityContext | null = null;
  private timerId: number = -1;
  private tickCount: number = 0;
  private backgroundRunning: boolean = false;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
    this.restore().catch((error: BusinessError) => {
      promptAction.showToast({ message: '读取设置失败' });
    });
    this.watchNetworkChanges();
    this.watchKeepAliveTakeover();
    this.startPolling();
  }

  // The page timer must be restarted on every show: aboutToAppear runs only
  // once, so clearing it on hide used to leave the dashboard frozen at the
  // values captured when the app went background.
  onPageShow(): void {
    this.preparePip();
    this.consumeCardOp();
    this.refreshIntent();
    this.refreshEntry();
    this.refreshRuleSetStatus();
    this.loadLatencyCache();
    this.startPolling();
    this.subscribeTraffic();
    this.poll();
  }

  onPageHide(): void {
    // Keep polling on purpose: with the PiP keepalive the process survives the
    // main task, and the 5 s heartbeat supervisor is what relaunches a
    // reclaimed VPN extension. Without PiP the system freezes this timer.
    //
    // Enabling auto-start here (before onBackground) is what makes the system
    // pop the PiP window as the app leaves the foreground.
    const context = this.ctx;
    if (context !== null && this.pipKeepAlive && this.intentOn) {
      PipManager.getInstance().setAutoStart(context, true);
      appLog(context, 'pip', 'PiP auto-start enabled at page hide');
    }
  }

  // FlClash-style keepalive entry: open the system widget picker for the way
  // card. The picker previews the card, its onAppear calls TempAbility, and
  // TempAbility starts the VPN + continuous task. The user just exits the
  // picker; the card does not need to be added to the desktop.
  private openKeepAliveForm(): void {
    const want: Want = {
      bundleName: 'com.way.app',
      abilityName: 'WayFormAbility',
      parameters: {
        'ohos.extra.param.key.form_name': 'way_widget',
        'ohos.extra.param.key.module_name': 'entry',
        'ohos.extra.param.key.form_dimension': formInfo.FormDimension.Dimension_2_2
      }
    };
    try {
      formProvider.openFormManager(want);
    } catch (error) {
      promptAction.showToast({ message: '打开卡片预览失败' });
    }
  }

  private preparePip(): void {    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (this.pipKeepAlive && this.intentOn) {
      // Create the controller while the app is still in the foreground, enable
      // auto-start for the next background, and close any PiP left from before.
      PipManager.getInstance().setAutoStart(context, true);
      PipManager.getInstance().stop();
    } else {
      PipManager.getInstance().setAutoStart(context, false);
      PipManager.getInstance().stop();
    }
  }

  aboutToDisappear(): void {
    this.stopPolling();
    this.unsubscribeTraffic();
    this.unwatchNetworkChanges();
    this.unwatchKeepAliveTakeover();
  }

  // Observe network changes so a switch (Wi-Fi <-> cellular) pauses the
  // heartbeat supervisor for a while. The extension itself only calls
  // native.rebind() on netAvailable; it does not restart the tunnel.
  private watchNetworkChanges(): void {
    if (this.netConn !== null) {
      return;
    }
    try {
      const conn: connection.NetConnection = connection.createNetConnection();
      const mark = (): void => {
        // The first event is just the current default network at registration;
        // only later events indicate a real switch.
        if (this.sawNetEvent) {
          this.networkSwitchAt = Date.now();
        }
        this.sawNetEvent = true;
      };
      conn.on('netAvailable', () => {
        mark();
      });
      conn.on('netLost', () => {
        mark();
      });
      conn.register((error: BusinessError) => {
        if (error && this.ctx !== null) {
          appLog(this.ctx, 'ui', 'network watch failed: ' + (error.message ?? 'unknown'));
        }
      });
      this.netConn = conn;
    } catch (error) {
    }
  }

  private unwatchNetworkChanges(): void {
    const conn = this.netConn;
    this.netConn = null;
    if (conn !== null) {
      try {
        conn.unregister(() => {
        });
      } catch (error) {
      }
    }
  }

  // The widget-preview TempAbility publishes this before it requests its own
  // continuous task. Release the UI's task first, otherwise both tasks show a
  // notification (the system task card + the live view).
  private async watchKeepAliveTakeover(): Promise<void> {
    if (this.takeoverSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber({ events: ['com.way.app.KEEPALIVE_TAKEOVER'] });
      commonEventManager.subscribe(sub, () => {
        this.keepAliveOwnedByTemp = true;
        if (this.keepAliveStarted) {
          this.keepAliveStarted = false;
          this.taskNotificationId = -1;
          const context = this.ctx;
          if (context !== null) {
            backgroundTaskManager.stopBackgroundRunning(context).catch((): void => {
            });
            appLog(context, 'keepalive', 'TempAbility took over the continuous task');
          }
        }
      });
      this.takeoverSubscriber = sub;
    } catch (error) {
    }
  }

  private unwatchKeepAliveTakeover(): void {
    const sub = this.takeoverSubscriber;
    this.takeoverSubscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  // Subscription channel: the VPN extension publishes counters once per second
  // (sing-box streams the same over the Clash API /traffic endpoint), so the
  // dashboard does not have to poll the status file.
  private async subscribeTraffic(): Promise<void> {
    if (this.trafficSubscriber !== null) {
      return;
    }
    try {
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber({ events: ['com.way.app.TRAFFIC'] });
      commonEventManager.subscribe(subscriber, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        this.up = (params['up'] as number) ?? this.up;
        this.down = (params['down'] as number) ?? this.down;
        this.upSpeed = (params['upSpeed'] as number) ?? 0;
        this.downSpeed = (params['downSpeed'] as number) ?? 0;
        this.flows = ((params['tcp'] as number) ?? 0) + ((params['udp'] as number) ?? 0);
        const startedAt: number = (params['startedAt'] as number) ?? 0;
        if (startedAt > 0) {
          this.seconds = (Date.now() - startedAt) / 1000;
        }
        this.state = 'running';
        this.message = '已连接';
        this.setSwitch(true);
        this.lastEventAt = Date.now();
        this.statusAge = 0;
      });
      this.trafficSubscriber = subscriber;
    } catch (error) {
      const err = error as BusinessError;
      if (this.ctx !== null) {
        appLog(this.ctx, 'ui', 'traffic subscribe failed: ' + (err.message ?? 'unknown'));
      }
    }
  }

  private unsubscribeTraffic(): void {
    const subscriber = this.trafficSubscriber;
    this.trafficSubscriber = null;
    if (subscriber !== null) {
      try {
        commonEventManager.unsubscribe(subscriber);
      } catch (error) {
      }
    }
  }

  private startPolling(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.timerId = setInterval(() => {
      this.poll();
    }, POLL_MS);
  }

  private stopPolling(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  // The on-demand watcher can bring the tunnel up while the page is in the
  // background; re-read the intent each time the page shows so a later
  // heartbeat loss is supervised against the current state.
  private async refreshIntent(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, 'way');
      this.intentOn = (store.getSync('vpnActive', false) as boolean) &&
        !(store.getSync('userOff', false) as boolean);
    } catch (error) {
    }
  }

  // FlClash-style "open app auto-connect": a manual swipe is a full stop (the
  // VPN is stopped and nothing resurrects it in the background), but the last
  // explicit state is remembered. On the next launch, if the app was connected
  // when it exited, reconnect. An explicit switch-off clears lastConnected.
  private maybeAutoConnect(context: common.UIAbilityContext): void {
    if (this.autoConnectTried) {
      return;
    }
    this.autoConnectTried = true;
    if (!this.autoConnect) {
      return;
    }
    setTimeout(() => {
      this.runAutoConnect(context).catch((): void => {
      });
    }, 500);
  }

  private async runAutoConnect(context: common.UIAbilityContext): Promise<void> {
    if (ssidSuspended(context)) {
      return;
    }
    if (selectedEntry(context) === null) {
      return;
    }
    const status: TunnelStatus | null = readStatus(context);
    if (status !== null && (status.state === 'running' || status.state === 'starting' ||
      status.state === 'suspended')) {
      return;
    }
    const wayStore = await preferences.getPreferences(context, 'way');
    const last: boolean = wayStore.getSync('lastConnected', false) as boolean;
    if (!last) {
      return;
    }
    appLog(context, 'lifecycle', 'auto-connect on launch (lastConnected=true)');
    await this.connect();
  }

  private refreshEntry(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const entry: ConfigEntry | null = selectedEntry(context);
    this.hasEntry = entry !== null;
    this.entryName = entry === null ? '' : entry.name;
    this.entryType = entry === null ? '' : entry.type;
    this.entryServer = entry === null ? '' : entry.server;
    this.refreshGeodataStatus();
  }

  private refreshGeodataStatus(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (!geodataReady(context)) {
      this.geoText = '未下载（仅使用基础规则）';
      return;
    }
    const meta: GeodataMeta | null = readGeodataMeta(context);
    if (meta === null) {
      this.geoText = '已就绪';
      return;
    }
    const total: number = meta.geositeBytes + meta.geoipBytes;
    this.geoText = formatTime(meta.updatedAt) + ' · ' + formatBytes(total);
  }

  private async restore(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const store = await preferences.getPreferences(context, PREF_NAME);
    this.notifyMe = store.getSync('notify', true) as boolean;
    this.rebindOnNetChange = store.getSync('rebind', true) as boolean;
    // "The user wants the tunnel up" lives in the 'way' store (markActive and
    // EntryAbility write it there), not in xray_prefs. It is separate from the
    // switch: the switch may flip off when a heartbeat goes stale, but intent
    // must survive so the supervisor can relaunch the extension.
    const wayStore = await preferences.getPreferences(context, 'way');
    this.intentOn = (wayStore.getSync('vpnActive', false) as boolean) &&
      !(wayStore.getSync('userOff', false) as boolean);
    // If the widget-preview TempAbility owns the task, the UI must not request
    // another one (that was the source of the duplicate notification).
    this.keepAliveOwnedByTemp = wayStore.getSync('tempKeepAlive', false) as boolean;
    // Routing is controlled by the mode buttons alone: a stale false here used
    // to disable every rule silently, which sent domestic apps through the node.
    this.splitOn = true;
    this.routeMode = store.getSync('mode', MODE_BYPASS) as string;
    this.geoSourceName = selectedPreset(context).name;
    this.blockQuic = store.getSync('blockQuic', false) as boolean;
    this.debugLog = store.getSync('debugLog', false) as boolean;
    this.onDemand = onDemandEnabled(context);
    this.rules = ssidRules(context);
    this.useRuleSet = store.getSync('useRuleSet', false) as boolean;
    this.blockAds = store.getSync('blockAds', true) as boolean;
    this.dohDns = store.getSync('dohDns', true) as boolean;
    this.pipKeepAlive = store.getSync('pipKeepAlive', true) as boolean;
    this.autoConnect = store.getSync('autoConnect', true) as boolean;
    // The converted ACL4SSR set ships in the HAP: seed it on first launch so the
    // feature works before the tunnel (and therefore the download) can.
    if (seedRuleSet(context)) {
      appLog(context, 'ui', 'rule set seeded from the bundled rawfile');
    }
    this.refreshRuleSetStatus();
    this.refreshSsid();
    this.refreshEntry();
    this.poll();
    this.maybeAutoConnect(context);
    if (this.splitOn && (geodataStale(context) || !geodataReady(context))) {
      this.runGeodataUpdate(true);
    }
    this.refreshStaleSubscriptions();
  }

  // sing-box style: refresh subscriptions that are older than a day, silently.
  private async refreshStaleSubscriptions(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const now: number = Date.now();
    for (const sub of readSubs(context)) {
      const record: SubscriptionRecord = sub;
      if (now - record.updatedAt < 24 * 3600 * 1000) {
        continue;
      }
      try {
        await refreshSubscription(context, record);
        appLog(context, 'ui', 'subscription refreshed: ' + record.url);
      } catch (error) {
        const err = error as BusinessError;
        appLog(context, 'ui', 'subscription refresh failed: ' + (err.message ?? 'network'));
      }
    }
  }

  private async persist(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const store = await preferences.getPreferences(context, PREF_NAME);
    store.putSync('notify', this.notifyMe);
    store.putSync('rebind', this.rebindOnNetChange);
    store.putSync('split', true);
    store.putSync('mode', this.routeMode);
    store.putSync('blockQuic', this.blockQuic);
    store.putSync('debugLog', this.debugLog);
    store.putSync('useRuleSet', this.useRuleSet);
    store.putSync('blockAds', this.blockAds);
    store.putSync('dohDns', this.dohDns);
    store.putSync('pipKeepAlive', this.pipKeepAlive);
    store.putSync('autoConnect', this.autoConnect);
    await store.flush();
  }

  // ACL4SSR rule set: either imported from the app (RuleSource downloads the
  // lists), restored from the bundled copy / the backup slot, or pasted in
  // pages/AddRules. Every switch keeps the previous copy in rules-backup.json.
  private refreshRuleSetStatus(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    this.hasBackup = hasBackup(context);
    const ruleSet: WayRuleSet | null = readRuleSet(context);
    if (ruleSet === null) {
      this.hasRuleSet = false;
      this.blockAdText = '0';
      this.ruleSetText = '未导入（使用内置规则）';
      if (this.useRuleSet) {
        this.useRuleSet = false;
        this.persist();
      }
      return;
    }
    this.hasRuleSet = true;
    // Shown next to the 拦截广告 switch so the number is not a mystery.
    this.blockAdText = '' + ruleSetCount(ruleSet, TARGET_BLOCK);
    let text: string = originLabel(ruleSet.origin) + ' · ' + ruleSetLine(ruleSet);
    const generated: number = Date.parse(ruleSet.generatedAt);
    if (Number.isFinite(generated) && generated > 0) {
      text += ' · ' + formatTime(generated);
    }
    this.ruleSetText = text;
  }

  private async importRuleSet(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.ruleBusy) {
      return;
    }
    this.ruleBusy = true;
    this.ruleProgress = '准备中…';
    try {
      const ruleSet: WayRuleSet = await buildRuleSet((progress: RuleBuildProgress) => {
        this.ruleProgress = progress.done + '/' + progress.total + ' ' + progress.current;
      });
      backupCurrent(context);
      ruleSet.origin = ORIGIN_UPDATE;
      writeRuleSet(context, ruleSet);
      this.useRuleSet = true;
      this.refreshRuleSetStatus();
      this.persist();
      appLog(context, 'ui', 'rule set imported: ' + ruleSet.lists.length + ' lists, ' +
        ruleSet.totals.rules + ' rules');
      await this.applyRoutingChange(context, '规则集已更新（' +
        ruleSet.totals.domains + ' 域名 / ' + ruleSet.totals.ip + ' IP）');
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'ui', 'rule set import failed: ' + (err.message ?? 'unknown'));
      promptAction.showToast({ message: '规则集更新失败: ' + (err.message ?? '网络错误') });
    } finally {
      this.ruleBusy = false;
      this.ruleProgress = '';
    }
  }

  // Restores the copy that ships in the HAP; the current one goes to backup.
  private useBundledRuleSet(): void {
    const context = this.ctx;
    if (context === null || this.ruleBusy) {
      return;
    }
    const restored: WayRuleSet | null = restoreBundled(context);
    if (restored === null) {
      promptAction.showToast({ message: '内置规则集不可用' });
      return;
    }
    this.useRuleSet = true;
    this.refreshRuleSetStatus();
    this.persist();
    appLog(context, 'ui', 'rule set restored from bundled rawfile');
    this.applyRoutingChange(context, '已切回内置规则集');
  }

  // Swaps the active set with the previous one.
  private useBackupRuleSet(): void {
    const context = this.ctx;
    if (context === null || this.ruleBusy) {
      return;
    }
    const restored: WayRuleSet | null = swapWithBackup(context);
    if (restored === null) {
      promptAction.showToast({ message: '没有可回滚的备份' });
      return;
    }
    this.useRuleSet = true;
    this.refreshRuleSetStatus();
    this.persist();
    appLog(context, 'ui', 'rule set swapped with backup: ' + restored.totals.rules + ' rules');
    this.applyRoutingChange(context, '已回滚到上一份规则集');
  }

  private openCustomRules(): void {
    router.pushUrl({ url: 'pages/AddRules' }).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开自定义规则页失败: ' + error.message });
    });
  }

  // The "更换" menu: one plain-language entry per source instead of four small
  // buttons on the card.
  private ruleMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '内置 ACL4SSR（随包快照，不联网）',
      action: () => {
        this.useBundledRuleSet();
      }
    });
    items.push({
      value: '在线更新（拉 ACL4SSR 最新，需联网）',
      action: () => {
        this.importRuleSet();
      }
    });
    items.push({
      value: '撤销上一次（恢复备份）',
      action: () => {
        this.useBackupRuleSet();
      }
    });
    items.push({
      value: '自定义（粘贴自己的 JSON）',
      action: () => {
        this.openCustomRules();
      }
    });
    return items;
  }

  // Rebuild config.json and apply the new routing to the running tunnel. Rule
  // set, ad-block and mode switches all only change routing, so they take effect
  // without a reconnect; a restart is the fallback when the live swap fails.
  // Switching stays silent on purpose: no toast, the card itself is the feedback.
  private async applyRoutingChange(context: common.UIAbilityContext,
    message: string): Promise<void> {
    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null) {
      return;
    }
    buildAndSaveTunnel(context, entry, this.buildOptions(context));
    if (!this.isTunnelRunning()) {
      return;
    }
    let result: ReloadResult = { ok: false, reason: 'not attempted' };
    try {
      result = await reloadRouting(context);
    } catch (error) {
      result = { ok: false, reason: 'exception' };
    }
    if (result.ok) {
      appLog(context, 'ui', 'routing applied live: ' + message);
      return;
    }
    appLog(context, 'ui', 'live apply failed (' + result.reason + '), restarting: ' + message);
    await this.restartTunnel(context, entry);
  }

  private toggleRuleSet(value: boolean): void {
    if (value && !this.hasRuleSet) {
      promptAction.showToast({ message: '请先更新规则集' });
      return;
    }
    this.useRuleSet = value;
    this.persist();
    const context = this.ctx;
    if (context !== null) {
      this.applyRoutingChange(context, value ? '已启用规则集' : '已关闭规则集');
    }
  }


  // One place that turns the UI state into routing options, so connect and the
  // live switches cannot drift apart.
  private buildOptions(context: common.UIAbilityContext): SplitOptions {
    const options: SplitOptions = {
      split: this.splitOn,
      geodata: geodataReady(context),
      mode: this.routeMode,
      blockQuic: this.blockQuic,
      debugLog: this.debugLog,
      // Gate on the in-memory switch: the pref write is asynchronous and a live
      // apply right after a toggle would otherwise read the previous value.
      ruleSet: this.useRuleSet ? readRuleSet(context) : null,
      blockAds: this.blockAds,
      doh: this.dohDns,
      bootstrapHosts: this.bootstrapHosts
    };
    return options;
  }

  // Resolves every node's server name once, before the tunnel exists: the core
  // otherwise asks the configured DoH through the tunnel for each name, which
  // made the per-node probe (and the first dial) 2-3 s slower.
  private async resolveNodeHosts(context: common.UIAbilityContext): Promise<Record<string, string[]> | null> {
    const hosts: Record<string, string[]> = {};
    const domains: string[] = [];
    for (const item of readStore(context).items) {
      const outbound: Record<string, Object> | null = proxyOutbound(item.json);
      if (outbound === null) {
        continue;
      }
      const endpoint: NodeEndpoint | null = outboundEndpoint(outbound);
      if (endpoint === null || endpoint.host.length === 0 || this.isIpLiteral(endpoint.host)) {
        continue;
      }
      if (domains.indexOf(endpoint.host) < 0) {
        domains.push(endpoint.host);
      }
    }
    // A probe target that is a literal needs no entry; a hostname would be
    // resolved here so the core never asks DoH for it.
    if (TEST_HOST.length > 0 && domains.indexOf(TEST_HOST) < 0) {
      domains.push(TEST_HOST);
    }
    const lookups: Promise<void>[] = domains.map((domain: string): Promise<void> => {
      return this.resolveOneHost(domain, hosts);
    });
    const all: Promise<void> = Promise.all(lookups).then((): void => {
    });
    // Never let a blocked resolver hold up the connect: 1.5 s budget, partial
    // hosts are fine (the core falls back to its own DNS for the rest).
    const budget: Promise<void> = new Promise<void>((resolve) => {
      setTimeout((): void => {
        resolve();
      }, 1500);
    });
    await Promise.race([all, budget]);
    return Object.keys(hosts).length > 0 ? hosts : null;
  }

  private isIpLiteral(host: string): boolean {
    if (host.indexOf(':') >= 0) {
      return true;
    }
    const parts: string[] = host.split('.');
    if (parts.length !== 4) {
      return false;
    }
    for (const part of parts) {
      const value: number = parseInt(part, 10);
      if (isNaN(value) || value < 0 || value > 255 || String(value) !== part) {
        return false;
      }
    }
    return true;
  }

  private async resolveOneHost(domain: string, hosts: Record<string, string[]>): Promise<void> {
    // Plain UDP first (what the user asked for: the speed test must not depend
    // on DoH), then the platform resolver as a fallback.
    const udp: string[] = await resolveUdp(domain, 700);
    if (udp.length > 0) {
      hosts[domain] = udp;
      return;
    }
    const timeout: Promise<connection.NetAddress[]> = new Promise((resolve) => {
      setTimeout((): void => {
        resolve([]);
      }, 700);
    });
    try {
      const list: connection.NetAddress[] = await Promise.race([
        connection.getAddressesByName(domain), timeout
      ]);
      const ips: string[] = [];
      for (const entry of list) {
        if (entry.address.length > 0 && ips.indexOf(entry.address) < 0) {
          ips.push(entry.address);
        }
      }
      if (ips.length > 0) {
        hosts[domain] = ips;
      }
    } catch (error) {
    }
  }

  // GFW / 绕过大陆 / 全局: rewrite config.json, then ask the extension to swap the
  // routing table of the running core. That keeps the tunnel up (no re-dial, no
  // notification flicker); if the swap is refused (old single-node config) the
  // tunnel is restarted instead.
  private async selectMode(mode: string): Promise<void> {
    if (this.routeMode === mode) {
      return;
    }
    this.routeMode = mode;
    this.persist();
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null) {
      return;
    }
    buildAndSaveTunnel(context, entry, this.buildOptions(context));
    if (!this.isTunnelRunning()) {
      return;
    }
    let result: ReloadResult = { ok: false, reason: 'not attempted' };
    try {
      result = await reloadRouting(context);
    } catch (error) {
      result = { ok: false, reason: 'exception' };
    }
    if (result.ok) {
      appLog(context, 'ui', 'routing swapped live: ' + mode);
      return;
    }
    appLog(context, 'ui', 'live routing swap failed (' + result.reason + '), restarting tunnel: ' + mode);
    await this.restartTunnel(context, entry);
  }

  // DNS lives in the config, not in the routing table, so a DoH switch needs a
  // real restart (the core loads DNS once per handle).
  private async toggleDoh(value: boolean): Promise<void> {
    this.dohDns = value;
    this.persist();
    const context = this.ctx;
    if (context === null || !this.isTunnelRunning()) {
      return;
    }
    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null) {
      return;
    }
    await this.restartTunnel(context, entry);
  }

  private isTunnelRunning(): boolean {
    const context = this.ctx;
    if (context === null) {
      return false;
    }
    return tunnelUp(context);
  }

  private modeName(mode: string): string {
    if (mode === MODE_GFW) {
      return 'GFW';
    }
    if (mode === MODE_GLOBAL) {
      return '全局';
    }
    return '绕过大陆';
  }

  // Rebuild config.json and bounce the tunnel: stop first because the extension
  // ignores a duplicate start while the core is alive.
  private async restartTunnel(context: common.UIAbilityContext, entry: ConfigEntry): Promise<void> {
    buildAndSaveTunnel(context, entry, this.buildOptions(context));
    try {
      await stopVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange));
    } catch (error) {
      appLog(context, 'ui', 'stop before restart failed: ' + JSON.stringify(error));
    }
    await startVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange, this.taskNotificationId, entry.name));
  }

  private poll(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (ssidSuspended(context)) {
      // Paused by an SSID rule: the button still reads as "on" (the user asked
      // for a connected-looking but yellow switch), while the tunnel is down.
      this.state = 'suspended';
      this.message = '已挂起（当前 Wi-Fi）';
      this.setSwitch(true);
      this.seconds = 0;
      this.upSpeed = 0;
      this.downSpeed = 0;
      return;
    }
    const status: TunnelStatus | null = readStatus(context);
    const now: number = Date.now();
    if (status !== null) {
      if (status.state === 'suspended') {
        // The extension paused the core for this Wi-Fi (it stays alive, so it
        // can resume on its own). Release the task: a paused tunnel has nothing
        // to keep alive and should not leave a stale card on the lock screen.
        if (this.keepAliveStarted) {
          this.stopKeepAliveTask();
        }
        this.state = 'suspended';
        this.message = status.message.length > 0 ? status.message : '已挂起（当前 Wi-Fi）';
        this.setSwitch(false);
        this.seconds = 0;
        this.upSpeed = 0;
        this.downSpeed = 0;
        return;
      }
      this.lastBeatAt = Math.max(this.lastBeatAt, status.updatedAt);
      const stale: boolean = now - status.updatedAt > HEARTBEAT_STALE_MS;
      if (!stale) {
        // A fresh beat means the extension is alive: reset the relaunch budget.
        this.recoveryAttempts = 0;
        this.nextRecoveryAt = 0;
        this.reviveFailures = 0;
        // A running tunnel with no stored intent (e.g. the app died between
        // startVpn and the markActive flush) must still be supervised.
        if (!this.busy && !this.intentOn && status.state === 'running') {
          this.intentOn = true;
          appLog(context, 'ui', 'intent inferred from a running tunnel');
        }
      }
      const recovering: boolean = stale && this.intentOn;
      const switching: boolean = stale && this.intentOn &&
        now - this.networkSwitchAt < NETWORK_GRACE_MS;
      this.state = recovering ? 'recovering' : (stale ? 'unknown' : status.state);
      this.message = switching ? '网络切换，正在重绑' :
        (recovering ? '心跳中断，正在恢复' :
          (stale ? '断开' : (status.state === 'stopped' ? '断开' : status.message)));
      this.up = status.up;
      this.down = status.down;
      this.flows = status.tcpFlows + status.udpFlows;
      this.seconds = (status.state === 'running' && !stale) ? (now - status.startedAt) / 1000 : 0;
      this.statusAge = Math.floor((now - status.updatedAt) / 1000);
      this.probeMs = status.probeMs;
      this.pssKb = status.pssKb ?? 0;
      this.cpuPercent = status.cpuPercent ?? 0;
      if (status.state === 'running' && status.startedAt !== this.lastStartedAt) {
        this.lastStartedAt = status.startedAt;
      }
      // An SSID suspension stops the task; a resumed tunnel needs its single
      // live-view card back (the extension cannot request it on its own).
      if (status.state === 'running' && !stale && !this.keepAliveStarted &&
        !this.keepAliveOwnedByTemp && now - this.lastNotifRefreshAt > 3000) {
        this.lastNotifRefreshAt = now;
        this.reviveTask().catch(() => {
        });
      }
      // Fallback speed when the push channel is unavailable: derive it from
      // consecutive polls instead of leaving the gauges at zero.
      if (!stale && now - this.lastEventAt > 2500) {
        if (this.prevStamp > 0 && now > this.prevStamp) {
          const delta: number = (now - this.prevStamp) / 1000;
          this.upSpeed = Math.max(0, (status.up - this.prevUp) / delta);
          this.downSpeed = Math.max(0, (status.down - this.prevDown) / delta);
        }
        this.prevUp = status.up;
        this.prevDown = status.down;
        this.prevStamp = now;
      }
      // While recovering, the switch stays on (the user still wants the tunnel)
      // and the supervisor relaunches the extension below. A hard "off" here
      // made the old self-heal unreachable: it tested this.isOn after clearing it.
      if (recovering) {
        this.setSwitch(true);
      } else {
        this.setSwitch(!stale && (status.state === 'running' || status.state === 'starting'));
      }
      // Keep the continuous task during recovery: the relaunched extension
      // publishes its live view on the same notification id. It is released
      // only when the user turns the tunnel off or the budget is exhausted.
      this.supervise(context);
    } else {
      // 没有状态文件：要么还在连接（busy），要么扩展进程已经没了。后者按
      // 「保活优先」拉起扩展（用已保存的 config，不重建、不先 stop）。
      if (this.busy) {
        this.state = 'starting';
        this.message = '正在创建 VPN';
        this.setSwitch(true);
        this.statusAge = -1;
      } else if (this.intentOn) {
        this.state = 'recovering';
        this.message = '扩展未运行，正在拉起';
        this.setSwitch(true);
        this.statusAge = -1;
        this.supervise(context);
      } else {
        this.state = 'stopped';
        this.message = '断开';
        this.seconds = 0;
        this.statusAge = -1;
        this.setSwitch(false);
      }
    }
    this.tickCount++;
    if (this.showLogs && this.tickCount % 3 === 0) {
      this.logs = readLogs(context, 6000);
    }
  }


  // 心跳监督（双进程互看的第一半）：UI 每 5 s 看一次 status.json，超过
  // HEARTBEAT_STALE_MS 没有新心跳就认为扩展进程没了。此时用已保存的
  // config.json 直接再次 startVpn —— 不重建配置、不先 stop，属于「拉起」
  // 而不是「重启」。1/2/4/8 s 退避，最多 5 次；有心跳就清零预算。
  private supervise(context: common.UIAbilityContext): void {
    if (!this.intentOn || this.busy || this.recovering) {
      return;
    }
    const now: number = Date.now();
    // Wi-Fi/cellular switch: native.rebind() can hold the extension's JS thread
    // for seconds. Give it the same grace the network event started; never
    // relaunch (or stop) a possibly-live extension during that window.
    if (now - this.networkSwitchAt < NETWORK_GRACE_MS) {
      return;
    }
    const since: number = Math.max(this.lastBeatAt, this.lastStartRequestAt);
    if (now - since < HEARTBEAT_STALE_MS || now < this.nextRecoveryAt) {
      return;
    }
    if (this.recoveryAttempts >= RECOVERY_MAX_ATTEMPTS) {
      appLog(context, 'ui', 'extension recovery budget exhausted after ' + this.recoveryAttempts);
      this.intentOn = false;
      this.state = 'stopped';
      this.message = '断开（恢复失败）';
      this.setSwitch(false);
      this.stopKeepAliveTask();
      PipManager.getInstance().setAutoStart(context, false);
      PipManager.getInstance().stop();
      return;
    }
    this.recoveryAttempts++;
    const backoff: number = Math.min(15000, 1000 * Math.pow(2, this.recoveryAttempts - 1));
    this.nextRecoveryAt = now + backoff;
    this.state = 'recovering';
    this.message = '心跳中断 ' + Math.floor((now - since) / 1000) + 's，正在拉起扩展';
    this.setSwitch(true);
    appLog(context, 'ui', 'heartbeat missing for ' + Math.floor((now - since) / 1000) +
      's, relaunch attempt ' + this.recoveryAttempts + ', next in ' + backoff + 'ms');
    this.reviveExtension().catch((): void => {
    });
  }

  private async reviveExtension(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.recovering) {
      return;
    }
    this.recovering = true;
    try {
      const entry: ConfigEntry | null = selectedEntry(context);
      const saved: string = loadConfig(context);
      if (entry === null || saved.length === 0) {
        // No usable saved config: the only correct move is a full connect,
        // which rebuilds it. Still bounded by the same recovery budget.
        appLog(context, 'ui', 'no saved config for relaunch, rebuilding');
        this.recovering = false;
        await this.connect();
        return;
      }
      if (!this.keepAliveStarted) {
        await this.startKeepAliveTask();
      }
      this.lastStartRequestAt = Date.now();
      try {
        await startVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange,
          this.taskNotificationId, entry.name));
        appLog(context, 'ui', 'extension relaunch requested with saved config (no rebuild)');
      } catch (error) {
        const err = error as BusinessError;
        this.reviveFailures++;
        appLog(context, 'ui', 'extension relaunch failed (' + this.reviveFailures + '): ' +
          (err.message ?? 'unknown'));
        // Do NOT stop on the first rejection: a live extension that is merely
        // busy rebinding rejects a duplicate start, and stopping it would turn
        // a network switch into a full VPN drop. Only clear the system slot
        // after several consecutive failures.
        if (this.reviveFailures >= 3) {
          this.reviveFailures = 0;
          try {
            await stopVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange));
          } catch (stopError) {
          }
        }
      }
    } finally {
      this.recovering = false;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private openConnections(): void {
    router.pushUrl({ url: 'pages/Connections' }).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开连接页失败: ' + error.message });
    });
  }

  private openNodes(): void {
    router.pushUrl({ url: 'pages/Configs' }).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开节点页失败: ' + error.message });
    });
  }

  // Node list inside the node card: pick a row to switch the tunnel to it.
  private loadNodeList(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const store = readStore(context);
    this.nodeList = store.items;
    this.selectedId = store.selectedId;
  }

  // Latency for every node in the expanded list: four probes in flight, 4 s
  // timeout each, results appear as they come in so a node can be picked while
  // the rest are still measuring.
  // Real RTT to the node: a plain TCP connect from this (net-protected) process
  // reaches the server directly, so the measured time is one network round trip -
  // both a completed handshake and an immediate RST land at ~1 RTT. No TLS, no
  // proxy handshake, no HTTP, which is why the numbers are far lower than the
  // request-based probe.
  private async tcpRtt(host: string, port: number, timeoutMs: number): Promise<number> {
    if (host.length === 0 || port <= 0) {
      return -1;
    }
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
    } catch (error) {
      return -1;
    }
    const handle: socket.TCPSocket = tcp;
    const started: number = Date.now();
    return new Promise<number>((resolve) => {
      let settled: boolean = false;
      let timer: number = -1;
      const finish = (value: number): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer !== -1) {
          clearTimeout(timer);
        }
        try {
          handle.close();
        } catch (error) {
        }
        resolve(value);
      };
      timer = setTimeout(() => {
        finish(-1);
      }, timeoutMs);
      handle.on('connect', () => {
        finish(Date.now() - started);
      });
      handle.on('error', () => {
        // A refused connection also arrives after one round trip.
        finish(Date.now() - started);
      });
      const options: socket.TCPConnectOptions = {
        address: { address: host, port: port },
        timeout: timeoutMs
      };
      handle.connect(options).then(() => {
        finish(Date.now() - started);
      }).catch(() => {
        finish(Date.now() - started);
      });
    });
  }

  // Numbers measured anywhere (this list or the node page) are read back from
  // the shared cache, so opening a list never probes on its own.
  private loadLatencyCache(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const cache: Map<string, LatencyEntry> = readLatencyCache(context);
    const values: Map<string, number> = new Map<string, number>();
    cache.forEach((value: LatencyEntry, key: string) => {
      values.set(key, value.ms);
    });
    this.nodeLatency = values;
  }

  private async probeNodes(): Promise<void> {
    if (this.nodeProbing) {
      return;
    }
    this.nodeProbing = true;
    const entries: ConfigEntry[] = this.nodeList.slice();
    const measured: Map<string, number> = new Map<string, number>();
    let cursor: number = 0;
    const worker = async (): Promise<void> => {
      while (cursor < entries.length) {
        const item: ConfigEntry = entries[cursor];
        cursor++;
        try {
          const endpoint = nodeEndpoint(item.json);
          let rtt: number = endpoint === null
            ? -1
            : await measureLatency(endpoint.host, endpoint.port, 3000);
          let via: string = 'tcp';
          if (rtt < 0 && this.isUdpNode(item.type)) {
            // UDP-only servers drop the TCP handshake; fall back to a real
            // request through the core so the row still shows something useful.
            const probe = await probeOutbound(NODE_TEST_URL, 8000, item.id);
            rtt = (probe.status === 0 && probe.delayMs > 0) ? probe.delayMs : -1;
            via = 'http';
          }
          measured.set(item.id, rtt);
          const context = this.ctx;
          if (context !== null) {
            recordLatency(context, item.id, rtt, via);
          }
        } catch (error) {
          measured.set(item.id, -1);
        }
        this.nodeLatency = new Map<string, number>(measured);
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < 4; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    this.nodeLatency = new Map<string, number>(measured);
    this.nodeProbing = false;
  }

  // Hysteria / TUIC / QUIC nodes listen on UDP only, so a TCP handshake is not a
  // latency sample for them.
  private isUdpNode(type: string): boolean {
    const value: string = type.toLowerCase();
    return value.indexOf('hysteria') >= 0 || value.indexOf('tuic') >= 0 ||
      value.indexOf('quic') >= 0 || value.indexOf('h3') >= 0 || value.indexOf('wireguard') >= 0;
  }

  private latencyText(id: string): string {
    const value: number | undefined = this.nodeLatency.get(id);
    if (value === undefined) {
      return this.nodeProbing ? '…' : '';
    }
    if (value < 0) {
      return '超时';
    }
    if (value >= 1000) {
      return (Math.round(value / 10) / 100) + ' s';
    }
    return value + ' ms';
  }

  private latencyColor(id: string): string {
    const value: number | undefined = this.nodeLatency.get(id);
    if (value === undefined) {
      return '#4C5D77';
    }
    if (value < 0) {
      return '#FF5C7A';
    }
    if (value < 300) {
      return '#3DDC97';
    }
    return value < 800 ? '#FFC857' : '#FF8A5B';
  }

  private async pickNode(item: ConfigEntry): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (item.id !== this.selectedId) {
      selectEntry(context, item.id);
      this.selectedId = item.id;
      this.entryName = item.name;
      this.hasEntry = true;
      if (this.isTunnelRunning()) {
        await this.restartTunnel(context, item);
      }
    }
    this.nodeExpanded = false;
  }

  private setSwitch(value: boolean): void {
    if (this.isOn === value) {
      return;
    }
    this.switchProgrammatic = true;
    this.isOn = value;
    // If the platform does not emit onChange for a code-side change, the flag
    // must not swallow the next real tap (that made the switch look dead and
    // the UI report "断开" after a resume).
    setTimeout((): void => {
      this.switchProgrammatic = false;
    }, 300);
  }


  // 桌面卡片会用 want.parameters.op 把「连接 / 断开」交给我们；页面一显示就消费掉。
  private consumeCardOp(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    // Fast path: EntryAbility writes AppStorage synchronously in onCreate /
    // onNewWant, so the page sees the op even before the async prefs flush.
    const quick: string | undefined = AppStorage.get<string>('wayCardOp');
    if (quick !== undefined && quick.length > 0) {
      AppStorage.set<string>('wayCardOp', '');
      this.clearPersistedCardOp(context);
      appLog(context, 'card', 'consuming card op: ' + quick);
      this.runCardOp(quick);
      return;
    }
    preferences.getPreferences(context, 'way').then((store) => {
      const op: string = store.getSync('cardOp', '') as string;
      if (op.length === 0) {
        return;
      }
      store.putSync('cardOp', '');
      store.flush();
      appLog(context, 'card', 'consuming card op: ' + op);
      this.runCardOp(op);
    }).catch((): void => {
    });
  }

  // The AppStorage fast path already consumed the op; drop the persisted copy
  // so a later onPageShow cannot execute the same card tap a second time.
  private clearPersistedCardOp(context: common.UIAbilityContext): void {
    preferences.getPreferences(context, 'way').then((store) => {
      if ((store.getSync('cardOp', '') as string).length > 0) {
        store.putSync('cardOp', '');
        store.flush();
      }
    }).catch((): void => {
    });
  }

  private runCardOp(op: string): void {
    if (op === 'connect') {
      this.connect().catch((): void => {
      });
    } else if (op === 'disconnect') {
      this.disconnect().catch((): void => {
      });
    }
  }

  private async connect(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.busy) {
      return;
    }

    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null) {
      promptAction.showToast({ message: '请先添加一个节点' });
      this.openNodes();
      return;
    }
    // On a suspend-SSID Wi-Fi the switch only reflects the suspended state:
    // starting the tunnel here would be stopped again by the watcher, so the
    // user's intent ("turn on") has to surface as "suspended" instead.
    const currentSsidName: string = await currentSsid();
    const ssidRule: SsidRule | null = findRule(context, currentSsidName);
    if (ssidRule !== null && ssidRule.action === SSID_SUSPEND) {
      // Turning on is a deliberate intent, so clear a previous "user off".
      await this.markActive(true);
      setSsidSuspended(context, true);
      setAppliedSsidAction(context, SSID_SUSPEND);
      this.state = 'suspended';
      this.message = '已挂起（当前 Wi-Fi）';
      this.setSwitch(true);
      promptAction.showToast({ message: '当前 Wi-Fi 已设置挂起' });
      return;
    }
    this.busy = true;
    this.usedFallback = false;
    // A deliberate connect resets the recovery budget and registers intent.
    this.intentOn = true;
    this.recoveryAttempts = 0;
    this.nextRecoveryAt = 0;
    if (this.connectWatchdog !== -1) {
      clearTimeout(this.connectWatchdog);
    }
    // Never leave the switch busy forever if a platform call stalls. The
    // watchdog is longer than the whole retry window below.
    this.connectWatchdog = setTimeout(() => {
      this.busy = false;
      this.connectWatchdog = -1;
    }, CONNECT_WATCHDOG_MS);
    this.message = '正在准备配置';
    let notifId: number = -1;
    let started: boolean = false;
    let lastError: string = '';
    try {
      // Every saved node goes into the tunnel config as a tagged outbound so the
      // node list can measure each node through the core (real delay) without
      // switching the tunnel. The selected node stays the default outbound.
      this.bootstrapHosts = await this.resolveNodeHosts(context);
      const tunnel: TunnelConfigResult =
        buildAndSaveTunnel(context, entry, this.buildOptions(context));
      appLog(context, 'ui', 'tunnel config: ' + tunnel.count + ' outbounds' +
        (tunnel.multi ? '' : ' (single)'));
      clearStatus(context);
      this.state = 'starting';
      this.message = '正在创建 VPN';
      this.setSwitch(true);
      // 1) Notification/task first. The extension draws its live view on the
      // notification id returned by startBackgroundRunning; starting the VPN
      // before that id exists (or before the permission dialog settles) is what
      // made the first taps fail. Wait for readiness, then register the task.
      if (this.notifyMe) {
        await this.ensureNotifyReady(2500);
      }
      notifId = await this.startKeepAliveTask();
      for (let attempt: number = 0; notifId < 0 && attempt < 2; attempt++) {
        appLog(context, 'ui', 'continuous task not ready, retrying ' + (attempt + 1));
        await this.delay(400 * (attempt + 1));
        this.keepAliveStarted = false;
        notifId = await this.startKeepAliveTask();
      }
      if (notifId >= 0) {
        // Give the system a beat to publish the task notification before the
        // extension publishes the first live view on that id.
        await this.delay(300);
      }
      // 2) Start the VPN, then verify status.json. This is the "connects only
      // on the third tap" fix: each attempt waits for a fresh heartbeat, and a
      // failed attempt clears the half-created VPN before the next one.
      for (let attempt: number = 0; attempt < CONNECT_ATTEMPTS && !started; attempt++) {
        this.lastStartRequestAt = Date.now();
        try {
          await startVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange, notifId, entry.name));
          appLog(context, 'ui', 'vpn start requested (attempt ' + (attempt + 1) + ')');
        } catch (error) {
          const err = error as BusinessError;
          lastError = err.message ?? JSON.stringify(error);
          appLog(context, 'ui', 'vpn start attempt ' + (attempt + 1) + ' failed: ' + lastError);
        }
        started = await this.waitTunnelReady(context, 3200);
        if (!started && attempt < CONNECT_ATTEMPTS - 1) {
          const backoff: number = 500 * Math.pow(2, attempt);
          appLog(context, 'ui', 'tunnel not ready, retry in ' + backoff + 'ms');
          await this.delay(backoff);
          try {
            await stopVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange));
          } catch (stopError) {
          }
          clearStatus(context);
        }
      }
      if (!started) {
        throw new Error(lastError.length > 0 ? lastError : '扩展未在限定时间内就绪');
      }
      this.markActive(true);
      this.intentOn = true;
      this.recoveryAttempts = 0;
      this.nextRecoveryAt = 0;
      this.lastBeatAt = Date.now();
      // Create the PiP controller while still foreground, so the next
      // background reliably auto-starts the small keepalive window.
      if (this.pipKeepAlive) {
        PipManager.getInstance().setAutoStart(context, true);
        PipManager.getInstance().stop();
      }
      if (tunnel.multi) {
        this.watchMultiNodeStart(tunnel.single, entry.name, notifId, 0);
      }
    } catch (error) {
      const err = error as BusinessError;
      this.state = 'error';
      this.message = '启动失败: ' + (err.message ?? JSON.stringify(error));
      this.setSwitch(false);
      // The switch is off, so the supervisor must not fight the user's view.
      this.intentOn = false;
      PipManager.getInstance().setAutoStart(context, false);
      PipManager.getInstance().stop();
      appLog(context, 'ui', 'vpn start failed: ' + (err.message ?? JSON.stringify(error)));
      // Leave no half-created VPN or dangling task notification behind: the
      // next tap must start from the same clean slot as a cold launch.
      try {
        await stopVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange));
      } catch (stopError) {
      }
      this.stopKeepAliveTask();
      clearStatus(context);
      promptAction.showToast({ message: this.message });
    } finally {
      if (this.connectWatchdog !== -1) {
        clearTimeout(this.connectWatchdog);
        this.connectWatchdog = -1;
      }
      this.busy = false;
    }
  }

  // Wait until the extension has written a fresh status.json. A tunnel that is
  // still booting (fresh "starting" heartbeat) is accepted rather than stopped:
  // killing a healthy boot is exactly the failure this retry loop must avoid.
  private async waitTunnelReady(context: common.UIAbilityContext,
    timeoutMs: number): Promise<boolean> {
    const deadline: number = Date.now() + timeoutMs;
    let sawStarting: boolean = false;
    while (Date.now() < deadline) {
      const status: TunnelStatus | null = readStatus(context);
      if (status !== null) {
        const fresh: boolean = Date.now() - status.updatedAt < 4000;
        if (status.state === 'running' && fresh) {
          return true;
        }
        if (status.state === 'error') {
          return false;
        }
        if (status.state === 'starting' && fresh) {
          sawStarting = true;
        }
      }
      await this.delay(250);
    }
    return sawStarting;
  }

  // Ask for notification permission and wait a bounded time for it. The old
  // fire-and-forget call left the first connect racing the permission dialog;
  // the user needed several taps before the task notification existed.
  private async ensureNotifyReady(timeoutMs: number): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return;
      }
      notificationManager.requestEnableNotification(context).catch((error: BusinessError) => {
        appLog(context, 'ui', 'notification permission: ' + (error.message ?? 'denied'));
      });
      const deadline: number = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        await this.delay(250);
        if (await notificationManager.isNotificationEnabled()) {
          return;
        }
      }
      appLog(context, 'ui', 'notification permission still off, starting anyway');
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'ui', 'notification readiness failed: ' + (err.message ?? 'unknown'));
    }
  }

  // One bad outbound fails the whole configuration load, so a failed multi-node
  // start is retried once with the single selected node: the tunnel must come up
  // even when a saved node is unusable. A slow boot is not a failure, so the
  // check repeats a couple of times while the status file is still missing.
  private watchMultiNodeStart(singleText: string, nodeName: string, notifId: number,
    attempt: number): void {
    setTimeout(() => {
      const context = this.ctx;
      if (context === null || this.usedFallback) {
        return;
      }
      const status: TunnelStatus | null = readStatus(context);
      if (status === null) {
        if (attempt < 2) {
          this.watchMultiNodeStart(singleText, nodeName, notifId, attempt + 1);
        }
        return;
      }
      if (status.state !== 'error') {
        return;
      }
      this.usedFallback = true;
      appLog(context, 'ui', 'multi-node config rejected, retrying with the single node');
      saveConfig(context, singleText);
      startVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange, notifId, nodeName))
        .catch((error: BusinessError) => {
          appLog(context, 'ui', 'single-node retry failed: ' + (error.message ?? 'unknown'));
        });
    }, 3000);
  }


  // The continuous task is owned by the visible main ability: launching the
  // windowless TempAbility used to swap the foreground window to its splash
  // screen, which looked like the UI freezing right after enabling the proxy.
  private async startKeepAliveTask(): Promise<number> {
    // Per docs/keepalive-harmony.md: the main ability owns the DATA_TRANSFER
    // task (a windowless UIAbility steals the foreground and shows its splash,
    // which is the "two cards / stuck UI" bug). Request the task FIRST, then
    // start the VPN with the returned notification id.
    const context = this.ctx;
    if (context === null) {
      return -1;
    }
    // The widget-preview TempAbility owns the single continuous task; asking
    // for another one is what produced two notifications.
    if (this.keepAliveOwnedByTemp) {
      return -1;
    }
    if (this.keepAliveStarted && this.taskNotificationId >= 0) {
      return this.taskNotificationId;
    }
    // A previous request may have set the flag without a usable id; force a
    // fresh request instead of returning -1 forever.
    this.keepAliveStarted = false;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.way.app',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      this.registerTaskWatch();
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      const taskInfo: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(context, request);
      this.taskId = taskInfo.continuousTaskId ?? -1;
      this.taskNotificationId = taskInfo.notificationId;
      this.keepAliveStarted = true;
      appLog(context, 'ui', 'continuous task started (dataTransfer live view) id=' + this.taskId +
        ' notification=' + this.taskNotificationId);
      return this.taskNotificationId;
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'ui', 'continuous task failed: ' + (err.message ?? 'unknown'));
      return -1;
    }
  }

  private stopKeepAliveTask(): void {
    const context = this.ctx;
    if (context === null || !this.keepAliveStarted) {
      return;
    }
    this.keepAliveStarted = false;
    this.taskNotificationId = -1;
    backgroundTaskManager.stopBackgroundRunning(context).catch(() => {
    });
  }

  // Swiping the task card cancels the continuous task; re-request it so the
  // tunnel keeps its single live-view card (docs/keepalive-harmony.md).
  private registerTaskWatch(): void {
    if (this.taskWatchRegistered) {
      return;
    }
    this.taskWatchRegistered = true;
    backgroundTaskManager.on('continuousTaskCancel',
      (cancelInfo: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        const context = this.ctx;
        if (context === null) {
          return;
        }
        if (this.keepAliveOwnedByTemp) {
          // Expected: we released our task on purpose for the TempAbility.
          appLog(context, 'ui', 'continuous task canceled (owned by TempAbility)');
          return;
        }
        appLog(context, 'ui', 'continuous task canceled, reviving');
        this.keepAliveStarted = false;
        setTimeout(() => {
          this.reviveTask().catch(() => {
          });
        }, 800);
      });
  }

  private async reviveTask(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const id: number = await this.startKeepAliveTask();
    if (id < 0) {
      return;
    }
    try {
      const data: commonEventManager.CommonEventPublishData = {
        parameters: { 'taskNotificationId': id }
      };
      commonEventManager.publish('com.way.app.TASK_ID', data, () => {
      });
    } catch (error) {
    }
  }


  private async markActive(active: boolean): Promise<void> {
    // Keep the in-memory intent in sync before the (possibly slow) flush: the
    // heartbeat supervisor reads it every poll.
    this.intentOn = active;
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, 'way');
      store.putSync('vpnActive', active);
      // Remember the last explicit state separately from the live intent: after
      // a manual swipe the intent is cleared (no background resurrection) but
      // the next launch can still auto-connect, like FlClash.
      store.putSync('lastConnected', active);
      // Remember an explicit user choice so the on-demand watcher cannot
      // reconnect against it.
      store.putSync('userOff', !active);
      if (!active) {
        // Explicit switch-off ends the widget-preview keepalive owner too.
        store.putSync('tempKeepAlive', false);
      }
      await store.flush();
    } catch (error) {
    }
  }

  // The windowless TempAbility owns the continuous task, so destroying the main
  // window no longer drops it (which used to kill the process and the tunnel).
  private async startTempAbility(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: 'com.way.app',
        abilityName: 'TempAbility'
      };
      await context.startAbility(want);
      appLog(context, 'ui', 'temp ability started');
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'ui', 'temp ability failed: ' + (err.message ?? 'unknown'));
    }
  }

  private stopTempAbility(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    // UIAbilityContext has no stopAbility(); TempAbility exits itself on this
    // event and releases the continuous task first.
    try {
      const data: commonEventManager.CommonEventPublishData = { parameters: {} };
      commonEventManager.publish('com.way.app.STOP_KEEPALIVE', data, () => {
      });
    } catch (error) {
    }
  }

  // Keep the app process (and the VPN extension inside it) alive in background.
  // The extension context is rejected with 401, so the UIAbility does it.
  private async startContinuousTask(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.backgroundRunning) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.way.app',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      // TASK_KEEPING is what FlClash-ohos uses, but phones need the
      // KEEP_BACKGROUND_RUNNING_SYSTEM ACL for it; fall back to DATA_TRANSFER,
      // which is reachable without an ACL.
      try {
        await backgroundTaskManager.startBackgroundRunning(context,
          backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
        this.backgroundRunning = true;
        appLog(context, 'ui', 'continuous task started (taskKeeping)');
      } catch (inner) {
        const keepErr = inner as BusinessError;
        await backgroundTaskManager.startBackgroundRunning(context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        this.backgroundRunning = true;
        appLog(context, 'ui', 'continuous task started (dataTransfer), taskKeeping failed: ' +
          (keepErr.message ?? 'unknown'));
      }
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'ui', 'continuous task failed: ' + (err.message ?? JSON.stringify(error)));
    }
  }

  private stopContinuousTask(): void {
    const context = this.ctx;
    if (context === null || !this.backgroundRunning) {
      return;
    }
    this.backgroundRunning = false;
    backgroundTaskManager.stopBackgroundRunning(context).catch((error: BusinessError) => {
      appLog(context, 'ui', 'stop continuous task failed: ' + (error.message ?? 'unknown'));
    });
  }

  private async disconnect(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.busy) {
      return;
    }
    this.busy = true;
    // The extension occasionally rejects a single stop request (busy handshake,
    // system tearing it down concurrently), which left the tunnel up with the
    // switch already off. Retry and verify instead of trusting one call.
    let stopped: boolean = false;
    for (let attempt: number = 0; attempt < 3 && !stopped; attempt++) {
      try {
        await stopVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange));
        stopped = true;
      } catch (error) {
        const err = error as BusinessError;
        appLog(context, 'ui', 'stop vpn attempt ' + (attempt + 1) + ' failed: ' +
          (err.message ?? 'unknown'));
        await new Promise<void>((resolve) => {
          setTimeout(() => {
            resolve();
          }, 300);
        });
      }
    }
    if (!stopped) {
      appLog(context, 'ui', 'stop vpn failed after retries, clearing state anyway');
    }
    this.stopKeepAliveTask();
    this.markActive(false);
    this.stopTempAbility();
    this.keepAliveOwnedByTemp = false;
    PipManager.getInstance().setAutoStart(context, false);
    PipManager.getInstance().stop();
    // Turning the switch off on a suspended Wi-Fi means "off", not "suspend
    // again": clear the policy markers so the watcher leaves it alone until the
    // user turns it on again.
    setSsidSuspended(context, false);
    setAppliedSsidAction(context, '');
    this.state = 'stopped';
    this.message = '断开';
    this.setSwitch(false);
    this.seconds = 0;
    this.up = 0;
    this.down = 0;
    this.flows = 0;
    clearStatus(context);
    this.busy = false;
  }

  private async refreshSsid(): Promise<void> {
    const ssid: string = await currentSsid();
    this.currentWifi = ssid;
  }


  private toggleOnDemand(value: boolean): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    this.onDemand = value;
    setFlag(context, 'onDemand', value);
    if (!value) {
      // Turning on-demand off must not leave the app auto-reconnecting.
      setSsidSuspended(context, false);
      if (this.state === 'suspended') {
        this.state = 'stopped';
        this.message = '断开';
        this.setSwitch(false);
      }
    } else {
      this.refreshSsid();
    }
  }

  private wifiTarget(): string {
    if (this.currentWifi.length > 0) {
      return this.currentWifi;
    }
    return this.manualSsid.trim();
  }

  private async requestLocation(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const manager = abilityAccessCtrl.createAtManager();
      await manager.requestPermissionsFromUser(context, ['ohos.permission.APPROXIMATELY_LOCATION']);
      this.refreshSsid();
    } catch (error) {
      appLog(context, 'ui', 'location permission request failed');
    }
  }

  private addRuleFromInput(action: string): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const typed: string = this.manualSsid.trim();
    const target: string = typed.length > 0 ? typed : this.currentWifi;
    if (target.length === 0) {
      promptAction.showToast({ message: '请先输入 Wi-Fi 名称' });
      return;
    }
    this.rules = setSsidRule(context, target, action);
    this.manualSsid = '';
  }

  private toggleRuleAction(rule: SsidRule): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const next: string = rule.action === SSID_SUSPEND ? SSID_DIRECT : SSID_SUSPEND;
    this.rules = setSsidRule(context, rule.ssid, next);
  }

  private setCurrentWifiRule(action: string): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const target: string = this.wifiTarget();
    if (target.length === 0) {
      promptAction.showToast({ message: '请先输入 Wi-Fi 名称' });
      return;
    }
    this.rules = setSsidRule(context, target, action);
  }

  private deleteRule(ssid: string): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    this.rules = removeSsidRule(context, ssid);
  }

  private clearRules(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    clearSsidRules(context);
    this.rules = [];
  }

  private cycleGeoSource(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const current: string = selectedPreset(context).id;
    let next: string = GEODATA_PRESETS[0].id;
    for (let i = 0; i < GEODATA_PRESETS.length; i++) {
      if (GEODATA_PRESETS[i].id === current) {
        next = GEODATA_PRESETS[(i + 1) % GEODATA_PRESETS.length].id;
        break;
      }
    }
    this.geoSourceName = selectPreset(context, next).name;
    this.runGeodataUpdate(false);
  }

  private async runGeodataUpdate(auto: boolean): Promise<void> {
    const context = this.ctx;
    if (context === null || this.geoBusy) {
      return;
    }
    this.geoBusy = true;
    this.geoText = '更新中…';
    try {
      const meta: GeodataMeta = await updateGeodata(context);
      this.geoText = formatTime(meta.updatedAt) + ' · ' +
        formatBytes(meta.geositeBytes + meta.geoipBytes);
      if (!auto) {
        promptAction.showToast({ message: '规则文件已更新' });
      }
    } catch (error) {
      const err = error as BusinessError;
      this.refreshGeodataStatus();
      if (!auto) {
        promptAction.showToast({ message: '更新失败: ' + (err.message ?? '网络错误') });
      }
    } finally {
      this.geoBusy = false;
    }
  }

  // Green while connected, amber while suspended, red for every disconnected
  // state; the header pill and the light bloom both read this.
  private statusColor(): string {
    if (this.state === 'running') {
      return '#3DDC97';
    }
    if (this.state === 'starting' || this.state === 'suspended' || this.state === 'recovering') {
      return '#FFC857';
    }
    return '#FF5C7A';
  }

  // Same colour at the given alpha, in ArkUI's #AARRGGBB order.
  private statusGlow(alpha: string): string {
    return '#' + alpha + this.statusColor().substring(1);
  }

  // Light strength 0..1 driven by the live throughput: idle keeps the glow faint,
  // a busy tunnel pushes it up (log scale so 4 KB/s already shows).
  private glowLevel(): number {
    const speed: number = this.upSpeed + this.downSpeed;
    const ramp: number = Math.log10(1 + speed / 512) / 2.6;
    return 0.18 + 0.82 * Math.min(1, ramp);
  }

  private alphaHex(ratio: number): string {
    const clamped: number = Math.max(0, Math.min(1, ratio));
    const value: number = Math.round(clamped * 255);
    const text: string = value.toString(16).toUpperCase();
    return text.length === 1 ? '0' + text : text;
  }

  // Card headline: same words as the pill, but real error text still wins.
  private stateTitle(): string {
    if (this.state === 'running' || this.state === 'suspended' ||
      this.state === 'starting' || this.state === 'recovering') {
      return this.statusLabel();
    }
    if (this.message.length === 0 || this.message === '断开') {
      return '未连接';
    }
    return this.message;
  }

  // VPN 进程（内核所在进程）的常驻内存与 CPU。
  private memoryText(): string {
    if (this.pssKb <= 0) {
      return this.state === 'running' ? '…' : '—';
    }
    return formatBytes(this.pssKb * 1024);
  }

  private cpuText(): string {
    if (this.pssKb <= 0) {
      return this.state === 'running' ? '…' : '—';
    }
    return (Math.round(this.cpuPercent * 1000) / 10) + '%';
  }

  private statusLabel(): string {
    if (this.state === 'running') {
      return '已连接';
    }
    if (this.state === 'suspended') {
      return '已挂起';
    }
    if (this.state === 'starting') {
      return '连接中';
    }
    if (this.state === 'recovering') {
      return '恢复中';
    }
    return '未连接';
  }

  build() {
    // Full-bleed background: painted under the status and navigation bars.
    // The title bar floats over the scroll content with a frosted (blurred)
    // backdrop, so cards slide underneath it instead of pushing it down.
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#101A2E', 0.0], ['#0B1020', 0.42], ['#090E1A', 1.0]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // Ambient status light *behind* the cards: it lights the page and bleeds
      // through the translucent card surface instead of sitting on top of it.
      Column()
        .width(300)
        .height(230)
        .radialGradient({
          center: [250, 62],
          radius: 150,
          colors: [
            [this.statusGlow(this.alphaHex(this.glowLevel() * 0.34)), 0.0],
            [this.statusGlow(this.alphaHex(this.glowLevel() * 0.16)), 0.5],
            [this.statusGlow('00'), 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.Transparent)
        .align(Alignment.TopEnd)
        .margin({ top: -20, right: -30 })

      Column() {
        Scroll() {
          Column({ space: 12 }) {
            this.statusCard()
            this.nodeCard()
            this.rulesCard()
            this.ssidCard()
            this.keepAliveCard()
            this.logCard()
            Column({ space: 2 }) {
              Text('HarmonyOS 代理客户端')
                .fontSize(12)
                .fontColor('#5C7192')
              Text('内核 xray-rust ' + this.coreInfo + ' · com.way.app')
                .fontSize(10)
                .fontColor('#44536B')
            }
            .width('100%')
            .margin({ top: 10, bottom: 16 })
          }
          .width('100%')
          .padding({
            left: 16,
            right: 16,
            top: this.headerHeight,
            bottom: this.insets.bottom + 12
          })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      // Very soft wash behind the title bar: no bar edge and no solid colour, it
      // only keeps the status-bar icons and the capsules readable when cards
      // scroll underneath. Touches pass through to the list.
      Column()
        .width('100%')
        .height(this.headerHeight + 10)
        .linearGradient({
          angle: 180,
          colors: [['#A60B1020', 0.0], ['#660B1020', 0.62], ['#000B1020', 1.0]]
        })
        .hitTestBehavior(HitTestMode.Transparent)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      this.header()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1020')
  }

  @Builder
  header() {
    // No bar surface at all: the page shows through between the two capsules.
    Row() {
      Row() {
          Text('way')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E8F1FF')
      }
      .padding({ left: 16, right: 16, top: 5, bottom: 6 })
      .borderRadius(22)
      .backgroundColor('#1AFFFFFF')
      // The left capsule picks up the status light as a tinted hairline, and the
      // tint breathes with the traffic like the bloom does.
      .border({ width: 1, color: this.statusGlow(this.alphaHex(0.08 + 0.32 * this.glowLevel())) })
      .backdropBlur(24)

      Blank()

      Text(this.statusLabel())
        .fontSize(13)
        .fontColor(this.statusColor())
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .borderRadius(20)
        .backgroundColor(this.statusGlow(this.alphaHex(0.10 + 0.22 * this.glowLevel())))
        .border({ width: 1, color: this.statusGlow(this.alphaHex(0.28 + 0.35 * this.glowLevel())) })
        .shadow({
          radius: 12 + 24 * this.glowLevel(),
          color: this.statusGlow(this.alphaHex(0.14 + 0.55 * this.glowLevel())),
          offsetY: 0
        })
        .backdropBlur(24)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: this.insets.top + 10, bottom: 10 })
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const measured: number = Number(newArea.height);
      if (measured > 0 && measured !== this.headerHeight) {
        this.headerHeight = measured;
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  @Builder
  statusCard() {
    Column() {
      Row() {
        Circle()
          .width(10)
          .height(10)
          .fill(this.statusColor())
        Text(this.stateTitle())
          .fontSize(15)
          .fontColor((this.state === 'suspended' || this.state === 'recovering') ? '#FFC857' : '#C7D6EC')
          .margin({ left: 10 })
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.isOn })
          .selectedColor((this.state === 'suspended' || this.state === 'recovering') ? '#F2B33D' : '#54C4FF')
          .onChange((value: boolean) => {
            if (this.switchProgrammatic) {
              this.switchProgrammatic = false;
              return;
            }
            if (this.busy) {
              return;
            }
            if (value) {
              this.connect();
            } else {
              this.disconnect();
            }
          })
      }
      .width('100%')

      Divider().color('#1C2740').margin({ top: 12, bottom: 12 })

      // Inline rather than a parameterised @Builder: ArkUI does not refresh a
      // @Builder whose arguments are passed by value, which left these metrics
      // frozen at the values of the first frame.
      Row() {
        Column() {
          Text(formatSpeed(this.downSpeed))
            .fontSize(16)
            .fontColor('#E4EEFF')
            .fontWeight(FontWeight.Medium)
          Text('↓ 累计 ' + formatBytes(this.down))
            .fontSize(10)
            .fontColor('#4C5D77')
            .margin({ top: 2 })
          Text('下载')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .layoutWeight(1)

        Column() {
          Text(formatSpeed(this.upSpeed))
            .fontSize(16)
            .fontColor('#E4EEFF')
            .fontWeight(FontWeight.Medium)
          Text('↑ 累计 ' + formatBytes(this.up))
            .fontSize(10)
            .fontColor('#4C5D77')
            .margin({ top: 2 })
          Text('上传')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .layoutWeight(1)

        Column() {
          Text(this.flows.toString())
            .fontSize(16)
            .fontColor('#E4EEFF')
            .fontWeight(FontWeight.Medium)
          Text('连接 ›')
            .fontSize(11)
            .fontColor('#54C4FF')
            .margin({ top: 2 })
          Text('点开查看')
            .fontSize(10)
            .fontColor('#4C5D77')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .onClick(() => {
          this.openConnections();
        })

        Column() {
          Text(formatDuration(this.seconds))
            .fontSize(16)
            .fontColor('#E4EEFF')
            .fontWeight(FontWeight.Medium)
          Text('时长')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
          Text('本次会话')
            .fontSize(10)
            .fontColor('#4C5D77')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
      }
      .width('100%')

      Row() {
        Text('内存 ' + this.memoryText())
          .fontSize(10)
          .fontColor('#4C5D77')
        Text('·')
          .fontSize(10)
          .fontColor('#2E3A54')
          .margin({ left: 6, right: 6 })
        Text('CPU ' + this.cpuText())
          .fontSize(10)
          .fontColor('#4C5D77')
        Blank()
        Text(this.isOn ? '内核 xray-rust ' + this.coreInfo : '')
          .fontSize(9)
          .fontColor('#2E3A54')
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(16)
    // Card body: translucent surface + hairline highlight. The light is a
    // gradient painted into the card itself (top-right corner), so the surface
    // looks lit instead of covered by a veil; it tracks the live throughput.
    .backgroundColor('#B3131A2C')
    .border({ width: 1, color: '#12FFFFFF' })
    .borderRadius(18)
    .radialGradient({
      center: ['100%', '0%'],
      radius: 330,
      colors: [
        [this.statusGlow(this.alphaHex(0.05 + 0.34 * this.glowLevel())), 0.0],
        [this.statusGlow(this.alphaHex(0.02 + 0.14 * this.glowLevel())), 0.42],
        [this.statusGlow('00'), 1.0]
      ]
    })
    .shadow({ radius: 18, color: '#4D000000', offsetY: 6 })
    .margin({ top: 6 })
  }

  @Builder
  metric(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(15)
        .fontColor('#E4EEFF')
        .fontWeight(FontWeight.Medium)
      Text(label)
        .fontSize(11)
        .fontColor('#5C7192')
        .margin({ top: 3 })
    }
    .layoutWeight(1)
  }

  @Builder
  nodeCard() {
    Column() {
      // Collapsed: 节点 + current node + 管理 (jumps to the node page) + 展开.
      Row() {
        Text('节点')
          .fontSize(14)
          .fontColor('#A9BAD1')
        Text(this.hasEntry ? this.entryName : '还没有节点')
          .fontSize(13)
          .fontColor(this.hasEntry ? '#54C4FF' : '#5C7192')
          .margin({ left: 10 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.probeMs > 0 && this.state === 'running' && !this.nodeExpanded) {
          Text(this.probeMs + ' ms')
            .fontSize(11)
            .fontColor(this.probeMs < 300 ? '#3DDC97' : (this.probeMs < 800 ? '#FFC857' : '#FF8A5B'))
            .margin({ right: 8 })
        }
        Text('管理')
          .fontSize(12)
          .fontColor('#54C4FF')
          .padding({ left: 8, right: 10, top: 4, bottom: 4 })
          .onClick(() => {
            this.openNodes();
          })
        Text(this.nodeExpanded ? '⌃' : '⌄')
          .fontSize(14)
          .fontColor('#5C7192')
      }
      .width('100%')
      .onClick(() => {
        if (!this.nodeExpanded) {
          this.loadNodeList();
        }
        this.nodeExpanded = !this.nodeExpanded;
        if (this.nodeExpanded) {
          // Expanding shows the cached numbers; measuring stays a manual action.
          this.loadLatencyCache();
        }
      })

      if (this.nodeExpanded) {
        Row() {
          Text(this.nodeProbing ? '测速中…' : '测速')
            .fontSize(11)
            .fontColor('#54C4FF')
            .onClick(() => {
              this.probeNodes();
            })
          Blank()
          Text(this.nodeLatency.size + '/' + this.nodeList.length + ' 已测')
            .fontSize(10)
            .fontColor('#5C7192')
        }
        .width('100%')
        .margin({ top: 6, bottom: 2 })

        Column() {
          ForEach(this.nodeList, (item: ConfigEntry) => {
            Row() {
              Text(item.name)
                .fontSize(13)
                .fontColor(item.id === this.selectedId ? '#54C4FF' : '#D6E4F7')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(this.latencyText(item.id))
                .fontSize(10)
                .fontColor(this.latencyColor(item.id))
                .margin({ right: 10 })
              Text(nodeTypeLabel(item.type))
                .fontSize(9)
                .fontColor('#7C8FA9')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#0F1728')
                .borderRadius(6)
                .margin({ right: 10 })
              Text(item.id === this.selectedId ? '✓' : '')
                .fontSize(13)
                .fontColor('#54C4FF')
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.pickNode(item);
            })
          }, (item: ConfigEntry) => item.id)
        }
        .width('100%')
        .margin({ top: 2 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#101827')
    .borderRadius(20)
    // The light reaches this card too, just weaker than the status card.
    .radialGradient({
      center: ['100%', '0%'],
      radius: 260,
      colors: [
        [this.statusGlow(this.alphaHex(0.02 + 0.12 * this.glowLevel())), 0.0],
        [this.statusGlow('00'), 1.0]
      ]
    })
    .border({ width: 1, color: '#0AFFFFFF' })
    .shadow({ radius: 26, color: '#3D000000', offsetY: 8 })
  }

  @Builder
  rulesCard() {
    Column() {
      // Collapsed by default: only the section name and the active mode. Tap
      // anywhere on this row to unfold the full card, tap again to fold it.
      Row() {
        Text('规则')
          .fontSize(14)
          .fontColor('#A9BAD1')
        Text(this.modeName(this.routeMode))
          .fontSize(13)
          .fontColor('#54C4FF')
          .margin({ left: 10 })
          .layoutWeight(1)
        Text(this.rulesExpanded ? '收起' : '展开')
          .fontSize(11)
          .fontColor('#5C7192')
          .margin({ right: 6 })
        Text(this.rulesExpanded ? '⌃' : '⌄')
          .fontSize(14)
          .fontColor('#5C7192')
      }
      .width('100%')
      .onClick(() => {
        this.rulesExpanded = !this.rulesExpanded;
      })

      if (this.rulesExpanded) {
      Row() {
        Text('全局模式即不分流')
          .fontSize(10)
          .fontColor('#44536B')
          .layoutWeight(1)
      }
      .width('100%')
      .margin({ top: 8 })

      Text(this.routeMode === MODE_GFW
        ? 'GFW 模式：仅被屏蔽的站点走节点，其余直连。'
        : (this.routeMode === MODE_GLOBAL
          ? '全局模式：所有流量都走节点。'
          : '绕过大陆：局域网与国内域名/IP 直连，其余走节点。'))
        .fontSize(11)
        .fontColor('#5C7192')
        .width('100%')
        .margin({ top: 6 })

      Row() {
        Text('GFW')
          .fontSize(12)
          .fontColor(this.routeMode === MODE_GFW ? '#0B1020' : '#7C8FA9')
          .backgroundColor(this.routeMode === MODE_GFW ? '#54C4FF' : '#101A2E')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(8)
          .onClick(() => {
            this.selectMode(MODE_GFW);
          })
        Text('绕过大陆')
          .fontSize(12)
          .fontColor(this.routeMode === MODE_BYPASS ? '#0B1020' : '#7C8FA9')
          .backgroundColor(this.routeMode === MODE_BYPASS ? '#54C4FF' : '#101A2E')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.selectMode(MODE_BYPASS);
          })
        Text('全局')
          .fontSize(12)
          .fontColor(this.routeMode === MODE_GLOBAL ? '#0B1020' : '#7C8FA9')
          .backgroundColor(this.routeMode === MODE_GLOBAL ? '#54C4FF' : '#101A2E')
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .height(32)
          .borderRadius(8)
          .margin({ left: 8 })
          .onClick(() => {
            this.selectMode(MODE_GLOBAL);
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Column() {
          Text('规则文件 geosite/geoip')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text(this.geoText)
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.geoBusy ? '更新中…' : '更新')
          .fontSize(12)
          .fontColor(this.geoBusy ? '#4C5D77' : '#54C4FF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#101A2E')
          .onClick(() => {
            if (!this.geoBusy) {
              this.runGeodataUpdate(false);
            }
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Column() {
          Text('屏蔽 QUIC')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text('拒绝 UDP 443，让应用回退到 TCP（推荐）')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.blockQuic })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.blockQuic = value;
            this.persist();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Column() {
          Text('诊断日志')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text('记录每条连接的路由决策，排查后再关（默认关闭）')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.debugLog })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.debugLog = value;
            this.persist();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Divider().color('#1C2740').margin({ top: 12, bottom: 12 })

      Row() {
        Column() {
          Text('分流规则集')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text(this.ruleBusy ? ('下载中 ' + this.ruleProgress) : this.ruleSetText)
            .fontSize(10)
            .fontColor(this.hasRuleSet ? '#7C8FA9' : '#5C7192')
            .margin({ top: 2 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.ruleBusy ? '…' : '更换')
          .fontSize(12)
          .fontColor(this.ruleBusy ? '#4C5D77' : '#54C4FF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#101A2E')
          .bindMenu(this.ruleMenu())
      }
      .width('100%')
      .margin({ top: 2 })

      Row() {
        Column() {
          Text('使用规则集')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text('开启后由规则集决定哪些直连、哪些走节点')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.useRuleSet })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.toggleRuleSet(value);
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Column() {
          Text('拦截广告')
            .fontSize(13)
            .fontColor(this.useRuleSet ? '#D6E4F7' : '#5C7192')
          Text(this.useRuleSet
            ? '丢弃规则集里 ' + this.blockAdText + ' 条广告域名（BanAD / BanProgramAD）'
            : '需要先开启「使用规则集」')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.blockAds })
          .selectedColor('#54C4FF')
          .enabled(this.useRuleSet)
          .opacity(this.useRuleSet ? 1 : 0.4)
          .onChange((value: boolean) => {
            this.blockAds = value;
            this.persist();
            const blocking = this.ctx;
            if (blocking !== null) {
              this.applyRoutingChange(blocking, value ? '已开启广告拦截' : '已关闭广告拦截');
            }
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Column() {
          Text('DoH DNS')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text(this.dohDns
            ? '国内 223.5.5.5 直连 · 国外 1.1.1.1 走节点（HTTPS 加密查询）'
            : '关闭时使用配置自带的普通 DNS')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.dohDns })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.toggleDoh(value);
          })
      }
      .width('100%')
      .margin({ top: 10 })


      Row() {
        Column() {
          Text('规则源')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text(this.geoSourceName + ' · 点击切换下载源')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('切换')
          .fontSize(12)
          .fontColor('#54C4FF')
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(8)
          .backgroundColor('#101A2E')
          .onClick(() => {
            this.cycleGeoSource();
          })
      }
      .width('100%')
      .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#101827')
    .borderRadius(20)
    .border({ width: 1, color: '#0AFFFFFF' })
    .shadow({ radius: 26, color: '#3D000000', offsetY: 8 })
  }

  @Builder
  ssidCard() {
    Column() {
      // Collapsed: 按需启动 + summary + the quick toggle; tap the row to expand.
      Row() {
        Text('按需启动')
          .fontSize(14)
          .fontColor('#A9BAD1')
        Text(this.onDemand ? ('已加 ' + this.rules.length + ' 条') : '关闭')
          .fontSize(12)
          .fontColor('#54C4FF')
          .margin({ left: 10 })
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.onDemand })
          .selectedColor('#54C4FF')
          .margin({ right: 10 })
          .onChange((value: boolean) => {
            this.toggleOnDemand(value);
          })
        Text(this.ssidExpanded ? '⌃' : '⌄')
          .fontSize(14)
          .fontColor('#5C7192')
      }
      .width('100%')
      .onClick(() => {
        this.ssidExpanded = !this.ssidExpanded;
      })

      if (this.ssidExpanded) {
        Text(this.onDemand
          ? ('按 Wi-Fi 自动挂起 · 已添加 ' + this.rules.length + ' 条')
          : '关闭时只手动连接；打开后按 Wi-Fi 自动连接/挂起')
          .fontSize(11)
          .fontColor('#5C7192')
          .width('100%')
          .margin({ top: 6 })

        if (this.onDemand) {
          Text(this.currentWifi.length > 0 ? ('当前 Wi-Fi：' + this.currentWifi) : '当前未连接 Wi-Fi')
            .fontSize(11)
            .fontColor(this.currentWifi.length > 0 ? '#7C8FA9' : '#4C5D77')
            .width('100%')
            .margin({ top: 6 })

          TextInput({ placeholder: this.currentWifi.length > 0 ? this.currentWifi : '输入 Wi-Fi 名称', text: this.manualSsid })
            .height(34)
            .fontSize(12)
            .fontColor('#E4EEFF')
            .placeholderColor('#7C8FA9')
            .backgroundColor(Color.Transparent)
            .border({ width: 1, color: '#35507A' })
            .borderRadius(8)
            .width('100%')
            .margin({ top: 6 })
            .onChange((value: string) => {
              this.manualSsid = value;
            })

          Row() {
            Text('添加')
              .fontSize(12)
              .fontColor('#0B1020')
              .fontWeight(FontWeight.Medium)
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(32)
              .borderRadius(8)
              .backgroundColor('#54C4FF')
              .onClick(() => {
                this.addRuleFromInput(SSID_SUSPEND);
              })
            Text('清空')
              .fontSize(12)
              .fontColor('#FF5C7A')
              .textAlign(TextAlign.Center)
              .width(48)
              .height(32)
              .margin({ left: 8 })
              .onClick(() => {
                this.clearRules();
              })
          }
          .width('100%')
          .margin({ top: 8 })

          ForEach(this.rules, (rule: SsidRule) => {
            Row() {
              Text(rule.ssid)
                .fontSize(12)
                .fontColor('#C7D6EC')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('挂起')
                .fontSize(11)
                .fontColor('#7C8FA9')
                .margin({ right: 12 })
              Text('删')
                .fontSize(11)
                .fontColor('#FF5C7A')
                .onClick(() => {
                  this.deleteRule(rule.ssid);
                })
            }
            .width('100%')
            .margin({ top: 6 })
          }, (rule: SsidRule) => rule.ssid)
        }
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#101827')
    .borderRadius(20)
    .border({ width: 1, color: '#0AFFFFFF' })
    .shadow({ radius: 26, color: '#3D000000', offsetY: 8 })
  }

  @Builder
  keepAliveCard() {
    Column() {
      Text('保活')
        .fontSize(14)
        .fontColor('#A9BAD1')
        .width('100%')
      Row() {
        Column() {
          Text('常驻通知')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text('在通知栏显示实时流量')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.notifyMe })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.notifyMe = value;
            this.persist();
          })
      }
      .width('100%')
      .margin({ top: 10 })

      Row() {
        Column() {
          Text('断网自动重连')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text('网络切换时重建底层连接')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.rebindOnNetChange })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.rebindOnNetChange = value;
            this.persist();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Column() {
          Text('模拟画中画保活')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text(this.pipKeepAlive ? '离开 App 弹小浮窗，划掉主应用后 VPN 继续' : '关闭后后台可能被系统回收')
            .fontSize(11)
            .fontColor(this.pipKeepAlive ? '#5C7192' : '#FFC857')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.pipKeepAlive })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.pipKeepAlive = value;
            this.persist();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Column() {
          Text('打开应用自动连接')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text(this.autoConnect ? '上次退出时是连接状态，启动 App 自动连上' : '启动 App 不自动连接')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.autoConnect })
          .selectedColor('#54C4FF')
          .onChange((value: boolean) => {
            this.autoConnect = value;
            this.persist();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Column() {
          Text('保活入口（卡片预览）')
            .fontSize(13)
            .fontColor('#D6E4F7')
          Text('打开系统卡片预览后直接退出，无需添加卡片')
            .fontSize(11)
            .fontColor('#5C7192')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button('打开')
          .fontSize(12)
          .height(30)
          .padding({ left: 14, right: 14 })
          .backgroundColor('#1E2C46')
          .fontColor('#8FC7FF')
          .onClick(() => {
            this.openKeepAliveForm();
          })
      }
      .width('100%')
      .margin({ top: 12 })

      Text('连接后内核运行在 VPN 扩展进程。点「保活入口」打开系统卡片预览，进入后直接退出即可拉起后台保活，不需要把卡片加到桌面。开启「模拟画中画」时，离开 App 会自动弹出小浮窗，划掉主应用后浮窗和进程保留；关闭则后台可能被回收。开启「打开应用自动连接」时，手动划掉后台会完整停止 VPN（不会在后台偷偷重启），下次打开 App 自动重连；关闭则下次启动保持断开。系统重启后需手动打开应用恢复。')
        .fontSize(11)
        .fontColor('#4C5D77')
        .margin({ top: 12 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#131A2C')
    .borderRadius(16)
  }

  @Builder
  logCard() {
    Column() {
      Row() {
        Text('日志')
          .fontSize(14)
          .fontColor('#A9BAD1')
          .layoutWeight(1)
        Text(this.showLogs ? '隐藏' : '查看')
          .fontSize(12)
          .fontColor('#54C4FF')
          .onClick(() => {
            this.showLogs = !this.showLogs;
            if (this.showLogs && this.ctx !== null) {
              this.logs = readLogs(this.ctx, 6000);
            }
          })
      }
      .width('100%')

      if (this.showLogs) {
        Text(this.logs.length > 0 ? this.logs : '（暂无日志）')
          .fontSize(10)
          .fontColor('#8FA3BF')
          .width('100%')
          .margin({ top: 10 })
          .maxLines(30)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor('#131A2C')
    .borderRadius(16)
  }
}




























































































