import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
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
    const size: number = fs.statSync(path).size;
    if (size === 0) {
      return '';
    }
    const readLen: number = Math.min(limit, size);
    const buffer: ArrayBuffer = new ArrayBuffer(readLen);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      fs.readSync(file.fd, buffer, { offset: size - readLen, length: readLen });
    } finally {
      fs.closeSync(file);
    }
    return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
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
