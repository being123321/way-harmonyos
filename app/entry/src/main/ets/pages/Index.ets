import { common } from '@kit.AbilityKit';
import { abilityAccessCtrl } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { formInfo, formProvider } from '@kit.FormKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import type { Want } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { promptAction, router, uiMaterial } from '@kit.ArkUI';
import { CommonModifier } from '@ohos.arkui.modifier';
import { connection } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import {
  ALL_THEMES, AppTheme, THEME_DARK, loadSavedThemeId, saveThemeId, syncWindowBars, themeById
} from '../common/Theme';
import {
  APP_VERSION_NAME, CORE_ID_RUST, CORE_ID_UPSTREAM, CORE_RUST_REPO_URL, CORE_UPSTREAM_REPO_URL,
  CORE_VERSION_NAME, CoreUpdateState, DISCLAIMER_TEXT, KernelManifestEntry, PROJECT_REPO_URL,
  UpdateCheckResult, checkAllUpdates, defaultCoreState, isCoreBundled, markCoreHealthy,
  readCoreState, rollbackCoreOnError, stageCoreUpdate
} from '../common/Updater';
import {
  Insets, NodeBadge, ReloadResult, TunnelStatus, appBundleName, appEvent, clearStatus, coreVersion,
  extractNodeBadges, formatBytes, formatDuration, formatTime, reloadRouting, tunnelUp,
  NodeEndpoint, formatSpeed, nodeEndpoint, nodeTypeLabel, outboundEndpoint, pageInsets, readLogs,
  tunnelOutboundTags, xrayDir, readStatus, saveConfig, saveTaskNotificationId, startVpn, stopVpn,
  vpnWant, loadConfig
} from '../common/Xray';
import {
  ConfigEntry, SubscriptionRecord, entriesOfSub, findById, manualEntries, readStore, readSubs,
  removeEntry, removeSub, selectEntry, selectedEntry, subIdOf, updateSub
} from '../common/Store';
import { formatExpire, formatQuota, refreshSubscription } from '../common/Subscription';
import {
  LatencyResult, TEST_CONCURRENCY, TEST_HOST, sortByLatency, testNodesRealDelay, testOne
} from '../common/Speedtest';
import { isFakeOrReservedIp } from '../common/Latency';
import { resolveUdp } from '../common/UdpDns';
import { LatencyEntry, readLatencyCache, recordLatency } from '../common/LatencyStore';
import { appLog } from '../common/AppLog';
import { initIpcAuth, publishScopedEvent, verifyIpcParams } from '../common/IpcAuth';
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
const FG_SELECTED_PROBE_MS: number = 5 * 60 * 1000;
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
  private needTaskIdSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private taskReviveAttempts: number = 0;
  // 连接前解析好的节点服务器地址（写进 config 的 dns.hosts）。
  private bootstrapHosts: Record<string, string[]> | null = null;
  private usedFallback: boolean = false;
  private keepAliveStarted: boolean = false
  private keepAliveOwnedByTemp: boolean = false;
  @State keepAliveTaskCanceled: boolean = false;
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
  // Reconnect when the app is opened again after a manual swipe-away. This is
  // the FlClash "auto-connect on launch" behaviour: the manual swipe is still a
  // full stop (no background resurrection), but the next launch restores it.
  @State autoConnect: boolean = true;
  @State keepAliveOnRemove: boolean = false;
  private autoConnectTried: boolean = false;
  private taskId: number = -1;
  private taskNotificationId: number = -1;
  private taskWatchRegistered: boolean = false;
  private taskCancelHandler: ((cancelInfo: backgroundTaskManager.ContinuousTaskCancelInfo) => void) | null = null;
  private taskAcquiring: boolean = false;
  private lastTaskAcquireAt: number = 0;
  private taskStableSince: number = 0;
  @State geoText: string = '未下载';
  @State hasRuleSet: boolean = false;
  @State ruleSetText: string = '未导入（使用内置规则）';
  @State useRuleSet: boolean = false;
  @State fakeDns: boolean = true;
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
  private activeNodeId: string = '';
  @State ssidExpanded: boolean = false;
  // Measured height of the floating title bar; used as the scroll's top spacer
  // so the first card never hides underneath it.
  @State headerHeight: number = 72;
  @State dohDns: boolean = true;
  @State dnsLeakProtect: boolean = true;
  @State webrtcLeakProtect: boolean = true;
  @State blockAdText: string = '0';
  @State geoBusy: boolean = false;
  // Anywhere-style 3-tab navigation: 0 主页, 1 节点, 2 设置.
  @State activeTab: number = 0;
  // Anywhere-style drill-down sub-page inside Settings tab:
  // '' | 'appearance' | 'routing' | 'privacy' | 'keepalive' | 'wifi' | 'logs' | 'about'
  @State settingsSubPage: string = '';
  @State themeId: string = 'dark';
  @State theme: AppTheme = THEME_DARK;
  // Floating frosted navigation bar drag-highlight state (modelled on sing-box-for-harmonyos).
  @State navDragging: boolean = false;
  @State navPointerX: number = 0;
  @State navPreviewIndex: number = -1;
  @State navBarWidth: number = 0;
  private navIgnoreClickUntil: number = 0;
  private nativeGlassSupport: boolean | null = null;
  private glassModifierCache: Map<string, CommonModifier> = new Map<string, CommonModifier>();
  // About & GitHub update / core rollback protection state.
  @State updateChecking: boolean = false;
  @State updateResult: UpdateCheckResult | null = null;
  @State coreState: CoreUpdateState = defaultCoreState();
  @State subs: SubscriptionRecord[] = [];
  @State expandedSubId: string = '';
  @State editingSubId: string = '';
  @State editSubName: string = '';
  @State editSubUrl: string = '';
  @State updatingSubIds: string[] = [];
  @State testingIds: string[] = [];
  @State testDone: number = 0;
  @State testTotal: number = 0;
  @State sortByDelay: boolean = false;
  private lastWaitPhase: string = '';
  private startingSince: number = 0;
  private initialSubExpanded: boolean = false;

  private ctx: common.UIAbilityContext | null = null;
  private timerId: number = -1;
  private tickCount: number = 0;
  private backgroundRunning: boolean = false;
  private pageVisible: boolean = false;
  private resumedAt: number = 0;
  private fgProbeTimer: number = -1;
  private fgProbeInFlight: boolean = false;

  aboutToAppear(): void {
    this.ctx = getContext(this) as common.UIAbilityContext;
    initIpcAuth(this.ctx);
    this.coreState = readCoreState(this.ctx);
    loadSavedThemeId(this.ctx).then((id: string) => {
      this.themeId = id;
      this.theme = themeById(id);
      if (this.ctx !== null) {
        syncWindowBars(this.ctx, this.theme);
      }
    });
    pageInsets(this.ctx).then((value: Insets) => {
      this.insets = value;
    });
    this.restore().catch((error: BusinessError) => {
      promptAction.showToast({ message: '读取设置失败' });
    });
    this.watchNetworkChanges();
    this.watchKeepAliveTakeover();
    this.watchNeedTaskId();
    this.startPolling();
  }

  // The page timer must be restarted on every show: aboutToAppear runs only
  // once, so clearing it on hide keeps background CPU/data updates at zero
  // (only the status bar live view keeps updating while in background).
  onPageShow(): void {
    this.pageVisible = true;
    this.resumedAt = Date.now();
    this.notifyUiVisibility(true);
    this.consumeCardOp();
    this.refreshIntent();
    this.refreshEntry();
    if (this.ctx !== null) {
      this.coreState = readCoreState(this.ctx);
      syncWindowBars(this.ctx, this.theme);
    }
    this.syncSelectedNodeIfRunning();
    this.refreshRuleSetStatus();
    this.loadLatencyCache();
    this.startPolling();
    this.subscribeTraffic();
    this.startFgSelectedProbe();
    setTimeout(() => {
      if (this.pageVisible) {
        this.poll();
      }
    }, 250);
  }

  onPageHide(): void {
    this.pageVisible = false;
    this.stopPolling();
    this.unsubscribeTraffic();
    this.stopFgSelectedProbe();
    this.notifyUiVisibility(false);
  }

  private notifyUiVisibility(visible: boolean): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    publishScopedEvent(appEvent('UI_VISIBILITY', context), { 'visible': visible ? 1 : 0 }, context);
  }

  // While the UI stays in the foreground, silently test the selected node once
  // every 5 minutes and refresh its displayed latency + cache.
  private startFgSelectedProbe(): void {
    if (this.fgProbeTimer !== -1) {
      return;
    }
    this.fgProbeTimer = setInterval(() => {
      this.runFgSelectedProbe().catch((): void => {
      });
    }, FG_SELECTED_PROBE_MS);
  }

  private stopFgSelectedProbe(): void {
    if (this.fgProbeTimer !== -1) {
      clearInterval(this.fgProbeTimer);
      this.fgProbeTimer = -1;
    }
  }

  private async runFgSelectedProbe(): Promise<void> {
    if (!this.pageVisible || this.busy || this.nodeProbing || this.fgProbeInFlight) {
      return;
    }
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null) {
      return;
    }
    this.fgProbeInFlight = true;
    try {
      const viaTunnel: boolean = tunnelUp(context);
      const tags: string[] = viaTunnel ? tunnelOutboundTags(context) : [];
      let tag: string = '';
      for (const item of tags) {
        if (item === entry.id) {
          tag = item;
          break;
        }
      }
      const res: LatencyResult = await testOne(entry, viaTunnel, tag, this.bootstrapHosts, context);
      if (!this.pageVisible) {
        return;
      }
      const next: Map<string, number> = new Map<string, number>(this.nodeLatency);
      next.set(res.id, res.ms);
      this.nodeLatency = next;
      if (res.ms > 0) {
        this.probeMs = res.ms;
      }
      recordLatency(context, res.id, res.ms, res.via);
    } catch (error) {
    } finally {
      this.fgProbeInFlight = false;
    }
  }

  // If the user picked a different node in the Configs page while the tunnel is
  // already running, immediately switch the lean single-node core to it.
  private syncSelectedNodeIfRunning(): void {
    const context = this.ctx;
    if (context === null || this.busy || !this.isTunnelRunning()) {
      return;
    }
    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null) {
      return;
    }
    if (this.activeNodeId.length === 0) {
      this.activeNodeId = entry.id;
      return;
    }
    if (entry.id !== this.activeNodeId) {
      this.activeNodeId = entry.id;
      this.selectedId = entry.id;
      this.restartTunnel(context, entry).catch((): void => {
      });
    }
  }

  aboutToDisappear(): void {
    this.pageVisible = false;
    this.stopPolling();
    this.unsubscribeTraffic();
    this.stopFgSelectedProbe();
    this.notifyUiVisibility(false);
    this.unwatchNetworkChanges();
    this.unwatchKeepAliveTakeover();
    this.unwatchNeedTaskId();
    this.unregisterTaskWatch();
  }

  onBackPress(): boolean {
    if (this.activeTab === 2 && this.settingsSubPage.length > 0) {
      this.closeSettingsSubPage();
      return true;
    }
    return false;
  }

  private openSettingsSubPage(page: string): void {
    this.settingsSubPage = page;
    if (page === 'logs') {
      this.showLogs = true;
      if (this.ctx !== null) {
        this.logs = readLogs(this.ctx, 6000);
      }
    } else if (page === 'wifi') {
      this.refreshSsid();
    }
  }

  private closeSettingsSubPage(): void {
    if (this.settingsSubPage === 'logs') {
      this.showLogs = false;
    }
    this.settingsSubPage = '';
  }

  private settingsSubTitle(): string {
    if (this.settingsSubPage === 'appearance') {
      return '外观与主题';
    }
    if (this.settingsSubPage === 'routing') {
      return '分流与路由';
    }
    if (this.settingsSubPage === 'privacy') {
      return '隧道与隐私防护';
    }
    if (this.settingsSubPage === 'keepalive') {
      return '后台保活与通知';
    }
    if (this.settingsSubPage === 'wifi') {
      return '受信任 Wi-Fi';
    }
    if (this.settingsSubPage === 'logs') {
      return '诊断与运行日志';
    }
    if (this.settingsSubPage === 'about') {
      return '内核与关于';
    }
    return '设置';
  }

  private async selectTheme(id: string): Promise<void> {
    const next: AppTheme = themeById(id);
    this.themeId = next.id;
    this.theme = next;
    this.glassModifierCache.clear();
    if (this.ctx !== null) {
      await saveThemeId(this.ctx, next.id);
      await syncWindowBars(this.ctx, next);
    }
  }

  private async runUpdateCheck(): Promise<void> {
    if (this.updateChecking) {
      return;
    }
    this.updateChecking = true;
    try {
      const result: UpdateCheckResult = await checkAllUpdates();
      this.updateResult = result;
      if (result.error.length > 0) {
        promptAction.showToast({ message: result.error });
      } else if (result.app !== null && result.app.hasUpdate) {
        promptAction.showToast({ message: '发现客户端新版本 ' + result.app.tag });
      } else if (result.coreRust !== null && result.coreRust.hasUpdate) {
        promptAction.showToast({ message: '发现 xray-rust 新版本 ' + result.coreRust.tag });
      } else if (result.coreUpstream !== null) {
        promptAction.showToast({ message: '已同步上游版本：Xray-core ' + result.coreUpstream.tag });
      } else {
        promptAction.showToast({ message: '当前已是最新版本' });
      }
    } finally {
      this.updateChecking = false;
    }
  }

  private manifestForCore(coreId: string): KernelManifestEntry | null {
    if (this.updateResult === null) {
      return null;
    }
    for (const item of this.updateResult.manifest) {
      if (item.id === coreId) {
        return item;
      }
    }
    return null;
  }

  private selectCoreEngine(coreId: string): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (this.coreState.activeCore === coreId) {
      promptAction.showToast({ message: '当前已使用 ' + coreId });
      return;
    }
    const manifestEntry: KernelManifestEntry | null = this.manifestForCore(coreId);
    const targetVer: string = manifestEntry !== null && manifestEntry.version.length > 0
      ? manifestEntry.version
      : (coreId === CORE_ID_RUST ? CORE_VERSION_NAME : 'latest');
    this.coreState = stageCoreUpdate(context, coreId, targetVer);
    if (!isCoreBundled(coreId)) {
      this.coreState = rollbackCoreOnError(
        context,
        '当前安装包未内置 ' + coreId + ' 二进制，请下载 GitHub 自动构建双内核版'
      );
      promptAction.showToast({ message: this.coreState.lastRollbackReason, duration: 4000 });
      return;
    }
    try {
      const abi: string = coreVersion();
      if (abi.length === 0) {
        throw new Error('内核 ABI 校验返回空');
      }
      this.coreInfo = abi;
      this.coreState = markCoreHealthy(context);
      promptAction.showToast({ message: '已切换至 ' + coreId + ' ' + this.coreState.activeVersion });
    } catch (error) {
      const err = error as BusinessError;
      this.coreState = rollbackCoreOnError(context, err.message ?? '内核初始化失败');
      promptAction.showToast({ message: this.coreState.lastRollbackReason, duration: 4000 });
    }
  }

  private verifyCoreIntegrity(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const abi: string = coreVersion();
      if (abi.length === 0) {
        throw new Error('内核 ABI 版本读取为空');
      }
      this.coreInfo = abi;
      this.coreState = markCoreHealthy(context);
      promptAction.showToast({ message: '内核校验通过：xray-rust ' + CORE_VERSION_NAME + ' (ABI ' + abi + ')' });
    } catch (error) {
      const err = error as BusinessError;
      const reason: string = err.message ?? '内核加载异常';
      this.coreState = rollbackCoreOnError(context, reason);
      promptAction.showToast({ message: this.coreState.lastRollbackReason, duration: 4000 });
    }
  }

  private openExternalUrl(url: string, label: string): void {
    const context = this.ctx;
    if (context === null) {
      this.copyPlainText(url, label);
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch(() => {
      this.copyPlainText(url, label);
    });
  }

  // ==================== Sing-box Style Floating Frosted Nav Bar Helpers ====================

  private nativeGlassAvailable(): boolean {
    if (this.nativeGlassSupport !== null) {
      return this.nativeGlassSupport;
    }
    let supported: boolean = false;
    try {
      if (deviceInfo.apiAvailable('26.0.0')) {
        supported = uiMaterial.isImmersiveMaterialSupported();
      }
    } catch (error) {
      supported = false;
    }
    this.nativeGlassSupport = supported;
    return supported;
  }

  private glassModifier(interactive: boolean): CommonModifier {
    const key: string = (this.theme.isDark ? 'dark' : 'light') + '-' + interactive;
    const cached: CommonModifier | undefined = this.glassModifierCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const modifier: CommonModifier = new CommonModifier();
    if (this.nativeGlassAvailable()) {
      try {
        modifier.systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
          materialColor: Color.Transparent,
          colorInvert: false,
          applyShadow: interactive,
          interactive: interactive,
          lightEffect: { color: this.theme.isDark ? '#55FFFFFF' : '#44FFFFFF' }
        }));
      } catch (error) {
      }
    }
    this.glassModifierCache.set(key, modifier);
    return modifier;
  }

  private navIndexForX(x: number): number {
    if (!Number.isFinite(x) || this.navBarWidth <= 0) {
      return -1;
    }
    return Math.min(2, Math.max(0, Math.floor(x / this.navBarWidth * 3)));
  }

  private highlightedNavIndex(): number {
    return (this.navDragging && this.navPreviewIndex >= 0) ? this.navPreviewIndex : this.activeTab;
  }

  private navCapsuleWidth(): number {
    return Math.max(0, this.navBarWidth / 3 - 8);
  }

  private navGlowLeft(): number {
    const glowW: number = this.navCapsuleWidth();
    if (this.navBarWidth <= 0 || glowW <= 0) {
      return 4;
    }
    const idx: number = this.highlightedNavIndex();
    const x: number = this.navDragging ? this.navPointerX : ((idx + 0.5) * this.navBarWidth / 3);
    return Math.min(Math.max(4, this.navBarWidth - glowW - 4), Math.max(4, x - glowW / 2));
  }

  private selectMainTab(index: number): void {
    if (index === 2 && this.activeTab === 2 && this.settingsSubPage.length > 0) {
      this.closeSettingsSubPage();
      return;
    }
    this.activeTab = index;
    if (index === 1) {
      this.refreshEntry();
      this.loadLatencyCache();
    } else if (index === 2 && this.ctx !== null) {
      this.coreState = readCoreState(this.ctx);
    }
  }

  private finishNavDrag(commit: boolean): void {
    if (!this.navDragging) {
      return;
    }
    const target: number = (commit && this.navPreviewIndex >= 0) ? this.navPreviewIndex : -1;
    this.navDragging = false;
    this.navPreviewIndex = -1;
    this.navIgnoreClickUntil = Date.now() + 300;
    if (target >= 0) {
      this.selectMainTab(target);
    }
  }

  private handleNavTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      this.finishNavDrag(false);
      return;
    }
    if (event.touches.length > 1) {
      this.finishNavDrag(false);
      return;
    }
    const point: TouchObject | undefined = event.changedTouches[0] || event.touches[0];
    if (event.type === TouchType.Down && point !== undefined) {
      this.navDragging = true;
      this.navPointerX = point.x;
      this.navPreviewIndex = this.navIndexForX(point.x);
    } else if (event.type === TouchType.Move && this.navDragging && point !== undefined) {
      const clampedX: number = Math.min(this.navBarWidth, Math.max(0, point.x));
      this.navPointerX = clampedX;
      this.navPreviewIndex = this.navIndexForX(clampedX);
    } else if (event.type === TouchType.Up) {
      if (this.navDragging && point !== undefined) {
        const clampedX: number = Math.min(this.navBarWidth, Math.max(0, point.x));
        this.navPointerX = clampedX;
        this.navPreviewIndex = this.navIndexForX(clampedX);
      }
      this.finishNavDrag(true);
    }
  }

  private privacySummary(): string {
    const tags: string[] = [];
    if (this.dnsLeakProtect) {
      tags.push('DNS');
    }
    if (this.webrtcLeakProtect) {
      tags.push('WebRTC');
    }
    if (tags.length === 0) {
      return '基础';
    }
    return tags.join(' · ');
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

  // Signed takeover event from TempAbility: release the UI's own continuous
  // task immediately so ONLY TempAbility's single traffic live-view stays up.
  private async watchKeepAliveTakeover(): Promise<void> {
    if (this.takeoverSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber({ events: [appEvent('KEEPALIVE_TAKEOVER', this.ctx)] });
      commonEventManager.subscribe(sub, (_error, data) => {
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.ctx)) {
          return;
        }
        this.keepAliveOwnedByTemp = true;
        this.keepAliveTaskCanceled = false;
        if (this.keepAliveStarted) {
          this.keepAliveStarted = false;
          this.taskNotificationId = -1;
          const context = this.ctx;
          if (context !== null) {
            backgroundTaskManager.stopBackgroundRunning(context).catch((): void => {
            });
            appLog(context, 'keepalive', 'TempAbility took over the single continuous task');
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

  // Signed request from XrayVpnAbility when lock-screen / watchdog dropped the
  // live-view notification: immediately re-acquire a fresh notification id and
  // send it back to the extension so the status bar notification stays alive.
  private async watchNeedTaskId(): Promise<void> {
    if (this.needTaskIdSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber({ events: [appEvent('NEED_TASK_ID', this.ctx)] });
      commonEventManager.subscribe(sub, (_error, data) => {
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.ctx)) {
          return;
        }
        if (this.intentOn && !this.keepAliveOwnedByTemp && this.canReviveKeepAlive()) {
          const now: number = Date.now();
          if (this.taskAcquiring || (this.lastTaskAcquireAt > 0 && now - this.lastTaskAcquireAt < 5000)) {
            return;
          }
          if (this.ctx !== null) {
            appLog(this.ctx, 'ui', 'extension requested fresh live-view task id, reviving');
          }
          this.keepAliveStarted = false;
          this.taskNotificationId = -1;
          this.reviveTask().catch((): void => {
          });
        }
      });
      this.needTaskIdSubscriber = sub;
    } catch (error) {
    }
  }

  private unwatchNeedTaskId(): void {
    const sub = this.needTaskIdSubscriber;
    this.needTaskIdSubscriber = null;
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
        await commonEventManager.createSubscriber({ events: [appEvent('TRAFFIC', this.ctx)] });
      commonEventManager.subscribe(subscriber, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.ctx)) {
          return;
        }
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
    const saved: string = loadConfig(context);
    if (saved.length > 0) {
      // Fast resume: the saved tunnel config is still valid, so reuse it and
      // only re-acquire the task/extension. The old full connect() rebuilt the
      // whole config, waited up to 2.5 s for notification readiness, and tried
      // three VPN starts; after a drop that turned a 1-click restart into a
      // visibly slow one.
      appLog(context, 'lifecycle', 'auto-connect fast resume (saved config)');
      this.state = 'starting';
      this.message = '正在恢复上次连接';
      this.setSwitch(true);
      await this.reviveExtension();
      return;
    }
    appLog(context, 'lifecycle', 'auto-connect on launch (no saved config, full connect)');
    await this.connect();
  }

  private refreshEntry(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const store = readStore(context);
    this.nodeList = store.items;
    this.subs = readSubs(context);
    const entry: ConfigEntry | null = selectedEntry(context);
    this.hasEntry = entry !== null;
    this.selectedId = entry === null ? '' : entry.id;
    this.entryName = entry === null ? '' : entry.name;
    this.entryType = entry === null ? '' : entry.type;
    this.entryServer = entry === null ? '' : entry.server;
    if (!this.initialSubExpanded) {
      this.autoExpandSelectedSub();
    }
    this.refreshGeodataStatus();
  }

  private autoExpandSelectedSub(): void {
    this.initialSubExpanded = true;
    const selected: ConfigEntry | null = findById(this.nodeList, this.selectedId);
    if (selected !== null) {
      const sid: string = subIdOf(selected);
      if (sid.length > 0) {
        this.expandedSubId = sid;
        return;
      }
    }
    if (manualEntries(this.nodeList).length === 0 && this.subs.length > 0 &&
      this.expandedSubId.length === 0) {
      this.expandedSubId = this.subs[0].id;
    }
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
    const rawTemp: boolean = wayStore.getSync('tempKeepAlive', false) as boolean;
    const tempBeat: number = wayStore.getSync('tempHeartbeat', 0) as number;
    const tempAlive: boolean = rawTemp && tempBeat > 0 && (Date.now() - tempBeat < 15000);
    this.keepAliveOwnedByTemp = tempAlive;
    if (rawTemp && !tempAlive) {
      wayStore.putSync('tempKeepAlive', false);
      wayStore.putSync('tempHeartbeat', 0);
      wayStore.flush();
    }
    this.keepAliveOnRemove = wayStore.getSync('keepAliveOnRemove', false) as boolean;
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
    this.fakeDns = store.getSync('fakeDns', true) as boolean;
    this.blockAds = false;
    this.dohDns = store.getSync('dohDns', true) as boolean;
    this.dnsLeakProtect = store.getSync('dnsLeakProtect', true) as boolean;
    this.webrtcLeakProtect = store.getSync('webrtcLeakProtect', true) as boolean;
    this.autoConnect = store.getSync('autoConnect', true) as boolean;
    // Remove legacy bundled ACL4SSR rules if upgraded from an older build so
    // only minimal built-in rules (or user-added custom rules) remain active.
    if (seedRuleSet(context)) {
      appLog(context, 'ui', 'legacy bundled ACL rule set purged');
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
    store.putSync('fakeDns', this.fakeDns);
    store.putSync('blockAds', this.blockAds);
    store.putSync('dohDns', this.dohDns);
    store.putSync('dnsLeakProtect', this.dnsLeakProtect);
    store.putSync('webrtcLeakProtect', this.webrtcLeakProtect);
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


  private toggleFakeDns(value: boolean): void {
    this.fakeDns = value;
    this.persist();
    promptAction.showToast({
      message: value ? 'FakeIP 已开启，重连后生效' : 'FakeIP 已关闭，重连后生效'
    });
  }

  // One place that turns the UI state into routing options, so connect and the
  // live switches cannot drift apart.
  private buildOptions(context: common.UIAbilityContext): SplitOptions {
    const options: SplitOptions = {
      split: this.splitOn,
      geodata: geodataReady(context),
      mode: this.routeMode,
      blockQuic: this.blockQuic,
      dnsLeakProtect: this.dnsLeakProtect,
      webrtcLeakProtect: this.webrtcLeakProtect,
      debugLog: this.debugLog,
      // Gate on the in-memory switch: the pref write is asynchronous and a live
      // apply right after a toggle would otherwise read the previous value.
      ruleSet: this.useRuleSet ? readRuleSet(context) : null,
      blockAds: this.blockAds,
      doh: this.dohDns,
      fakeDns: this.fakeDns,
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
    // on DoH), then the platform resolver as a fallback. Always reject FakeIP
    // (198.18.0.0/15) so bootstrap hosts can never be poisoned.
    const udp: string[] = await resolveUdp(domain, 700);
    const cleanUdp: string[] = [];
    for (const ip of udp) {
      if (!isFakeOrReservedIp(ip) && cleanUdp.indexOf(ip) < 0) {
        cleanUdp.push(ip);
      }
    }
    if (cleanUdp.length > 0) {
      hosts[domain] = cleanUdp;
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
        if (!isFakeOrReservedIp(entry.address) && ips.indexOf(entry.address) < 0) {
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
  // routing table of the running core. When entering/leaving Global mode with DNS
  // leak protection enabled, restart so remote-only DNS policy takes effect too.
  private async selectMode(mode: string): Promise<void> {
    if (this.routeMode === mode) {
      return;
    }
    const prevMode: string = this.routeMode;
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
    if (this.dnsLeakProtect && (prevMode === MODE_GLOBAL || mode === MODE_GLOBAL)) {
      await this.restartTunnel(context, entry);
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

  private toggleBlockQuic(value: boolean): void {
    this.blockQuic = value;
    this.persist();
    const context = this.ctx;
    if (context !== null) {
      this.applyRoutingChange(context, value ? '已屏蔽 QUIC' : '已允许 QUIC');
    }
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

  // 防 DNS 泄露同时涉及 dns 服务器列表与 53/853 路由规则：运行中自动重启隧道生效。
  private async toggleDnsLeakProtect(value: boolean): Promise<void> {
    this.dnsLeakProtect = value;
    this.persist();
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry !== null) {
      buildAndSaveTunnel(context, entry, this.buildOptions(context));
      if (this.isTunnelRunning()) {
        await this.restartTunnel(context, entry);
        return;
      }
    }
  }

  // 防 WebRTC 泄露纯属路由规则，可在运行中热更新生效。
  private toggleWebrtcLeakProtect(value: boolean): void {
    this.webrtcLeakProtect = value;
    this.persist();
    const context = this.ctx;
    if (context !== null) {
      this.applyRoutingChange(context, value ? '已启用防 WebRTC 泄露' : '已关闭防 WebRTC 泄露');
    }
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
      if (!this.busy && status.state === 'error') {
        this.intentOn = false;
        this.startingSince = 0;
        this.recoveryAttempts = 0;
        this.nextRecoveryAt = 0;
        this.reviveFailures = 0;
        this.state = 'error';
        this.message = status.message.length > 0 ? status.message : '连接失败';
        this.seconds = 0;
        this.upSpeed = 0;
        this.downSpeed = 0;
        this.setSwitch(false);
        this.stopKeepAliveTask();
        return;
      }
      this.lastBeatAt = Math.max(this.lastBeatAt, status.updatedAt);
      const justResumed: boolean = this.resumedAt > 0 && now - this.resumedAt < 5000;
      const stale: boolean = !justResumed && (now - status.updatedAt > HEARTBEAT_STALE_MS);
      if (!stale && status.state === 'running') {
        // Only a confirmed running tunnel resets the recovery budget; resetting
        // on "starting" caused an infinite relaunch loop when core crashed on boot.
        this.recoveryAttempts = 0;
        this.nextRecoveryAt = 0;
        this.reviveFailures = 0;
        this.startingSince = 0;
        // A running tunnel with no stored intent (e.g. the app died between
        // startVpn and the markActive flush) must still be supervised.
        if (!this.busy && !this.intentOn) {
          this.intentOn = true;
          appLog(context, 'ui', 'intent inferred from a running tunnel');
        }
      } else if (status.state === 'stopped') {
        this.startingSince = 0;
      }
      const recovering: boolean = stale && this.intentOn;
      if (!this.busy && (status.state === 'starting' || recovering)) {
        if (this.startingSince === 0) {
          this.startingSince = now;
        } else if (now - this.startingSince > 22000) {
          const stuckPhase: string = status.message.length > 0 ? status.message : '初始化';
          this.intentOn = false;
          this.startingSince = 0;
          this.recoveryAttempts = 0;
          this.nextRecoveryAt = 0;
          this.state = 'error';
          this.message = '连接超时，卡在：' + stuckPhase;
          this.seconds = 0;
          this.upSpeed = 0;
          this.downSpeed = 0;
          this.setSwitch(false);
          this.stopKeepAliveTask();
          appLog(context, 'ui', 'starting watchdog aborted: ' + this.message);
          stopVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange)).catch(() => {
          });
          promptAction.showToast({ message: this.message });
          return;
        }
      }
      const switching: boolean = stale && this.intentOn &&
        now - this.networkSwitchAt < NETWORK_GRACE_MS;
      this.state = recovering ? 'starting' : (stale ? 'unknown' : status.state);
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
        if (this.startingSince === 0) {
          this.startingSince = now;
        } else if (now - this.startingSince > 22000) {
          this.intentOn = false;
          this.startingSince = 0;
          this.state = 'error';
          this.message = '连接超时，VPN 扩展未能启动';
          this.setSwitch(false);
          this.stopKeepAliveTask();
          promptAction.showToast({ message: this.message });
          return;
        }
        this.state = 'starting';
        this.message = '扩展未运行，正在拉起';
        this.setSwitch(true);
        this.statusAge = -1;
        this.supervise(context);
      } else {
        this.startingSince = 0;
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
    if (this.resumedAt > 0 && now - this.resumedAt < 5000) {
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
      return;
    }
    this.recoveryAttempts++;
    const backoff: number = Math.min(15000, 1000 * Math.pow(2, this.recoveryAttempts - 1));
    this.nextRecoveryAt = now + backoff;
    this.state = 'starting';
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
      if (this.notifyMe) {
        await this.ensureNotifyReady(600);
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

  private openAddConfig(): void {
    router.pushUrl({ url: 'pages/AddConfig' }).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开添加节点页失败: ' + error.message });
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

  // Latency for every node in the expanded list: same path as the node page.
  // When connected the core performs a real HTTP probe through each outbound;
  // when not connected it falls back to a direct TCP/UDP handshake.
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
    await this.probeScope(this.visibleTestTargets());
  }

  private visibleTestTargets(): ConfigEntry[] {
    const targets: ConfigEntry[] = [];
    for (const item of manualEntries(this.nodeList)) {
      targets.push(item);
    }
    if (this.expandedSubId.length > 0) {
      for (const item of entriesOfSub(this.nodeList, this.expandedSubId)) {
        targets.push(item);
      }
    }
    if (targets.length === 0) {
      return this.nodeList.slice();
    }
    return targets;
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

  private async probeScope(scope: ConfigEntry[]): Promise<void> {
    if (this.nodeProbing) {
      return;
    }
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const entries: ConfigEntry[] = scope.length > 0 ? scope.slice() : readStore(context).items.slice();
    if (entries.length === 0) {
      promptAction.showToast({ message: '没有可测速的节点' });
      return;
    }
    this.nodeProbing = true;
    this.testTotal = entries.length;
    this.testDone = 0;
    const ids: string[] = [];
    for (const item of entries) {
      ids.push(item.id);
    }
    this.markTestingNodes(ids, true);
    const measured: Map<string, number> = new Map<string, number>(this.nodeLatency);
    try {
      const viaTunnel: boolean = tunnelUp(context);
      const tags: string[] = viaTunnel ? tunnelOutboundTags(context) : [];
      // When VPN is connected, never resolve in the UI process (FakeIP 198.19.x.x
      // would poison bootstrapHosts); let the protected extension core resolve.
      let hosts: Record<string, string[]> | null = this.bootstrapHosts;
      if (!viaTunnel && hosts === null) {
        hosts = await this.resolveNodeHosts(context);
        if (hosts !== null) {
          this.bootstrapHosts = hosts;
        }
      }
      await testNodesRealDelay(entries, viaTunnel, tags, hosts, (result: LatencyResult) => {
        measured.set(result.id, result.ms);
        recordLatency(context, result.id, result.ms, result.via);
        this.markTestingNodes([result.id], false);
        this.nodeLatency = new Map<string, number>(measured);
        this.testDone++;
      }, context);
    } catch (error) {
    } finally {
      this.markTestingNodes(ids, false);
      this.nodeLatency = new Map<string, number>(measured);
      this.nodeProbing = false;
    }
  }

  private async probeSingleNode(entry: ConfigEntry): Promise<void> {
    const context = this.ctx;
    if (context === null || this.isTestingNode(entry.id)) {
      return;
    }
    this.markTestingNodes([entry.id], true);
    try {
      const viaTunnel: boolean = tunnelUp(context);
      const tags: string[] = viaTunnel ? tunnelOutboundTags(context) : [];
      const liveTag: string = tags.indexOf(entry.id) >= 0 ? entry.id : '';
      const result: LatencyResult = await testOne(entry, viaTunnel, liveTag, this.bootstrapHosts, context);
      const next: Map<string, number> = new Map<string, number>(this.nodeLatency);
      next.set(result.id, result.ms);
      this.nodeLatency = next;
      recordLatency(context, result.id, result.ms, result.via);
    } finally {
      this.markTestingNodes([entry.id], false);
    }
  }

  private latencyText(id: string): string {
    if (this.isTestingNode(id)) {
      return '…';
    }
    const value: number | undefined = this.nodeLatency.get(id);
    if (value === undefined) {
      return '测速';
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
    if (this.isTestingNode(id)) {
      return '#54C4FF';
    }
    const value: number | undefined = this.nodeLatency.get(id);
    if (value === undefined) {
      return '#4C5D77';
    }
    if (value < 0) {
      return '#5C7192';
    }
    if (value < 300) {
      return '#3DDC97';
    }
    return value < 500 ? '#FFC857' : '#FF5C7A';
  }

  private async pickNode(item: ConfigEntry): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    if (item.id !== this.selectedId) {
      selectEntry(context, item.id);
      this.selectedId = item.id;
      this.activeNodeId = item.id;
      this.entryName = item.name;
      this.entryType = item.type;
      this.entryServer = item.server;
      this.hasEntry = true;
      if (this.isTunnelRunning()) {
        promptAction.showToast({ message: '已切换节点：' + item.name });
        await this.restartTunnel(context, item);
      } else {
        promptAction.showToast({ message: '已选择：' + item.name });
      }
    }
    this.nodeExpanded = false;
  }

  private selectedNodeEntry(): ConfigEntry | null {
    return findById(this.nodeList, this.selectedId);
  }

  private sortEntriesByDelay(raw: ConfigEntry[]): ConfigEntry[] {
    if (!this.sortByDelay) {
      return raw;
    }
    const results: LatencyResult[] = [];
    this.nodeLatency.forEach((ms: number, id: string) => {
      results.push({ id: id, ms: ms, via: 'http', at: 0 });
    });
    return sortByLatency(raw, results);
  }

  private manualNodeList(): ConfigEntry[] {
    return this.sortEntriesByDelay(manualEntries(this.nodeList));
  }

  private subNodeList(subId: string): ConfigEntry[] {
    return this.sortEntriesByDelay(entriesOfSub(this.nodeList, subId));
  }

  private findSub(id: string): SubscriptionRecord | null {
    for (const s of this.subs) {
      if (s.id === id) {
        return s;
      }
    }
    return null;
  }

  private isUpdatingSub(id: string): boolean {
    return this.updatingSubIds.indexOf(id) >= 0;
  }

  private setUpdatingSub(id: string, active: boolean): void {
    const next: string[] = [];
    for (const item of this.updatingSubIds) {
      if (item !== id) {
        next.push(item);
      }
    }
    if (active) {
      next.push(id);
    }
    this.updatingSubIds = next;
  }

  private subContainsSelected(subId: string): boolean {
    const selected: ConfigEntry | null = this.selectedNodeEntry();
    return selected !== null && subIdOf(selected) === subId;
  }

  private openAddMode(mode: number, autoScan: boolean = false): void {
    const params: Record<string, Object> = { 'mode': mode, 'autoScan': autoScan };
    router.pushUrl({ url: 'pages/AddConfig', params: params }).catch((error: BusinessError) => {
      promptAction.showToast({ message: '打开添加页失败: ' + error.message });
    });
  }

  private addNodeMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: '扫描二维码（节点 / 订阅）',
      action: () => {
        this.openAddMode(0, true);
      }
    });
    items.push({
      value: '粘贴链接或订阅地址',
      action: () => {
        this.openAddMode(0, false);
      }
    });
    items.push({
      value: '添加订阅',
      action: () => {
        this.openAddMode(1, false);
      }
    });
    items.push({
      value: '导入 JSON 配置',
      action: () => {
        this.openAddMode(2, false);
      }
    });
    return items;
  }

  private copyPlainText(text: string, label: string): void {
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
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: {
        value: '删除',
        fontColor: '#FF5C7A',
        action: () => {
          const context = this.ctx;
          if (context !== null) {
            removeEntry(context, entry.id);
            this.refreshEntry();
          }
        }
      }
    });
  }

  private confirmDeleteSub(id: string): void {
    const rec: SubscriptionRecord | null = this.findSub(id);
    const name: string = rec === null ? '' : rec.name;
    const cnt: number = entriesOfSub(this.nodeList, id).length;
    AlertDialog.show({
      title: '删除订阅',
      message: '删除「' + name + '」及其 ' + cnt + ' 个节点？',
      primaryButton: { value: '取消', action: () => {} },
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
            this.refreshEntry();
            promptAction.showToast({ message: '订阅已删除' });
          }
        }
      }
    });
  }

  private beginEditSub(id: string): void {
    const rec: SubscriptionRecord | null = this.findSub(id);
    if (rec === null) {
      return;
    }
    this.editingSubId = id;
    this.editSubName = rec.name;
    this.editSubUrl = rec.url;
  }

  private async commitEditSub(id: string): Promise<void> {
    const context = this.ctx;
    const rec: SubscriptionRecord | null = this.findSub(id);
    if (context === null || rec === null) {
      return;
    }
    const url: string = this.editSubUrl.trim();
    const name: string = this.editSubName.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      promptAction.showToast({ message: '订阅地址必须是 http(s) 链接' });
      return;
    }
    const moved: boolean = url !== rec.url;
    updateSub(context, id, url, name);
    this.editingSubId = '';
    this.refreshEntry();
    if (moved) {
      await this.refreshOneSub(id);
    } else {
      promptAction.showToast({ message: '订阅已保存' });
    }
  }

  private async refreshOneSub(id: string): Promise<void> {
    const context = this.ctx;
    const rec: SubscriptionRecord | null = this.findSub(id);
    if (context === null || rec === null || this.isUpdatingSub(id)) {
      return;
    }
    this.setUpdatingSub(id, true);
    try {
      const next: SubscriptionRecord = await refreshSubscription(context, rec);
      this.refreshEntry();
      promptAction.showToast({ message: '已更新 ' + next.count + ' 个节点' });
    } catch (error) {
      const err = error as BusinessError;
      promptAction.showToast({ message: '更新失败: ' + (err.message ?? '网络错误') });
    } finally {
      this.setUpdatingSub(id, false);
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
      this.setUpdatingSub(sub.id, true);
      try {
        await refreshSubscription(context, sub);
        okCount++;
        this.refreshEntry();
      } catch (error) {
        failCount++;
      } finally {
        this.setUpdatingSub(sub.id, false);
      }
    }
    promptAction.showToast({
      message: failCount === 0
        ? ('已更新全部 ' + okCount + ' 个订阅')
        : ('更新完成：成功 ' + okCount + '，失败 ' + failCount)
    });
  }

  private proxyMoreMenu(): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: this.sortByDelay ? '排序：按延迟（点此切回默认）' : '排序：默认顺序（点此按延迟）',
      action: () => {
        this.sortByDelay = !this.sortByDelay;
      }
    });
    items.push({
      value: '测速全部节点',
      action: () => {
        if (!this.nodeProbing) {
          this.probeScope(this.nodeList.slice());
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
      value: '添加订阅',
      action: () => {
        this.openAddMode(1);
      }
    });
    items.push({
      value: '导入 JSON 配置',
      action: () => {
        this.openAddMode(2);
      }
    });
    return items;
  }

  private formatShortStamp(ts: number): string {
    if (ts <= 0) {
      return '从未';
    }
    const d: Date = new Date(ts);
    const p = (n: number): string => n < 10 ? '0' + n : '' + n;
    return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  private toggleMainVpn(): void {
    if (this.busy) {
      return;
    }
    if (this.state === 'running' || this.state === 'starting' || this.state === 'suspended') {
      this.disconnect();
    } else {
      this.connect();
    }
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

  private promptAddNode(reason: string): void {
    this.setSwitch(false);
    this.intentOn = false;
    this.state = 'stopped';
    this.message = '请先添加节点';
    AlertDialog.show({
      title: '尚未添加可用节点',
      message: reason,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '去添加节点',
        fontColor: '#54C4FF',
        action: () => {
          this.openAddConfig();
        }
      }
    });
  }

  private async connect(): Promise<void> {
    const context = this.ctx;
    if (context === null || this.busy) {
      return;
    }

    const entry: ConfigEntry | null = selectedEntry(context);
    if (entry === null || entry.json.trim().length === 0 || proxyOutbound(entry.json) === null) {
      this.promptAddNode(entry === null
        ? '当前还没有任何节点，请先导入订阅、粘贴链接或 JSON 配置后再开启 VPN。'
        : '当前选中的节点配置无效或缺少服务器信息，请重新添加或切换可用节点。');
      return;
    }
    // HarmonyOS background VPN keepalive requires notification permission for
    // the DATA_TRANSFER live-view task. Gate VPN start on notification approval.
    const notifyReady: boolean = await this.requireNotifyPermission(context);
    if (!notifyReady) {
      this.setSwitch(false);
      this.intentOn = false;
      this.state = 'stopped';
      this.message = '需要开启通知权限';
      AlertDialog.show({
        title: '请先开启通知权限',
        message: '鸿蒙后台运行 VPN 需要通知栏流量实况窗权限。请允许通知后再开启 VPN（若未弹出系统授权框，请前往系统设置 → 通知与状态栏中打开 way 的通知）。',
        primaryButton: {
          value: '取消',
          action: () => {
          }
        },
        secondaryButton: {
          value: '重新授权',
          fontColor: '#54C4FF',
          action: () => {
            this.connect().catch((): void => {
            });
          }
        }
      });
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
      if (!this.keepAliveOwnedByTemp) {
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
      }
      // 2) Start the VPN, then verify status.json. This is the "connects only
      // on the third tap" fix: each attempt waits for a fresh heartbeat, and a
      // failed attempt clears the half-created VPN before the next one.
      const maxAttempts: number = 2;
      for (let attempt: number = 0; attempt < maxAttempts && !started; attempt++) {
        this.lastStartRequestAt = Date.now();
        try {
          await startVpn(vpnWant(context, this.notifyMe, this.rebindOnNetChange, notifId, entry.name));
          appLog(context, 'ui', 'vpn start requested (attempt ' + (attempt + 1) + ')');
        } catch (error) {
          const err = error as BusinessError;
          lastError = err.message ?? JSON.stringify(error);
          appLog(context, 'ui', 'vpn start attempt ' + (attempt + 1) + ' failed: ' + lastError);
        }
        started = await this.waitTunnelReady(context, 4500, 10000);
        if (!started) {
          const failedNow: TunnelStatus | null = readStatus(context);
          if (failedNow !== null && failedNow.state === 'error') {
            break;
          }
          if (attempt < maxAttempts - 1) {
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
      }
      if (!started) {
        const failedStatus: TunnelStatus | null = readStatus(context);
        const extMsg: string = (failedStatus !== null && failedStatus.state === 'error' && failedStatus.message.length > 0)
          ? failedStatus.message : '';
        const phaseMsg: string = this.lastWaitPhase.length > 0
          ? ('连接超时（卡在：' + this.lastWaitPhase + '）') : '';
        throw new Error(extMsg.length > 0 ? extMsg : (phaseMsg.length > 0 ? phaseMsg :
          (lastError.length > 0 ? lastError : '扩展未在限定时间内就绪（请确认已在系统弹窗允许创建 VPN）')));
      }
      this.markActive(true);
      this.activeNodeId = entry.id;
      this.intentOn = true;
      this.recoveryAttempts = 0;
      this.nextRecoveryAt = 0;
      this.lastBeatAt = Date.now();
      if (this.keepAliveOwnedByTemp) {
        publishScopedEvent(appEvent('REQUEST_TASK_ID', context), {}, context);
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

  // Wait until the extension actually reaches "running". While a fresh
  // "starting" heartbeat arrives, allow up to maxWaitMs; never treat a stuck
  // or crashed "starting" state as ready.
  private async waitTunnelReady(context: common.UIAbilityContext,
    minWaitMs: number, maxWaitMs: number): Promise<boolean> {
    const startedAt: number = Date.now();
    const baseDeadline: number = startedAt + minWaitMs;
    const hardDeadline: number = startedAt + maxWaitMs;
    let sawStarting: boolean = false;
    this.lastWaitPhase = '';
    while (Date.now() < hardDeadline) {
      const status: TunnelStatus | null = readStatus(context);
      const now: number = Date.now();
      if (status !== null) {
        const fresh: boolean = now - status.updatedAt < 4500;
        if (status.state === 'running' && fresh) {
          return true;
        }
        if (status.state === 'error') {
          if (status.message.length > 0) {
            this.lastWaitPhase = status.message;
          }
          return false;
        }
        if (status.state === 'starting') {
          if (status.message.length > 0) {
            this.lastWaitPhase = status.message;
            this.message = status.message;
          }
          if (fresh) {
            sawStarting = true;
          } else if (sawStarting) {
            return false;
          }
        }
      }
      if (!sawStarting && now >= baseDeadline) {
        return false;
      }
      await this.delay(200);
    }
    return false;
  }

  // Strict gate: return true only when notification permission is granted.
  private async requireNotifyPermission(context: common.UIAbilityContext): Promise<boolean> {
    try {
      if (await notificationManager.isNotificationEnabled()) {
        return true;
      }
      try {
        await notificationManager.requestEnableNotification(context);
      } catch (error) {
        const err = error as BusinessError;
        appLog(context, 'ui', 'notification permission request: ' + (err.message ?? 'denied'));
      }
      const deadline: number = Date.now() + 2500;
      while (Date.now() < deadline) {
        if (await notificationManager.isNotificationEnabled()) {
          return true;
        }
        await this.delay(250);
      }
      return await notificationManager.isNotificationEnabled();
    } catch (error) {
      return false;
    }
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


  private canReviveKeepAlive(): boolean {
    const context = this.ctx;
    if (context === null || !this.intentOn || ssidSuspended(context)) {
      return false;
    }
    const status: TunnelStatus | null = readStatus(context);
    if (status !== null && (status.state === 'stopped' || status.state === 'error' ||
      status.state === 'suspended')) {
      return false;
    }
    return true;
  }

  private async startKeepAliveTask(): Promise<number> {
    const context = this.ctx;
    if (context === null) {
      return -1;
    }
    if (this.keepAliveOwnedByTemp) {
      return -1;
    }
    if (this.keepAliveStarted && this.taskNotificationId >= 0) {
      return this.taskNotificationId;
    }
    if (this.taskAcquiring) {
      return this.taskNotificationId;
    }
    this.taskAcquiring = true;
    this.keepAliveStarted = false;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: appBundleName(context),
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
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
      this.keepAliveTaskCanceled = false;
      this.lastTaskAcquireAt = Date.now();
      this.taskStableSince = this.lastTaskAcquireAt;
      saveTaskNotificationId(context, this.taskNotificationId);
      appLog(context, 'ui', 'continuous task started (dataTransfer live view) id=' + this.taskId +
        ' notification=' + this.taskNotificationId);
      return this.taskNotificationId;
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'ui', 'continuous task failed: ' + (err.message ?? 'unknown'));
      return -1;
    } finally {
      this.taskAcquiring = false;
    }
  }

  private stopKeepAliveTask(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    this.taskReviveAttempts = 0;
    this.taskStableSince = 0;
    saveTaskNotificationId(context, -1);
    if (!this.keepAliveStarted && this.taskId < 0) {
      return;
    }
    this.keepAliveStarted = false;
    this.keepAliveTaskCanceled = false;
    this.taskId = -1;
    this.taskNotificationId = -1;
    backgroundTaskManager.stopBackgroundRunning(context).catch(() => {
    });
  }

  // Filter cancellation strictly by matching taskId so late callbacks for an
  // already-replaced task never wipe out the active live-view notification, and
  // reset backoff automatically once a task stays stable for >= 30 s.
  private registerTaskWatch(): void {
    if (this.taskWatchRegistered) {
      return;
    }
    this.taskWatchRegistered = true;
    const handler = (cancelInfo: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (this.taskId < 0 || (cancelInfo !== undefined && cancelInfo !== null &&
        cancelInfo.id !== undefined && cancelInfo.id !== this.taskId)) {
        return;
      }
      const context = this.ctx;
      const now: number = Date.now();
      if (this.taskStableSince > 0 && now - this.taskStableSince >= 30000) {
        this.taskReviveAttempts = 0;
      }
      this.keepAliveStarted = false;
      this.taskId = -1;
      this.taskNotificationId = -1;
      this.keepAliveTaskCanceled = this.intentOn;
      if (context !== null) {
        saveTaskNotificationId(context, -1);
        appLog(context, 'ui', 'continuous task canceled (attempt ' + (this.taskReviveAttempts + 1) + ')');
      }
      if (this.intentOn && !this.keepAliveOwnedByTemp && this.canReviveKeepAlive()) {
        const delays: number[] = [1500, 3000, 6000, 12000, 20000, 30000, 60000];
        const delayMs: number = delays[Math.min(this.taskReviveAttempts, delays.length - 1)];
        this.taskReviveAttempts = Math.min(this.taskReviveAttempts + 1, delays.length - 1);
        setTimeout(() => {
          if (this.intentOn && !this.keepAliveOwnedByTemp && !this.keepAliveStarted &&
            !this.taskAcquiring && this.canReviveKeepAlive()) {
            this.reviveTask().catch((): void => {
            });
          }
        }, delayMs);
      }
    };
    this.taskCancelHandler = handler;
    try {
      backgroundTaskManager.on('continuousTaskCancel', handler);
    } catch (error) {
    }
  }

  private unregisterTaskWatch(): void {
    if (!this.taskWatchRegistered) {
      return;
    }
    this.taskWatchRegistered = false;
    try {
      if (this.taskCancelHandler !== null) {
        backgroundTaskManager.off('continuousTaskCancel', this.taskCancelHandler);
      } else {
        backgroundTaskManager.off('continuousTaskCancel');
      }
    } catch (error) {
    }
    this.taskCancelHandler = null;
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
    publishScopedEvent(appEvent('TASK_ID', context), { 'taskNotificationId': id }, context);
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
        store.putSync('tempStartedAt', 0);
      }
      await store.flush();
    } catch (error) {
    }
  }

  // Background VPN toggle: persists preference so EntryAbility.onDestroy leaves
  // the VpnExtensionAbility and live-view task alive when the main card is swiped
  // away — strictly zero automatic widget/card popups on toggle or app upgrade.
  private async toggleKeepAliveOnRemove(value: boolean): Promise<void> {
    this.keepAliveOnRemove = value;
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const way = await preferences.getPreferences(context, 'way');
      way.putSync('keepAliveOnRemove', value);
      await way.flush();
    } catch (error) {
    }
    if (value) {
      appLog(context, 'lifecycle', 'background-vpn ON (silent, no card popup)');
      promptAction.showToast({ message: '已开启：划掉主窗口后 VPN 将继续后台运行', duration: 2500 });
    } else {
      appLog(context, 'lifecycle', 'background-vpn OFF: stopping TempAbility');
      publishScopedEvent(appEvent('STOP_KEEPALIVE', context), {}, context);
      this.keepAliveOwnedByTemp = false;
      this.keepAliveStarted = false;
      this.taskNotificationId = -1;
      if (this.isTunnelRunning()) {
        this.reviveTask().catch((): void => {
        });
      }
      promptAction.showToast({ message: '已关闭：清后台将停止 VPN', duration: 2500 });
    }
  }

  // FlClash-ohos / way-1000020 headless keepalive entry:
  // Opening the system widget preview causes the launcher (a system process) to
  // render WidgetCard, whose onAppear fires postCardAction(action:'call') to
  // TempAbility. That launches TempAbility completely windowless (no blank
  // window and no mission card in recents), so swiping away all cards cannot
  // destroy TempAbility or kill the VPN. The user just cancels the preview.
  private openKeepAliveForm(): void {
    const context = this.ctx;
    const want: Want = {
      bundleName: appBundleName(context),
      abilityName: 'WayFormAbility',
      parameters: {
        'ohos.extra.param.key.form_name': 'way_widget',
        'ohos.extra.param.key.module_name': 'entry',
        'ohos.extra.param.key.form_dimension': formInfo.FormDimension.Dimension_2_2
      }
    };
    try {
      formProvider.openFormManager(want);
      if (context !== null) {
        appLog(context, 'keepalive', 'opened widget preview for headless TempAbility call');
      }
    } catch (error) {
      const err = error as BusinessError;
      if (context !== null) {
        appLog(context, 'keepalive', 'openFormManager failed, falling back: ' + (err.message ?? 'unknown'));
      }
      this.startTempAbility().catch((): void => {
      });
    }
  }

  private async startTempAbility(): Promise<void> {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    try {
      const want: Want = {
        bundleName: appBundleName(context),
        abilityName: 'TempAbility'
      };
      await context.startAbility(want);
      appLog(context, 'keepalive', 'transparent TempAbility started once');
    } catch (error) {
      const err = error as BusinessError;
      appLog(context, 'keepalive', 'TempAbility start failed: ' + (err.message ?? 'unknown'));
      promptAction.showToast({ message: '后台保活启动失败，请看日志' });
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
            bundleName: appBundleName(context),
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
    if (this.keepAliveOnRemove) {
      // Keep transparent TempAbility in standby so next connect needs zero popups.
      publishScopedEvent(appEvent('PAUSE_KEEPALIVE', context), {}, context);
    } else {
      publishScopedEvent(appEvent('STOP_KEEPALIVE', context), {}, context);
    }
    this.keepAliveOwnedByTemp = false;
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


  // On-demand is driven by the rule list, not a separate switch: adding any
  // rule enables it, deleting the last rule disables it.
  private syncOnDemand(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const enabled: boolean = this.rules.length > 0;
    this.onDemand = enabled;
    setFlag(context, 'onDemand', enabled);
    if (!enabled) {
      setSsidSuspended(context, false);
      if (this.state === 'suspended') {
        this.state = 'stopped';
        this.message = '断开';
        this.setSwitch(false);
      }
    }
    this.refreshSsid();
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
    this.syncOnDemand();
    this.manualSsid = '';
  }

  private toggleRuleAction(rule: SsidRule): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    const next: string = rule.action === SSID_SUSPEND ? SSID_DIRECT : SSID_SUSPEND;
    this.rules = setSsidRule(context, rule.ssid, next);
    this.syncOnDemand();
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
    this.syncOnDemand();
  }

  private deleteRule(ssid: string): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    this.rules = removeSsidRule(context, ssid);
    this.syncOnDemand();
  }

  private clearRules(): void {
    const context = this.ctx;
    if (context === null) {
      return;
    }
    clearSsidRules(context);
    this.rules = [];
    this.syncOnDemand();
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

  private statusColor(): string {
    if (this.state === 'running') {
      return this.theme.success;
    }
    if (this.state === 'starting' || this.state === 'suspended') {
      return this.theme.warning;
    }
    if (this.state === 'error') {
      return this.theme.danger;
    }
    return this.theme.textSecondary;
  }

  private stateTitle(): string {
    if (this.state === 'running' || this.state === 'suspended') {
      return this.statusLabel();
    }
    if (this.state === 'starting') {
      return (this.message.length > 0 && this.message !== '连接中') ? this.message : '正在连接…';
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
    if (this.state === 'error') {
      return '连接失败';
    }
    return '未连接';
  }

  build() {
    // Clean, pure, understated canvas supporting Light / Dark / OLED / Sage / Slate themes,
    // plus sing-box-for-harmonyos style floating frosted glass navigation bar with drag highlight.
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.theme.bg)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        if (this.activeTab === 0) {
          this.homeTab()
        } else if (this.activeTab === 1) {
          this.proxiesTab()
        } else {
          this.settingsTab()
        }
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      this.header()

      // Floating frosted glass navigation bar (sing-box style) with touch-drag highlight.
      Column() {
        this.floatingNavBar()
      }
      .width('100%')
      .position({ x: 0, y: '100%' })
      .markAnchor({ x: 0, y: '100%' })
      .padding({ left: 20, right: 20, bottom: this.insets.bottom + 10 })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bg)
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      if (this.activeTab === 0) {
        // Pure minimal brand wordmark only — no status badge on the top-right.
        Text('way')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
          .letterSpacing(0.3)

        Blank()
      } else if (this.activeTab === 1) {
        Row({ space: 8 }) {
          Text('节点')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textPrimary)
          Text('' + this.nodeList.length)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.accent)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(10)
            .backgroundColor(this.theme.accentSoft)
        }

        Blank()

        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.bolt_1'))
            .fontSize(14)
            .fontColor([this.nodeProbing ? this.theme.textTertiary : this.theme.accent])
          Text(this.nodeProbing ? (this.testDone + '/' + this.testTotal) : '测速')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.nodeProbing ? this.theme.textTertiary : this.theme.accent)
        }
        .height(34)
        .padding({ left: 11, right: 11 })
        .borderRadius(17)
        .backgroundColor(this.theme.surface)
        .border({ width: 0.5, color: this.theme.border })
        .onClick(() => {
          if (!this.nodeProbing) {
            this.probeNodes();
          }
        })

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor([this.theme.accent])
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(this.theme.surface)
        .border({ width: 0.5, color: this.theme.border })
        .onClick(() => {
          this.openAddMode(0, false);
        })

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(18)
            .fontColor([this.theme.textSecondary])
        }
        .width(34)
        .height(34)
        .borderRadius(17)
        .backgroundColor(this.theme.surface)
        .border({ width: 0.5, color: this.theme.border })
        .bindMenu(this.proxyMoreMenu())
      } else {
        if (this.settingsSubPage.length > 0) {
          Row({ space: 6 }) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize(18)
                .fontColor([this.theme.accent])
            }
            .width(32)
            .height(32)
            .borderRadius(16)
            .backgroundColor(this.theme.surface)
            .border({ width: 0.5, color: this.theme.border })
            Text(this.settingsSubTitle())
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)
              .margin({ left: 4 })
          }
          .onClick(() => {
            this.closeSettingsSubPage();
          })

          Blank()
        } else {
          Text('设置')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.theme.textPrimary)

          Blank()
        }
      }
    }
    .width('100%')
    .padding({ left: 20, right: 18, top: this.insets.top + 10, bottom: 10 })
    .backgroundColor(this.theme.bg)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const measured: number = Number(newArea.height);
      if (measured > 0 && measured !== this.headerHeight) {
        this.headerHeight = measured;
      }
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }

  // Sing-box style floating frosted pill navigation bar with live touch-drag highlight capsule.
  @Builder
  floatingNavBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      // Frosted glass backdrop layer
      Column()
        .width('100%')
        .height(60)
        .borderRadius(30)
        .backgroundColor(this.nativeGlassAvailable() ? this.theme.navBgGlass : this.theme.navBg)
        .backdropBlur(this.nativeGlassAvailable() ? 0 : 28)
        .backgroundEffect({
          radius: this.nativeGlassAvailable() ? 0 : 14,
          saturation: 1.15,
          brightness: this.theme.isDark ? 1.02 : 1.03,
          color: Color.Transparent
        })
        .border({ width: 0.7, color: this.theme.navBorder })
        .shadow({ radius: this.nativeGlassAvailable() ? 0 : 12, color: this.theme.shadow, offsetY: 4 })
        .hitTestBehavior(HitTestMode.None)

      // Sliding highlight capsule following pointer during press/drag and snapping on release.
      if (this.navBarWidth > 0) {
        Column()
          .width(this.navCapsuleWidth())
          .height(52)
          .borderRadius(26)
          .backgroundColor(this.theme.navHighlight)
          .border({ width: 0.5, color: this.theme.navHighlightBorder })
          .position({ x: this.navGlowLeft(), y: 4 })
          .hitTestBehavior(HitTestMode.None)
          .animation({ duration: this.navDragging ? 0 : 160, curve: Curve.EaseOut })
      }

      Row() {
        this.navItem(0, $r('sys.symbol.house_fill'), $r('sys.symbol.house'), '主页')
        this.navItem(1, $r('sys.symbol.paperplane_fill'), $r('sys.symbol.paperplane'), '节点')
        this.navItem(2, $r('sys.symbol.gearshape_fill'), $r('sys.symbol.gearshape'), '设置')
      }
      .width('100%')
      .height(60)
    }
    .width('100%')
    .height(60)
    .borderRadius(30)
    .clip(true)
    .attributeModifier(this.glassModifier(true))
    .onAreaChange((_old: Area, area: Area) => {
      const w: number = Number(area.width);
      if (w > 0 && w !== this.navBarWidth) {
        this.navBarWidth = w;
      }
    })
    .onTouch((event: TouchEvent) => {
      this.handleNavTouch(event);
    })
  }

  @Builder
  navItem(index: number, activeIcon: Resource, inactiveIcon: Resource, label: string) {
    Column({ space: 3 }) {
      SymbolGlyph(this.highlightedNavIndex() === index ? activeIcon : inactiveIcon)
        .fontSize(20)
        .fontColor([this.highlightedNavIndex() === index ? this.theme.accent : this.theme.textSecondary])
        .animation({ duration: 140, curve: Curve.EaseOut })
      Text(label)
        .fontSize(10)
        .fontWeight(this.highlightedNavIndex() === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.highlightedNavIndex() === index ? this.theme.accent : this.theme.textSecondary)
        .animation({ duration: 140, curve: Curve.EaseOut })
    }
    .layoutWeight(1)
    .height(60)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      if (Date.now() >= this.navIgnoreClickUntil) {
        this.selectMainTab(index);
      }
    })
  }

  // ==================== TAB 0: HOME (Pure, Understated, Unboxed Power Circle) ====================

  @Builder
  homeTab() {
    Scroll() {
      Column({ space: 18 }) {
        this.powerOrbSection()
        this.activeProxyCapsule()
        this.quickModeBar()
        if (this.state === 'running' || this.state === 'starting') {
          this.liveTelemetryCard()
        }
      }
      .width('100%')
      .padding({
        left: 20,
        right: 20,
        top: this.headerHeight + (this.state === 'running' ? 18 : 52),
        bottom: this.insets.bottom + 96
      })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  @Builder
  powerOrbSection() {
    Column({ space: 18 }) {
      // Anywhere-style minimalist power button: pure neutral circle, border, and
      // power glyph — ONLY the single bottom indicator dot lights up by state.
      Stack({ alignContent: Alignment.Center }) {
        if (this.state === 'starting') {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.theme.textSecondary)
        } else {
          SymbolGlyph($r('sys.symbol.power'))
            .fontSize(42)
            .fontWeight(FontWeight.Medium)
            .fontColor([this.theme.powerIdleIcon])
        }

        Circle()
          .width(7)
          .height(7)
          .fill(this.state === 'running' ? this.theme.success
            : (this.state === 'starting' || this.state === 'suspended' ? this.theme.warning
              : (this.state === 'error' ? this.theme.danger : this.theme.textTertiary)))
          .shadow(this.state === 'running' || this.state === 'starting' ||
            this.state === 'suspended' || this.state === 'error'
            ? {
                radius: 8,
                color: this.state === 'running' ? this.theme.success
                  : (this.state === 'error' ? this.theme.danger : this.theme.warning),
                offsetX: 0,
                offsetY: 0
              }
            : { radius: 0, color: Color.Transparent })
          .offset({ y: 40 })
      }
      .width(136)
      .height(136)
      .borderRadius(68)
      .clip(true)
      .backgroundColor(this.theme.powerIdleBg)
      .border({
        width: 1.2,
        color: this.theme.powerIdleBorder
      })
      .onClick(() => {
        this.toggleMainVpn();
      })

      Column({ space: 6 }) {
        Text(this.stateTitle())
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.state === 'error' ? this.theme.danger
            : (this.state === 'suspended' ? this.theme.warning : this.theme.textPrimary))
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Row({ space: 8 }) {
          Text(this.state === 'running'
            ? ('已运行 ' + formatDuration(this.seconds))
            : (this.hasEntry ? '轻触按钮切换连接' : '请先添加节点或订阅'))
            .fontSize(13)
            .fontColor(this.theme.textSecondary)
          if (this.probeMs > 0 && this.state === 'running') {
            Text(this.probeMs + ' ms')
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.probeMs < 300 ? this.theme.success : (this.probeMs < 500 ? this.theme.warning : this.theme.danger))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(8)
              .backgroundColor(this.theme.surface)
              .border({ width: 0.5, color: this.theme.border })
          }
        }
        .justifyContent(FlexAlign.Center)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .padding({ top: 4, bottom: 10 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  activeProxyCapsule() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.hasEntry ? $r('sys.symbol.paperplane_fill') : $r('sys.symbol.plus_circle_fill'))
          .fontSize(17)
          .fontColor([this.hasEntry ? this.theme.accent : this.theme.success])
      }
      .width(38)
      .height(38)
      .borderRadius(12)
      .backgroundColor(this.hasEntry ? this.theme.accentSoft : this.theme.successSoft)

      Column({ space: 5 }) {
        Text(this.hasEntry ? this.entryName : '添加节点或订阅')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.hasEntry && this.selectedNodeEntry() !== null) {
          Row({ space: 5 }) {
            ForEach(extractNodeBadges(this.entryType, this.selectedNodeEntry()!.json), (badge: NodeBadge) => {
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
        } else {
          Text('支持二维码扫码、分享链接、订阅与 JSON')
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        if (this.hasEntry) {
          this.activeTab = 1;
          this.refreshEntry();
          this.loadLatencyCache();
        } else {
          this.openAddMode(0, false);
        }
      })

      if (this.hasEntry && this.selectedNodeEntry() !== null) {
        Text(this.latencyText(this.selectedId))
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.latencyColor(this.selectedId))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor(this.theme.surfaceMuted)
          .onClick(() => {
            const current: ConfigEntry | null = this.selectedNodeEntry();
            if (current !== null) {
              this.probeSingleNode(current);
            }
          })
      }

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.theme.textTertiary])
        .onClick(() => {
          if (this.hasEntry) {
            this.activeTab = 1;
            this.refreshEntry();
            this.loadLatencyCache();
          } else {
            this.openAddMode(0, false);
          }
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  @Builder
  quickModeBar() {
    Row({ space: 4 }) {
      this.modeSegment(MODE_GFW, 'GFW')
      this.modeSegment(MODE_BYPASS, '绕过大陆')
      this.modeSegment(MODE_GLOBAL, '全局')
    }
    .width('100%')
    .padding(4)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(16)
  }

  @Builder
  modeSegment(mode: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.routeMode === mode ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.routeMode === mode ? this.theme.accentOn : this.theme.textSecondary)
      .backgroundColor(this.routeMode === mode ? this.theme.accent : Color.Transparent)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(36)
      .borderRadius(12)
      .onClick(() => {
        this.selectMode(mode);
      })
  }

  @Builder
  liveTelemetryCard() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 3 }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.arrow_down'))
              .fontSize(11)
              .fontColor([this.theme.success])
            Text('下载')
              .fontSize(11)
              .fontColor(this.theme.textSecondary)
          }
          Text(formatSpeed(this.downSpeed))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
          Text(formatBytes(this.down))
            .fontSize(11)
            .fontColor(this.theme.textTertiary)
        }
        .layoutWeight(1)

        Column({ space: 3 }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.arrow_up'))
              .fontSize(11)
              .fontColor([this.theme.accent])
            Text('上传')
              .fontSize(11)
              .fontColor(this.theme.textSecondary)
          }
          Text(formatSpeed(this.upSpeed))
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
          Text(formatBytes(this.up))
            .fontSize(11)
            .fontColor(this.theme.textTertiary)
        }
        .layoutWeight(1)

        Column({ space: 3 }) {
          Row({ space: 3 }) {
            Text('活跃连接')
              .fontSize(11)
              .fontColor(this.theme.textSecondary)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(10)
              .fontColor([this.theme.accent])
          }
          Text(this.flows.toString())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
          Text('点击查看')
            .fontSize(11)
            .fontColor(this.theme.accent)
        }
        .layoutWeight(1)
        .onClick(() => {
          this.openConnections();
        })
      }
      .width('100%')

      Divider().color(this.theme.divider)

      Row({ space: 6 }) {
        Text('内存 ' + this.memoryText())
          .fontSize(11)
          .fontColor(this.theme.textSecondary)
        Text('·')
          .fontSize(11)
          .fontColor(this.theme.textTertiary)
        Text('CPU ' + this.cpuText())
          .fontSize(11)
          .fontColor(this.theme.textSecondary)
        Blank()
        if (this.dnsLeakProtect) {
          Text('防 DNS 泄露')
            .fontSize(10)
            .fontColor(this.theme.success)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(6)
            .backgroundColor(this.theme.successSoft)
        }
        if (this.webrtcLeakProtect) {
          Text('WebRTC')
            .fontSize(10)
            .fontColor(this.theme.accent)
            .padding({ left: 7, right: 7, top: 2, bottom: 2 })
            .borderRadius(6)
            .backgroundColor(this.theme.accentSoft)
        }
      }
      .width('100%')
      .onClick(() => {
        this.activeTab = 2;
        this.openSettingsSubPage('privacy');
      })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  // ==================== TAB 1: PROXIES ====================

  @Builder
  proxiesTab() {
    Scroll() {
      Column({ space: 10 }) {
        Row() {
          Text('共 ' + this.nodeList.length + ' 节点 · ' + this.subs.length + ' 订阅')
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
          Blank()
          Text(this.sortByDelay ? '按延迟排序' : '默认顺序')
            .fontSize(11)
            .fontColor(this.theme.accent)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(8)
            .backgroundColor(this.theme.accentSoft)
            .onClick(() => {
              this.sortByDelay = !this.sortByDelay;
            })
        }
        .width('100%')
        .padding({ left: 4, right: 4, bottom: 2 })

        if (this.nodeList.length === 0 && this.subs.length === 0) {
          Column({ space: 14 }) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.paperplane_fill'))
                .fontSize(26)
                .fontColor([this.theme.accent])
            }
            .width(54)
            .height(54)
            .borderRadius(16)
            .backgroundColor(this.theme.accentSoft)

            Text('还没有节点或订阅')
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.textPrimary)
            Text('支持扫码导入、主流协议链接、订阅地址与 JSON 配置')
              .fontSize(13)
              .fontColor(this.theme.textSecondary)
              .textAlign(TextAlign.Center)

            Row({ space: 10 }) {
              Button() {
                Row({ space: 6 }) {
                  SymbolGlyph($r('sys.symbol.qrcode'))
                    .fontSize(16)
                    .fontColor([this.theme.accentOn])
                  Text('扫码导入')
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.theme.accentOn)
                }
              }
              .layoutWeight(1)
              .height(44)
              .backgroundColor(this.theme.accent)
              .borderRadius(22)
              .onClick(() => {
                this.openAddMode(0, true);
              })

              Button('添加节点')
                .layoutWeight(1)
                .height(44)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.textPrimary)
                .backgroundColor(this.theme.surfaceMuted)
                .borderRadius(22)
                .onClick(() => {
                  this.openAddMode(0, false);
                })
            }
            .width('100%')
            .margin({ top: 6 })
          }
          .width('100%')
          .padding({ top: 44, bottom: 36, left: 24, right: 24 })
          .backgroundColor(this.theme.surface)
          .border({ width: 0.5, color: this.theme.border })
          .borderRadius(20)
        } else {
          if (manualEntries(this.nodeList).length > 0) {
            ForEach(this.manualNodeList(), (entry: ConfigEntry) => {
              this.proxyItemRow(entry, false)
            }, (entry: ConfigEntry) => entry.id)
          }

          ForEach(this.subs, (sub: SubscriptionRecord) => {
            this.subscriptionAccordion(sub)
          }, (sub: SubscriptionRecord) => sub.id + '|' + sub.updatedAt + '|' + sub.name + '|' + sub.url)
        }
      }
      .width('100%')
      .padding({
        left: 16,
        right: 16,
        top: this.headerHeight + 4,
        bottom: this.insets.bottom + 96
      })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  @Builder
  proxyItemRow(entry: ConfigEntry, inContainer: boolean) {
    Row() {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          Text(entry.name)
            .fontSize(14)
            .fontWeight(entry.id === this.selectedId ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(this.theme.textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: '88%' })
          if (entry.id === this.selectedId) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor([this.theme.accent])
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
        this.pickNode(entry);
      })

      Text(this.latencyText(entry.id))
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.latencyColor(entry.id))
        .textAlign(TextAlign.End)
        .constraintSize({ minWidth: 56 })
        .padding({ left: 8, right: 2, top: 8, bottom: 8 })
        .onClick(() => {
          this.probeSingleNode(entry);
        })
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .backgroundColor(entry.id === this.selectedId
      ? this.theme.surfaceSelected
      : (inContainer ? this.theme.surfaceMuted : this.theme.surface))
    .border({
      width: entry.id === this.selectedId ? 1 : 0.5,
      color: entry.id === this.selectedId ? this.theme.accent : this.theme.border
    })
    .borderRadius(16)
    .bindContextMenu(this.proxyContextMenu(entry, inContainer), ResponseType.LongPress)
  }

  @Builder
  proxyContextMenu(entry: ConfigEntry, owned: boolean) {
    Menu() {
      MenuItem({ content: '测试延迟' })
        .onClick(() => {
          this.probeSingleNode(entry);
        })
      if (entry.server.length > 0) {
        MenuItem({ content: '复制服务器地址' })
          .onClick(() => {
            this.copyPlainText(entry.server, '服务器地址');
          })
      }
      if (!owned) {
        MenuItem({ content: '删除节点' })
          .contentFontColor(this.theme.danger)
          .onClick(() => {
            this.confirmDeleteNode(entry);
          })
      }
    }
  }

  @Builder
  subscriptionAccordion(sub: SubscriptionRecord) {
    Column() {
      if (this.editingSubId === sub.id) {
        Column({ space: 10 }) {
          Text('编辑订阅')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
            .width('100%')
          TextInput({ text: this.editSubName, placeholder: '订阅名称' })
            .height(40)
            .fontSize(13)
            .fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textTertiary)
            .backgroundColor(this.theme.surfaceMuted)
            .borderRadius(12)
            .width('100%')
            .onChange((value: string) => {
              this.editSubName = value;
            })
          TextInput({ text: this.editSubUrl, placeholder: 'https://example.com/sub?token=...' })
            .height(40)
            .fontSize(12)
            .fontColor(this.theme.textPrimary)
            .placeholderColor(this.theme.textTertiary)
            .backgroundColor(this.theme.surfaceMuted)
            .borderRadius(12)
            .width('100%')
            .onChange((value: string) => {
              this.editSubUrl = value;
            })
          Row({ space: 10 }) {
            Button('取消')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor(this.theme.textSecondary)
              .backgroundColor(this.theme.surfaceMuted)
              .borderRadius(12)
              .onClick(() => {
                this.editingSubId = '';
              })
            Button('保存')
              .layoutWeight(1)
              .height(38)
              .fontSize(13)
              .fontColor(this.theme.accentOn)
              .backgroundColor(this.theme.accent)
              .borderRadius(12)
              .onClick(() => {
                this.commitEditSub(sub.id);
              })
          }
          .width('100%')
        }
        .width('100%')
      } else {
        Row({ space: 12 }) {
          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.worldclock_fill'))
              .fontSize(17)
              .fontColor([this.subContainsSelected(sub.id) ? this.theme.accent : this.theme.textSecondary])
          }
          .width(34)
          .height(34)
          .borderRadius(10)
          .backgroundColor(this.subContainsSelected(sub.id) ? this.theme.accentSoft : this.theme.surfaceMuted)

          Column({ space: 3 }) {
            Row({ space: 8 }) {
              Text(sub.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.isUpdatingSub(sub.id)) {
                LoadingProgress()
                  .width(14)
                  .height(14)
                  .color(this.theme.accent)
              }
              Text('' + entriesOfSub(this.nodeList, sub.id).length)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.accent)
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(10)
                .backgroundColor(this.theme.accentSoft)
              SymbolGlyph(this.expandedSubId === sub.id
                ? $r('sys.symbol.chevron_up')
                : $r('sys.symbol.chevron_down'))
                .fontSize(14)
                .fontColor([this.theme.textTertiary])
            }
            .width('100%')

            if (this.expandedSubId === sub.id) {
              Text((sub.total > 0 || sub.upload > 0 || sub.download > 0)
                ? formatQuota(sub.upload + sub.download, sub.total)
                : ('更新于 ' + this.formatShortStamp(sub.updatedAt)))
                .fontSize(11)
                .fontColor(this.theme.textSecondary)
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
          if (sub.total > 0 || sub.upload > 0 || sub.download > 0) {
            Progress({
              value: sub.upload + sub.download,
              total: sub.total > 0 ? sub.total : 1,
              type: ProgressType.Linear
            })
              .width('100%')
              .height(4)
              .color(this.theme.accent)
              .backgroundColor(this.theme.surfaceMuted)
              .margin({ top: 10 })

            Row() {
              Text('到期 ' + formatExpire(sub.expire))
                .fontSize(11)
                .fontColor(this.theme.textTertiary)
                .layoutWeight(1)
              Text('更新于 ' + this.formatShortStamp(sub.updatedAt))
                .fontSize(11)
                .fontColor(this.theme.textTertiary)
            }
            .width('100%')
            .margin({ top: 6 })
          }

          Row({ space: 6 }) {
            this.subActionBtn(
              $r('sys.symbol.arrow_clockwise'),
              this.isUpdatingSub(sub.id) ? '更新中' : '更新',
              this.isUpdatingSub(sub.id) ? this.theme.textTertiary : this.theme.accent,
              () => {
                if (!this.isUpdatingSub(sub.id)) {
                  this.refreshOneSub(sub.id);
                }
              }
            )
            this.subActionBtn(
              $r('sys.symbol.bolt_1'),
              '测速',
              this.nodeProbing ? this.theme.textTertiary : this.theme.success,
              () => {
                if (!this.nodeProbing) {
                  this.probeScope(this.subNodeList(sub.id));
                }
              }
            )
            this.subActionBtn(
              $r('sys.symbol.square_and_pencil'),
              '编辑',
              this.theme.textSecondary,
              () => {
                this.beginEditSub(sub.id);
              }
            )
            this.subActionBtn(
              $r('sys.symbol.text_clipboard'),
              '复制',
              this.theme.textSecondary,
              () => {
                this.copyPlainText(sub.url, '订阅链接');
              }
            )
            this.subActionBtn(
              $r('sys.symbol.trash'),
              '删除',
              this.theme.danger,
              () => {
                this.confirmDeleteSub(sub.id);
              }
            )
          }
          .width('100%')
          .margin({ top: 10 })

          Divider().color(this.theme.divider).margin({ top: 12, bottom: 10 })

          if (entriesOfSub(this.nodeList, sub.id).length === 0) {
            Text('该订阅暂无节点，请点上方「更新」拉取。')
              .fontSize(12)
              .fontColor(this.theme.textTertiary)
              .width('100%')
              .padding({ top: 6, bottom: 6 })
          } else {
            Column({ space: 8 }) {
              ForEach(this.subNodeList(sub.id), (entry: ConfigEntry) => {
                this.proxyItemRow(entry, true)
              }, (entry: ConfigEntry) => entry.id)
            }
            .width('100%')
          }
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.surface)
    .border({
      width: 0.5,
      color: this.expandedSubId === sub.id ? this.theme.borderStrong : this.theme.border
    })
    .borderRadius(20)
  }

  @Builder
  subActionBtn(symbol: Resource, label: string, color: string, onTap: () => void) {
    Row({ space: 4 }) {
      SymbolGlyph(symbol)
        .fontSize(12)
        .fontColor([color])
      Text(label)
        .fontSize(11)
        .fontColor(color)
    }
    .layoutWeight(1)
    .height(32)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor(this.theme.surfaceMuted)
    .onClick(onTap)
  }

  // ==================== TAB 2: SETTINGS (Anywhere ToolboxView + Themes + About/Updater) ====================

  @Builder
  settingsTab() {
    Scroll() {
      Column({ space: 16 }) {
        if (this.settingsSubPage === '') {
          this.settingsRootList()
        } else if (this.settingsSubPage === 'appearance') {
          this.settingsAppearancePage()
        } else if (this.settingsSubPage === 'routing') {
          this.settingsRoutingPage()
        } else if (this.settingsSubPage === 'privacy') {
          this.settingsPrivacyPage()
        } else if (this.settingsSubPage === 'keepalive') {
          this.settingsKeepAlivePage()
        } else if (this.settingsSubPage === 'wifi') {
          this.settingsWifiPage()
        } else if (this.settingsSubPage === 'logs') {
          this.settingsLogsPage()
        } else {
          this.settingsAboutPage()
        }
      }
      .width('100%')
      .padding({
        left: 18,
        right: 18,
        top: this.headerHeight + 6,
        bottom: this.insets.bottom + 96
      })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
  }

  @Builder
  settingsRootList() {
    // Section 1: Appearance & Personalization (matches Anywhere Personalization section)
    Column() {
      this.settingsNavRow(
        $r('sys.symbol.slider_vertical_3'),
        '#EC4899',
        '外观与主题',
        this.theme.name,
        () => {
          this.openSettingsSubPage('appearance');
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    // Section 2: VPN & Routing
    Column() {
      this.settingsNavRow(
        $r('sys.symbol.slider_horizontal_2'),
        '#8B5CF6',
        '分流与路由',
        this.useRuleSet && this.hasRuleSet ? '自定义规则' : this.modeName(this.routeMode),
        () => {
          this.openSettingsSubPage('routing');
        }
      )
      Divider().color(this.theme.divider).margin({ left: 58 })
      this.settingsNavRow(
        $r('sys.symbol.lock_fill'),
        '#3B82F6',
        '隧道与隐私防护',
        this.privacySummary(),
        () => {
          this.openSettingsSubPage('privacy');
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    // Section 3: HarmonyOS Keep-Alive & Trusted Network
    Column() {
      this.settingsNavRow(
        $r('sys.symbol.bell_fill'),
        '#10B981',
        '后台保活与通知',
        this.keepAliveOnRemove ? '无窗口保活' : '标准',
        () => {
          this.openSettingsSubPage('keepalive');
        }
      )
      Divider().color(this.theme.divider).margin({ left: 58 })
      this.settingsNavRow(
        $r('sys.symbol.wifi'),
        '#06B6D4',
        '受信任 Wi-Fi',
        this.rules.length > 0 ? (this.rules.length + ' 条规则') : '未设置',
        () => {
          this.openSettingsSubPage('wifi');
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    // Section 4: Diagnostics & About/Core
    Column() {
      this.settingsNavRow(
        $r('sys.symbol.waveform'),
        '#6366F1',
        '实时连接监控',
        this.state === 'running' ? (this.flows + ' 条活跃') : '',
        () => {
          this.openConnections();
        }
      )
      Divider().color(this.theme.divider).margin({ left: 58 })
      this.settingsNavRow(
        $r('sys.symbol.doc_plaintext_fill'),
        '#F59E0B',
        '诊断与运行日志',
        this.debugLog ? '诊断已开' : '',
        () => {
          this.openSettingsSubPage('logs');
        }
      )
      Divider().color(this.theme.divider).margin({ left: 58 })
      this.settingsNavRow(
        $r('sys.symbol.info_circle_fill'),
        '#64748B',
        '内核与关于',
        'v' + APP_VERSION_NAME,
        () => {
          this.openSettingsSubPage('about');
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  @Builder
  settingsNavRow(icon: Resource, badgeBg: string, title: string, value: string, onTap: () => void) {
    Row({ space: 14 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(icon)
          .fontSize(16)
          .fontColor(['#FFFFFF'])
      }
      .width(30)
      .height(30)
      .borderRadius(8)
      .backgroundColor(badgeBg)

      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textPrimary)
        .layoutWeight(1)

      if (value.length > 0) {
        Text(value)
          .fontSize(13)
          .fontColor(this.theme.textSecondary)
      }

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([this.theme.textTertiary])
    }
    .width('100%')
    .padding({ left: 14, right: 16, top: 14, bottom: 14 })
    .onClick(onTap)
  }

  @Builder
  settingsSectionHeader(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.theme.textSecondary)
      .width('100%')
      .padding({ left: 6 })
  }

  @Builder
  settingsToggleRow(title: string, subtitle: string, value: boolean, onChange: (v: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text(title)
          .fontSize(15)
          .fontColor(this.theme.textPrimary)
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(this.theme.accent)
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 13, bottom: 13 })
  }

  // ---- Sub-page: Appearance & Themes ----
  @Builder
  settingsAppearancePage() {
    this.settingsSectionHeader('选择界面主题')
    Column() {
      ForEach(ALL_THEMES, (item: AppTheme, idx: number) => {
        Column() {
          if (idx > 0) {
            Divider().color(this.theme.divider).margin({ left: 62 })
          }
          Row({ space: 14 }) {
            // Dual-tone theme swatch preview
            Stack({ alignContent: Alignment.BottomEnd }) {
              Column()
                .width(34)
                .height(34)
                .borderRadius(10)
                .backgroundColor(item.previewBg)
                .border({ width: 1, color: this.theme.borderStrong })
              Circle()
                .width(12)
                .height(12)
                .fill(item.previewAccent)
                .border({ width: 1.5, color: item.previewBg })
                .margin({ right: 3, bottom: 3 })
            }
            .width(34)
            .height(34)

            Column({ space: 2 }) {
              Text(item.name)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.theme.textPrimary)
              Text(item.subtitle)
                .fontSize(12)
                .fontColor(this.theme.textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            if (this.themeId === item.id) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill_1'))
                .fontSize(20)
                .fontColor([this.theme.accent])
            }
          }
          .width('100%')
          .padding({ left: 14, right: 16, top: 13, bottom: 13 })
          .onClick(() => {
            this.selectTheme(item.id);
          })
        }
      }, (item: AppTheme) => item.id)
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  // ---- Sub-page: Routing ----
  @Builder
  settingsRoutingPage() {
    this.settingsSectionHeader('路由模式')
    Column({ space: 10 }) {
      Row({ space: 4 }) {
        this.modeSegment(MODE_GFW, 'GFW')
        this.modeSegment(MODE_BYPASS, '绕过大陆')
        this.modeSegment(MODE_GLOBAL, '全局')
      }
      .width('100%')
      .padding(4)
      .backgroundColor(this.theme.surfaceMuted)
      .borderRadius(14)

      Text(this.routeMode === MODE_GFW
        ? '仅受限站点走节点，其余国内与常见海外站点直连。'
        : (this.routeMode === MODE_GLOBAL
          ? '所有公网流量与远程 DNS 全部经由代理节点转发。'
          : '局域网与大陆域名/IP 直连，其余海外流量走节点。'))
        .fontSize(12)
        .fontColor(this.theme.textSecondary)
        .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    this.settingsSectionHeader('规则集与地理数据')
    Column() {
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('自定义规则')
            .fontSize(15)
            .fontColor(this.theme.textPrimary)
          Text(this.hasRuleSet ? this.ruleSetText : '未添加（默认使用极简基础规则）')
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.hasRuleSet ? '编辑' : '添加')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accent)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(14)
          .fontColor([this.theme.textTertiary])
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        this.openCustomRules();
      })

      if (this.hasRuleSet) {
        Divider().color(this.theme.divider).margin({ left: 16 })
        this.settingsToggleRow(
          '启用自定义规则',
          '开启后优先按自定义规则分流',
          this.useRuleSet,
          (v: boolean) => {
            this.toggleRuleSet(v);
          }
        )
      }

      Divider().color(this.theme.divider).margin({ left: 16 })

      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('GeoData 规则文件')
            .fontSize(15)
            .fontColor(this.theme.textPrimary)
          Text(this.geoText)
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text(this.geoBusy ? '更新中…' : '更新')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.geoBusy ? this.theme.textTertiary : this.theme.accent)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor(this.theme.accentSoft)
          .onClick(() => {
            if (!this.geoBusy) {
              this.runGeodataUpdate(false);
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 13, bottom: 13 })

      Divider().color(this.theme.divider).margin({ left: 16 })

      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('规则下载源')
            .fontSize(15)
            .fontColor(this.theme.textPrimary)
          Text(this.geoSourceName)
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('切换')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accent)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor(this.theme.accentSoft)
          .onClick(() => {
            this.cycleGeoSource();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 13, bottom: 13 })
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  // ---- Sub-page: Tunnel & Privacy ----
  @Builder
  settingsPrivacyPage() {
    this.settingsSectionHeader('防泄露保护')
    Column() {
      this.settingsToggleRow(
        '防 DNS 泄露',
        '拦截 53/853 逃逸与 IPv6 DNS 泄露，海外及全局强制远程解析',
        this.dnsLeakProtect,
        (v: boolean) => {
          this.toggleDnsLeakProtect(v);
        }
      )
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.settingsToggleRow(
        '防 WebRTC 泄露',
        '阻断 STUN/TURN 探测真实 IP；如需语音视频通话可热关闭',
        this.webrtcLeakProtect,
        (v: boolean) => {
          this.toggleWebrtcLeakProtect(v);
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    this.settingsSectionHeader('DNS 与传输')
    Column() {
      this.settingsToggleRow(
        'DoH 加密 DNS',
        this.dohDns ? '国内 223.5.5.5 直连 · 海外 1.1.1.1 走节点' : '使用普通 DNS 解析',
        this.dohDns,
        (v: boolean) => {
          this.toggleDoh(v);
        }
      )
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.settingsToggleRow(
        'FakeIP 域名优先',
        '减少海外连接 DNS 等待，重连后生效',
        this.fakeDns,
        (v: boolean) => {
          this.toggleFakeDns(v);
        }
      )
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.settingsToggleRow(
        '屏蔽 QUIC (UDP 443)',
        '拒绝 UDP 443 回退至 TCP，热生效',
        this.blockQuic,
        (v: boolean) => {
          this.toggleBlockQuic(v);
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  // ---- Sub-page: HarmonyOS Keep-Alive & Notifications ----
  @Builder
  settingsKeepAlivePage() {
    this.settingsSectionHeader('后台运行与实况窗')
    Column() {
      this.settingsToggleRow(
        '后台运行 VPN',
        '划掉主窗口后保持 VPN 在线（更新或开关均不弹卡片）',
        this.keepAliveOnRemove,
        (v: boolean) => {
          this.toggleKeepAliveOnRemove(v);
        }
      )
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.settingsToggleRow(
        '常驻流量实况窗',
        '锁屏自动心跳续命 · 状态点（🟢运行 · 🟡挂起 · 🔴异常）',
        this.notifyMe,
        (v: boolean) => {
          this.notifyMe = v;
          this.persist();
        }
      )
      Divider().color(this.theme.divider).margin({ left: 16 })
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('恢复实况窗通知')
            .fontSize(15)
            .fontColor(this.theme.textPrimary)
          Text(this.keepAliveTaskCanceled ? '实况窗曾被系统清理，将自动恢复或点右侧立即补发' : '锁屏掉通知时自动重连，亦可手动补发')
            .fontSize(12)
            .fontColor(this.keepAliveTaskCanceled ? this.theme.warning : this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('恢复')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accent)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(12)
          .backgroundColor(this.theme.accentSoft)
          .onClick(() => {
            if (!this.isTunnelRunning()) {
              promptAction.showToast({ message: '请先连接 VPN' });
              return;
            }
            this.taskReviveAttempts = 0;
            this.reviveTask().then(() => {
              promptAction.showToast({ message: '已恢复流量实况窗' });
            }).catch(() => {
              promptAction.showToast({ message: '恢复通知失败' });
            });
          })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 13, bottom: 13 })

      Divider().color(this.theme.divider).margin({ left: 16 })
      Row({ space: 12 }) {
        Column({ space: 3 }) {
          Text('桌面快捷卡片（可选）')
            .fontSize(15)
            .fontColor(this.theme.textPrimary)
          Text('仅在需要把开关添加到桌面时手动打开')
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('添加')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textSecondary)
          .padding({ left: 14, right: 14, top: 7, bottom: 7 })
          .borderRadius(12)
          .backgroundColor(this.theme.surfaceMuted)
          .onClick(() => {
            this.openKeepAliveForm();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 13, bottom: 13 })
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    this.settingsSectionHeader('自动恢复')
    Column() {
      this.settingsToggleRow(
        '断网自动重连',
        'Wi-Fi 与蜂窝切换时自动重绑底层连接',
        this.rebindOnNetChange,
        (v: boolean) => {
          this.rebindOnNetChange = v;
          this.persist();
        }
      )
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.settingsToggleRow(
        '打开应用自动连接',
        '若上次退出时处于连接状态，下次启动自动恢复',
        this.autoConnect,
        (v: boolean) => {
          this.autoConnect = v;
          this.persist();
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  // ---- Sub-page: Trusted Wi-Fi ----
  @Builder
  settingsWifiPage() {
    this.settingsSectionHeader('当前网络')
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(17)
          .fontColor([this.currentWifi.length > 0 ? this.theme.success : this.theme.textTertiary])
      }
      .width(34)
      .height(34)
      .borderRadius(10)
      .backgroundColor(this.currentWifi.length > 0 ? this.theme.successSoft : this.theme.surfaceMuted)

      Column({ space: 2 }) {
        Text(this.currentWifi.length > 0 ? this.currentWifi : '未获取到当前 Wi-Fi')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
        Text(this.currentWifi.length > 0 ? '加入列表后连入该 Wi-Fi 自动挂起（通知栏显示🟡）' : '需要大致位置权限以读取 Wi-Fi 名称')
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.currentWifi.length === 0) {
        Text('授权')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accent)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(12)
          .backgroundColor(this.theme.accentSoft)
          .onClick(() => {
            this.requestLocation();
          })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    this.settingsSectionHeader('添加受信任 Wi-Fi（自动挂起）')
    Column({ space: 10 }) {
      TextInput({
        placeholder: this.currentWifi.length > 0 ? this.currentWifi : '输入 Wi-Fi 名称 (SSID)',
        text: this.manualSsid
      })
        .height(44)
        .fontSize(14)
        .fontColor(this.theme.textPrimary)
        .placeholderColor(this.theme.textTertiary)
        .backgroundColor(this.theme.surfaceMuted)
        .border({ width: 0.5, color: this.theme.border })
        .borderRadius(12)
        .padding({ left: 12, right: 12 })
        .width('100%')
        .onChange((value: string) => {
          this.manualSsid = value;
        })

      Row({ space: 10 }) {
        Button('添加到挂起列表')
          .layoutWeight(1)
          .height(40)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accentOn)
          .backgroundColor(this.theme.accent)
          .borderRadius(12)
          .onClick(() => {
            this.addRuleFromInput(SSID_SUSPEND);
          })
        if (this.rules.length > 0) {
          Button('清空')
            .width(72)
            .height(40)
            .fontSize(13)
            .fontColor(this.theme.danger)
            .backgroundColor(this.theme.dangerSoft)
            .borderRadius(12)
            .onClick(() => {
              this.clearRules();
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    if (this.rules.length > 0) {
      this.settingsSectionHeader('已添加规则（' + this.rules.length + '）')
      Column() {
        ForEach(this.rules, (rule: SsidRule, idx: number) => {
          Column() {
            if (idx > 0) {
              Divider().color(this.theme.divider).margin({ left: 16 })
            }
            Row({ space: 10 }) {
              Text(rule.ssid)
                .fontSize(14)
                .fontColor(this.theme.textPrimary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('自动挂起')
                .fontSize(11)
                .fontColor(this.theme.textSecondary)
              Stack({ alignContent: Alignment.Center }) {
                SymbolGlyph($r('sys.symbol.trash'))
                  .fontSize(15)
                  .fontColor([this.theme.danger])
              }
              .width(30)
              .height(30)
              .borderRadius(8)
              .backgroundColor(this.theme.dangerSoft)
              .onClick(() => {
                this.deleteRule(rule.ssid);
              })
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 12, bottom: 12 })
          }
        }, (rule: SsidRule) => rule.ssid)
      }
      .width('100%')
      .backgroundColor(this.theme.surface)
      .border({ width: 0.5, color: this.theme.border })
      .borderRadius(20)
    }
  }

  // ---- Sub-page: Diagnostics & Logs ----
  @Builder
  settingsLogsPage() {
    Column() {
      this.settingsToggleRow(
        '诊断日志',
        '记录每条连接的路由决策，排查完成后建议关闭',
        this.debugLog,
        (v: boolean) => {
          this.debugLog = v;
          this.persist();
        }
      )
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    Row() {
      Text('运行日志')
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.textSecondary)
      Blank()
      Row({ space: 12 }) {
        Text('刷新')
          .fontSize(12)
          .fontColor(this.theme.accent)
          .onClick(() => {
            if (this.ctx !== null) {
              this.logs = readLogs(this.ctx, 6000);
              promptAction.showToast({ message: '日志已刷新' });
            }
          })
        Text('复制')
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
          .onClick(() => {
            this.copyPlainText(this.logs, '运行日志');
          })
      }
    }
    .width('100%')
    .padding({ left: 6, right: 6 })

    Column() {
      Text(this.logs.length > 0 ? this.logs : '（暂无日志）')
        .fontSize(11)
        .fontColor(this.theme.textSecondary)
        .width('100%')
        .lineHeight(17)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(18)
  }

  // ---- Sub-page: Core, Updates, Repositories & Disclaimer ----
  @Builder
  settingsAboutPage() {
    // App Hero Card with new minimalist app icon & GitHub update checker
    Column({ space: 10 }) {
      Image($r('app.media.app_icon'))
        .width(64)
        .height(64)
        .borderRadius(16)

      Text('way')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textPrimary)
      Text('v' + APP_VERSION_NAME + ' · 内核 ' + this.coreState.activeCore + ' ' + this.coreState.activeVersion + ' (ABI ' + this.coreInfo + ')')
        .fontSize(12)
        .fontColor(this.theme.textSecondary)

      Button(this.updateChecking ? '正在检查更新…' : '检测 GitHub 更新')
        .height(38)
        .padding({ left: 22, right: 22 })
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.theme.accentOn)
        .backgroundColor(this.theme.accent)
        .borderRadius(19)
        .enabled(!this.updateChecking)
        .margin({ top: 4 })
        .onClick(() => {
          this.runUpdateCheck();
        })

      if (this.updateResult !== null) {
        Column({ space: 6 }) {
          if (this.updateResult.error.length > 0) {
            Text(this.updateResult.error)
              .fontSize(12)
              .fontColor(this.theme.danger)
          } else {
            if (this.updateResult.app !== null) {
              Row() {
                Text('客户端最新：' + this.updateResult.app.tag + (this.updateResult.app.hasUpdate ? '（有更新）' : '（已是最新）'))
                  .fontSize(12)
                  .fontColor(this.updateResult.app.hasUpdate ? this.theme.success : this.theme.textSecondary)
                  .layoutWeight(1)
                Text('查看 ›')
                  .fontSize(12)
                  .fontColor(this.theme.accent)
                  .onClick(() => {
                    if (this.updateResult !== null && this.updateResult.app !== null) {
                      this.openExternalUrl(this.updateResult.app.url, '客户端发布页');
                    }
                  })
              }
              .width('100%')
            }
            if (this.updateResult.coreRust !== null) {
              Row() {
                Text('xray-rust 上游：' + this.updateResult.coreRust.tag +
                  (this.updateResult.coreRust.hasUpdate ? '（有更新）' : '（已是最新）'))
                  .fontSize(12)
                  .fontColor(this.updateResult.coreRust.hasUpdate ? this.theme.success : this.theme.textSecondary)
                  .layoutWeight(1)
                Text('查看 ›')
                  .fontSize(12)
                  .fontColor(this.theme.accent)
                  .onClick(() => {
                    if (this.updateResult !== null && this.updateResult.coreRust !== null) {
                      this.openExternalUrl(this.updateResult.coreRust.url, 'xray-rust 发布页');
                    }
                  })
              }
              .width('100%')
            }
            if (this.updateResult.coreUpstream !== null) {
              Row() {
                Text('Xray-core 上游：' + this.updateResult.coreUpstream.tag)
                  .fontSize(12)
                  .fontColor(this.theme.textSecondary)
                  .layoutWeight(1)
                Text('查看 ›')
                  .fontSize(12)
                  .fontColor(this.theme.accent)
                  .onClick(() => {
                    if (this.updateResult !== null && this.updateResult.coreUpstream !== null) {
                      this.openExternalUrl(this.updateResult.coreUpstream.url, 'Xray-core 发布页');
                    }
                  })
              }
              .width('100%')
            }
            if (this.updateResult.manifest.length > 0) {
              Text('GitHub 自动构建内核清单已同步（' + this.updateResult.manifest.length + ' 项）')
                .fontSize(11)
                .fontColor(this.theme.accent)
                .width('100%')
            }
          }
        }
        .width('100%')
        .padding(12)
        .margin({ top: 4 })
        .backgroundColor(this.theme.surfaceMuted)
        .borderRadius(14)
      }
    }
    .width('100%')
    .padding({ top: 22, bottom: 20, left: 16, right: 16 })
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    // Core Selection & Automatic Rollback Protection
    this.settingsSectionHeader('代理内核与安全回退')
    Column() {
      Row({ space: 12 }) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.memory_module'))
            .fontSize(16)
            .fontColor(['#FFFFFF'])
        }
        .width(30)
        .height(30)
        .borderRadius(8)
        .backgroundColor('#10B981')

        Column({ space: 2 }) {
          Text('当前内核 · ' + this.coreState.activeCore)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.theme.textPrimary)
          Text('版本 ' + this.coreState.activeVersion + ' · ABI ' + this.coreInfo + ' · 更新报错自动回退上一版本')
            .fontSize(12)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('校验')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.accent)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(10)
          .backgroundColor(this.theme.accentSoft)
          .onClick(() => {
            this.verifyCoreIntegrity();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 14, bottom: 14 })

      Divider().color(this.theme.divider).margin({ left: 14 })

      // Core Option 1: xray-rust (bundled)
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text('xray-rust（Rust 轻量内核）')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.textPrimary)
            Text('已内置')
              .fontSize(10)
              .fontColor(this.theme.success)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(6)
              .backgroundColor(this.theme.successSoft)
          }
          Text('低内存占用 · 同步 aimalygin/xray-rust 自动构建')
            .fontSize(11)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.coreState.activeCore === CORE_ID_RUST) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill_1'))
            .fontSize(20)
            .fontColor([this.theme.accent])
        }
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 12, bottom: 12 })
      .onClick(() => {
        this.selectCoreEngine(CORE_ID_RUST);
      })

      Divider().color(this.theme.divider).margin({ left: 14 })

      // Core Option 2: XTLS/Xray-core (GitHub Actions dual-core build)
      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text('Xray-core（原版 XTLS 内核）')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme.textPrimary)
            Text(isCoreBundled(CORE_ID_UPSTREAM) ? '已内置' : 'GitHub 自动构建')
              .fontSize(10)
              .fontColor(isCoreBundled(CORE_ID_UPSTREAM) ? this.theme.success : this.theme.accent)
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(6)
              .backgroundColor(isCoreBundled(CORE_ID_UPSTREAM) ? this.theme.successSoft : this.theme.accentSoft)
          }
          Text('完整原版协议特性 · 切换异常时自动回退至 xray-rust')
            .fontSize(11)
            .fontColor(this.theme.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.coreState.activeCore === CORE_ID_UPSTREAM) {
          SymbolGlyph($r('sys.symbol.checkmark_circle_fill_1'))
            .fontSize(20)
            .fontColor([this.theme.accent])
        }
      }
      .width('100%')
      .padding({ left: 16, right: 14, top: 12, bottom: 12 })
      .onClick(() => {
        this.selectCoreEngine(CORE_ID_UPSTREAM);
      })

      if (this.coreState.lastRollbackReason.length > 0) {
        Divider().color(this.theme.divider).margin({ left: 14 })
        Row({ space: 8 }) {
          SymbolGlyph($r('sys.symbol.info_circle_fill'))
            .fontSize(15)
            .fontColor([this.theme.warning])
          Text(this.coreState.lastRollbackReason)
            .fontSize(12)
            .fontColor(this.theme.warning)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 10, bottom: 12 })
      }
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    // Project & Core Repositories
    this.settingsSectionHeader('开源地址')
    Column() {
      this.aboutLinkRow('项目地址', PROJECT_REPO_URL)
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.aboutLinkRow('当前内核（xray-rust）', CORE_RUST_REPO_URL)
      Divider().color(this.theme.divider).margin({ left: 16 })
      this.aboutLinkRow('上游内核（Xray-core）', CORE_UPSTREAM_REPO_URL)
    }
    .width('100%')
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)

    // Disclaimer
    this.settingsSectionHeader('免责声明')
    Column({ space: 8 }) {
      Text(DISCLAIMER_TEXT)
        .fontSize(12)
        .lineHeight(20)
        .fontColor(this.theme.textSecondary)
        .width('100%')
      Row() {
        Text('应用包名')
          .fontSize(12)
          .fontColor(this.theme.textTertiary)
        Blank()
        Text(appBundleName(this.ctx))
          .fontSize(12)
          .fontColor(this.theme.textSecondary)
      }
      .width('100%')
      .padding({ top: 6 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.theme.surface)
    .border({ width: 0.5, color: this.theme.border })
    .borderRadius(20)
  }

  @Builder
  aboutLinkRow(title: string, url: string) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.theme.textPrimary)
        Text(url)
          .fontSize(11)
          .fontColor(this.theme.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        this.openExternalUrl(url, title);
      })

      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.text_clipboard'))
          .fontSize(15)
          .fontColor([this.theme.accent])
      }
      .width(32)
      .height(32)
      .borderRadius(10)
      .backgroundColor(this.theme.accentSoft)
      .onClick(() => {
        this.copyPlainText(url, title);
      })
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 12, bottom: 12 })
  }
}





























































































