import { bundleManager, common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { rpc } from '@kit.IPCKit';
import { inspectVpnStatus } from './VpnStatusPolicy';
import { recordLifecycle } from './LocalDiagnostics';

const BIND_FRESH_MS: number = 3000;
const BIND_RETRY_MS: number = 10000;

// Based on Tailscale-OHOS PR #22 (upstream 5defb85198373370ecf83d22e7fc113f4f44ec42).
// The platform keeps a real UI-to-VPN connection; it does not simulate another
// background activity. Keep this object in the UIAbility, not a page component.
export class VpnExtensionBinding {
  private context?: common.UIAbilityContext;
  private timer: number = -1;
  private connectionId: number = -1;
  private generation: number = 0;
  private nextBindAtMs: number = 0;
  private heartbeatAfterMs: number = 0;
  private manuallyStopped: boolean = false;

  start(context: common.UIAbilityContext): void {
    if (this.context !== undefined && this.context !== context) {
      this.stop();
    }
    this.context = context;
    if (this.timer < 0) {
      this.timer = setInterval(() => this.reconcile(), 1000);
    }
    this.reconcile();
  }

  stop(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.unbind();
    this.context = undefined;
  }

  allowNewConnection(): void {
    this.manuallyStopped = false;
    this.heartbeatAfterMs = Date.now();
    this.nextBindAtMs = 0;
  }

  beforeManualStop(): void {
    // Suppress binding before requesting the stop. Late callbacks and a last
    // still-fresh heartbeat must not rebind or cold-start a user-stopped VPN.
    this.manuallyStopped = true;
    this.unbind();
  }

  private reconcile(): void {
    const context = this.context;
    if (context === undefined || this.manuallyStopped) {
      return;
    }
    try {
      const now: number = Date.now();
      const observation = inspectVpnStatus(
        fileIo.readTextSync(`${context.filesDir}/vpn-probe-status.txt`), now);
      if (observation.kind === 'stopped' || observation.kind === 'failed') {
        this.unbind();
        return;
      }
      // Unknown/stale status never tears down an existing binding. A new bind
      // is allowed only with recent evidence that the actual TUN is running.
      if (this.connectionId >= 0 || observation.kind !== 'running' ||
        !/(?:^|\|\s*)tun=true(?:\s|$)/.test(observation.status) ||
        now - observation.heartbeatMs > BIND_FRESH_MS ||
        observation.heartbeatMs <= this.heartbeatAfterMs || now < this.nextBindAtMs) {
        return;
      }
      this.bind(context);
    } catch (_error) {
      // File availability is not evidence that an existing session stopped.
    }
  }

  private bind(context: common.UIAbilityContext): void {
    const generation: number = ++this.generation;
    const options: common.ConnectOptions = {
      onConnect: (_element: bundleManager.ElementName, _remote: rpc.IRemoteObject): void => {
        if (generation === this.generation) {
          recordLifecycle(context.filesDir, 'ui', 'vpn-bind-connected');
        }
      },
      onDisconnect: (_element: bundleManager.ElementName): void => {
        if (generation === this.generation) {
          this.invalidate(true);
          recordLifecycle(context.filesDir, 'ui', 'vpn-bind-disconnected');
        }
      },
      onFailed: (code: number): void => {
        if (generation === this.generation) {
          this.invalidate(true);
          recordLifecycle(context.filesDir, 'ui', 'vpn-bind-failed', -1, 0, 0, code);
        }
      }
    };
    const want: Want = {
      bundleName: 'com.example.tailscaleharmony',
      abilityName: 'TailscaleVpnExtensionAbility',
      parameters: { tailscaleBindOnly: true }
    };
    try {
      const id: number = context.connectServiceExtensionAbility(want, options);
      if (generation !== this.generation) {
        this.disconnectHandle(context, id);
        return;
      }
      if (id < 0) {
        this.invalidate(true);
        recordLifecycle(context.filesDir, 'ui', 'vpn-bind-refused', -1, 0, 0, id);
        return;
      }
      this.connectionId = id;
      recordLifecycle(context.filesDir, 'ui', 'vpn-bind-requested');
    } catch (error) {
      if (generation === this.generation) {
        this.invalidate(true);
        recordLifecycle(context.filesDir, 'ui', 'vpn-bind-error', -1, 0, 0,
          (error as BusinessError).code ?? -1);
      }
    }
  }

  private invalidate(retryLater: boolean): void {
    this.generation++;
    this.connectionId = -1;
    this.heartbeatAfterMs = Date.now();
    this.nextBindAtMs = retryLater ? Date.now() + BIND_RETRY_MS : 0;
  }

  private unbind(): void {
    const context = this.context;
    const id: number = this.connectionId;
    this.invalidate(false);
    if (context !== undefined) {
      this.disconnectHandle(context, id);
    }
  }

  private disconnectHandle(context: common.UIAbilityContext, id: number): void {
    if (id < 0) {
      return;
    }
    try {
      context.disconnectServiceExtensionAbility(id).catch((): void => {
        recordLifecycle(context.filesDir, 'ui', 'vpn-unbind-unavailable');
      });
    } catch (_error) {
      recordLifecycle(context.filesDir, 'ui', 'vpn-unbind-unavailable');
    }
  }
}

export const vpnExtensionBinding: VpnExtensionBinding = new VpnExtensionBinding();
