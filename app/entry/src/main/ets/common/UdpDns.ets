import { socket } from '@kit.NetworkKit';
import { isFakeOrReservedIp } from './Latency';

// Plain-UDP DNS resolver used for probe bootstrap (both pre-connect and inside
// the protectProcessNet() VPN extension so probes never receive FakeIP 198.19.x.x).
const DNS_SERVERS: string[] = ['223.5.5.5', '119.29.29.29', '114.114.114.114'];

function buildQuery(id: number, host: string): Uint8Array {
  const labels: string[] = host.split('.');
  let size: number = 12 + 1 + 4;
  for (const label of labels) {
    size += 1 + label.length;
  }
  const buf: Uint8Array = new Uint8Array(size);
  buf[0] = (id >> 8) & 0xff;
  buf[1] = id & 0xff;
  buf[2] = 0x01;
  buf[3] = 0x00;
  buf[4] = 0x00;
  buf[5] = 0x01;
  let off: number = 12;
  for (const label of labels) {
    buf[off++] = label.length & 0xff;
    for (let i = 0; i < label.length; i++) {
      buf[off++] = label.charCodeAt(i) & 0xff;
    }
  }
  buf[off++] = 0;
  buf[off++] = 0x00;
  buf[off++] = 0x01;
  buf[off++] = 0x00;
  buf[off++] = 0x01;
  return buf;
}

function skipName(data: Uint8Array, start: number): number {
  let off: number = start;
  while (off < data.length) {
    const len: number = data[off];
    if (len === 0) {
      return off + 1;
    }
    if ((len & 0xc0) === 0xc0) {
      return off + 2;
    }
    off += 1 + len;
  }
  return off;
}

function parseAnswer(data: Uint8Array, id: number): string[] {
  const ips: string[] = [];
  if (data.length < 12) {
    return ips;
  }
  if (((data[0] << 8) | data[1]) !== id) {
    return ips;
  }
  const questions: number = (data[4] << 8) | data[5];
  const answers: number = (data[6] << 8) | data[7];
  let off: number = 12;
  for (let i = 0; i < questions; i++) {
    off = skipName(data, off) + 4;
  }
  for (let i = 0; i < answers && off + 10 <= data.length; i++) {
    off = skipName(data, off);
    if (off + 10 > data.length) {
      break;
    }
    const type: number = (data[off] << 8) | data[off + 1];
    const length: number = (data[off + 8] << 8) | data[off + 9];
    off += 10;
    if (type === 1 && length === 4 && off + 4 <= data.length) {
      const ip: string = data[off].toString() + '.' + data[off + 1].toString() + '.' +
        data[off + 2].toString() + '.' + data[off + 3].toString();
      if (!isFakeOrReservedIp(ip) && ips.indexOf(ip) < 0) {
        ips.push(ip);
      }
    }
    off += length;
  }
  return ips;
}

function queryOnce(host: string, server: string, timeoutMs: number): Promise<string[]> {
  const id: number = Math.floor(Math.random() * 65535);
  const udp = socket.constructUDPSocketInstance();
  return new Promise<string[]>((resolve) => {
    let settled: boolean = false;
    const finish = (ips: string[]): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      try {
        udp.off('message');
      } catch (error) {
      }
      try {
        udp.close();
      } catch (error) {
      }
      resolve(ips);
    };
    const timer: number = setTimeout(() => {
      finish([]);
    }, timeoutMs);
    try {
      udp.on('message', (value: socket.SocketMessageInfo) => {
        finish(parseAnswer(new Uint8Array(value.message), id));
      });
      udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
        const packet: Uint8Array = buildQuery(id, host);
        udp.send({
          data: packet.buffer as ArrayBuffer,
          address: { address: server, port: 53, family: 1 }
        }).catch(() => {
          finish([]);
        });
      }).catch(() => {
        finish([]);
      });
    } catch (error) {
      finish([]);
    }
  });
}

// Races all plain-UDP resolvers concurrently and returns the first clean IPv4 answer.
export async function resolveUdp(host: string, timeoutMs: number): Promise<string[]> {
  return new Promise<string[]>((resolve) => {
    let settled: boolean = false;
    let remaining: number = DNS_SERVERS.length;
    const done = (ips: string[]): void => {
      if (settled) {
        return;
      }
      settled = true;
      resolve(ips);
    };
    for (const server of DNS_SERVERS) {
      queryOnce(host, server, timeoutMs).then((ips: string[]) => {
        if (ips.length > 0) {
          done(ips);
          return;
        }
        remaining--;
        if (remaining <= 0) {
          done([]);
        }
      }).catch(() => {
        remaining--;
        if (remaining <= 0) {
          done([]);
        }
      });
    }
  });
}
