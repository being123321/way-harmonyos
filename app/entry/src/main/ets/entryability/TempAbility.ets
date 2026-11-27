import { UIAbility, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { rpc } from '@kit.IPCKit';
import { window } from '@kit.ArkUI';
import { appLog } from '../common/AppLog';
import { initIpcAuth, publishScopedEvent, verifyIpcParams } from '../common/IpcAuth';
import { appBundleName, appEvent, loadConfig, readStatus, saveTaskNotificationId, startVpn, vpnWant } from '../common/Xray';
import { selectedEntry } from '../common/Store';

class KeepAliveReply implements rpc.Parcelable {
  marshalling(_dataOut: rpc.MessageSequence): boolean {
    return true;
  }

  unmarshalling(_dataIn: rpc.MessageSequence): boolean {
    return true;
  }
}

// Transparent background keepalive owner:
//   - Started once when "后台运行 VPN" is toggled ON (or silently via widget call).
//   - Uses a fully transparent startup icon & window background and immediately
//     moves itself to background so the user sees no blank page.
//   - Owns the single DATA_TRANSFER + LIVE_VIEW continuous task while active,
//     broadcasts KEEPALIVE_TAKEOVER + TASK_ID (signed with sandbox ipcToken) so
//     the main UI releases its own task and the shade shows ONLY 1 traffic card.
//   - Stays in standby across VPN disconnects/reconnects (no repeat popups) and
//     never runs an unbounded continuousTaskCancel retry loop.
export default class TempAbility extends UIAbility {
  private running: boolean = false;
  private supervisorTimer: number = -1;
  private arming: boolean = false;
  private hasWindow: boolean = false;
  private explicitStop: boolean = false;
  private cancelRetryCount: number = 0;
  private cancelWatchRegistered: boolean = false;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private taskId: number = -1;
  private taskNotificationId: number = -1;
  private lastAcquireAt: number = 0;
  private acquiring: boolean = false;

  onCreate(): void {
    initIpcAuth(this.context);
    appLog(this.context, 'keepalive', 'TempAbility onCreate');
    this.registerCallee();
    this.watchControlEvents();
    this.arm().catch((): void => {
    });
  }

  private registerCallee(): void {
    try {
      this.callee.on('keepalive', (_data: rpc.MessageSequence): rpc.Parcelable => {
        appLog(this.context, 'keepalive', 'callee keepalive invoked');
        this.arm().catch((): void => {
        });
        return new KeepAliveReply();
      });
    } catch (error) {
    }
  }

  // In headless Call mode (launched by WidgetCard.onAppear action:'call'),
  // onWindowStageCreate is NEVER called, so no blank window or recents card
  // exists at all. Only if started via fallback startAbility do we push the
  // window to background after arm() completes.
  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.hasWindow = true;
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      win.setWindowBackgroundColor('#00000000');
    } catch (error) {
    }
    if (!this.arming) {
      this.context.moveAbilityToBackground().catch((): void => {
      });
    }
  }

  onForeground(): void {
    if (this.hasWindow && !this.arming) {
      this.context.moveAbilityToBackground().catch((): void => {
      });
    }
  }

  onBackground(): void {
    appLog(this.context, 'keepalive', 'TempAbility onBackground');
  }

  private shouldPreserveOnDestroy(): boolean {
    if (this.explicitStop) {
      return false;
    }
    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      const keepOnRemove: boolean = way.getSync('keepAliveOnRemove', false) as boolean;
      const active: boolean = way.getSync('vpnActive', false) as boolean;
      const userOff: boolean = way.getSync('userOff', false) as boolean;
      return keepOnRemove && active && !userOff;
    } catch (error) {
      return false;
    }
  }

  onDestroy(): void {
    const preserve: boolean = this.shouldPreserveOnDestroy();
    appLog(this.context, 'keepalive',
      'TempAbility onDestroy, running=' + this.running + ', preserve=' + preserve);
    try {
      this.callee.off('keepalive');
    } catch (error) {
    }
    this.stopSupervisor();
    if (!preserve) {
      this.release();
      this.clearKeepAliveFlag();
    } else {
      // User swiped/closed the blank window while background VPN is still ON:
      // do NOT call stopBackgroundRunning or stopVpn so the independent VPN
      // extension keeps running uninterrupted.
      this.running = false;
      this.cancelWatchRegistered = false;
      try {
        backgroundTaskManager.off('continuousTaskCancel');
      } catch (error) {
      }
      this.clearKeepAliveFlag();
    }
    const sub = this.subscriber;
    this.subscriber = null;
    if (sub !== null) {
      try {
        commonEventManager.unsubscribe(sub);
      } catch (error) {
      }
    }
  }

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
      const enabled: boolean = way.getSync('keepAliveOnRemove', false) as boolean;
      appLog(this.context, 'keepalive',
        'arm: active=' + active + ' last=' + last + ' userOff=' + userOff +
        ' suspended=' + suspended + ' keepOnRemove=' + enabled);
      if (!enabled) {
        this.context.terminateSelf().catch((): void => {
        });
        return;
      }
      if (userOff || suspended || (!active && !last)) {
        // Stay alive in standby while keepAliveOnRemove=true so the next
        // connect() activates us silently via ARM_KEEPALIVE without any popup.
        appLog(this.context, 'keepalive', 'TempAbility in standby (waiting for VPN connect)');
        return;
      }
      if (loadConfig(this.context).length === 0) {
        appLog(this.context, 'keepalive', 'TempAbility in standby (no saved config yet)');
        return;
      }
      way.putSync('vpnActive', true);
      way.putSync('userOff', false);
      await way.flush();
      const notifId: number = await this.acquire();
      if (!this.running) {
        appLog(this.context, 'keepalive', 'continuous task unavailable, leaving UI task in place');
        return;
      }
      // Hand off the single notification id to XrayVpnAbility FIRST (which
      // cancels any previous UI notification id) and tell the UI to stop its
      // own continuous task so ONLY 1 traffic notification exists.
      this.publishTaskId();
      publishScopedEvent(appEvent('KEEPALIVE_TAKEOVER', this.context), {}, this.context);
      const entry = selectedEntry(this.context);
      const name: string = entry === null ? '' : entry.name;
      try {
        await startVpn(vpnWant(this.context, true, true, notifId, name));
      } catch (error) {
      }
      way.putSync('tempKeepAlive', true);
      way.putSync('tempStartedAt', Date.now());
      way.putSync('tempHeartbeat', Date.now());
      await way.flush();
      this.startSupervisor();
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'arm failed: ' + (err.message ?? 'unknown'));
    } finally {
      this.arming = false;
      if (this.hasWindow) {
        this.context.moveAbilityToBackground().catch((): void => {
        });
      }
    }
  }

  private publishTaskId(): void {
    if (this.taskNotificationId < 0) {
      return;
    }
    publishScopedEvent(appEvent('TASK_ID', this.context), {
      'taskNotificationId': this.taskNotificationId
    }, this.context);
  }

  private clearKeepAliveFlag(): void {
    try {
      const way = preferences.getPreferencesSync(this.context, { name: 'way' });
      way.putSync('tempKeepAlive', false);
      way.putSync('tempStartedAt', 0);
      way.putSync('tempHeartbeat', 0);
      way.flush();
    } catch (error) {
    }
  }

  private async watchControlEvents(): Promise<void> {
    try {
      const evStop: string = appEvent('STOP_KEEPALIVE', this.context);
      const evPause: string = appEvent('PAUSE_KEEPALIVE', this.context);
      const evArm: string = appEvent('ARM_KEEPALIVE', this.context);
      const evReqId: string = appEvent('REQUEST_TASK_ID', this.context);
      const evNeedId: string = appEvent('NEED_TASK_ID', this.context);
      const sub: commonEventManager.CommonEventSubscriber = await commonEventManager.createSubscriber({
        events: [evStop, evPause, evArm, evReqId, evNeedId]
      });
      commonEventManager.subscribe(sub, (_error, data) => {
        if (data === undefined || data === null) {
          return;
        }
        const params: Record<string, Object> = data.parameters as Record<string, Object>;
        if (!verifyIpcParams(params, this.context)) {
          return;
        }
        const event: string = data.event ?? '';
        if (event === evNeedId) {
          const now: number = Date.now();
          if (this.shouldPreserveOnDestroy() && !this.acquiring &&
            (this.lastAcquireAt === 0 || now - this.lastAcquireAt >= 5000)) {
            this.running = false;
            this.taskId = -1;
            this.taskNotificationId = -1;
            this.acquire().then((id: number) => {
              if (this.running && id >= 0) {
                this.publishTaskId();
              }
            }).catch((): void => {
            });
          }
          return;
        }
        if (event === evReqId) {
          if (this.running) {
            this.publishTaskId();
            publishScopedEvent(appEvent('KEEPALIVE_TAKEOVER', this.context), {}, this.context);
          }
          return;
        }
        if (event === evArm) {
          appLog(this.context, 'keepalive', 'ARM_KEEPALIVE received');
          this.arm().catch((): void => {
          });
          return;
        }
        if (event === evPause) {
          appLog(this.context, 'keepalive', 'PAUSE_KEEPALIVE received (standby)');
          this.stopSupervisor();
          this.release();
          this.clearKeepAliveFlag();
          return;
        }
        appLog(this.context, 'keepalive', 'STOP_KEEPALIVE received');
        this.explicitStop = true;
        this.stopSupervisor();
        this.release();
        this.clearKeepAliveFlag();
        this.context.terminateSelf();
      });
      this.subscriber = sub;
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'watch control failed: ' + (err.message ?? 'unknown'));
    }
  }

  private async acquire(): Promise<number> {
    if (this.running && this.taskNotificationId >= 0) {
      return this.taskNotificationId;
    }
    if (this.acquiring) {
      return this.taskNotificationId;
    }
    this.acquiring = true;
    try {
      const agent: WantAgent = await this.buildAgent();
      if (!this.cancelWatchRegistered) {
        this.cancelWatchRegistered = true;
        // Filter by matching taskId so late cancellation of an older task
        // never clobbers a newly acquired live-view task.
        backgroundTaskManager.on('continuousTaskCancel',
          (cancelInfo: backgroundTaskManager.ContinuousTaskCancelInfo) => {
            if (this.taskId < 0 || (cancelInfo !== undefined && cancelInfo !== null &&
              cancelInfo.id !== undefined && cancelInfo.id !== this.taskId)) {
              return;
            }
            appLog(this.context, 'keepalive',
              'TempAbility continuous task canceled, retryCount=' + this.cancelRetryCount);
            this.running = false;
            this.taskId = -1;
            this.taskNotificationId = -1;
            if (!this.shouldPreserveOnDestroy() || this.cancelRetryCount >= 5) {
              this.clearKeepAliveFlag();
              return;
            }
            const delays: number[] = [1500, 3000, 6000, 12000, 20000];
            const delayMs: number = delays[Math.min(this.cancelRetryCount, delays.length - 1)];
            this.cancelRetryCount++;
            setTimeout(() => {
              if (!this.shouldPreserveOnDestroy()) {
                return;
              }
              this.acquire().then((id: number) => {
                if (this.running && id >= 0) {
                  this.publishTaskId();
                  publishScopedEvent(appEvent('KEEPALIVE_TAKEOVER', this.context), {}, this.context);
                }
              }).catch((): void => {
              });
            }, delayMs);
          });
      }
      this.cancelRetryCount = 0;
      this.lastAcquireAt = Date.now();
      await this.acquireDataTransfer(agent);
      if (this.running) {
        return this.taskNotificationId;
      }
      try {
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
        appLog(this.context, 'keepalive', 'continuous task: taskKeeping');
        this.running = true;
        this.taskNotificationId = -1;
        return -1;
      } catch (keepError) {
        const keepErr = keepError as BusinessError;
        appLog(this.context, 'keepalive', 'taskKeeping refused: ' + (keepErr.message ?? '?'));
      }
      return -1;
    } catch (error) {
      const err = error as BusinessError;
      appLog(this.context, 'keepalive', 'continuous task failed: ' + (err.message ?? 'unknown'));
      return -1;
    } finally {
      this.acquiring = false;
    }
  }

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
      saveTaskNotificationId(this.context, this.taskNotificationId);
      appLog(this.context, 'keepalive',
        'continuous task: dataTransfer id=' + this.taskId + ' notification=' + info.notificationId);
      this.running = true;
    } catch (error) {
      const err = error as BusinessError;
      try {
        await backgroundTaskManager.startBackgroundRunning(this.context,
          backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
        appLog(this.context, 'keepalive',
          'continuous task: dataTransfer legacy (' + (err.message ?? '?') + ')');
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
          bundleName: appBundleName(this.context),
          abilityName: 'EntryAbility'
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }

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
      way.putSync('tempHeartbeat', Date.now());
      await way.flush();
      const status = readStatus(this.context);
      const now: number = Date.now();
      // Do not fight a confirmed foreign VPN takeover.
      if (status !== null && status.state === 'stopped' &&
        status.message.indexOf('其他应用接管') >= 0) {
        return;
      }
      const stale: boolean = status === null ||
        ((status.state === 'running' || status.state === 'starting') &&
          now - status.updatedAt > 12000) ||
        status.state === 'stopped' || status.state === 'error';
      if (!stale) {
        return;
      }
      const last: number = way.getSync('watchdogLastStart', 0) as number;
      if (now - last < 15000) {
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
    this.cancelWatchRegistered = false;
    if (!this.running) {
      return;
    }
    this.running = false;
    this.taskNotificationId = -1;
    try {
      backgroundTaskManager.off('continuousTaskCancel');
      backgroundTaskManager.stopBackgroundRunning(this.context);
    } catch (error) {
    }
  }
}
