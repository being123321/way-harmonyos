import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import type { Want } from '@kit.AbilityKit';
import { cardLog } from './CardLog';

// Visible 2x2 quick-toggle card. The card process must stay light: it uses
// CardLog (CoreFileKit only) instead of AppLog/Xray, which would load the
// 26 MB native core in the form sandbox.
export default class WayFormAbility extends FormExtensionAbility {
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> = want.parameters ?? {};
    const formName: string = (params['ohos.extra.param.key.form_name'] as string) ?? '';
    cardLog(this.context, 'form added: ' + (formName.length > 0 ? formName : 'unknown'));
    return formBindingData.createFormBindingData({});
  }

  onFormEvent(formId: string, message: string): void {
    cardLog(this.context, 'form event: ' + message);
  }

  onRemoveForm(formId: string): void {
    cardLog(this.context, 'form removed: ' + formId);
  }
}
