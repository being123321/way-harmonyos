import { socket } from '@kit.NetworkKit';

// UDP/QUIC reachability probe for UDP-only nodes such as Hysteria2.
//
// A QUIC server answers a long-header packet with an unsupported version using
// a Version Negotiation packet, so even without a full TLS handshake a reply
// proves the endpoint is alive and yields a round-trip time. A silent server
// (or a filtered port) simply times out.
export async function udpQuicLatency(host: string, port: number, timeoutMs: number): Promise<number> {
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
        finish(Date.now() - start);
      });
      udp.bind({ address: '0.0.0.0', port: 0, family: 1 }).then(() => {
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
          udp.send({ data: packet.buffer as ArrayBuffer, address: { address: host, port: port, family: 1 } }).catch(() => {
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
