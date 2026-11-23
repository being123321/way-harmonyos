import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import type { Want } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { cardLog } from './CardLog';
import { WATCHDOG_FORM_NAME, checkAndRevive } from './Watchdog';

// Desktop cards:
//   * way_widget    - the visible connect/disconnect card;
//   * way_watchdog  - a 1x1 transparent card whose lifecycle acts as an
//                     independent VPN recovery trigger when the UI process is
//                     gone (see Watchdog.ets for the platform lifetime limits).
export default class WayFormAbility extends FormExtensionAbility {
  private watchdogTimer: number = -1;

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> = want.parameters ?? {};
    const formName: string = (params['ohos.extra.param.key.form_name'] as string) ?? '';
    cardLog(this.context, 'form added: ' + (formName.length > 0 ? formName : 'unknown'));
    if (formName === WATCHDOG_FORM_NAME) {
      this.runWatchdog('');
      // onAddForm has no formId; look the published form up shortly after and
      // ask for the first refresh in 5 minutes.
      setTimeout(() => {
        this.scheduleRefresh();
      }, 1500);
    }
    return formBindingData.createFormBindingData({});
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    cardLog(this.context, 'form updated: ' + formId);
    this.runWatchdog(formId);
  }

  private runWatchdog(formId: string): void {
    checkAndRevive(this.context).then((result: string) => {
      cardLog(this.context, 'watchdog: ' + result);
    }).catch((error: BusinessError) => {
      cardLog(this.context, 'watchdog error: ' + JSON.stringify(error));
    });
    if (formId.length > 0) {
      formProvider.setFormNextRefreshTime(formId, 5).catch((error: BusinessError) => {
        cardLog(this.context, 'watchdog refresh failed: ' + JSON.stringify(error));
      });
    }
    // The form process normally lives ~10 s after the last callback; keep a
    // short in-process loop so a VPN that dies during that window is caught.
    if (this.watchdogTimer === -1) {
      this.watchdogTimer = setInterval(() => {
        checkAndRevive(this.context).then((result: string) => {
          cardLog(this.context, 'watchdog tick: ' + result);
        }).catch((error: BusinessError) => {
          cardLog(this.context, 'watchdog tick error: ' + JSON.stringify(error));
        });
      }, 5000);
    }
  }

  private scheduleRefresh(): void {
    formProvider.getPublishedRunningFormInfos().then((forms: formInfo.RunningFormInfo[]) => {
      for (const form of forms) {
        if (form.formName === WATCHDOG_FORM_NAME) {
          this.runWatchdog(form.formId);
          return;
        }
      }
      cardLog(this.context, 'watchdog form not published yet');
    }).catch((error: BusinessError) => {
      cardLog(this.context, 'watchdog form lookup failed: ' + JSON.stringify(error));
    });
  }

  onFormEvent(formId: string, message: string): void {
    cardLog(this.context, 'form event: ' + message);
  }

  onRemoveForm(formId: string): void {
    cardLog(this.context, 'form removed: ' + formId);
    this.stopWatchdog();
  }

  onStop(): void {
    this.stopWatchdog();
  }

  private stopWatchdog(): void {
    if (this.watchdogTimer !== -1) {
      clearInterval(this.watchdogTimer);
      this.watchdogTimer = -1;
    }
  }
}
