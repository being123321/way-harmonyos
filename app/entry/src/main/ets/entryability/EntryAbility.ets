import { AbilityConstant, UIAbility, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import type { BusinessError } from '@kit.BasicServicesKit';
import { appLog } from '../common/AppLog';
import { readStatus, startVpn, stopVpn, vpnWant, clearStatus } from '../common/Xray';
import { SSID_SUSPEND, appliedSsidAction, currentSsid, findRule, setAppliedSsidAction, setSsidSuspended, setSuspendOverride, ssidSuspended, suspendOverride } from '../common/Ssid';
import { selectedEntry } from '../common/Store';
import { MODE_BYPASS, MODE_DIRECT, SplitOptions } from '../common/Rules';
import { buildAndSaveTunnel } from '../common/TunnelConfig';
import { activeRuleSet, dohEnabled, ruleSetAdsEnabled } from '../common/RuleSet';
import { geodataReady } from '../common/Geodata';
import { preferences } from '@kit.ArkData';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { PipManager } from '../common/PipManager';

const DOMAIN: number = 0x0000;
const TAG: string = 'way';
const SSID_HANDLED_IN_EXTENSION: boolean = false;

export default class EntryAbility extends UIAbility {
  private wifiTimer: number = -1;
  private wifiHandler: (() => void) | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.startWifiWatch();
    this.stashCardOp(want).catch((): void => {
    });
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.stashCardOp(want).catch((): void => {
    });
  }

  // 桌面卡片通过 want.parameters.op 传「connect / disconnect」，页面加载后消费。
  // AppStorage 是同步的，先写它，避免页面 onPageShow 早于下面的异步落盘。
  private stashCardOp(want: Want): Promise<void> {
    const params: Record<string, Object> = want.parameters ?? {};
    const raw: Object | undefined = params['op'];
    if (typeof raw !== 'string' || (raw as string).length === 0) {
      return Promise.resolve();
    }
    const op: string = raw as string;
    try {
      AppStorage.setOrCreate<string>('wayCardOp', op);
    } catch (error) {
    }
    return this.persistCardOp(op);
  }

  private async persistCardOp(op: string): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.context, 'way');
      store.putSync('cardOp', op);
      await store.flush();
      appLog(this.context, 'card', 'card op queued: ' + op);
    } catch (error) {
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    if (this.wifiHandler !== null) {
      try {
        wifiManager.off('wifiConnectionChange', this.wifiHandler);
      } catch (error) {
      }
      this.wifiHandler = null;
    }
    // With the simulated-PiP keepalive the main task may be swiped away while
    // the PiP window (and this ability) stays alive. That is not an explicit
    // exit: keep the VPN intent so the tunnel/task survive.
    if (this.pipKeepAliveActive()) {
      appLog(this.context, 'lifecycle', 'onDestroy with PiP keepalive, tunnel left running');
    } else {
      // 用户手动清后台：把隧道停掉并清「已连接」标记，之后不自动重连。
      this.stopForManualKill().catch((): void => {
      });
    }
  }

  private pipKeepAliveActive(): boolean {
    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      const active: boolean = way.getSync('vpnActive', false) as boolean;
      const userOff: boolean = way.getSync('userOff', false) as boolean;
      const suspended: boolean = way.getSync('ssidSuspended', false) as boolean;
      const prefs = preferences.getPreferencesSync(this.context, { name: 'xray_prefs' });
      const enabled: boolean = prefs.getSync('pipKeepAlive', true) as boolean;
      return enabled && active && !userOff && !suspended;
    } catch (error) {
      return false;
    }
  }

  private async stopForManualKill(): Promise<void> {
    // Closing the app is a full exit: no watcher, no task, no pending suspend
    // state. Otherwise the next launch would look like a re-suspension instead
    // of a fresh start (and nothing must keep running in the background).
    if (this.wifiTimer !== -1) {
      clearInterval(this.wifiTimer);
      this.wifiTimer = -1;
    }
    try {
      const store = await preferences.getPreferences(this.context, 'way');
      store.putSync('vpnActive', false);
      // Manual close must not auto-reconnect later.
      store.putSync('userOff', true);
      store.putSync('ssidSuspended', false);
      store.putSync('appliedSsidAction', '');
      store.putSync('suspendOverride', false);
      await store.flush();
    } catch (error) {
    }
    try {
      await stopVpn(vpnWant(this.context, true, true));
      appLog(this.context, 'lifecycle', 'task destroyed, tunnel stopped');
    } catch (error) {
    }
    try {
      backgroundTaskManager.stopBackgroundRunning(this.context).catch(() => {
      });
    } catch (error) {
    }
  }


  private startWifiWatch(): void {
    if (this.wifiTimer !== -1) {
      return;
    }
    // The 3 s timer freezes with the app in the background; the Wi-Fi change
    // event is delivered as a callback and is what makes a background restore
    // possible when the user leaves the suspended network.
    const handler = (): void => {
      this.checkWifi().catch(() => {
      });
    };
    this.wifiHandler = handler;
    try {
      wifiManager.on('wifiConnectionChange', handler);
    } catch (error) {
    }
    this.wifiTimer = setInterval(() => {
      this.checkWifi().catch(() => {
      });
    }, 3000);
    setTimeout(() => {
      this.checkWifi().catch(() => {
      });
    }, 800);
  }

  // On-demand start plus SSID suspension: leaving a listed Wi-Fi brings the
  // tunnel back, joining one stops it.
  // SSID policy: a suspend Wi-Fi full-stops the tunnel (no heartbeat, no task).
  // Leaving it restarts the tunnel as a fresh start, using the last intent.
  private async checkWifi(): Promise<void> {
    const store = await preferences.getPreferences(this.context, 'way');
    const onDemand: boolean = store.getSync('onDemand', false) as boolean;
    if (!onDemand) {
      return;
    }
    const ssid: string = await currentSsid();
    const rule = findRule(this.context, ssid);
    const status = readStatus(this.context);
    const running: boolean = status !== null && status.state === 'running' &&
      Date.now() - status.updatedAt < 8000;
    const suspended: boolean = ssidSuspended(this.context);
    const suspendHere: boolean = rule !== null && rule.action === SSID_SUSPEND;

    if (suspendHere) {
      // The user explicitly turned it off on this Wi-Fi: stay off until they
      // turn it on again (the switch-off path clears these markers).
      if (store.getSync('userOff', false) as boolean) {
        if (suspended) {
          setSsidSuspended(this.context, false);
          setAppliedSsidAction(this.context, '');
        }
        return;
      }
      if (!suspended) {
        setSsidSuspended(this.context, true);
        setAppliedSsidAction(this.context, SSID_SUSPEND);
      }
      if (running) {
        appLog(this.context, 'wifi', 'ssid ' + ssid + ' suspended, stopping vpn');
        try {
          await stopVpn(vpnWant(this.context, true, true));
        } catch (error) {
          appLog(this.context, 'wifi', 'ssid suspend stop failed');
        }
        // No heartbeat, no task: suspension means everything is off.
        try {
          backgroundTaskManager.stopBackgroundRunning(this.context).catch(() => {
          });
        } catch (error) {
        }
      }
      return;
    }

    if (!suspended) {
      return;
    }
    // A manual close/disconnect clears the intent: never restore against it.
    if (store.getSync('userOff', false) as boolean) {
      setSsidSuspended(this.context, false);
      setAppliedSsidAction(this.context, '');
      return;
    }
    const desired: boolean = store.getSync('vpnActive', false) as boolean;
    if (running) {
      if (status !== null && Date.now() - status.updatedAt < 3000) {
        setSsidSuspended(this.context, false);
        setAppliedSsidAction(this.context, '');
      }
      return;
    }
    setSsidSuspended(this.context, false);
    setAppliedSsidAction(this.context, '');
    if (!desired) {
      return;
    }
    appLog(this.context, 'wifi', 'left suspended ssid, restarting tunnel');
    await this.startWithMode(store.getSync('mode', MODE_BYPASS) as string);
  }

  private async startWithMode(mode: string): Promise<void> {
    const store = await preferences.getPreferences(this.context, 'way');
    const current: string = store.getSync('mode', MODE_BYPASS) as string;
    if (mode === MODE_DIRECT && current !== MODE_DIRECT) {
      store.putSync('restoreMode', current);
    }
    store.putSync('mode', mode);
    store.putSync('vpnActive', true);
    await store.flush();
    try {
      await stopVpn(vpnWant(this.context, true, true));
    } catch (error) {
    }
    const entry = selectedEntry(this.context);
    if (entry === null) {
      appLog(this.context, 'wifi', 'mode switch skipped: no node');
      return;
    }
    const options: SplitOptions = {
      split: true,
      geodata: geodataReady(this.context),
      mode: mode,
      blockQuic: store.getSync('blockQuic', true) as boolean,
      debugLog: store.getSync('debugLog', false) as boolean,
      ruleSet: activeRuleSet(this.context),
      blockAds: ruleSetAdsEnabled(this.context),
      doh: dohEnabled(this.context),
      bootstrapHosts: null
    };
    buildAndSaveTunnel(this.context, entry, options);
    clearStatus(this.context);
    // A restored tunnel must look like a fresh start: task first (that is what
    // carries the live-view card), then the VPN. If the system refuses the
    // request in the background, the tunnel still runs and the UI re-acquires
    // the task when it is next opened.
    let notifId: number = -1;
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
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      const taskInfo: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(this.context, request);
      notifId = taskInfo.notificationId;
      appLog(this.context, 'wifi', 'restore task notification=' + notifId);
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'wifi', 'restore task refused: ' + (err.message ?? 'unknown'));
    }
    try {
      await startVpn(vpnWant(this.context, true, true, notifId, entry.name));
      appLog(this.context, 'wifi', 'vpn restarted in ' + mode + ' mode');
    } catch (error) {
      appLog(this.context, 'wifi', 'mode switch failed');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent ok');
    });

    // Edge-to-edge: paint under the status and navigation bars, keep the bars
    // themselves transparent with light icons.
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      // PiP needs a typeNode created from the main window's UIContext.
      PipManager.getInstance().makeTypeNode(win.getUIContext());
      PipManager.getInstance().prepare(this.context);
      win.setWindowLayoutFullScreen(true).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'fullscreen failed: %{public}s', JSON.stringify(error));
      });
      const bars: window.SystemBarProperties = {
        // Transparent bars: the page gradient is drawn edge to edge, so the
        // status bar shows the app instead of a coloured band.
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: '#FFFFFF',
        navigationBarContentColor: '#FFFFFF'
      };
      win.setWindowBackgroundColor('#00000000');
      win.setWindowSystemBarProperties(bars).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'system bar failed: %{public}s', JSON.stringify(error));
      });
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'window setup failed: %{public}s', JSON.stringify(error));
    }
  }

  onWindowStageDestroy(): void {
  }

  onBackground(): void {
    try {
      if (!this.pipKeepAliveActive()) {
        PipManager.getInstance().setAutoStart(this.context, false);
        return;
      }
      // The system pops the small PiP window when the app goes to the
      // background; it survives the main task being swiped away.
      PipManager.getInstance().setAutoStart(this.context, true);
      appLog(this.context, 'pip', 'PiP auto-start enabled on background');
    } catch (error) {
    }
  }

  onForeground(): void {
    try {
      PipManager.getInstance().setAutoStart(this.context, false);
      PipManager.getInstance().stop();
      appLog(this.context, 'pip', 'foreground, PiP stopped');
    } catch (error) {
    }
  }
}


























