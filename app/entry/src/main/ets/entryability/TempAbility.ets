import { UIAbility } from '@kit.AbilityKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { appLog } from '../common/AppLog';

// Holds the continuous task for the whole tunnel lifetime. The main
// EntryAbility's task dies with its window, and the system then reclaims the
// process (appspawn exit 254) together with the VPN extension; a second,
// windowless ability keeps the task alive independently, as FlClash-ohos does.
export default class TempAbility extends UIAbility {
  private running: boolean = false;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private taskId: number = -1;
  private taskAgent: WantAgent | null = null;

  onCreate(): void {
    this.acquire();
    this.watchStop();
  }

  onDestroy(): void {
    this.release();
    const sub = this.subscriber;
    this.subscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

  private async watchStop(): Promise<void> {
    try {
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: ['com.way.app.STOP_KEEPALIVE']
      });
      commonEventManager.subscribe(sub, () => {
        this.release();
        this.context.terminateSelf();
      });
      this.subscriber = sub;
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'watch stop failed: ' + (err.message ?? 'unknown'));
    }
  }

  private async acquire(): Promise<void> {
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
        return;
      } catch (keepError) {
        const keepErr = keepError as BusinessError;
        appLog(this.context, 'keepalive',
          'taskKeeping refused: ' + (keepErr.message ?? '?') + ', trying dataTransfer request');
      }
      await this.acquireDataTransfer(agent);
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'continuous task failed: ' + (err.message ?? 'unknown'));
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


