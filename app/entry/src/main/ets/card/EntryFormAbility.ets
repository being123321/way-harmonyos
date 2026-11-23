import { FormExtensionAbility, formBindingData, formInfo } from '@kit.FormKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import type { Want } from '@kit.AbilityKit';
import type { common } from '@kit.AbilityKit';

// 桌面卡片只做一次"转发意图"，不持有隧道。
//
// This file deliberately does NOT import AppLog/Xray: AppLog pulls in Xray,
// which loads libentry.so and the VPN kit. The form extension runs in its own,
// memory-tight process that only needs FormKit; pulling the 26 MB core in just
// to append a log line made the form process start slowly (and, on some ROMs,
// fail before onAddForm is reached, so the card never appeared). Keep the card
// ability self-contained and log through fileIo directly.
function cardLog(context: common.Context, message: string): void {
  try {
    const dir: string = context.filesDir + '/xray';
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const date = new Date();
    const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
    const stamp: string = date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
      ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
    const path: string = dir + '/app.log';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, stamp + ' [card] ' + message + '\n');
    fs.closeSync(file);
  } catch (error) {
  }
}

export default class WayFormAbility extends FormExtensionAbility {
  // Called synchronously when the launcher asks whether the card is ready.
  // READY is the normal state for a card that needs no initial network data.
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    const params: Record<string, Object> = want.parameters ?? {};
    const dimension: string = (params['ohos.extra.param.key.form_dimension'] as string) ?? '';
    cardLog(this.context, 'form added' + (dimension.length > 0 ? ' (' + dimension + ')' : ''));
    return formBindingData.createFormBindingData({});
  }

  onFormEvent(formId: string, message: string): void {
    cardLog(this.context, 'form event: ' + message);
  }

  onRemoveForm(formId: string): void {
    cardLog(this.context, 'form removed');
  }
}
