import { vpnExtension, VpnExtensionAbility, connection, socket } from '@kit.NetworkKit';
import type { Want } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import native from 'libentry.so';
import { localStamp } from '../common/AppLog';
import { commonEventManager } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { util } from '@kit.ArkTS';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { wifiManager } from '@kit.ConnectivityKit';
import { SSID_SUSPEND, findRule } from '../common/Ssid';
import { initIpcAuth, publishScopedEvent, verifyIpcParams } from '../common/IpcAuth';
import { appBundleName, appEvent, readTaskNotificationId, saveTaskNotificationId } from '../common/Xray';
import { resolveUdp } from '../common/UdpDns';
import { isFakeOrReservedIp, isIpAddressLiteral } from '../common/Latency';
import { markCoreHealthy, readCoreState, rollbackCoreOnError } from '../common/Updater';
import {
  RecoveryBudget, VpnChannelSample, emptyRecoveryBudget, isRecoveryBudgetExhausted,
  nextRecoveryAttempt, probeVpnChannel
} from '../common/VpnRecovery';
import { VpnMemoryPressureObserver } from '../common/VpnMemoryPressure';

interface ProbeResult {
  delayMs: number;
  failureKind: number;
  httpStatus: number;
}

interface XrayStats {
  up: number;
  down: number;
  tcpFlows: number;
  udpFlows: number;
  drops: number;
  packets: number;
}

interface XrayNative {
  version(): string;
  capabilities(): number;
  importProfile(requestJson: string): string;
  start(configJson: string, tunFd: number, mtu: number, logDir: string, geodataDir: string): void;
  restart(configJson: string, tunFd: number, mtu: number, logDir: string, geodataDir: string): void;
  stop(): void;
  isRunning(): boolean;
  warnings(): string;
  stats(): XrayStats;
  rebind(): number;
  trimMemory(): boolean;
}

interface TunnelStatus {
  state: string;
  message: string;
  startedAt: number;
  updatedAt: number;
  up: number;
  down: number;
  tcpFlows: number;
  udpFlows: number;
  restartCount: number;
  probeMs: number;
  pssKb?: number;
  cpuPercent?: number;
}

const XRAY_DIR: string = 'xray';
const TUN_ADDRESS_V4: string = '172.19.0.1';
// One MTU everywhere: the system VPN interface and the core's TUN ingress must
// agree, or the core may hand the driver packets the interface cannot carry.
const TUN_MTU: number = 1400;
const TUN_ADDRESS_V6: string = 'fdfe:dcba:9876::1';
const TUN_INTERFACE: string = 'vpn-tun';
const DNS_ANCHOR: string = '198.18.0.1';
const NOTIFICATION_ID: number = 1001;
// protectProcessNet() is what keeps the core's own outbound sockets outside the
// tunnel. Without it they are routed back into our TUN and the tunnel floods
// itself (280 MB up / 540 B down in the field test), so it stays on.
const USE_PROTECT_PROCESS_NET: boolean = true;

export default class XrayVpnAbility extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private timerId: number = -1;
  private logDir: string = '';
  private statusPath: string = '';
  private startedAt: number = 0;
  private tunFd: number = -1;
  private geodataDir: string = '';
  private restarts: number = 0;
  private lastProbeMs: number = 0;
  private recoveryBudget: RecoveryBudget = emptyRecoveryBudget();
  private recoveryPending: boolean = false;
  private ownedVpnNetId: number = -1;
  private foreignConsecutiveCount: number = 0;
  private foreignCheckInFlight: boolean = false;
  private memoryObserver: VpnMemoryPressureObserver | null = null;
  private lastMemorySoftReclaimAt: number = 0;
  private lastLiveViewAt: number = 0;
  private lastNeedTaskIdAt: number = 0;
  private lastLiveUp: number = -1;
  private lastLiveDown: number = -1;
  private lastStatusWriteAt: number = 0;
  private lastProbeDownBytes: number = -1;
  private debugLogEnabled: boolean = false;
  private rebindEnabled: boolean = true;
  private notifyEnabled: boolean = true;
  private taskNotificationId: number = -1;
  private taskIdSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private probeSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private probeProfilesSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private probeCancelSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private reloadSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private pssKb: number = 0;
  private cpuPercent: number = 0;
  private connSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private uiVisibilitySubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private uiVisible: boolean = true;
  private probeHostCache: Map<string, string[]> = new Map<string, string[]>();
  private probeHostCacheAt: Map<string, number> = new Map<string, number>();
  private nodeName: string = '';
  private configPath: string = '';
  private netAvailableHandler: ((data: connection.NetHandle) => void) | null = null;
  private netLostHandler: ((data: connection.NetHandle) => void) | null = null;
  private netConn: connection.NetConnection | null = null;
  private backgroundRunning: boolean = false;
  private notifyFailures: number = 0;
  private tickCount: number = 0;
  private lastUp: number = 0;
  private lastDown: number = 0;
  private lastStamp: number = 0;
  private ssidTimer: number = -1;
  private ssidHandler: (() => void) | null = null;
  private ssidSuspended: boolean = false;

  onCreate(want: Want): void {
    initIpcAuth(this.context);
    this.bindHandlers(want);
    this.watchTaskId();
    this.watchProbeRequests();
    this.watchProbeProfilesRequests();
    this.watchProbeCancelRequests();
    this.watchReloadRequests();
    this.watchConnectionRequests();
    this.watchUiVisibility();
    this.startMemoryObserver();
    if (native.isRunning()) {
      // The system relaunched the extension while the core is still live:
      // keep the running tunnel instead of starting a second one.
      this.appendLog('duplicate start ignored, core already running');
      this.writeStatus('running', '已连接');
      this.startTickLoop();
      return;
    }
    // Let the ability lifecycle finish first; startup does real I/O.
    setTimeout(() => {
      this.bootTunnel().catch((error: BusinessError) => {
        this.writeStatus('error', '启动失败: ' + JSON.stringify(error));
      });
    }, 0);
  }

  onDestroy(): void {
    this.appendLog('extension destroyed, tunnel gone');
    this.shutdown('destroyed');
  }

  private bindHandlers(want: Want): void {
    this.startedAt = Date.now();
    const params: Record<string, Object> = want.parameters ?? {};
    const configPath: string = params['configPath'] as string ?? '';
    this.configPath = configPath;
    const dir: string = this.context.filesDir;
    this.logDir = dir + '/' + XRAY_DIR;
    this.statusPath = this.logDir + '/status.json';
    this.rebindEnabled = params['rebindOnNetChange'] as boolean ?? true;
    this.notifyEnabled = params['notify'] as boolean ?? true;
    this.taskNotificationId = params['taskNotificationId'] as number ?? -1;
    if (this.taskNotificationId < 0) {
      this.taskNotificationId = readTaskNotificationId(this.context);
    } else {
      saveTaskNotificationId(this.context, this.taskNotificationId);
    }
    this.nodeName = params['nodeName'] as string ?? '';
    this.geodataDir = params['geodataDir'] as string ?? '';
  }

  // Read config.json on demand instead of pinning the full JSON string in heap
  // memory for the lifetime of the VPN extension.
  private readConfigText(): string {
    const path: string = this.configPath.length > 0 ? this.configPath : (this.logDir + '/config.json');
    if (path.length === 0) {
      return '';
    }
    try {
      if (fs.accessSync(path)) {
        return fs.readTextSync(path);
      }
    } catch (error) {
      this.appendLog('read config failed: ' + JSON.stringify(error));
    }
    return '';
  }

  // SSID suspension lives in the extension, the way sing-box does it: the
  // extension stays alive and pauses the core, so leaving the Wi-Fi can resume
  // without needing the UI (whose timers freeze in the background).
  private startSsidWatch(): void {
    if (this.ssidTimer !== -1) {
      return;
    }
    const handler = (): void => {
      this.checkSsid().catch((): void => {
      });
    };
    this.ssidHandler = handler;
    try {
      wifiManager.on('wifiConnectionChange', handler);
    } catch (error) {
    }
    this.ssidTimer = setInterval(handler, 5000);
  }

  private stopSsidWatch(): void {
    if (this.ssidHandler !== null) {
      try {
        wifiManager.off('wifiConnectionChange', this.ssidHandler);
      } catch (error) {
      }
    }
    this.ssidHandler = null;
    if (this.ssidTimer !== -1) {
      clearInterval(this.ssidTimer);
      this.ssidTimer = -1;
    }
  }

  private async checkSsid(): Promise<void> {
    let ssid: string = '';
    try {
      if (wifiManager.isWifiActive()) {
        const linked: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
        if (linked.connState === wifiManager.ConnState.CONNECTED) {
          ssid = (linked.ssid ?? '').replace(/^"|"$/g, '');
        }
      }
    } catch (error) {
      ssid = '';
    }
    const rule = findRule(this.context, ssid);
    const wantSuspend: boolean = rule !== null && rule.action === SSID_SUSPEND;
    if (wantSuspend && !this.ssidSuspended) {
      this.suspendForSsid(ssid);
    } else if (!wantSuspend && this.ssidSuspended) {
      this.resumeFromSsid();
    }
  }

  private suspendForSsid(ssid: string): void {
    this.ssidSuspended = true;
    try {
      native.stop();
    } catch (error) {
      this.appendLog('ssid suspend: native.stop failed');
    }
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    // Update live-view notification with yellow dot when suspended by trusted Wi-Fi.
    this.writeStatus('suspended', '已挂起（' + ssid + '）');
    this.publishStatusLiveView('suspended', '当前 Wi-Fi（' + ssid + '）已自动挂起');
    this.appendLog('ssid ' + ssid + ' suspended, core paused');
  }

  private resumeFromSsid(): void {
    this.ssidSuspended = false;
    const cfg: string = this.readConfigText();
    if (cfg.length === 0) {
      this.appendLog('ssid resume failed: config empty');
      this.writeStatus('error', '恢复失败');
      return;
    }
    try {
      native.start(cfg, this.tunFd, TUN_MTU, this.logDir, this.geodataDir);
    } catch (error) {
      this.appendLog('ssid resume failed: ' + ((error as BusinessError).message ?? ''));
      this.writeStatus('error', '恢复失败');
      return;
    }
    // A resumed core is a new session; the UI uses a fresh startedAt to
    // re-acquire the continuous task (and with it the live-view card).
    this.startedAt = Date.now();
    this.writeStatus('running', '已连接');
    this.startTickLoop();
    this.appendLog('left suspended ssid, core resumed');
  }

  private startTickLoop(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.timerId = setInterval(() => {
      this.tick();
    }, 1000);
  }

  private async bootTunnel(): Promise<void> {
    this.ensureDir();
    this.appendLog('native version ' + native.version() + ', capabilities ' + native.capabilities());
    let configText: string = this.readConfigText();
    if (configText.length === 0) {
      // The UI may still be flushing config.json when the extension starts.
      for (let attempt = 0; attempt < 10 && configText.length === 0; attempt++) {
        await new Promise<void>((resolve) => {
          setTimeout(() => {
            resolve();
          }, 200);
        });
        configText = this.readConfigText();
      }
    }
    if (configText.length === 0) {
      this.writeStatus('error', '配置文件为空');
      return;
    }
    let phase: string = '准备配置';
    try {
      this.debugLogEnabled = configText.indexOf('"loglevel":"debug"') >= 0 ||
        configText.indexOf('"loglevel": "debug"') >= 0;
      phase = '创建 VPN 接口';
      this.writeStatus('starting', '正在创建 VPN 接口');

      const conn: vpnExtension.VpnConnection = vpnExtension.createVpnConnection(this.context);
      this.conn = conn;

      // Resolve the outbound servers before the tunnel exists and keep their
      // addresses outside the default route: a second safety net next to
      // protectProcessNet(), and the same idea the Apple adapter uses.
      const excluded: vpnExtension.RouteInfo[] = await this.buildExcludedRoutes(configText);
      // Single-VPN mode: requesting a second vpnId put us behind the system's
      // multi-VPN chooser, where apps only use the tunnel when they opt in. The
      // single mode owns the default route for every app, like sing-box.
      const vpnId: string = '';
      const config: vpnExtension.VpnConfig = this.buildVpnConfig(this.dnsServers(configText), excluded, vpnId);
      let fd: number = -1;
      try {
        fd = await conn.create(config);
      } catch (error) {
        const err = error as BusinessError;
        if (err.code === 2203002) {
          this.writeStatus('error', '已有其他 VPN 正在运行，请先关闭');
        } else {
          this.writeStatus('error', '创建 VPN 接口失败: ' + err.code + ' ' + err.message);
        }
        this.appendLog('vpn create failed: ' + JSON.stringify(error));
        return;
      }
      this.appendLog('tun fd=' + fd);
      this.tunFd = fd;

      // Every socket the core opens must bypass the tunnel, otherwise the
      // outbound connection loops back into our own TUN device.
      phase = '保护进程网络';
      this.writeStatus('starting', '正在保护进程网络');
      if (USE_PROTECT_PROCESS_NET) {
        try {
          await conn.protectProcessNet();
          this.appendLog('protectProcessNet ok');
        } catch (error) {
          const err = error as BusinessError;
          this.appendLog('protectProcessNet failed: ' + (err.message ?? JSON.stringify(error)));
        }
      } else {
        this.appendLog('protectProcessNet skipped, using excluded routes');
      }

      phase = '启动 Xray 核心';
      this.writeStatus('starting', '正在启动 Xray 核心');
      try {
        native.start(configText, fd, TUN_MTU, this.logDir, this.geodataDir);
      } catch (error) {
        const err = error as BusinessError;
        const errMsg: string = err.message ?? JSON.stringify(error);
        const coreState = readCoreState(this.context);
        if (coreState.pendingCore.length > 0) {
          const rolled = rollbackCoreOnError(this.context, errMsg);
          this.appendLog('auto-rollback triggered: ' + rolled.lastRollbackReason);
          this.writeStatus('error', rolled.lastRollbackReason);
        } else {
          this.writeStatus('error', 'Xray 启动失败: ' + errMsg);
        }
        this.appendLog('native.start failed: ' + errMsg);
        await this.destroyConn();
        return;
      }
      configText = '';
      markCoreHealthy(this.context);

      const warnings: string = native.warnings();
      if (warnings.length > 0) {
        this.appendLog('config warnings: ' + warnings);
      }

      this.watchNetworks();
      this.writeStatus('running', '已连接');
      this.appendLog('tunnel running');
      this.mirrorCoreLog('start');
      this.tick();
      this.startTickLoop();
      // Reclaim startup config/geodata parsing peak buffers once the tunnel settles.
      setTimeout(() => {
        if (native.isRunning()) {
          this.reclaimMemory('post-boot');
        }
      }, 4000);
    } catch (error) {
      const err = error as BusinessError;
      const msg: string = phase + '异常: ' + (err.message ?? JSON.stringify(error));
      this.writeStatus('error', msg);
      this.appendLog('bootTunnel exception in ' + phase + ': ' + JSON.stringify(error));
      await this.destroyConn();
    }
  }

  // The core answers DNS at its own anchor only when the config declares a DNS
  // module; otherwise syscall DNS is simply proxied to a public resolver.
  private dnsServers(configText: string): string[] {
    try {
      const parsed: Record<string, Object> = JSON.parse(configText) as Record<string, Object>;
      const dns: Object | undefined = parsed['dns'];
      if (dns !== undefined && dns !== null) {
        return [DNS_ANCHOR];
      }
    } catch (error) {
    }
    return ['1.1.1.1', '8.8.8.8'];
  }

  // Outbound server addresses from the config, used for tunnel-exclusion routes.
  private serverHosts(configText: string): string[] {
    const hosts: string[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(configText) as Record<string, Object>;
      const outbounds: Object[] = (root['outbounds'] as Object[]) ?? [];
      if (outbounds.length === 0) {
        return hosts;
      }
      const outbound: Record<string, Object> = outbounds[0] as Record<string, Object>;
      const settings: Object | undefined = outbound['settings'] as Object | undefined;
      if (settings === undefined || settings === null) {
        return hosts;
      }
      const s: Record<string, Object> = settings as Record<string, Object>;
      const address: Object | undefined = s['address'];
      if (typeof address === 'string' && (address as string).length > 0) {
        hosts.push(address as string);
      }
      const vnext: Object[] | undefined = s['vnext'] as Object[] | undefined;
      if (vnext !== undefined) {
        for (const entry of vnext) {
          const a: Object | undefined = (entry as Record<string, Object>)['address'];
          if (typeof a === 'string' && (a as string).length > 0) {
            hosts.push(a as string);
          }
        }
      }
      const peers: Object[] | undefined = s['peers'] as Object[] | undefined;
      if (peers !== undefined) {
        for (const entry of peers) {
          const ep: Object | undefined = (entry as Record<string, Object>)['endpoint'];
          if (typeof ep === 'string' && (ep as string).length > 0) {
            hosts.push(stripPort(ep as string));
          }
        }
      }
    } catch (error) {
    }
    return hosts;
  }

  // Resolve the default server without letting a stuck DNS lookup delay the
  // tunnel: 1.5 s per name, and only for the one server the tunnel dials.
  private resolveHost(host: string, timeoutMs: number): Promise<string[]> {
    if (isIpAddress(host)) {
      return Promise.resolve([host]);
    }
    const lookup: Promise<string[]> = connection.getAddressesByName(host).then(
      (list: connection.NetAddress[]): string[] => {
        const out: string[] = [];
        for (const entry of list) {
          out.push(entry.address);
        }
        return out;
      },
      (error: BusinessError): string[] => {
        this.appendLog('resolve ' + host + ' failed: ' + JSON.stringify(error));
        return [];
      });
    const timeout: Promise<string[]> = new Promise<string[]>((resolve) => {
      setTimeout((): void => {
        resolve([]);
      }, timeoutMs);
    });
    return Promise.race([lookup, timeout]);
  }

  private async buildExcludedRoutes(configText: string): Promise<vpnExtension.RouteInfo[]> {
    const routes: vpnExtension.RouteInfo[] = [];
    const seen: Set<string> = new Set();
    const hosts: string[] = this.serverHosts(configText);
    const resolved: string[][] = await Promise.all(hosts.map(
      (host: string): Promise<string[]> => this.resolveHost(host, 1500)));
    for (const ips of resolved) {
      for (const ip of ips) {
        if (ip.length === 0 || seen.has(ip)) {
          continue;
        }
        seen.add(ip);
        const family: number = ip.includes(':') ? 2 : 1;
        const destination: connection.NetAddress = { address: ip, family: family };
        const gateway: connection.NetAddress = { address: '', family: family };
        const link: vpnExtension.LinkAddress = {
          address: destination,
          prefixLength: family === 2 ? 128 : 32
        };
        const route: vpnExtension.RouteInfo = {
          interface: '',
          destination: link,
          gateway: gateway,
          hasGateway: false,
          isDefaultRoute: false,
          isExcludedRoute: true
        };
        routes.push(route);
        this.appendLog('excluded route ' + ip);
      }
    }
    return routes;
  }

  private buildVpnConfig(dnsAddresses: string[], excluded: vpnExtension.RouteInfo[],
    vpnId: string): vpnExtension.VpnConfig {
    // Explicitly typed pieces: ArkTS rejects untyped nested literals.
    const v4: connection.NetAddress = { address: TUN_ADDRESS_V4, family: 1 };
    const v6: connection.NetAddress = { address: TUN_ADDRESS_V6, family: 2 };
    // Empty route interface: the system attaches the route to the VPN vNIC it
    // created. Naming it ('vpn-tun', as FlClash does) left the TUN receiving
    // almost no packets on this firmware, so the tunnel carried no traffic.
    const anyV4: connection.NetAddress = { address: '0.0.0.0', family: 1 };
    const anyV6: connection.NetAddress = { address: '::', family: 2 };
    const gatewayV4: connection.NetAddress = { address: '0.0.0.0', family: 1 };
    const gatewayV6: connection.NetAddress = { address: '::', family: 2 };
    const localV4: vpnExtension.LinkAddress = { address: v4, prefixLength: 30 };
    const localV6: vpnExtension.LinkAddress = { address: v6, prefixLength: 126 };
    const defaultV4: vpnExtension.RouteInfo = {
      interface: TUN_INTERFACE,
      destination: { address: anyV4, prefixLength: 0 },
      gateway: gatewayV4,
      hasGateway: false,
      isDefaultRoute: true
    };
    const defaultV6: vpnExtension.RouteInfo = {
      interface: TUN_INTERFACE,
      destination: { address: anyV6, prefixLength: 0 },
      gateway: gatewayV6,
      hasGateway: false,
      isDefaultRoute: true
    };
    const routes: vpnExtension.RouteInfo[] = [defaultV4, defaultV6];
    for (const route of excluded) {
      routes.push(route);
    }
    const config: vpnExtension.VpnConfig = {
      addresses: [localV4, localV6],
      routes: routes,
      dnsAddresses: dnsAddresses,
      mtu: TUN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: true,
      isBlocking: false,
      isInternal: false
    };
    if (vpnId.length > 0) {
      config.vpnId = vpnId;
    }
    return config;
  }

  private startMemoryObserver(): void {
    if (this.memoryObserver !== null) {
      return;
    }
    const observer = new VpnMemoryPressureObserver(
      async (reason: string): Promise<void> => {
        this.reclaimMemory(reason);
      },
      (msg: string): void => {
        this.appendLog(msg);
      }
    );
    try {
      observer.start(this.context.getApplicationContext());
      this.memoryObserver = observer;
    } catch (error) {
      this.appendLog('memory observer start failed');
    }
  }

  private stopMemoryObserver(): void {
    const observer = this.memoryObserver;
    this.memoryObserver = null;
    if (observer !== null) {
      observer.stop();
    }
  }

  // Soft memory reclaim under OS memory pressure or RSS soft limit:
  // cancel in-flight speedtest probes, truncate verbose logs, and flush native
  // allocator thread caches back to the OS.
  private reclaimMemory(reason: string): void {
    this.appendLog('memory pressure reclaim (' + reason + '), pssKb=' + this.pssKb);
    try {
      native.cancelProbes();
    } catch (error) {
    }
    try {
      native.trimMemory();
    } catch (error) {
    }
    this.trimCoreLog(true);
  }

  private async checkForeignVpn(): Promise<void> {
    if (this.foreignCheckInFlight || this.conn === null || this.tunFd < 0) {
      return;
    }
    this.foreignCheckInFlight = true;
    try {
      const sample: VpnChannelSample = await probeVpnChannel(this.ownedVpnNetId, TUN_ADDRESS_V4, TUN_ADDRESS_V6);
      if (sample.state === 'owned' && sample.netId >= 0) {
        this.ownedVpnNetId = sample.netId;
        this.foreignConsecutiveCount = 0;
      } else if (sample.state === 'foreign' && this.ownedVpnNetId >= 0) {
        // Only act on foreign takeover if this firmware previously reported our
        // own VPN netId and two consecutive probes confirm another VPN replaced it.
        this.foreignConsecutiveCount++;
        if (this.foreignConsecutiveCount >= 2) {
          this.appendLog('confirmed foreign VPN takeover (previous netId=' + this.ownedVpnNetId + '), stopping core');
          this.shutdown('系统 VPN 已被其他应用接管');
        }
      } else {
        this.foreignConsecutiveCount = 0;
      }
    } finally {
      this.foreignCheckInFlight = false;
    }
  }

  private async attemptBoundedRestart(): Promise<void> {
    if (this.recoveryPending) {
      return;
    }
    const now: number = Date.now();
    if (isRecoveryBudgetExhausted(this.recoveryBudget, now)) {
      this.writeStatus('error', '120 秒内核心已重启 3 次，已停止自动重启');
      return;
    }
    const nextBudget: RecoveryBudget | null = nextRecoveryAttempt(this.recoveryBudget, now);
    if (nextBudget === null) {
      return;
    }
    this.recoveryPending = true;
    try {
      const sample: VpnChannelSample = await probeVpnChannel(this.ownedVpnNetId, TUN_ADDRESS_V4, TUN_ADDRESS_V6);
      if (sample.state === 'foreign') {
        this.appendLog('core exit with foreign VPN active, stopping without retry');
        this.shutdown('系统 VPN 已被其他应用接管');
        return;
      }
      const conn = this.conn;
      if (conn === null || this.tunFd < 0) {
        this.writeStatus('error', '连接对象已释放');
        return;
      }
      this.recoveryBudget = nextBudget;
      this.restarts++;
      this.appendLog('core not running, bounded restart attempt ' + nextBudget.attempts + '/3 (total ' + this.restarts + ')');
      const cfg: string = this.readConfigText();
      if (cfg.length === 0) {
        this.writeStatus('error', '配置文件为空');
        return;
      }
      try {
        native.restart(cfg, this.tunFd, TUN_MTU, this.logDir, this.geodataDir);
        this.writeStatus('running', '已恢复连接');
      } catch (error) {
        this.appendLog('restart failed: ' + ((error as BusinessError).message ?? JSON.stringify(error)));
        if (isRecoveryBudgetExhausted(this.recoveryBudget, Date.now())) {
          this.writeStatus('error', '核心反复退出，已停止自动重启');
        }
      }
    } finally {
      this.recoveryPending = false;
    }
  }

  // Bounded crash supervision, foreign-VPN detection, and throttled live-view updates.
  private tick(): void {
    if (!native.isRunning()) {
      this.attemptBoundedRestart().catch((): void => {
      });
      return;
    }
    const stats: XrayStats = native.stats();
    const now: number = Date.now();
    const elapsed: number = this.lastStamp === 0 ? 0 : (now - this.lastStamp) / 1000;
    let upSpeed: number = 0;
    let downSpeed: number = 0;
    const trafficActive: boolean = stats.up !== this.lastUp || stats.down !== this.lastDown;
    if (elapsed > 0) {
      upSpeed = Math.max(0, (stats.up - this.lastUp) / elapsed);
      downSpeed = Math.max(0, (stats.down - this.lastDown) / elapsed);
    }
    this.lastUp = stats.up;
    this.lastDown = stats.down;
    this.lastStamp = now;
    if (this.uiVisible) {
      if (trafficActive || this.tickCount % 5 === 0) {
        this.publishTraffic(stats, upSpeed, downSpeed);
      }
      if (this.tickCount % 10 === 0) {
        this.sampleUsage();
      }
    } else if (this.tickCount % 30 === 0) {
      // In background/lockscreen keep periodic RSS soft-limit check active to prevent OOM kill.
      this.sampleUsage();
    }
    // Always keep status.json heartbeat fresh even in background (4 s cadence when UI is hidden,
    // 2-3 s in foreground), otherwise keepalive watchdogs and tunnelUp() mistake it for dead.
    const statusInterval: number = this.uiVisible ? (trafficActive ? 2000 : 3000) : 4000;
    if (this.lastStatusWriteAt === 0 || now - this.lastStatusWriteAt >= statusInterval) {
      this.lastStatusWriteAt = now;
      this.writeStatus('running', '已连接', stats);
    }
    if (this.notifyEnabled) {
      this.publishNotification(stats, downSpeed, upSpeed, now);
    }
    if (this.tickCount % 15 === 0 && this.tickCount > 0) {
      this.checkForeignVpn().catch((): void => {
      });
    }
    // Probe liveness ONLY while foreground UI is visible and downlink is idle.
    if (this.uiVisible && this.tickCount % 60 === 0 && this.tickCount > 0) {
      const curDown: number = Math.floor(stats.down);
      if (this.lastProbeDownBytes === curDown) {
        this.probeLiveness();
      }
      this.lastProbeDownBytes = curDown;
    }
    this.tickCount++;
    if (this.tickCount % 120 === 0) {
      this.appendLog('stats packets=' + stats.packets + ' up=' + stats.up + ' down=' + stats.down +
        ' tcp=' + stats.tcpFlows + ' udp=' + stats.udpFlows + ' drops=' + stats.drops +
        ' pss=' + Math.round(this.pssKb / 1024) + 'MB');
      this.mirrorCoreLog('stats');
    }
    if (this.debugLogEnabled && this.tickCount % 30 === 0) {
      this.mirrorAccessLog();
    }
    if (this.tickCount % 30 === 0 && this.tickCount > 0) {
      try {
        native.trimMemory();
      } catch (error) {
      }
    }
    if (this.tickCount % 120 === 0) {
      this.trimCoreLog(false);
    }
  }

  // Sampled every 10 s: reading smaps_rollup is not free, and the numbers only
  // need to be roughly current. Enforces a 32 MB soft limit reclaim.
  private sampleUsage(): void {
    try {
      this.pssKb = Number(hidebug.getPss());
      this.cpuPercent = hidebug.getCpuUsage();
      const now: number = Date.now();
      if (this.pssKb > 32768 && now - this.lastMemorySoftReclaimAt > 60000) {
        this.lastMemorySoftReclaimAt = now;
        this.reclaimMemory('soft-limit-' + Math.round(this.pssKb / 1024) + 'MB');
      }
    } catch (error) {
    }
  }

  private writeStatus(state: string, message: string, stats?: XrayStats): void {
    if (this.statusPath.length === 0) {
      return;
    }
    const status: TunnelStatus = {
      state: state,
      message: message,
      startedAt: this.startedAt,
      updatedAt: Date.now(),
      up: stats === undefined ? 0 : stats.up,
      down: stats === undefined ? 0 : stats.down,
      tcpFlows: stats === undefined ? 0 : stats.tcpFlows,
      udpFlows: stats === undefined ? 0 : stats.udpFlows,
      restartCount: this.restarts,
      probeMs: this.lastProbeMs,
      pssKb: this.pssKb,
      cpuPercent: this.cpuPercent
    };
    try {
      const file = fs.openSync(this.statusPath,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(status));
      fs.closeSync(file);
    } catch (error) {
      this.appendLog('write status failed: ' + JSON.stringify(error));
    }
    if (state === 'error' && this.notifyEnabled) {
      this.publishStatusLiveView('error', message.length > 0 ? message : '无法连接');
    }
  }


  // Android foreground-service equivalent: a continuous DATA_TRANSFER task
  // keeps the app process (and with it the VPN extension) alive in background.
  private async startKeepAlive(): Promise<void> {
    if (this.backgroundRunning) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: appBundleName(this.context),
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      const taskInfo: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(this.context, request);
      this.taskNotificationId = taskInfo.notificationId;
      this.backgroundRunning = true;
      this.appendLog('continuous task started, notification=' + this.taskNotificationId);
    } catch (error) {
      const err = error as BusinessError;
      this.appendLog('continuous task failed: ' + (err.message ?? JSON.stringify(error)));
    }
  }

  private stopKeepAlive(): void {
    if (!this.backgroundRunning) {
      return;
    }
    this.backgroundRunning = false;
    backgroundTaskManager.stopBackgroundRunning(this.context).catch((error: BusinessError) => {
      this.appendLog('stop continuous task failed: ' + (error.message ?? 'unknown'));
    });
  }

  // Push the counters to the UI process (sing-box streams the same data over
  // the Clash API /traffic endpoint). The UI subscribes instead of polling the
  // status file every second.
  private publishTraffic(stats: XrayStats, upSpeed: number, downSpeed: number): void {
    const params: Record<string, Object> = {
      'up': Math.floor(stats.up),
      'down': Math.floor(stats.down),
      'upSpeed': Math.floor(upSpeed),
      'downSpeed': Math.floor(downSpeed),
      'tcp': stats.tcpFlows,
      'udp': stats.udpFlows,
      'startedAt': this.startedAt,
      'state': 'running'
    };
    publishScopedEvent(appEvent('TRAFFIC', this.context), params, this.context);
  }


  private watchNetworks(): void {
    if (!this.rebindEnabled) {
      return;
    }
    this.netAvailableHandler = (data: connection.NetHandle) => {
      this.appendLog('network available, rebinding carriers');
      try {
        const started: number = Date.now();
        const accepted: number = native.rebind();
        this.appendLog('rebind accepted ' + accepted + ' in ' + (Date.now() - started) + 'ms');
      } catch (error) {
        this.appendLog('rebind failed: ' + JSON.stringify(error));
      }
    };
    this.netLostHandler = (data: connection.NetHandle) => {
      this.appendLog('network lost, waiting for a usable path');
    };
    try {
      const netConn: connection.NetConnection = connection.createNetConnection();
      netConn.register((error: BusinessError) => {
        if (error) {
          this.appendLog('netconnection register failed: ' + JSON.stringify(error));
        }
      });
      netConn.on('netAvailable', this.netAvailableHandler);
      netConn.on('netLost', this.netLostHandler);
      this.netConn = netConn;
    } catch (error) {
      this.appendLog('network observer failed: ' + JSON.stringify(error));
    }
  }

  private unwatchNetworks(): void {
    const netConn = this.netConn;
    this.netConn = null;
    if (netConn !== null) {
      try {
        netConn.unregister((error: BusinessError) => {
        });
      } catch (error) {
      }
    }
    this.netAvailableHandler = null;
    this.netLostHandler = null;
  }

  private shutdown(reason: string): void {
    this.stopSsidWatch();
    this.stopMemoryObserver();
    if (this.taskNotificationId >= 0) {
      notificationManager.cancel(this.taskNotificationId).catch(() => {
      });
    }
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.unwatchNetworks();
    this.stopKeepAlive();
    this.stopTaskIdWatch();
    this.stopProbeWatch();
    this.stopReloadWatch();
    this.stopConnectionWatch();
    this.stopUiVisibilityWatch();
    try {
      native.stop();
    } catch (error) {
      this.appendLog('native.stop failed: ' + JSON.stringify(error));
    }
    this.destroyConn();
    this.ownedVpnNetId = -1;
    this.writeStatus('stopped', reason);
    this.appendLog('tunnel stopped: ' + reason);
  }

  private async watchUiVisibility(): Promise<void> {
    if (this.uiVisibilitySubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('UI_VISIBILITY', this.context)]
      });
      commonEventManager.subscribe(sub, (_error, data) => {
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        const v: Object | undefined = params['visible'];
        const visible: boolean = v === 1 || v === true || v === '1';
        const changed: boolean = this.uiVisible !== visible;
        this.uiVisible = visible;
        if (visible && changed && native.isRunning()) {
          // Immediately refresh status.json & traffic counters when UI returns to foreground.
          const stats: XrayStats = native.stats();
          this.sampleUsage();
          this.lastStatusWriteAt = Date.now();
          this.writeStatus('running', '已连接', stats);
          this.publishTraffic(stats, 0, 0);
        }
      });
      this.uiVisibilitySubscriber = sub;
    } catch (error) {
    }
  }

  private stopUiVisibilityWatch(): void {
    const sub = this.uiVisibilitySubscriber;
    this.uiVisibilitySubscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  private stopTaskIdWatch(): void {
    const sub = this.taskIdSubscriber;
    this.taskIdSubscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  private async destroyConn(): Promise<void> {
    const conn = this.conn;
    this.conn = null;
    if (conn !== null) {
      try {
        await conn.destroy();
      } catch (error) {
        this.appendLog('vpn destroy failed: ' + JSON.stringify(error));
      }
    }
  }

  // The UI re-acquires the continuous task when the user swipes its
  // notification away; it then pushes the new notification id here so the live
  // view keeps updating the right card.
  private async watchTaskId(): Promise<void> {
    if (this.taskIdSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('TASK_ID', this.context)]
      });
      commonEventManager.subscribe(sub, (_error, data) => {
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        const id: number = params['taskNotificationId'] as number;
        if (id !== undefined && id !== null && id >= 0) {
          const prevId: number = this.taskNotificationId;
          if (prevId >= 0 && prevId !== id) {
            // Cancel the previous live-view notification so two notifications
            // can never coexist in the notification shade.
            notificationManager.cancel(prevId).catch(() => {
            });
          }
          this.taskNotificationId = id;
          saveTaskNotificationId(this.context, id);
          this.lastLiveViewAt = 0;
          this.appendLog('live view moved to notification ' + id);
          if (native.isRunning() && !this.ssidSuspended) {
            this.publishStatusLiveView('running', '↓ 0 B/s  ↑ 0 B/s');
          }
        }
      });
      this.taskIdSubscriber = sub;
    } catch (error) {
      this.appendLog('task id watch failed: ' + JSON.stringify(error));
    }
  }

  private ensureDir(): void {
    try {
      if (!fs.accessSync(this.logDir)) {
        fs.mkdirSync(this.logDir, true);
      }
    } catch (error) {
      this.appendLog('mkdir failed: ' + JSON.stringify(error));
    }
  }

  // Throttled single live-view traffic notification:
  //   - When bytes changed: refresh at most once every 2000 ms.
  //   - When idle (e.g. screen locked): refresh every 10000 ms so HarmonyOS
  //     DATA_TRANSFER live-view watchdog never expires the lockscreen card.
  private publishNotification(stats: XrayStats, downSpeed: number, upSpeed: number, now: number): void {
    if (this.taskNotificationId < 0) {
      const recovered: number = readTaskNotificationId(this.context);
      if (recovered >= 0) {
        this.taskNotificationId = recovered;
      } else {
        this.requestTaskNotification(now);
        return;
      }
    }
    const upBytes: number = Math.floor(stats.up);
    const downBytes: number = Math.floor(stats.down);
    const trafficChanged: boolean = upBytes !== this.lastLiveUp || downBytes !== this.lastLiveDown;
    const minInterval: number = trafficChanged ? 2000 : 10000;
    if (this.lastLiveViewAt > 0 && now - this.lastLiveViewAt < minInterval) {
      return;
    }
    this.lastLiveViewAt = now;
    this.lastLiveUp = upBytes;
    this.lastLiveDown = downBytes;
    this.publishLiveView(stats, downSpeed, upSpeed);
  }

  private requestTaskNotification(now: number): void {
    if (now - this.lastNeedTaskIdAt < 15000) {
      return;
    }
    this.lastNeedTaskIdAt = now;
    publishScopedEvent(appEvent('NEED_TASK_ID', this.context), {}, this.context);
  }

  // Minimal single live-view traffic card with status dot:
  //   running   -> 🟢 <node>
  //   suspended -> 🟡 <node> · 已挂起
  //   error     -> 🔴 <node> · 无法连接
  private publishLiveView(stats: XrayStats, downSpeed: number, upSpeed: number): void {
    const liveLine: string = '↓ ' + formatBytes(downSpeed) + '/s  ↑ ' + formatBytes(upSpeed) + '/s';
    this.publishStatusLiveView('running', liveLine);
  }

  private publishStatusLiveView(state: string, detailLine: string): void {
    if (this.taskNotificationId < 0) {
      const recovered: number = readTaskNotificationId(this.context);
      if (recovered >= 0) {
        this.taskNotificationId = recovered;
      } else {
        return;
      }
    }
    try {
      const baseName: string = this.nodeName.length > 0 ? this.nodeName : 'way';
      let title: string = '🟢 ' + baseName;
      if (state === 'suspended') {
        title = '🟡 ' + baseName + ' · 已挂起';
      } else if (state === 'error') {
        title = '🔴 ' + baseName + ' · 无法连接';
      }
      const data: Record<string, Object> = {};
      data['title'] = title;
      data['fileName'] = detailLine;
      const request: notificationManager.NotificationRequest = {
        id: this.taskNotificationId,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        isOngoing: true,
        isUnremovable: true,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title: title,
            text: detailLine
          }
        },
        template: {
          name: 'downloadTemplate',
          data: data
        }
      };
      notificationManager.publish(request).then(() => {
        this.notifyFailures = 0;
      }).catch((error: BusinessError) => {
        this.notifyFailures++;
        if (this.notifyFailures === 1 || this.tickCount % 30 === 0) {
          this.appendLog('live view update failed (' + error.code + ', streak=' + this.notifyFailures +
            '): ' + (error.message ?? 'unknown'));
        }
        // Only ask UI to re-acquire task id after consecutive failures, avoiding
        // churn from transient lockscreen rate limits.
        if (this.notifyFailures >= 3) {
          this.taskNotificationId = -1;
          saveTaskNotificationId(this.context, -1);
          this.requestTaskNotification(Date.now());
        }
      });
    } catch (error) {
      this.appendLog('live view error: ' + JSON.stringify(error));
    }
  }

  private clockStamp(): string {
    const date = new Date();
    const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
    return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
  }

  private formatDuration(startedAt: number): string {
    const elapsed: number = Math.max(0, Math.floor((Date.now() - startedAt) / 1000));
    const h: number = Math.floor(elapsed / 3600);
    const m: number = Math.floor((elapsed % 3600) / 60);
    const s: number = elapsed % 60;
    return h + ':' + (m < 10 ? '0' + m : '' + m) + ':' + (s < 10 ? '0' + s : '' + s);
  }

  // The node list measures a node's real delay through the core: the UI process
  // has no core handle (this extension owns it), so it publishes a PROBE request
  // here and this process answers with the FFI's per-outbound HTTP probe. The
  // probe is NAPI async work, so it never blocks this process's tick loop.
  private async watchProbeRequests(): Promise<void> {
    if (this.probeSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('PROBE', this.context)]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        const requestId: string = (params['requestId'] as string) ?? '';
        const tag: string = (params['tag'] as string) ?? '';
        const url: string = (params['url'] as string) ?? '';
        const timeoutMs: number = (params['timeoutMs'] as number) ?? 4000;
        this.runProbeRequest(requestId, tag, url, timeoutMs);
      });
      this.probeSubscriber = sub;
    } catch (error) {
      this.appendLog('probe watch failed: ' + JSON.stringify(error));
    }
  }

  private async runProbeRequest(requestId: string, tag: string, url: string,
    timeoutMs: number): Promise<void> {
    if (requestId.length === 0 || url.length === 0) {
      return;
    }
    let status: number = -1;
    let delayMs: number = 0;
    let failureKind: number = 0;
    let httpStatus: number = 0;
    let message: string = '';
    try {
      const raw: string = JSON.stringify(await native.probeOutbound(url, timeoutMs, tag) as Object);
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      status = (parsed['status'] as number) ?? -1;
      delayMs = (parsed['delayMs'] as number) ?? 0;
      failureKind = (parsed['failureKind'] as number) ?? 0;
      httpStatus = (parsed['httpStatus'] as number) ?? 0;
      message = (parsed['message'] as string) ?? '';
    } catch (error) {
      message = 'probe exception';
    }
    const params: Record<string, Object> = {
      'requestId': requestId,
      'status': status,
      'delayMs': delayMs,
      'failureKind': failureKind,
      'httpStatus': httpStatus,
      'message': message
    };
    publishScopedEvent(appEvent('PROBE_RESULT', this.context), params, this.context);
  }

  // v2rayNG-style speed test: the UI sends a TUN-less config plus the probe
  // list; this process builds a temporary core, probes each tagged outbound,
  // frees it, and returns the results. The live core/tunnel are untouched.
  private async watchProbeProfilesRequests(): Promise<void> {
    if (this.probeProfilesSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('PROBE_PROFILES', this.context)]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) return;
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) return;
        const requestId: string = (params['requestId'] as string) ?? '';
        const reqFile: string = (params['reqFile'] as string) ?? '';
        const resFile: string = (params['resFile'] as string) ?? '';
        const config: string = (params['config'] as string) ?? '';
        const probesRaw: string = (params['probes'] as string) ?? '[]';
        const geodataDir: string = (params['geodataDir'] as string) ?? '';
        this.runProbeProfiles(requestId, config, probesRaw, geodataDir, reqFile, resFile);
      });
      this.probeProfilesSubscriber = sub;
    } catch (error) {
      this.appendLog('profiles probe watch failed: ' + JSON.stringify(error));
    }
  }

  // Extract every outbound server hostname from a temporary probe config and
  // resolve them via plain UDP DNS inside this protectProcessNet() extension
  // process, injecting clean physical IPv4 addresses into `dns.hosts`.
  // Without this, xray-core-rs's bootstrap resolver falls back to system
  // getaddrinfo(), which returns FakeIP 198.19.x.x while VPN is active and
  // makes every protected outbound socket time out in a black hole.
  private async injectProtectedProbeHosts(configText: string): Promise<string> {
    try {
      const root: Record<string, Object> = JSON.parse(configText) as Record<string, Object>;
      const outbounds: Object[] = (root['outbounds'] as Object[]) ?? [];
      const domains: string[] = [];
      const addHost = (candidate: Object | undefined): void => {
        if (typeof candidate !== 'string') return;
        const host: string = stripPort((candidate as string).trim());
        if (host.length === 0 || isIpAddressLiteral(host)) return;
        if (domains.indexOf(host) < 0) {
          domains.push(host);
        }
      };
      for (const item of outbounds) {
        const ob: Record<string, Object> = item as Record<string, Object>;
        const settings: Record<string, Object> | undefined = ob['settings'] as Record<string, Object> | undefined;
        if (settings === undefined || settings === null) continue;
        addHost(settings['address']);
        const vnext: Object[] | undefined = settings['vnext'] as Object[] | undefined;
        if (vnext !== undefined) {
          for (const v of vnext) {
            addHost((v as Record<string, Object>)['address']);
          }
        }
        const servers: Object[] | undefined = settings['servers'] as Object[] | undefined;
        if (servers !== undefined) {
          for (const s of servers) {
            addHost((s as Record<string, Object>)['address']);
          }
        }
        const peers: Object[] | undefined = settings['peers'] as Object[] | undefined;
        if (peers !== undefined) {
          for (const p of peers) {
            addHost((p as Record<string, Object>)['endpoint']);
          }
        }
      }
      if (domains.length === 0) {
        return configText;
      }
      const dnsObj: Record<string, Object> = (root['dns'] as Record<string, Object>) ?? {};
      const hostsObj: Record<string, string[]> = (dnsObj['hosts'] as Record<string, string[]>) ?? {};
      const nowMs: number = Date.now();
      const pending: string[] = [];
      for (const d of domains) {
        if (hostsObj[d] !== undefined && hostsObj[d].length > 0) {
          continue;
        }
        const cached: string[] | undefined = this.probeHostCache.get(d);
        const cachedAt: number = this.probeHostCacheAt.get(d) ?? 0;
        if (cached !== undefined && cached.length > 0 && nowMs - cachedAt < 30000) {
          hostsObj[d] = cached;
          continue;
        }
        pending.push(d);
      }
      if (pending.length > 0) {
        const lookups: Promise<void>[] = pending.map((domain: string): Promise<void> => {
          return resolveUdp(domain, 1200).then((ips: string[]) => {
            const clean: string[] = [];
            for (const ip of ips) {
              if (!isFakeOrReservedIp(ip) && clean.indexOf(ip) < 0) {
                clean.push(ip);
              }
            }
            if (clean.length > 0) {
              hostsObj[domain] = clean;
              this.probeHostCache.set(domain, clean);
              this.probeHostCacheAt.set(domain, Date.now());
            }
          }).catch((): void => {
          });
        });
        const all: Promise<void> = Promise.all(lookups).then((): void => {
        });
        const budget: Promise<void> = new Promise<void>((resolve) => {
          setTimeout(() => resolve(), 1800);
        });
        await Promise.race([all, budget]);
      }
      if (Object.keys(hostsObj).length > 0) {
        dnsObj['hosts'] = hostsObj as Object;
        root['dns'] = dnsObj;
        return JSON.stringify(root);
      }
    } catch (error) {
      this.appendLog('injectProtectedProbeHosts failed: ' + JSON.stringify(error));
    }
    return configText;
  }

  private async runProbeProfiles(requestId: string, config: string, probesRaw: string,
    geodataDir: string, reqFile: string = '', resFile: string = ''): Promise<void> {
    if (requestId.length === 0) return;
    let ok: boolean = false;
    let results: string = '[]';
    let errorMsg: string = '';
    try {
      let effectiveConfig: string = config;
      let probes: Object[] = [];
      let effectiveGeo: string = geodataDir;
      if (reqFile.length > 0 && fs.accessSync(reqFile)) {
        const reqText: string = fs.readTextSync(reqFile);
        const reqDoc: Record<string, Object> = JSON.parse(reqText) as Record<string, Object>;
        effectiveConfig = (reqDoc['config'] as string) ?? '';
        probes = (reqDoc['probes'] as Object[]) ?? [];
        effectiveGeo = (reqDoc['geodataDir'] as string) ?? '';
      } else {
        probes = JSON.parse(probesRaw) as Object[];
      }
      if (effectiveConfig.length === 0) {
        throw new Error('empty probe config');
      }
      effectiveConfig = await this.injectProtectedProbeHosts(effectiveConfig);
      results = JSON.stringify(await native.probeProfiles(effectiveConfig, probes, effectiveGeo) as Object);
      ok = true;
    } catch (error) {
      const err = error as BusinessError;
      errorMsg = typeof error === 'string' ? error : (err.message ?? JSON.stringify(error));
      this.appendLog('probeProfiles exception: ' + errorMsg);
    }
    let inlineResults: string = results;
    let writtenResFile: string = '';
    if (resFile.length > 0) {
      try {
        const f = fs.openSync(resFile, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(f.fd, results);
        fs.closeSync(f);
        writtenResFile = resFile;
        inlineResults = '';
      } catch (writeErr) {
      }
    }
    const params: Record<string, Object> = {
      'requestId': requestId,
      'ok': ok ? 1 : 0,
      'results': inlineResults,
      'resFile': writtenResFile,
      'error': errorMsg
    };
    publishScopedEvent(appEvent('PROBE_PROFILES_RESULT', this.context), params, this.context);
    try {
      native.trimMemory();
    } catch (error) {
    }
  }

  private stopProbeWatch(): void {
    const sub = this.probeSubscriber;
    this.probeSubscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
    const profilesSub = this.probeProfilesSubscriber;
    this.probeProfilesSubscriber = null;
    if (profilesSub !== null) {
      try {
        commonEventManager.unsubscribe(profilesSub);
      } catch (error) {
      }
    }
    const cancelSub = this.probeCancelSubscriber;
    this.probeCancelSubscriber = null;
    if (cancelSub !== null) {
      try {
        commonEventManager.unsubscribe(cancelSub);
      } catch (error) {
      }
    }
  }

  // The node list asks for this when another run starts or the page closes:
  // cancel the probes already in flight so their workers free up immediately.
  private async watchProbeCancelRequests(): Promise<void> {
    if (this.probeCancelSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('PROBE_CANCEL', this.context)]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        try {
          native.cancelProbes();
          this.appendLog('probes cancelled by ui');
        } catch (exception) {
          this.appendLog('probe cancel failed: ' + JSON.stringify(exception));
        }
      });
      this.probeCancelSubscriber = sub;
    } catch (error) {
      this.appendLog('probe cancel watch failed: ' + JSON.stringify(error));
    }
  }

  // The UI rebuilt config.json after a mode switch and asks for a routing-only
  // reload: read the file, hand its routing object to the core and answer so the
  // UI can fall back to a restart when the swap is refused.
  private async watchReloadRequests(): Promise<void> {
    if (this.reloadSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('RELOAD_ROUTING', this.context)]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        const requestId: string = (params['requestId'] as string) ?? '';
        this.appendLog('routing reload requested ' + requestId);
        this.runReloadRequest(requestId);
      });
      this.reloadSubscriber = sub;
    } catch (error) {
      this.appendLog('reload watch failed: ' + JSON.stringify(error));
    }
  }

  private async runReloadRequest(requestId: string): Promise<void> {
    let ok: boolean = false;
    let message: string = '';
    try {
      const path: string = this.configPath.length > 0 ? this.configPath : (this.logDir + '/config.json');
      const text: string = fs.readTextSync(path);
      const config: Record<string, Object> = JSON.parse(text) as Record<string, Object>;
      const routing: Record<string, Object> = config['routing'] as Record<string, Object>;
      if (routing === undefined || routing === null) {
        message = 'config has no routing section';
      } else {
        // The FFI expects exactly one top-level "routing" object, not the bare
        // routing body.
        const document: Record<string, Object> = { 'routing': routing };
        native.replaceRouting(JSON.stringify(document));
        ok = true;
        message = 'routing reloaded';
        this.appendLog('routing reloaded for live mode switch');
      }
    } catch (error) {
      const failure = error as BusinessError;
      message = failure.message === undefined ? JSON.stringify(error) : failure.message;
      this.appendLog('routing reload failed: ' + message);
    }
    const payload: Record<string, Object> = {
      'requestId': requestId,
      'ok': ok ? 1 : 0,
      'message': message
    };
    publishScopedEvent(appEvent('RELOAD_ROUTING_RESULT', this.context), payload, this.context);
  }

  // Live connection inventory: {op:'list'} returns the core snapshot JSON,
  // {op:'close', id} drops one connection. The UI polls this once a second.
  private async watchConnectionRequests(): Promise<void> {
    if (this.connSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [appEvent('CONNECTIONS', this.context)]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        const requestId: string = (params['requestId'] as string) ?? '';
        const op: string = (params['op'] as string) ?? 'list';
        if (op === 'close') {
          const id: number = Number(params['id'] ?? 0);
          this.runCloseConnection(requestId, id);
        } else if (op === 'latency') {
          const host: string = (params['host'] as string) ?? '';
          const port: number = Number(params['port'] ?? 0);
          const timeout: number = Number(params['timeout'] ?? 3000);
          this.runLatencyProbe(requestId, host, port, timeout);
        } else {
          this.runConnectionList(requestId);
        }
      });
      this.connSubscriber = sub;
    } catch (error) {
      this.appendLog('connection watch failed: ' + JSON.stringify(error));
    }
  }

  // Real network RTT to a node server. This process is protected
  // (protectProcessNet), so the TCP handshake leaves directly instead of being
  // routed back into our own tunnel; a completed handshake and an immediate RST
  // both land at ~1 RTT, which is what a latency number should be.
  private runLatencyProbe(requestId: string, host: string, port: number, timeoutMs: number): void {
    let tcp: socket.TCPSocket | null = null;
    try {
      tcp = socket.constructTCPSocketInstance();
    } catch (error) {
      this.publishLatency(requestId, -1);
      return;
    }
    const handle: socket.TCPSocket = tcp;
    const started: number = Date.now();
    let settled: boolean = false;
    const finish = (value: number): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      try {
        handle.close();
      } catch (error) {
      }
      this.publishLatency(requestId, value);
    };
    const timer: number = setTimeout(() => {
      finish(-1);
    }, timeoutMs);
    handle.on('connect', () => {
      finish(Date.now() - started);
    });
    handle.on('error', () => {
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
  }

  private publishLatency(requestId: string, ms: number): void {
    const params: Record<string, Object> = {
      'requestId': requestId,
      'ok': ms >= 0 ? 1 : 0,
      'json': '' + ms
    };
    publishScopedEvent(appEvent('CONNECTIONS_RESULT', this.context), params, this.context);
  }

  private runConnectionList(requestId: string): void {
    let ok: boolean = false;
    let payload: string = '';
    try {
      payload = native.connectionSnapshot();
      ok = true;
    } catch (error) {
      const failure = error as BusinessError;
      payload = failure.message === undefined ? 'snapshot failed' : failure.message;
      this.appendLog('connection snapshot failed: ' + payload);
    }
    const params: Record<string, Object> = {
      'requestId': requestId,
      'ok': ok ? 1 : 0,
      'json': payload
    };
    publishScopedEvent(appEvent('CONNECTIONS_RESULT', this.context), params, this.context);
  }

  private runCloseConnection(requestId: string, id: number): void {
    let ok: boolean = false;
    let payload: string = '';
    try {
      native.closeConnection(id);
      ok = true;
      payload = 'closed';
    } catch (error) {
      const failure = error as BusinessError;
      payload = failure.message === undefined ? 'close failed' : failure.message;
      this.appendLog('close connection failed: ' + payload);
    }
    const params: Record<string, Object> = {
      'requestId': requestId,
      'ok': ok ? 1 : 0,
      'json': payload
    };
    publishScopedEvent(appEvent('CONNECTIONS_RESULT', this.context), params, this.context);
  }

  private stopConnectionWatch(): void {
    const sub = this.connSubscriber;
    this.connSubscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  private stopReloadWatch(): void {
    const sub = this.reloadSubscriber;
    this.reloadSubscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  // Idle liveness probe: uses HTTPS 443 with globally cached TLS CA roots
  // (`CACHED_SYSTEM_TLS` in xray-rust) so port-80 filtering never causes false
  // reconnects and CA roots are never re-allocated on the heap.
  private async probeLiveness(): Promise<void> {
    try {
      const raw: string =
        JSON.stringify(await native.probeOutbound('https://www.gstatic.com/generate_204', 5000, '') as Object);
      const result: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const failureKind: number = (result['failureKind'] as number) ?? 1;
      if (failureKind !== 0) {
        this.appendLog('probe failed kind=' + failureKind);
        this.appendLog('rebind accepted ' + native.rebind());
      } else {
        this.lastProbeMs = (result['delayMs'] as number) ?? 0;
      }
    } catch (error) {
      this.appendLog('probe error: ' + JSON.stringify(error));
    }
  }

  private appendLog(line: string): void {
    if (this.logDir.length === 0) {
      return;
    }
    const entry: string = localStamp() + ' ' + line + '\n';
    try {
      if (!fs.accessSync(this.logDir)) {
        fs.mkdirSync(this.logDir, true);
      }
      const path: string = this.logDir + '/ability.log';
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, entry);
      fs.closeSync(file);
    } catch (error) {
    }
  }
  // Keep xray-error.log bounded: the core appends debug stats continuously.
  // Access log tail: the core writes it 0600 but the extension shares its uid,
  // so mirror the last routed lines into ability.log for diagnostics.
  private mirrorAccessLog(): void {
    try {
      const path: string = this.logDir + '/xray-access.log';
      if (!fs.accessSync(path)) {
        return;
      }
      const size: number = fs.statSync(path).size;
      if (size <= 0) {
        return;
      }
      const readLen: number = Math.min(size, 2048);
      const buffer: ArrayBuffer = new ArrayBuffer(readLen);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buffer, { offset: size - readLen, length: readLen });
      } finally {
        fs.closeSync(file);
      }
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      const picked: string[] = [];
      for (const line of text.split(/\r?\n/)) {
        if (line.indexOf('accepted') >= 0 && line.indexOf('outbound=') >= 0) {
          picked.push(line.substring(0, 160));
        }
      }
      if (picked.length === 0) {
        return;
      }
      this.appendLog('access: ' + picked.slice(-3).join(' | '));
    } catch (error) {
    }
  }

  private trimCoreLog(force: boolean = false): void {
    const limit: number = force ? 128 * 1024 : 512 * 1024;
    const names: string[] = ['xray-error.log', 'xray-access.log', 'ability.log'];
    for (const name of names) {
      try {
        const path: string = this.logDir + '/' + name;
        if (!fs.accessSync(path)) {
          continue;
        }
        if (fs.statSync(path).size > limit) {
          fs.truncateSync(path, 0);
          if (name !== 'ability.log') {
            this.appendLog('core log truncated: ' + name + (force ? ' (pressure)' : ''));
          }
        }
      } catch (error) {
      }
    }
  }

  // Tail-read only: loading the whole file threw OutOfMemoryError (234 MB
  // allocation) and the runtime killed the VPN process.
  private mirrorCoreLog(tag: string): void {
    try {
      const path: string = this.logDir + '/xray-error.log';
      if (!fs.accessSync(path)) {
        return;
      }
      const size: number = fs.statSync(path).size;
      if (size <= 0) {
        return;
      }
      const readLen: number = Math.min(size, 4096);
      const buffer: ArrayBuffer = new ArrayBuffer(readLen);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buffer, { offset: size - readLen, length: readLen });
      } finally {
        fs.closeSync(file);
      }
      const text: string = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
      const picked: string[] = [];
      for (const line of text.split(/\r?\n/)) {
        if (line.indexOf(' error ') >= 0 || line.indexOf('panic') >= 0 || line.indexOf('ERROR') >= 0 ||
          line.indexOf('routeDecision') >= 0) {
          picked.push(line);
        }
      }
      if (picked.length === 0) {
        return;
      }
      const tail: string = picked.slice(-3).join(' | ');
      this.appendLog('core[' + tag + ']: ' + (tail.length > 500 ? tail.substring(tail.length - 500) : tail));
    } catch (error) {
    }
  }
}
function formatBytes(value: number): string {
  if (value < 1024) {
    return value.toFixed(0) + ' B';
  }
  if (value < 1024 * 1024) {
    return (value / 1024).toFixed(1) + ' KB';
  }
  if (value < 1024 * 1024 * 1024) {
    return (value / (1024 * 1024)).toFixed(1) + ' MB';
  }
  return (value / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function isIpAddress(value: string): boolean {
  if (value.includes(':')) {
    return true;
  }
  const parts: string[] = value.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    const number: number = Number(part);
    if (!Number.isInteger(number) || number < 0 || number > 255) {
      return false;
    }
  }
  return true;
}

function stripPort(endpoint: string): string {
  if (endpoint.startsWith('[')) {
    const end: number = endpoint.indexOf(']');
    return end > 0 ? endpoint.substring(1, end) : endpoint;
  }
  const index: number = endpoint.lastIndexOf(':');
  if (index < 0) {
    return endpoint;
  }
  const port: string = endpoint.substring(index + 1);
  if (port.length > 0 && Number.isInteger(Number(port))) {
    return endpoint.substring(0, index);
  }
  return endpoint;
}







































