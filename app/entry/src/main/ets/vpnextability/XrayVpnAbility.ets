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
// Node-list delay test crosses processes: the UI cannot see the core handle (the
// extension runs in its own process), so it asks this process over common events.
const PROBE_REQUEST_EVENT: string = 'com.way.app.PROBE';
// Cancels the probes already in flight (ABI 1.15), sent by the node list when a
// new run starts or the page closes.
const PROBE_CANCEL_EVENT: string = 'com.way.app.PROBE_CANCEL';
// Live mode switch: the UI rewrites config.json and asks this process to swap
// the routing table, so GFW / 绕过大陆 / 全局 apply without dropping the tunnel.
const RELOAD_REQUEST_EVENT: string = 'com.way.app.RELOAD_ROUTING';
const RELOAD_RESULT_EVENT: string = 'com.way.app.RELOAD_ROUTING_RESULT';
// Live connection inventory (list + close) for the 连接 page.
const CONN_REQUEST_EVENT: string = 'com.way.app.CONNECTIONS';
const CONN_RESULT_EVENT: string = 'com.way.app.CONNECTIONS_RESULT';
const PROBE_RESULT_EVENT: string = 'com.way.app.PROBE_RESULT';

export default class XrayVpnAbility extends VpnExtensionAbility {
  private conn: vpnExtension.VpnConnection | null = null;
  private timerId: number = -1;
  private configText: string = '';
  private logDir: string = '';
  private statusPath: string = '';
  private startedAt: number = 0;
  private tunFd: number = -1;
  private geodataDir: string = '';
  private restarts: number = 0;
  private lastProbeMs: number = 0;
  private failedRestarts: number = 0;
  private rebindEnabled: boolean = true;
  private notifyEnabled: boolean = true;
  private taskNotificationId: number = -1;
  private taskIdSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private probeSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private probeCancelSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private reloadSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  private pssKb: number = 0;
  private cpuPercent: number = 0;
  private connSubscriber: commonEventManager.CommonEventSubscriber | null = null;
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

  onCreate(want: Want): void {
    this.bindHandlers(want);
    this.watchProbeRequests();
    this.watchProbeCancelRequests();
    this.watchReloadRequests();
    this.watchConnectionRequests();
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
    this.nodeName = params['nodeName'] as string ?? '';
    this.geodataDir = params['geodataDir'] as string ?? '';
    this.configText = '';
    if (configPath.length > 0) {
      try {
        this.configText = fs.readTextSync(configPath);
      } catch (error) {
        this.appendLog('read config failed: ' + JSON.stringify(error));
      }
    }
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
    if (this.configText.length === 0) {
      // The UI may still be flushing config.json when the extension starts.
      for (let attempt = 0; attempt < 10 && this.configText.length === 0; attempt++) {
        await new Promise<void>((resolve) => {
          setTimeout(() => {
            resolve();
          }, 200);
        });
        try {
          if (this.configPath.length > 0 && fs.accessSync(this.configPath)) {
            this.configText = fs.readTextSync(this.configPath);
          }
        } catch (error) {
        }
      }
    }
    if (this.configText.length === 0) {
      this.writeStatus('error', '配置文件为空');
      return;
    }
    this.writeStatus('starting', '正在创建 VPN 接口');

    const conn: vpnExtension.VpnConnection = vpnExtension.createVpnConnection(this.context);
    this.conn = conn;

    // Resolve the outbound servers before the tunnel exists and keep their
    // addresses outside the default route: a second safety net next to
    // protectProcessNet(), and the same idea the Apple adapter uses.
    const excluded: vpnExtension.RouteInfo[] = await this.buildExcludedRoutes();
    // Single-VPN mode: requesting a second vpnId put us behind the system's
    // multi-VPN chooser, where apps only use the tunnel when they opt in. The
    // single mode owns the default route for every app, like sing-box.
    const vpnId: string = '';
    const config: vpnExtension.VpnConfig = this.buildVpnConfig(this.dnsServers(), excluded, vpnId);
    let fd: number = -1;
    try {
      fd = await conn.create(config);
    } catch (error) {
      const err = error as BusinessError;
      this.writeStatus('error', '创建 VPN 接口失败: ' + err.code + ' ' + err.message);
      this.appendLog('vpn create failed: ' + JSON.stringify(error));
      return;
    }
    this.appendLog('tun fd=' + fd);
    this.tunFd = fd;

    // Every socket the core opens must bypass the tunnel, otherwise the
    // outbound connection loops back into our own TUN device.
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

    try {
      native.start(this.configText, fd, TUN_MTU, this.logDir, this.geodataDir);
    } catch (error) {
      const err = error as BusinessError;
      this.writeStatus('error', 'Xray 启动失败: ' + err.message);
      this.appendLog('native.start failed: ' + ((error as BusinessError).message ?? JSON.stringify(error)));
      await this.destroyConn();
      return;
    }

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
  }

  // The core answers DNS at its own anchor only when the config declares a DNS
  // module; otherwise syscall DNS is simply proxied to a public resolver.
  private dnsServers(): string[] {
    try {
      const parsed: Record<string, Object> = JSON.parse(this.configText) as Record<string, Object>;
      const dns: Object | undefined = parsed['dns'];
      if (dns !== undefined && dns !== null) {
        return [DNS_ANCHOR];
      }
    } catch (error) {
    }
    return ['1.1.1.1', '8.8.8.8'];
  }

  // Outbound server addresses from the config, used for tunnel-exclusion routes.
  // Only the default outbound's server is dialled by the tunnel itself. The
  // other saved nodes are reached only by the probe API from this protected
  // process, so excluding their hosts would cost one DNS lookup each (seconds
  // when a name does not resolve) without protecting anything.
  private serverHosts(): string[] {
    const hosts: string[] = [];
    try {
      const root: Record<string, Object> = JSON.parse(this.configText) as Record<string, Object>;
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

  private async buildExcludedRoutes(): Promise<vpnExtension.RouteInfo[]> {
    const routes: vpnExtension.RouteInfo[] = [];
    const seen: Set<string> = new Set();
    const hosts: string[] = this.serverHosts();
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

  // FlClash-style supervision: keep the core alive, react to network changes,
  // and republish the persistent notification with live traffic.
  private tick(): void {
    if (!native.isRunning()) {
      if (this.failedRestarts >= 3) {
        this.writeStatus('error', '核心反复退出，已停止自动重启');
        return;
      }
      this.restarts++;
      this.appendLog('core not running, restart attempt ' + this.restarts);
      try {
        const conn = this.conn;
        if (conn === null || this.tunFd < 0) {
          this.writeStatus('error', '连接对象已释放');
          return;
        }
        native.restart(this.configText, this.tunFd, TUN_MTU, this.logDir, this.geodataDir);
        this.failedRestarts = 0;
      } catch (error) {
        this.failedRestarts++;
        this.appendLog('restart failed: ' + ((error as BusinessError).message ?? JSON.stringify(error)));
      }
      return;
    }
    const stats: XrayStats = native.stats();
    const now: number = Date.now();
    const elapsed: number = this.lastStamp === 0 ? 0 : (now - this.lastStamp) / 1000;
    let upSpeed: number = 0;
    let downSpeed: number = 0;
    if (elapsed > 0) {
      upSpeed = Math.max(0, (stats.up - this.lastUp) / elapsed);
      downSpeed = Math.max(0, (stats.down - this.lastDown) / elapsed);
    }
    this.lastUp = stats.up;
    this.lastDown = stats.down;
    this.lastStamp = now;
    if (this.taskIdSubscriber === null && this.tickCount === 1) {
      this.watchTaskId();
    }
    this.publishTraffic(stats, upSpeed, downSpeed);
    if (this.notifyEnabled && this.tickCount % 2 === 0) {
      this.publishNotification(stats, downSpeed, upSpeed);
    }
    if (this.tickCount % 30 === 0 && this.tickCount > 0) {
      this.probeLiveness();
    }
    if (this.tickCount % 5 === 0) {
      this.sampleUsage();
    }
    this.writeStatus('running', '已连接', stats);
    this.tickCount++;
    if (this.tickCount % 60 === 0) {
      this.appendLog('stats packets=' + stats.packets + ' up=' + stats.up + ' down=' + stats.down +
        ' tcp=' + stats.tcpFlows + ' udp=' + stats.udpFlows + ' drops=' + stats.drops);
      this.mirrorCoreLog('stats');
    }
    if (this.tickCount % 15 === 0) {
      this.mirrorAccessLog();
    }
    if (this.tickCount % 300 === 0) {
      this.trimCoreLog();
    }
  }

  // Sampled every few ticks: reading smaps_rollup is not free, and the numbers
  // only need to be roughly current.
  private sampleUsage(): void {
    try {
      this.pssKb = Number(hidebug.getPss());
      this.cpuPercent = hidebug.getCpuUsage();
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
            bundleName: 'com.way.app',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this.backgroundRunning = true;
      this.appendLog('continuous task started');
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
    const data: commonEventManager.CommonEventPublishData = {
      parameters: {
        'up': Math.floor(stats.up),
        'down': Math.floor(stats.down),
        'upSpeed': Math.floor(upSpeed),
        'downSpeed': Math.floor(downSpeed),
        'tcp': stats.tcpFlows,
        'udp': stats.udpFlows,
        'startedAt': this.startedAt,
        'state': 'running'
      }
    };
    try {
      commonEventManager.publish('com.way.app.TRAFFIC', data, (error: BusinessError) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          this.notifyFailures++;
        }
      });
    } catch (error) {
    }
  }


  private watchNetworks(): void {
    if (!this.rebindEnabled) {
      return;
    }
    this.netAvailableHandler = (data: connection.NetHandle) => {
      this.appendLog('network available, rebinding carriers');
      try {
        const accepted: number = native.rebind();
        this.appendLog('rebind accepted ' + accepted);
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
    this.stopProbeWatch();
    this.stopReloadWatch();
    this.stopConnectionWatch();
    try {
      native.stop();
    } catch (error) {
      this.appendLog('native.stop failed: ' + JSON.stringify(error));
    }
    this.destroyConn();
    this.writeStatus('stopped', reason);
    this.appendLog('tunnel stopped: ' + reason);
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
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: ['com.way.app.TASK_ID']
      });
      commonEventManager.subscribe(sub, (error, data) => {
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (params === undefined || params === null) {
          return;
        }
        const id: number = params['taskNotificationId'] as number;
        if (id !== undefined && id !== null && id >= 0) {
          this.taskNotificationId = id;
          this.appendLog('live view moved to notification ' + id);
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

  // Live traffic in the notification bar: the persistent task notification and
  // an app notification together are what keeps the process off the kill list,
  // so the numbers here are the visible proof that the tunnel is still alive.
  private publishNotification(stats: XrayStats, downSpeed: number, upSpeed: number): void {
    if (this.taskNotificationId >= 0) {
      this.publishLiveView(stats, downSpeed, upSpeed);
      return;
    }
    try {
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'way 已连接',
            text: '↓ ' + formatBytes(downSpeed) + '/s · ↑ ' + formatBytes(upSpeed) + '/s · 累计 ' +
              formatBytes(stats.up) + ' ↑ / ' + formatBytes(stats.down) + ' ↓'
          }
        },
        wantAgent: undefined,
        notificationSlotType: notificationManager.SlotType.OTHER_TYPES,
        tapDismissed: false,
        isOngoing: true
      };
      notificationManager.publish(request).catch((error: BusinessError) => {
        if (this.tickCount % 60 === 0) {
          this.appendLog('notification publish failed: ' + (error.message ?? 'unknown'));
        }
      });
    } catch (error) {
    }
  }

  // Take over the continuous-task notification: publish SYSTEM_LIVE_VIEW on the
  // id returned by startBackgroundRunning, exactly like TunBox does. Otherwise
  // the system hides the app's own notification while the task card is up.
  private publishLiveView(stats: XrayStats, downSpeed: number, upSpeed: number): void {
    try {
      const liveLine: string = '↓' + formatBytes(downSpeed) + '/s ↑' + formatBytes(upSpeed) + '/s';
      const title: string = this.nodeName.length > 0 ? this.nodeName : 'way';
      const data: Record<string, Object> = {};
      data['title'] = title;
      data['fileName'] = liveLine;
      const request: notificationManager.NotificationRequest = {
        id: this.taskNotificationId,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title: 'way · ' + title,
            text: liveLine
          }
        },
        template: {
          name: 'downloadTemplate',
          data: data
        }
      };
      notificationManager.publish(request).catch((error: BusinessError) => {
        if (this.tickCount % 60 === 0) {
          this.appendLog('live view update failed: ' + (error.message ?? 'unknown'));
        }
      });
    } catch (error) {
      this.appendLog('live view error: ' + JSON.stringify(error));
    }
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
        events: [PROBE_REQUEST_EVENT]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (params === undefined || params === null) {
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
    const data: commonEventManager.CommonEventPublishData = { parameters: params };
    try {
      commonEventManager.publish(PROBE_RESULT_EVENT, data, () => {
      });
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
        events: [PROBE_CANCEL_EVENT]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
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
        events: [RELOAD_REQUEST_EVENT]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        const requestId: string = (params === undefined || params === null)
          ? '' : ((params['requestId'] as string) ?? '');
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
    const data: commonEventManager.CommonEventPublishData = { parameters: payload };
    try {
      commonEventManager.publish(RELOAD_RESULT_EVENT, data, () => {
      });
    } catch (error) {
    }
  }

  // Live connection inventory: {op:'list'} returns the core snapshot JSON,
  // {op:'close', id} drops one connection. The UI polls this once a second.
  private async watchConnectionRequests(): Promise<void> {
    if (this.connSubscriber !== null) {
      return;
    }
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [CONN_REQUEST_EVENT]
      });
      commonEventManager.subscribe(sub, (error, data) => {
        if (error !== undefined && error !== null && error.code !== 0) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        const requestId: string = (params === undefined || params === null)
          ? '' : ((params['requestId'] as string) ?? '');
        const op: string = (params === undefined || params === null)
          ? '' : ((params['op'] as string) ?? 'list');
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
    const data: commonEventManager.CommonEventPublishData = {
      parameters: {
        'requestId': requestId,
        'ok': ms >= 0 ? 1 : 0,
        'json': '' + ms
      }
    };
    try {
      commonEventManager.publish(CONN_RESULT_EVENT, data, () => {
      });
    } catch (error) {
    }
  }

  private runConnectionList(requestId: string): void {    let ok: boolean = false;
    let payload: string = '';
    try {
      payload = native.connectionSnapshot();
      ok = true;
    } catch (error) {
      const failure = error as BusinessError;
      payload = failure.message === undefined ? 'snapshot failed' : failure.message;
      this.appendLog('connection snapshot failed: ' + payload);
    }
    const data: commonEventManager.CommonEventPublishData = {
      parameters: {
        'requestId': requestId,
        'ok': ok ? 1 : 0,
        'json': payload
      }
    };
    try {
      commonEventManager.publish(CONN_RESULT_EVENT, data, () => {
      });
    } catch (error) {
    }
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
    const data: commonEventManager.CommonEventPublishData = {
      parameters: {
        'requestId': requestId,
        'ok': ok ? 1 : 0,
        'json': payload
      }
    };
    try {
      commonEventManager.publish(CONN_RESULT_EVENT, data, () => {
      });
    } catch (error) {
    }
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

  // Periodic request through the tunnel: keeps the carrier active (so the system
  // sees ongoing traffic) and surfaces dead tunnels early. Async so an 8 s probe
  // no longer stalls the status heartbeat.
  private async probeLiveness(): Promise<void> {
    try {
      const raw: string =
        JSON.stringify(await native.probeOutbound('https://www.gstatic.com/generate_204', 8000, '') as Object);
      const result: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const failureKind: number = (result['failureKind'] as number) ?? 1;
      if (failureKind !== 0) {
        this.appendLog('probe failed kind=' + failureKind);
        this.appendLog('rebind accepted ' + native.rebind());
      } else {
        this.lastProbeMs = (result['delayMs'] as number) ?? 0;
        this.appendLog('probe ok ' + this.lastProbeMs + 'ms');
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

  private trimCoreLog(): void {
    try {
      const path: string = this.logDir + '/xray-error.log';
      if (!fs.accessSync(path)) {
        return;
      }
      if (fs.statSync(path).size > 8 * 1024 * 1024) {
        fs.truncateSync(path, 0);
        this.appendLog('core log truncated');
      }
    } catch (error) {
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






























