import { AbilityConstant, common, Configuration, EnvironmentCallback } from '@kit.AbilityKit';

// Subscribes to OS memory-pressure notifications inside the VPN extension process.
// Throttled to at most once every 30 s to avoid reclaim storms.
export class VpnMemoryPressureObserver {
  private appContext: common.ApplicationContext | null = null;
  private callbackId: number = -1;
  private generation: number = 0;
  private pending: boolean = false;
  private lastRequestAt: number = 0;
  private reclaim: (reason: string) => Promise<void>;
  private report: (message: string) => void;

  constructor(reclaim: (reason: string) => Promise<void>, report: (message: string) => void) {
    this.reclaim = reclaim;
    this.report = report;
  }

  start(appContext: common.ApplicationContext): void {
    this.stop();
    const generation: number = this.generation;
    const callback: EnvironmentCallback = {
      onConfigurationUpdated: (_config: Configuration): void => {
      },
      onMemoryLevel: (level: AbilityConstant.MemoryLevel): void => {
        if (generation !== this.generation || this.callbackId < 0 || this.pending) {
          return;
        }
        if (level !== AbilityConstant.MemoryLevel.MEMORY_LEVEL_LOW &&
          level !== AbilityConstant.MemoryLevel.MEMORY_LEVEL_CRITICAL &&
          level !== AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_LOW &&
          level !== AbilityConstant.MemoryLevel.MEMORY_LEVEL_BACKGROUND_CRITICAL) {
          return;
        }
        const now: number = Date.now();
        if (this.lastRequestAt > 0 && now - this.lastRequestAt < 30000) {
          return;
        }
        this.lastRequestAt = now;
        this.pending = true;
        Promise.resolve().then(async (): Promise<void> => {
          if (generation === this.generation && this.callbackId >= 0) {
            await this.reclaim('os-level-' + level);
          }
        }).catch(() => {
          this.report('VPN memory-pressure reclaim failed');
        }).finally(() => {
          if (generation === this.generation) {
            this.pending = false;
          }
        });
      }
    };
    try {
      this.appContext = appContext;
      this.callbackId = appContext.on('environment', callback);
    } catch (error) {
      this.appContext = null;
      this.callbackId = -1;
      this.report('VPN memory-pressure observer unavailable');
    }
  }

  stop(): void {
    this.generation++;
    this.pending = false;
    const context = this.appContext;
    const id: number = this.callbackId;
    this.appContext = null;
    this.callbackId = -1;
    if (context !== null && id >= 0) {
      try {
        context.off('environment', id).catch(() => {
        });
      } catch (error) {
      }
    }
  }
}
