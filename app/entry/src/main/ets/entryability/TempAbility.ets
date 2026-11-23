import { UIAbility } from '@kit.AbilityKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { appLog } from '../common/AppLog';
import { loadConfig, readStatus, startVpn, vpnWant } from '../common/Xray';
import { selectedEntry } from '../common/Store';

// FlClash-ohos style keepalive ability.
//
// The launcher previews a widget card before it is added; the card's onAppear
// posts action:'call' to this ability (see card/WidgetCard.ets). That means the
// user only has to open the system widget picker and exit: this ability starts
// the VPN extension with the saved config and holds a continuous task, so
// swiping the main UI away no longer reclaims the VPN. The card itself does not
// need to be added to the home screen.
export default class TempAbility extends UIAbility {
  private running: boolean = false;
  private supervisorTimer: number = -1;
  private arming: boolean = false;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private taskId: number = -1;
  private taskNotificationId: number = -1;
  private taskAgent: WantAgent | null = null;

  onCreate(): void {
    appLog(this.context, 'keepalive', 'TempAbility onCreate');
    this.watchStop();
    this.arm().catch((): void => {
    });
  }

  // The blank keepalive ability has no page, but the system still reports
  // foreground/background; these two lines tell us whether the card preview
  // actually brought it up and whether it ever became visible in recents.
  onForeground(): void {
    appLog(this.context, 'keepalive', 'TempAbility onForeground (visible)');
  }

  onBackground(): void {
    appLog(this.context, 'keepalive', 'TempAbility onBackground');
  }

  onDestroy(): void {
    let temp: boolean = false;
    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      temp = way.getSync('tempKeepAlive', false) as boolean;
    } catch (error) {
    }
    appLog(this.context, 'keepalive',
      'TempAbility onDestroy, tempKeepAlive=' + temp + ', running=' + this.running);
    this.stopSupervisor();
    this.release();
    this.clearKeepAliveFlag();
    const sub = this.subscriber;
    this.subscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  // Started either by the widget preview (onAppear call action) or by the app.
  // Idempotent: re-arming while the tunnel is already up only re-requests the
  // task/VPN, which the extension treats as a duplicate start.
  private async arm(): Promise<void> {
    if (this.arming) {
      return;
    }
    this.arming = true;
    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      const active: boolean = way.getSync('vpnActive', false) as boolean;
      const last: boolean = way.getSync('lastConnected', false) as boolean;
      const userOff: boolean = way.getSync('userOff', false) as boolean;
      const suspended: boolean = way.getSync('ssidSuspended', false) as boolean;
      appLog(this.context, 'keepalive',
        'arm: active=' + active + ' last=' + last + ' userOff=' + userOff + ' suspended=' + suspended);
      if (userOff || suspended || (!active && !last)) {
        appLog(this.context, 'keepalive', 'widget trigger ignored: intent off');
        this.context.terminateSelf().catch((): void => {
        });
        return;
      }
      if (loadConfig(this.context).length === 0) {
        appLog(this.context, 'keepalive', 'widget trigger ignored: no saved config');
        this.context.terminateSelf().catch((): void => {
        });
        return;
      }
      way.putSync('vpnActive', true);
      way.putSync('userOff', false);
      await way.flush();
      // Acquire OUR task first. Only after it is up do we ask the UI to stop
      // its own task; stopping first left the VPN task-less when the picker
      // preview failed to call this ability, and the system reclaimed it.
      const notifId: number = await this.acquire();
      appLog(this.context, 'keepalive',
        'arm: task running=' + this.running + ' notification=' + notifId);
      if (!this.running) {
        appLog(this.context, 'keepalive', 'widget trigger: no continuous task, leaving UI task in place');
        this.context.terminateSelf().catch((): void => {
        });
        return;
      }
      if (notifId >= 0) {
        // If the VPN extension was already running under the UI's old task id,
        // startVpn is a duplicate start and does not re-bind handlers. Push the
        // new notification id so the live view replaces this task card instead
        // of publishing to the old id.
        try {
          const data: commonEventManager.CommonEventPublishData = {
            parameters: { 'taskNotificationId': notifId }
          };
          commonEventManager.publish('com.way.app.TASK_ID', data, () => {
          });
        } catch (error) {
        }
      }
      const entry = selectedEntry(this.context);
      const name: string = entry === null ? '' : entry.name;
      try {
        await startVpn(vpnWant(this.context, true, true, notifId, name));
        appLog(this.context, 'keepalive', 'widget trigger: VPN started, notification=' + notifId);
      } catch (error) {
        // The extension is usually already running (duplicate start); the task
        // and the TASK_ID handoff above are what matter. The supervisor below
        // retries if the heartbeat is actually gone.
        const err = error as BusinessError;
        appLog(this.context, 'keepalive', 'widget trigger startVpn: ' + (err.message ?? 'unknown'));
      }
      // From here the TempAbility owns the keepalive.
      way.putSync('tempKeepAlive', true);
      await way.flush();
      try {
        const data: commonEventManager.CommonEventPublishData = { parameters: {} };
        commonEventManager.publish('com.way.app.KEEPALIVE_TAKEOVER', data, () => {
        });
      } catch (error) {
      }
      this.startSupervisor();
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'widget trigger failed: ' + (err.message ?? 'unknown'));
    } finally {
      this.arming = false;
    }
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  private clearKeepAliveFlag(): void {    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      way.putSync('tempKeepAlive', false);
      way.flush();
    } catch (error) {
    }
  }

  private async watchStop(): Promise<void> {
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: ['com.way.app.STOP_KEEPALIVE']
      });
      commonEventManager.subscribe(sub, () => {
        appLog(this.context, 'keepalive', 'STOP_KEEPALIVE received');
        this.stopSupervisor();
        this.release();
        this.clearKeepAliveFlag();
        this.context.terminateSelf();
      });
      this.subscriber = sub;
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'watch stop failed: ' + (err.message ?? 'unknown'));
    }
  }

  private async acquire(): Promise<number> {
    try {
      const agent: WantAgent = await this.buildAgent();
      this.taskAgent = agent;
      // The system can revoke the task (continuousTaskCancel); FlClash-ohos
      // re-requests it a second later instead of giving up.
      backgroundTaskManager.on('continuousTaskCancel',
        (cancelInfo: backgroundTaskManager.ContinuousTaskCancelInfo) => {
          if (this.running) {
            setTimeout(() => {
              this.acquire();
            }, 1000);
          }
        });
      // Prefer the DATA_TRANSFER + live-view form: it returns a notification id
      // the extension can publish on, and it survives backgrounding on phones.
      await this.acquireDataTransfer(agent);
      if (this.running) {
        return this.taskNotificationId;
      }
      try {
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
        appLog(this.context, 'keepalive', 'continuous task: taskKeeping (no notification id)');
        this.running = true;
        this.taskNotificationId = -1;
        return -1;
      } catch (keepError) {
        const keepErr = keepError as BusinessError;
        appLog(this.context, 'keepalive',
          'taskKeeping refused: ' + (keepErr.message ?? '?'));
      }
      return -1;
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'continuous task failed: ' + (err.message ?? 'unknown'));
      return -1;
    }
  }

  // DATA_TRANSFER through the ContinuousTaskRequest API with the live-view
  // subtype. The legacy startBackgroundRunning overload produced a task the
  // system reclaimed once the app went to background; this form survives lock
  // screen (verified over 12 minutes). DATA_TRANSFER rejects
  // updateBackgroundRunning, so no refresh loop is needed.
  private async acquireDataTransfer(agent: WantAgent): Promise<void> {
    try {
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      const info: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(this.context, request);
      this.taskId = info.continuousTaskId ?? -1;
      this.taskNotificationId = info.notificationId;
      appLog(this.context, 'keepalive',
        'continuous task: dataTransfer request id=' + this.taskId + ' notification=' + info.notificationId);
      this.running = true;
    } catch (error) {
      const err = error as BusinessError;
      try {
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        appLog(this.context, 'keepalive',
          'continuous task: dataTransfer legacy (request API refused: ' + (err.message ?? '?') + ')');
        this.running = true;
        this.taskNotificationId = -1;
      } catch (inner) {
        const innerErr = inner as BusinessError;
        appLog(this.context, 'keepalive', 'continuous task failed: ' + (innerErr.message ?? 'unknown'));
      }
    }
  }

  private async buildAgent(): Promise<WantAgent> {
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
    return wantAgent.getWantAgent(info);
  }

  // The widget-preview keepalive also supervises the heartbeat: when the UI is
  // swiped away its page timer may freeze, so this ability is the last owner
  // that can restart a reclaimed VPN extension.
  private startSupervisor(): void {
    if (this.supervisorTimer !== -1) {
      return;
    }
    this.supervisorTimer = setInterval(() => {
      this.supervise().catch((): void => {
      });
    }, 5000);
  }

  private stopSupervisor(): void {
    if (this.supervisorTimer !== -1) {
      clearInterval(this.supervisorTimer);
      this.supervisorTimer = -1;
    }
  }

  private async supervise(): Promise<void> {
    if (this.arming) {
      return;
    }
    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      if (!(way.getSync('tempKeepAlive', false) as boolean)) {
        return;
      }
      if (way.getSync('userOff', false) as boolean) {
        return;
      }
      if (way.getSync('ssidSuspended', false) as boolean) {
        return;
      }
      const status = readStatus(this.context);
      const now: number = Date.now();
      // 12 s, not the UI's 5 s: a network switch can block native.rebind() and
      // stall the heartbeat for several seconds without the extension dying.
      const stale: boolean = status === null ||
        ((status.state === 'running' || status.state === 'starting') &&
          now - status.updatedAt > 12000) ||
        status.state === 'stopped' || status.state === 'error';
      if (!stale) {
        return;
      }
      const last: number = way.getSync('watchdogLastStart', 0) as number;
      if (now - last < 10000) {
        return;
      }
      way.putSync('watchdogLastStart', now);
      await way.flush();
      const entry = selectedEntry(this.context);
      const name: string = entry === null ? '' : entry.name;
      await startVpn(vpnWant(this.context, true, true, this.taskNotificationId, name));
      appLog(this.context, 'keepalive', 'supervisor restarted vpn');
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'supervisor failed: ' + (err.message ?? 'unknown'));
    }
  }

  private release(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    try {
      backgroundTaskManager.off('continuousTaskCancel');
      backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (error) {
    }
  }
}
