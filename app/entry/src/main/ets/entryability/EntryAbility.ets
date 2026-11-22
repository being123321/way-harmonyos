import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import type { BusinessError } from '@kit.BasicServicesKit';
import { appLog } from '../common/AppLog';
import { readStatus, startVpn, stopVpn, vpnWant, clearStatus } from '../common/Xray';
import { SSID_SUSPEND, appliedSsidAction, currentSsid, findRule, setAppliedSsidAction, setSsidSuspended, ssidSuspended } from '../common/Ssid';
import { selectedEntry } from '../common/Store';
import { MODE_BYPASS, MODE_DIRECT, SplitOptions } from '../common/Rules';
import { buildAndSaveTunnel } from '../common/TunnelConfig';
import { activeRuleSet, dohEnabled, ruleSetAdsEnabled } from '../common/RuleSet';
import { geodataReady } from '../common/Geodata';
import { preferences } from '@kit.ArkData';

const DOMAIN: number = 0x0000;
const TAG: string = 'way';

export default class EntryAbility extends UIAbility {
  private wifiTimer: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
    this.startWifiWatch();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    // 用户手动清后台：把隧道停掉并清「已连接」标记，之后不自动重连。
    this.stopForManualKill().catch((): void => {
    });
  }

  private async stopForManualKill(): Promise<void> {
    try {
      const store = await preferences.getPreferences(this.context, 'way');
      store.putSync('vpnActive', false);
      await store.flush();
    } catch (error) {
    }
    try {
      await stopVpn(vpnWant(this.context, true, true));
      appLog(this.context, 'lifecycle', 'task destroyed, tunnel stopped');
    } catch (error) {
    }
  }


  private startWifiWatch(): void {
    if (this.wifiTimer !== -1) {
      return;
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
  private async checkWifi(): Promise<void> {
    const store = await preferences.getPreferences(this.context, 'way');
    const onDemand: boolean = store.getSync('onDemand', false) as boolean;
    if (!onDemand) {
      return;
    }
    // An explicit disconnect wins over on-demand: never reconnect against it.
    if (store.getSync('userOff', false) as boolean) {
      return;
    }
    const ssid: string = await currentSsid();
    const rule = findRule(this.context, ssid);
    const status = readStatus(this.context);
    const running: boolean = status !== null && status.state === 'running' &&
      Date.now() - status.updatedAt < 8000;
    const applied: string = appliedSsidAction(this.context);

    if (rule === null) {
      // Not a suspended SSID: only undo a previous suspension. Whether the
      // tunnel should be up is the user's switch plus the crash-recovery
      // watchdog, not on-demand.
      const wasSuspended: boolean = appliedSsidAction(this.context) === SSID_SUSPEND;
      setSsidSuspended(this.context, false);
      setAppliedSsidAction(this.context, '');
      if (wasSuspended && !running) {
        const desired: boolean = store.getSync('vpnActive', false) as boolean;
        if (desired) {
          appLog(this.context, 'wifi', 'left suspended ssid, restoring tunnel');
          await this.startWithMode(store.getSync('mode', MODE_BYPASS) as string);
        }
      }
      return;
    }

    if (rule.action === SSID_SUSPEND) {
      if (running) {
        appLog(this.context, 'wifi', 'ssid ' + ssid + ' suspended, stopping vpn');
        setAppliedSsidAction(this.context, SSID_SUSPEND);
        setSsidSuspended(this.context, true);
        try {
          await stopVpn(vpnWant(this.context, true, true));
        } catch (error) {
          appLog(this.context, 'wifi', 'ssid suspend stop failed');
        }
      }
      return;
    }


  }

  // Restarts the tunnel with the given routing mode, remembering the previous
  // one so leaving the Wi-Fi can restore it.
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
    try {
      await startVpn(vpnWant(this.context, true, true));
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

  onForeground(): void {
  }

  onBackground(): void {
  }
}



















