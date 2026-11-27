import { connection, socket } from '@kit.NetworkKit';
import { resolveUdp } from './UdpDns';

function isIpv4Literal(host: string): boolean {
  const parts: string[] = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (const part of parts) {
    const value: number = parseInt(part, 10);
    if (isNaN(value) || value < 0 || value > 255 || String(value) !== part) {
      return false;
    }
  }
  return true;
}

export function isIpAddressLiteral(host: string): boolean {
  return host.indexOf(':') >= 0 || isIpv4Literal(host);
}

// Reject FakeIP (198.18.0.0/15), unspecified (0.x), and loopback (127.x / ::1)
// so DNS responses intercepted by TUN FakeIP can never poison probe bootstrap.
export function isFakeOrReservedIp(ip: string): boolean {
  const trimmed: string = ip.trim();
  if (trimmed.length === 0) {
    return true;
  }
  if (trimmed === '::1' || trimmed === '::') {
    return true;
  }
  return trimmed.startsWith('198.18.') ||
    trimmed.startsWith('198.19.') ||
    trimmed.startsWith('127.') ||
    trimmed.startsWith('0.');
}

// HarmonyOS TCPSocket.connect / UDPSocket.send require an IP address literal
// matching the `family` field (1=IPv4, 2=IPv6). Resolve domain names first.
export async function resolveHostIp(host: string, timeoutMs: number): Promise<string> {
  const trimmed: string = host.trim();
  if (trimmed.length === 0) {
    return '';
  }
  if (isIpAddressLiteral(trimmed)) {
    return trimmed;
  }
  const budget: number = Math.min(timeoutMs, 1500);
  try {
    const udpIps: string[] = await resolveUdp(trimmed, Math.min(budget, 800));
    for (const candidate of udpIps) {
      if (!isFakeOrReservedIp(candidate)) {
        return candidate;
      }
    }
  } catch (error) {
  }
  try {
    const timer: Promise<connection.NetAddress[]> = new Promise((resolve) => {
      setTimeout((): void => {
        resolve([]);
      }, budget);
    });
    const list: connection.NetAddress[] = await Promise.race([
      connection.getAddressesByName(trimmed),
      timer
    ]);
    for (const item of list) {
      if (!isFakeOrReservedIp(item.address)) {
        return item.address;
      }
    }
  } catch (error) {
  }
  return '';
}

// UDP/QUIC reachability probe for UDP-only nodes such as Hysteria2.
//
// A QUIC server answers a long-header packet with an unsupported version using
// a Version Negotiation packet, so even without a full TLS handshake a reply
// proves the endpoint is alive and yields a round-trip time. A silent server
// (or a filtered port) simply times out.
export async function udpQuicLatency(host: string, port: number, timeoutMs: number): Promise<number> {
  const ip: string = await resolveHostIp(host, timeoutMs);
  if (ip.length === 0) {
    return -1;
  }
  const family: number = ip.indexOf(':') >= 0 ? 2 : 1;
  const bindAddr: string = family === 2 ? '::' : '0.0.0.0';
  const udp = socket.constructUDPSocketInstance();
  const start: number = Date.now();
  return new Promise<number>((resolve) => {
    let settled: boolean = false;
    const finish = (value: number): void => {
      if (settled) {
        return;
      }
      settled = true;
      try {
        udp.off('message');
      } catch (error) {
      }
      try {
        udp.close();
      } catch (error) {
      }
      resolve(value);
    };
    const timer: number = setTimeout(() => {
      finish(-1);
    }, timeoutMs);
    try {
      udp.on('message', () => {
        clearTimeout(timer);
        const elapsed: number = Date.now() - start;
        finish(elapsed > 0 ? elapsed : 1);
      });
      udp.bind({ address: bindAddr, port: 0, family: family }).then(() => {
        {
          const packet: Uint8Array = new Uint8Array(1280);
          // Long header, fixed bit, random connection id, unsupported version.
          packet[0] = 0xc0;
          packet[1] = 0x0a;
          packet[2] = 0x0a;
          packet[3] = 0x0a;
          packet[4] = 0x0a;
          for (let i = 5; i < packet.length; i++) {
            packet[i] = (i * 37) & 0xff;
          }
          udp.send({ data: packet.buffer as ArrayBuffer, address: { address: ip, port: port, family: family } }).catch(() => {
            clearTimeout(timer);
            finish(-1);
          });
        }
      }).catch(() => {
        clearTimeout(timer);
        finish(-1);
      });
    } catch (error) {
      clearTimeout(timer);
      finish(-1);
    }
  });
}
