import { UIAbility } from '@kit.AbilityKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { appLog } from '../common/AppLog';
import { loadConfig, startVpn, vpnWant } from '../common/Xray';
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
  private arming: boolean = false;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private taskId: number = -1;
  private taskNotificationId: number = -1;
  private taskAgent: WantAgent | null = null;

  onCreate(): void {
    this.watchStop();
    this.arm().catch((): void => {
    });
  }

  onDestroy(): void {
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
      // EntryAbility.onDestroy checks this: a manual swipe of the main window
      // must not stop a VPN that this keepalive ability owns.
      way.putSync('tempKeepAlive', true);
      await way.flush();
      const notifId: number = await this.acquire();
      const entry = selectedEntry(this.context);
      const name: string = entry === null ? '' : entry.name;
      await startVpn(vpnWant(this.context, true, true, notifId, name));
      appLog(this.context, 'keepalive', 'widget trigger: VPN started, notification=' + notifId);
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'widget trigger failed: ' + (err.message ?? 'unknown'));
    } finally {
      this.arming = false;
    }
  }

  private clearKeepAliveFlag(): void {
    try {
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
      try {
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
        appLog(this.context, 'keepalive', 'continuous task: taskKeeping');
        this.running = true;
        this.taskNotificationId = -1;
        return -1;
      } catch (keepError) {
        const keepErr = keepError as BusinessError;
        appLog(this.context, 'keepalive',
          'taskKeeping refused: ' + (keepErr.message ?? '?') + ', trying dataTransfer request');
      }
      await this.acquireDataTransfer(agent);
      return this.taskNotificationId;
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
