import { Want } from '@kit.AbilityKit';
import { vpnExtension, VpnExtensionAbility } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import nativeBridge from 'libtailscale_ohos.so';
import { PhysicalDNS } from '../services/PhysicalDNS';

const DOMAIN = 0x0000;
const TAG = 'TailscaleVpn';
const BUNDLE_NAME = 'com.example.tailscaleharmony';

interface BackendHealthSnapshot {
  status: string;
}

export default class TailscaleVpnExtensionAbility extends VpnExtensionAbility {
  private vpnConnection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private statusTimer: number = -1;
  private statusUpdateInFlight: boolean = false;
  private destroyed: boolean = false;
  private latestStatus: string = '';
  private physicalDNS: PhysicalDNS = new PhysicalDNS();
  private physicalDNSStatus: string = 'Physical DNS pending';

  onCreate(want: Want): void {
    this.writeStatus('VPN extension lifecycle entered');
    hilog.info(DOMAIN, TAG, 'VPN extension created. ability=%{public}s', want.abilityName ?? '');
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
      this.writeStatus('VPN connection object created');
      this.startStartupHeartbeat();
      this.createProbeTun().catch((error: BusinessError) => {
        this.failStartup(`FAILED | VPN startup | code=${error.code ?? -1}`);
        hilog.error(DOMAIN, TAG, 'VPN startup failed. code=%{public}d', error.code ?? -1);
      });
    } catch (error) {
      const businessError = error as BusinessError;
      this.failStartup(`FAILED | VPN connection object | code=${businessError.code ?? -1}`);
      hilog.error(DOMAIN, TAG, 'VPN connection initialization failed. code=%{public}d',
        businessError.code ?? -1);
    }
  }

  private async createProbeTun(): Promise<void> {
    const connection = this.vpnConnection;
    if (connection === undefined) {
      return;
    }

    // HarmonyOS starts a VPN Extension in its own application process. The
    // UI process may have already authenticated, but its in-memory Go backend
    // is not shared with this process. Restore the backend from the persistent
    // state directory here and wait until the assigned addresses are ready.
    const backendConfigText: string = await this.restoreBackendVpnConfig();
    if (this.destroyed) {
      return;
    }
    if (backendConfigText.startsWith('FAILED')) {
      this.failStartup(backendConfigText);
      return;
    }
    const configParts: string[] = backendConfigText.split('|');
    if (configParts.length < 2 || configParts[0].length === 0) {
      this.failStartup('FAILED | VPN config | invalid address payload');
      return;
    }
    const addresses: vpnExtension.LinkAddress[] = [{
      address: { address: configParts[0], family: 1 },
      prefixLength: 32
    }];
    const routes: vpnExtension.RouteInfo[] = [{
      interface: 'vpn-tun',
      destination: {
        address: { address: '100.64.0.0', family: 1 },
        prefixLength: 10
      },
      gateway: { address: '0.0.0.0', family: 1 },
      hasGateway: false,
      isDefaultRoute: false
    }];
    if (configParts[1].length > 0) {
      addresses.push({
        address: { address: configParts[1], family: 2 },
        prefixLength: 128
      });
      routes.push({
        interface: 'vpn-tun',
        destination: {
          address: { address: 'fd7a:115c:a1e0::', family: 2 },
          prefixLength: 48
        },
        gateway: { address: '::', family: 2 },
        hasGateway: false,
        isDefaultRoute: false
      });
    }
    if (configParts.length >= 3 && configParts[2].length > 0) {
      const dynamicRoutes: string[] = configParts[2].split(',');
      for (const routeText of dynamicRoutes) {
        const prefixParts: string[] = routeText.split('/');
        if (prefixParts.length !== 2) {
          continue;
        }
        const family: number = prefixParts[0].includes(':') ? 2 : 1;
        const prefixLength: number = Number(prefixParts[1]);
        routes.push({
          interface: 'vpn-tun',
          destination: {
            address: { address: prefixParts[0], family: family },
            prefixLength: prefixLength
          },
          gateway: { address: family === 2 ? '::' : '0.0.0.0', family: family },
          hasGateway: false,
          isDefaultRoute: prefixLength === 0
        });
      }
    }
    const useTailscaleDNS: boolean = configParts.length >= 4 && configParts[3] === 'true';
    if (useTailscaleDNS && !this.physicalDNSStatus.startsWith('OK')) {
      this.failStartup(this.physicalDNSStatus);
      return;
    }
    const config: vpnExtension.VpnConfig = {
      addresses: addresses,
      routes: routes,
      dnsAddresses: useTailscaleDNS ? ['100.100.100.100'] : [],
      mtu: 1280,
      isIPv4Accepted: true,
      isIPv6Accepted: configParts[1].length > 0,
      isBlocking: false,
      blockedApplications: [BUNDLE_NAME]
    };

    // A development reinstall can terminate the prior extension before its
    // asynchronous onDestroy cleanup finishes. destroy() is scoped to this
    // application's VPN connection and makes startup idempotent.
    this.writeStatus('Removing stale application VPN instance');
    try {
      await connection.destroy();
    } catch (_cleanupError) {
      // No existing connection is also a valid clean state.
    }

    if (this.destroyed) {
      return;
    }
    try {
      this.writeStatus('VPN probe TUN creation pending');
      this.tunFd = await connection.create(config);
      if (this.destroyed) {
        await connection.destroy();
        return;
      }
      const probeStatus: string = nativeBridge.tunFdProbe(this.tunFd);
      if (probeStatus.startsWith('OK')) {
        const restartStatus: string = nativeBridge.backendRestartWithTun(
          `${this.context.filesDir}/tailscale`, this.deviceModel(), this.tunFd);
        const finalStatus: string = await this.waitForVpnBackend(restartStatus);
        if (this.destroyed) {
          return;
        }
        if (!finalStatus.includes('state=Running')) {
          this.failStartup(finalStatus);
          return;
        }
        this.writeStatus(finalStatus);
        this.startStatusUpdates();
        // Optional diagnostics must not delay heartbeats or fail a working VPN.
        this.runPeerProbes().catch(() => {
          this.writePeerStatus('FAILED | peer diagnostics | unavailable');
        });
      } else {
        this.failStartup(`FAILED | VPN TUN descriptor | ${probeStatus}`);
      }
      hilog.info(DOMAIN, TAG, 'VPN probe TUN created. bridge=%{public}s', probeStatus);
    } catch (error) {
      const businessError = error as BusinessError;
      this.failStartup(`FAILED | VPN probe TUN | code=${businessError.code ?? -1}`);
      hilog.error(DOMAIN, TAG, 'VPN probe TUN creation failed. code=%{public}d',
        businessError.code ?? -1);
    }
  }

  private async restoreBackendVpnConfig(): Promise<string> {
    await this.physicalDNS.start((status: string) => {
      this.physicalDNSStatus = status;
    });
    if (this.destroyed) {
      return 'FAILED | VPN startup | cancelled';
    }
    const stateDir: string = `${this.context.filesDir}/tailscale`;
    const startStatus: string = nativeBridge.backendStart(stateDir, this.deviceModel());
    if (startStatus.startsWith('FAILED')) {
      return startStatus;
    }
    this.writeStatus('VPN backend starting | restoring authenticated session');
    let configStatus: string = 'FAILED | VPN config | backend restore timeout';
    let peerBootstrapAttempted: boolean = false;
    // The native startup restores network and exit-node preferences with two
    // bounded 15-second waits before exposing its current backend state.
    const deadlineMs: number = Date.now() + 45000;
    while (Date.now() < deadlineMs) {
      if (this.destroyed) {
        return 'FAILED | VPN startup | cancelled';
      }
      configStatus = await nativeBridge.backendVpnConfigAsync();
      if (!configStatus.startsWith('FAILED')) {
        return configStatus;
      }
      if (!peerBootstrapAttempted && !this.destroyed) {
        const snapshotText: string = await nativeBridge.backendSnapshot();
        const status: string = (JSON.parse(snapshotText) as BackendHealthSnapshot).status;
        if (this.canBootstrapPeer(status)) {
          peerBootstrapAttempted = true;
          await this.bootstrapPeer();
          continue;
        }
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 250);
      });
    }
    return configStatus;
  }

  private deviceModel(): string {
    const marketName: string = deviceInfo.marketName.trim();
    if (marketName.length > 0 && marketName !== 'default') {
      return marketName;
    }
    return deviceInfo.productModel.trim();
  }

  private async waitForVpnBackend(initialStatus: string): Promise<string> {
    if (initialStatus.startsWith('FAILED')) {
      return initialStatus;
    }
    let backendStatus: string = initialStatus;
    let peerBootstrapAttempted: boolean = false;
    const deadlineMs: number = Date.now() + 45000;
    while (Date.now() < deadlineMs) {
      if (this.destroyed) {
        return 'FAILED | VPN startup | cancelled';
      }
      const snapshotText: string = await nativeBridge.backendSnapshot();
      backendStatus = (JSON.parse(snapshotText) as BackendHealthSnapshot).status;
      if (backendStatus.includes('state=Running') || backendStatus.startsWith('FAILED')) {
        return backendStatus;
      }
      if (!peerBootstrapAttempted && this.canBootstrapPeer(backendStatus)) {
        peerBootstrapAttempted = true;
        await this.bootstrapPeer();
        continue;
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 250);
      });
    }
    return 'FAILED | VPN backend | restart timeout';
  }

  private canBootstrapPeer(status: string): boolean {
    return !this.destroyed && status.includes('state=Starting') &&
      /tailscaleIPs=[1-9][0-9]*(?: |$)/.test(status);
  }

  private async bootstrapPeer(): Promise<void> {
    this.writeStatus('VPN backend starting | establishing peer transport');
    try {
      // Native TSMP probing has a 10-second context and cannot grant login.
      // A live peer can advance Starting when a DERP relay is unavailable.
      this.writePeerStatus(await nativeBridge.backendPeerProbeAsync());
    } catch (_error) {
      this.writePeerStatus('FAILED | peer bootstrap | unavailable');
    }
  }

  private startStartupHeartbeat(): void {
    this.statusTimer = setInterval(() => {
      this.writeStatus(this.latestStatus);
    }, 1000);
  }

  private async runPeerProbes(): Promise<void> {
    await nativeBridge.backendArmMagicDNSProbeAsync();
    if (!this.destroyed) {
      this.writePeerStatus(await nativeBridge.backendPeerProbeAsync());
    }
  }

  private stopStatusUpdates(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
  }

  private failStartup(status: string): void {
    if (this.destroyed) {
      return;
    }
    this.stopStatusUpdates();
    this.physicalDNS.stop();
    this.writeStatus(status);
    this.cleanupBackend();
    const connection = this.vpnConnection;
    if (connection !== undefined) {
      connection.destroy().catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'Failed VPN cleanup. code=%{public}d', error.code ?? -1);
      });
    }
  }

  private cleanupBackend(): void {
    try {
      nativeBridge.backendStopAsync().then((status: string) => {
        if (status.startsWith('FAILED')) {
          hilog.error(DOMAIN, TAG, 'VPN backend cleanup failed');
        }
      }).catch(() => {
        hilog.error(DOMAIN, TAG, 'VPN backend cleanup unavailable');
      });
    } catch (_error) {
      hilog.error(DOMAIN, TAG, 'VPN backend cleanup could not start');
    }
  }

  private startStatusUpdates(): void {
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
    }
    this.statusTimer = setInterval(() => {
      if (this.destroyed || this.statusUpdateInFlight) {
        return;
      }
      this.statusUpdateInFlight = true;
      nativeBridge.backendSnapshot()
        .then((snapshotText: string) => {
          const snapshot: BackendHealthSnapshot = JSON.parse(snapshotText) as BackendHealthSnapshot;
          this.writeStatus(snapshot.status);
        })
        .catch(() => {
          this.writeStatus('FAILED | VPN backend | status unavailable');
        })
        .finally(() => {
          this.statusUpdateInFlight = false;
        });
    }, 1000);
  }

  private writePeerStatus(status: string): void {
    if (this.destroyed) {
      return;
    }
    this.writeTextFile(`${this.context.filesDir}/vpn-peer-probe-status.txt`, status);
  }

  private writeStatus(status: string): void {
    if (this.destroyed) {
      return;
    }
    this.latestStatus = status;
    this.writeTextFile(`${this.context.filesDir}/vpn-probe-status.txt`,
      `${status} | physicalDNS=${this.physicalDNSStatus} | heartbeatMs=${Date.now()}`);
  }

  private writeTextFile(path: string, content: string): void {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, content);
    } catch (_error) {
      // Status persistence is best-effort and must never stop VPN startup.
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_error) {
          // The descriptor may already be closed after a platform write failure.
        }
      }
    }
  }

  onDestroy(): void {
    this.stopStatusUpdates();
    this.physicalDNS.stop();
    this.writeStatus('VPN extension destroyed');
    this.destroyed = true;
    this.cleanupBackend();
    const connection = this.vpnConnection;
    this.vpnConnection = undefined;
    this.tunFd = -1;
    if (connection !== undefined) {
      connection.destroy().catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'VPN destroy failed. code=%{public}d', error.code);
      });
    }
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
  }
}
