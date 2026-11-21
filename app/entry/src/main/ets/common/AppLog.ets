import { fileIo as fs } from '@kit.CoreFileKit';
import type { common } from '@kit.AbilityKit';
import { ensureXrayDir, xrayDir } from './Xray';

// Tiny append-only log next to the tunnel logs, so failures in the UI process
// (import, geodata download) can be inspected over hdc without a debugger.
export function appLog(context: common.Context, tag: string, message: string): void {
  try {
    ensureXrayDir(context);
    const path: string = xrayDir(context) + '/app.log';
    const line: string = localStamp() + ' [' + tag + '] ' + message + '\n';
    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
    fs.writeSync(file.fd, line);
    fs.closeSync(file);
  } catch (error) {
  }
}

export function readAppLog(context: common.Context, limit: number): string {
  const path: string = xrayDir(context) + '/app.log';
  try {
    if (!fs.accessSync(path)) {
      return '';
    }
    const text: string = fs.readTextSync(path);
    return text.length > limit ? text.substring(text.length - limit) : text;
  } catch (error) {
    return '';
  }
}

// Local wall-clock stamp; the device logs used to be UTC and looked 8h off.
export function localStamp(): string {
  const date = new Date();
  const pad = (value: number): string => value < 10 ? '0' + value : '' + value;
  return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) +
    ' ' + pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
}
