import { fileIo as fs } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';

// The card/form process must stay light: it must not import AppLog/Xray,
// because that chain loads the 26 MB native core. This small helper writes the
// same app.log lines as AppLog without any of that dependency.
export function cardLog(context: common.Context, message: string): void {
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
