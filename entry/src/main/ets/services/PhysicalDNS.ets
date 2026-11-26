import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import nativeBridge from 'libtailscale_ohos.so';

interface BaseDNSConfig {
  nameservers: string[];
}

// Each backend process owns a monitor. Resolver addresses stay in memory and
// are never included in status messages or logs.
export class PhysicalDNS {
  private timer: number = -1;
  private generation: number = 0;
  private active: boolean = false;
  private pending?: Promise<string>;
  private appliedConfig: string = '';
  private appliedNetId: number = -1;
  private onStatus?: (status: string) => void;

  async start(onStatus: (status: string) => void): Promise<string> {
    this.active = true;
    this.onStatus = onStatus;
    const generation: number = this.generation;
    // A previous lifecycle may still be completing a read/native call. Drain
    // it before capturing again, without allowing overlapping native updates.
    if (this.pending !== undefined) {
      await this.pending;
    }
    if (!this.isCurrent(generation)) {
      return 'FAILED | physical DNS | cancelled';
    }
    const status: string = await this.refresh();
    if (this.isCurrent(generation) && this.timer < 0) {
      this.timer = setInterval(() => { this.refresh(); }, 5000);
    }
    return status;
  }

  stop(): void {
    this.active = false;
    this.generation++;
    this.onStatus = undefined;
    this.appliedConfig = '';
    this.appliedNetId = -1;
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private refresh(): Promise<string> {
    if (this.pending !== undefined) {
      return this.pending;
    }
    const generation: number = this.generation;
    this.pending = this.captureAndApply(generation).then((status: string) => {
      if (this.isCurrent(generation) && this.onStatus !== undefined) {
        this.onStatus(status);
      }
      return status;
    }).finally(() => { this.pending = undefined; });
    return this.pending;
  }

  private isCurrent(generation: number): boolean {
    return this.active && generation === this.generation;
  }

  private async captureAndApply(generation: number): Promise<string> {
    try {
      const before: connection.NetHandle = await connection.getDefaultNet();
      const caps: connection.NetCapabilities = await connection.getNetCapabilities(before);
      if (before.netId <= 0 || caps.bearerTypes.includes(connection.NetBearType.BEARER_VPN)) {
        return 'FAILED | physical DNS | no physical default network';
      }
      const properties: connection.ConnectionProperties = await connection.getConnectionProperties(before);
      const after: connection.NetHandle = await connection.getDefaultNet();
      if (before.netId !== after.netId) {
        return 'FAILED | physical DNS | network changed during capture';
      }
      const nameservers: string[] = [];
      for (const server of properties.dnses) {
        const address: string = server.address.trim();
        if (address.length > 0 && !nameservers.includes(address)) {
          nameservers.push(address);
        }
      }
      if (nameservers.length === 0 || nameservers.length > 64) {
        return 'FAILED | physical DNS | resolver list unavailable';
      }
      if (!this.isCurrent(generation)) {
        return 'FAILED | physical DNS | cancelled';
      }
      const config: BaseDNSConfig = { nameservers: nameservers };
      const payload: string = JSON.stringify(config);
      if (payload === this.appliedConfig && before.netId === this.appliedNetId) {
        return 'OK | physical DNS | current';
      }
      const result: string = await nativeBridge.backendSetBaseDNSAsync(payload);
      if (!this.isCurrent(generation)) {
        return 'FAILED | physical DNS | cancelled';
      }
      if (!result.startsWith('OK')) {
        // Native errors are a fixed, identity-redacted contract.
        return result.startsWith('FAILED') ? result : 'FAILED | physical DNS | native update rejected';
      }
      this.appliedConfig = payload;
      this.appliedNetId = before.netId;
      return 'OK | physical DNS | captured';
    } catch (error) {
      const businessError = error as BusinessError;
      return `FAILED | physical DNS | capture or update unavailable | code=${businessError.code ?? -1}`;
    }
  }
}
