import nativeBridge from 'libtailscale_ohos.so';
import { PhysicalDNS } from '../services/PhysicalDNS';
import { inspectVpnStatus, VpnStatusObservation } from '../services/VpnStatusPolicy';
import { recordLifecycle } from '../services/LocalDiagnostics';
import { vpnExtensionBinding } from '../services/VpnExtensionBinding';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { LengthMetrics } from '@kit.ArkUI';
import {
  BlurStrategy,
  DividerMode,
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsTabs,
  ScrollEffectType,
  hdsEffect,
  hdsMaterial
} from '@kit.UIDesignKit';

const MIN_CONNECTION_LOADING_MS: number = 1400;
const VPN_HEARTBEAT_TIMEOUT_MS: number = 120000;

interface ExitNodeChoice {
  id: string;
  name: string;
  online: boolean;
  selected: boolean;
}

interface PeerSummary {
  key: string;
  name: string;
  os: string;
  deviceModel: string;
  deviceType: string;
  addresses: string[];
  online: boolean;
  exitNode: boolean;
}

interface NetworkSettings {
  routeAll: boolean;
  corpDNS: boolean;
  exitNodeAllowLANAccess: boolean;
}

interface AccountSummary {
  displayName: string;
  loginName: string;
  profilePicURL: string;
  tailnetName: string;
  deviceName: string;
  addresses: string[];
}

interface BackendSnapshot {
  status: string;
  exitNodes: ExitNodeChoice[];
  peers: PeerSummary[];
  networkSettings: NetworkSettings;
  account: AccountSummary;
}

class PeerDataSource implements IDataSource {
  private data: PeerSummary[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): PeerSummary {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  replaceAll(peers: PeerSummary[]): void {
    this.data = [...peers];
    this.listeners.forEach((listener: DataChangeListener) => listener.onDataReloaded());
  }
}

@Component
export struct BridgeStatus {
  @State nativeStatus: string = 'Go Bridge Pending';
  @State engineStatus: string = 'Tailscale Engine Pending';
  @State backendStatus: string = 'Tailscale Backend Stopped';
  @State loginHandoffStatus: string = 'Secure Login Pending';
  @State controlProbeStatus: string = 'Control TLS Probe Pending';
  @State vpnStatus: string = 'HarmonyOS VPN Extension Stopped';
  @State vpnStatusUncertain: boolean = false;
  @State vpnStopPending: boolean = false;
  @State connectionFailureDetail: string = '';
  @State magicDNSProbeStatus: string = 'MagicDNS Probe Pending';
  @State exitNodes: ExitNodeChoice[] = [];
  @State peers: PeerSummary[] = [];
  @State networkSettings: NetworkSettings = {
    routeAll: true,
    corpDNS: true,
    exitNodeAllowLANAccess: false
  };
  @State networkSettingStatus: string = '';
  @State accountSummary: AccountSummary = {
    displayName: '',
    loginName: '',
    profilePicURL: '',
    tailnetName: '',
    deviceName: '',
    addresses: []
  };
  @State avatarLoadFailed: boolean = false;
  @State appVersion: string = '0.3.19-release';
  @State tailscaleVersion: string = '—';
  @State exitNodeStatus: string = '未使用出口节点';
  @State logoutStatus: string = '';
  @State diagnosticsUnlocked: boolean = false;
  @State diagnosticsExpanded: boolean = false;
  @State loginInProgress: boolean = false;
  @State connectInProgress: boolean = false;
  @State backendReady: boolean = false;
  @State devicesLoading: boolean = true;
  @State hasAuthenticatedSession: boolean = false;
  @State currentTab: number = 0;
  @State glowLevel: number = 3;
  @State layoutWidth: number = 360;
  @State expandedPeerKeys: string[] = [];
  private connectionPollTimer: number = -1;
  private connectionCompletionTimer: number = -1;
  private connectionStartedAtMs: number = 0;
  private vpnFailureAtMs: number = 0;
  private extensionStartupFailed: boolean = false;
  private vpnBackendNeedsRestore: boolean = false;
  private vpnRequestStartedAtMs: number = 0;
  private vpnRequestAcceptedAtMs: number = 0;
  private healthPollTimer: number = -1;
  private loginPollTimer: number = -1;
  private magicDNSProbeUrl: string = '';
  private settingsScroller: Scroller = new Scroller();
  private diagnosticsTapCount: number = 0;
  private diagnosticsLastTapMs: number = 0;
  private lifecycleTimers: number[] = [];
  private lifecycleGeneration: number = 0;
  private refreshInFlight: boolean = false;
  private physicalDNS: PhysicalDNS = new PhysicalDNS();
  private backendStartPending?: Promise<void>;
  private backendStartGeneration: number = -1;
  private backendOwnedElsewhere: boolean = false;
  private foreignOwnerObservedAtMs: number = 0;
  private uiOwnsBackend: boolean = false;
  private lastOwnershipCheckMs: number = 0;
  private ignoreVpnHeartbeatBeforeMs: number = 0;
  private peerDataSource: PeerDataSource = new PeerDataSource();

  private applyPeers(peers: PeerSummary[]): void {
    this.peers = peers;
    this.peerDataSource.replaceAll(peers);
  }

  aboutToAppear(): void {
    this.lifecycleGeneration++;
    this.loadGlowLevel();
    this.resetDiagnosticsMode();
    this.backendReady = false;
    this.devicesLoading = true;
    this.verifyNativeBridge();
    this.loadAppVersion();
    const vpnIsLive: boolean = this.refreshVpnProbeStatus();
    if (!vpnIsLive) {
      if (!this.isConnecting() && !this.extensionStartupFailed) {
        this.startBackend();
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      }
    } else {
      this.backendReady = true;
      this.devicesLoading = false;
      this.hasAuthenticatedSession = true;
    }
    // Recheck after the heartbeat freshness window. This covers an extension
    // process that was killed just before the UI appeared (for example during
    // an application update) while its last heartbeat still looked current.
    this.scheduleLifecycleTask(() => {
      if (!this.isConnecting() && !this.refreshVpnProbeStatus() &&
        !this.extensionStartupFailed) {
        this.startBackend();
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      }
    }, 6000);
    this.startHealthPolling();
  }

  aboutToDisappear(): void {
    this.lifecycleGeneration++;
    this.physicalDNS.stop();
    this.stopConnectionPolling();
    this.clearConnectionCompletionTimer();
    this.stopHealthPolling();
    this.stopLoginPolling();
    this.clearLifecycleTimers();
    this.resetDiagnosticsMode();
  }

  private scheduleLifecycleTask(task: () => void, delayMs: number): number {
    const generation: number = this.lifecycleGeneration;
    const timer: number = setTimeout(() => {
      if (generation === this.lifecycleGeneration) {
        task();
      }
    }, delayMs);
    this.lifecycleTimers.push(timer);
    return timer;
  }

  private clearLifecycleTimers(): void {
    this.lifecycleTimers.forEach((timer: number) => clearTimeout(timer));
    this.lifecycleTimers = [];
  }

  private loadAppVersion(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
      .then((info: bundleManager.BundleInfo) => {
        this.appVersion = info.versionName;
      })
      .catch(() => {
        // Keep the packaged fallback when bundle metadata is temporarily unavailable.
      });
  }

  private verifyNativeBridge(): void {
    try {
      this.nativeStatus = nativeBridge.hello();
      this.tailscaleVersion = nativeBridge.tailscaleVersion();
    } catch (error) {
      this.nativeStatus = `Go Bridge Failed: ${JSON.stringify(error)}`;
    }
  }

  private async probeUserspaceEngine(): Promise<void> {
    try {
      this.engineStatus = await nativeBridge.probeEngineAsync();
    } catch (error) {
      this.engineStatus = `Tailscale Engine Failed: ${JSON.stringify(error)}`;
    }
  }

  private startBackend(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    if (this.backendStartPending !== undefined) {
      if (this.backendStartGeneration === generation) {
        return this.backendStartPending;
      }
      return this.backendStartPending.then(() => {
        if (generation === this.lifecycleGeneration) {
          return this.startBackend();
        }
        return Promise.resolve();
      });
    }
    this.backendStartGeneration = generation;
    this.backendStartPending = this.startBackendWithDNS().finally(() => {
      this.backendStartPending = undefined;
    });
    return this.backendStartPending;
  }

  private async startBackendWithDNS(): Promise<void> {
    const generation: number = this.lifecycleGeneration;
    this.lastOwnershipCheckMs = Date.now();
    this.backendReady = false;
    this.devicesLoading = true;
    this.backendStatus = 'Tailscale backend starting | capturing physical DNS';
    try {
      await this.physicalDNS.start((status: string) => {
        this.networkSettingStatus = status;
      });
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      // The excluded UI backend can authenticate using the physical network
      // even if base DNS capture is unavailable. Keep its diagnostic visible.
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.backendStatus = nativeBridge.backendStart(`${context.filesDir}/tailscale`, this.deviceModel());
      if (this.backendStatus === 'BUSY | backend owned by another process') {
        this.backendOwnedElsewhere = true;
        this.foreignOwnerObservedAtMs = Date.now();
        this.uiOwnsBackend = false;
        this.physicalDNS.stop();
        this.markVpnStatusUncertain();
        return;
      }
      if (this.backendStatus.startsWith('OK') && !this.backendStatus.includes('tun=true')) {
        // Only successful acquisition of the native process lock proves that
        // a previous VPN process no longer owns this persistent backend.
        this.backendOwnedElsewhere = false;
        this.foreignOwnerObservedAtMs = 0;
        this.uiOwnsBackend = true;
        this.vpnBackendNeedsRestore = false;
        this.ignoreVpnHeartbeatBeforeMs = Date.now();
        if (!this.connectInProgress) {
          this.vpnStatusUncertain = false;
          this.vpnStatus = 'HarmonyOS VPN Extension Stopped (no active owner)';
        }
      }
    } catch (_error) {
      if (generation === this.lifecycleGeneration) {
        this.backendStatus = 'FAILED | backend start | physical DNS or native startup unavailable';
        this.backendReady = true;
        this.devicesLoading = false;
      }
    }
  }

  private deviceModel(): string {
    const marketName: string = deviceInfo.marketName.trim();
    if (marketName.length > 0 && marketName !== 'default') {
      return marketName;
    }
    return deviceInfo.productModel.trim();
  }

  private async refreshBackendStatus(): Promise<void> {
    if (this.refreshInFlight || this.backendOwnedElsewhere) {
      return;
    }
    const generation: number = this.lifecycleGeneration;
    this.refreshInFlight = true;
    try {
      const snapshotText: string = await nativeBridge.backendSnapshot();
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      const snapshot: BackendSnapshot = JSON.parse(snapshotText) as BackendSnapshot;
      this.backendStatus = snapshot.status;
      if (this.backendStatus.includes('state=Running')) {
        this.backendReady = true;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = true;
        this.exitNodes = snapshot.exitNodes;
        this.applyPeers(snapshot.peers);
        this.networkSettings = snapshot.networkSettings;
        const account: AccountSummary = snapshot.account;
        this.accountSummary = {
          displayName: account.displayName,
          loginName: account.loginName,
          profilePicURL: account.profilePicURL,
          tailnetName: account.tailnetName,
          deviceName: account.deviceName.length > 0 ? account.deviceName : this.deviceModel(),
          addresses: account.addresses
        };
        this.avatarLoadFailed = false;
      } else if (this.needsLogin()) {
        this.backendReady = true;
        this.devicesLoading = false;
        this.hasAuthenticatedSession = false;
        this.applyPeers([]);
        this.exitNodes = [];
        this.accountSummary = {
          displayName: '', loginName: '', profilePicURL: '', tailnetName: '', deviceName: '', addresses: []
        };
      } else if (this.backendStatus.startsWith('FAILED')) {
        this.backendReady = true;
        this.devicesLoading = false;
      }
    } catch (error) {
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      this.backendStatus = `Tailscale Backend Failed: ${JSON.stringify(error)}`;
      this.backendReady = true;
      this.devicesLoading = false;
    } finally {
      this.refreshInFlight = false;
    }
  }

  private refreshExitNodes(): void {
    try {
      const choicesText: string = nativeBridge.backendExitNodes();
      this.exitNodes = JSON.parse(choicesText) as ExitNodeChoice[];
      const selected: ExitNodeChoice | undefined = this.exitNodes.find(
        (choice: ExitNodeChoice) => choice.selected);
      this.exitNodeStatus = selected === undefined ? '未使用出口节点' : `已选择：${selected.name}`;
    } catch (_error) {
      this.exitNodes = [];
      this.exitNodeStatus = '出口节点列表暂不可用';
    }
  }

  private async setExitNode(id: string): Promise<void> {
    try {
      this.exitNodeStatus = await nativeBridge.backendSetExitNodeAsync(id);
      if (!this.exitNodeStatus.startsWith('FAILED')) {
        this.refreshBackendStatus();
      }
    } catch (_error) {
      this.exitNodeStatus = 'FAILED | exit node | update unavailable';
    }
  }

  private refreshPeers(): void {
    try {
      const peersText: string = nativeBridge.backendPeers();
      this.applyPeers(JSON.parse(peersText) as PeerSummary[]);
    } catch (_error) {
      this.applyPeers([]);
    }
    this.devicesLoading = false;
  }

  private refreshAccount(): void {
    try {
      const accountText: string = nativeBridge.backendAccount();
      const backendAccount: AccountSummary = JSON.parse(accountText) as AccountSummary;
      this.accountSummary = {
        displayName: backendAccount.displayName,
        loginName: backendAccount.loginName,
        profilePicURL: backendAccount.profilePicURL,
        tailnetName: backendAccount.tailnetName,
        deviceName: backendAccount.deviceName.length > 0 ? backendAccount.deviceName : this.deviceModel(),
        addresses: backendAccount.addresses
      };
      this.avatarLoadFailed = false;
    } catch (_error) {
      this.accountSummary = {
        displayName: '', loginName: '', profilePicURL: '', tailnetName: '', deviceName: '', addresses: []
      };
      this.avatarLoadFailed = false;
    }
  }

  private refreshNetworkSettings(): void {
    try {
      const settingsText: string = nativeBridge.backendNetworkSettings();
      this.networkSettings = JSON.parse(settingsText) as NetworkSettings;
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | unavailable';
    }
  }

  private async setNetworkSetting(key: string, enabled: boolean): Promise<void> {
    try {
      this.networkSettingStatus = await nativeBridge.backendSetNetworkSettingAsync(key, enabled);
      if (!this.networkSettingStatus.startsWith('FAILED')) {
        this.refreshBackendStatus();
      }
    } catch (_error) {
      this.networkSettingStatus = 'FAILED | network setting | update unavailable';
    }
  }

  private openSecureLogin(): void {
    if (this.loginInProgress) {
      return;
    }
    this.loginInProgress = true;
    this.loginHandoffStatus = 'Preparing secure login';
    this.stopLoginPolling();
    // Keep one visible frame for the in-button LoadingProgress before a fast
    // handoff switches the foreground application to the system browser.
    this.loginPollTimer = setTimeout(() => this.pollSecureLogin(0), 600);
  }

  private async pollSecureLogin(attempt: number): Promise<void> {
    try {
      const authUrl: string = await nativeBridge.backendAuthURLAsync();
      if (authUrl.startsWith('PENDING')) {
        if (attempt >= 24) {
          this.loginHandoffStatus = 'FAILED | login URL | timed out';
          this.loginInProgress = false;
          return;
        }
        this.loginPollTimer = setTimeout(() => this.pollSecureLogin(attempt + 1), 400);
        return;
      }
      if (!authUrl.startsWith('https://login.tailscale.com/')) {
        this.loginHandoffStatus = authUrl.startsWith('FAILED') ? authUrl :
          'FAILED | login URL | rejected unexpected origin';
        this.loginInProgress = false;
        return;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.loginHandoffStatus = 'Opening secure login in system browser';
      context.openLink(authUrl, { appLinkingOnly: false })
        .then(() => {
          this.loginHandoffStatus = 'Secure login page opened';
          this.loginInProgress = false;
        })
        .catch(() => {
          this.loginHandoffStatus = 'FAILED | secure browser handoff';
          this.loginInProgress = false;
        });
    } catch (error) {
      this.loginHandoffStatus = `FAILED | secure browser handoff | ${JSON.stringify(error)}`;
      this.loginInProgress = false;
    }
  }

  private stopLoginPolling(): void {
    if (this.loginPollTimer >= 0) {
      clearTimeout(this.loginPollTimer);
      this.loginPollTimer = -1;
    }
  }

  private runControlProbe(): void {
    try {
      this.controlProbeStatus = nativeBridge.controlProbe();
    } catch (error) {
      this.controlProbeStatus = `Control TLS Probe Failed: ${JSON.stringify(error)}`;
    }
  }

  private vpnWant(): Want {
    return {
      bundleName: 'com.example.tailscaleharmony',
      abilityName: 'TailscaleVpnExtensionAbility'
    };
  }

  private beginVpnConnection(): void {
    if (this.connectInProgress || this.isConnecting() || this.vpnStatusUncertain || this.vpnStopPending) {
      return;
    }
    this.clearConnectionCompletionTimer();
    this.connectionFailureDetail = '';
    this.vpnFailureAtMs = 0;
    this.vpnRequestStartedAtMs = 0;
    this.vpnRequestAcceptedAtMs = 0;
    this.connectionStartedAtMs = Date.now();
    vpnExtensionBinding.allowNewConnection();
    this.setConnectInProgress(true);
    // Let the button render its loading state before the native/VPN calls.
    this.scheduleLifecycleTask(() => this.startVpnProbe(), 300);
  }

  private async startVpnProbe(): Promise<void> {
    let backendStopRequested: boolean = false;
    try {
      if (this.backendStartPending !== undefined) {
        await this.backendStartPending;
      }
      const retryExtensionFailure: boolean = this.extensionStartupFailed;
      const restoreBackend: boolean = retryExtensionFailure || this.vpnBackendNeedsRestore;
      if (retryExtensionFailure) {
        // Stop the failed extension before reclaiming its persistent backend.
        await vpnExtension.stopVpnExtensionAbility(this.vpnWant());
        this.extensionStartupFailed = false;
      }
      if (restoreBackend) {
        await this.startBackend();
      }
      if (this.backendOwnedElsewhere) {
        // The previous extension may still be releasing its core. Keep the
        // unknown session stoppable and let bounded ownership polling resolve
        // it; a local config/snapshot cannot describe the other process.
        this.setConnectInProgress(false);
        return;
      }
      let backendConfig: string = await nativeBridge.backendVpnConfigAsync();
      for (let attempt: number = 0; restoreBackend && backendConfig.startsWith('FAILED') &&
        attempt < 60; attempt++) {
        await new Promise<void>((resolve: () => void) => {
          setTimeout(resolve, 250);
        });
        backendConfig = await nativeBridge.backendVpnConfigAsync();
      }
      if (backendConfig.startsWith('FAILED')) {
        const snapshotText: string = await nativeBridge.backendSnapshot();
        const snapshot: BackendSnapshot = JSON.parse(snapshotText) as BackendSnapshot;
        this.backendStatus = snapshot.status;
        if (snapshot.status.includes('state=Starting')) {
          // A bounded data-plane probe can establish a direct peer path when
          // the control session is authenticated but DERP is unavailable.
          await nativeBridge.backendPeerProbeAsync();
          backendConfig = await nativeBridge.backendVpnConfigAsync();
        }
      }
      if (backendConfig.startsWith('FAILED')) {
        this.failVpnConnection(backendConfig, '连接准备未完成，请稍后重试。');
        return;
      }
      const magicDNSProbeUrl: string = await nativeBridge.backendMagicDNSProbeURLAsync();
      if (magicDNSProbeUrl.startsWith('http://')) {
        this.magicDNSProbeUrl = magicDNSProbeUrl;
        this.magicDNSProbeStatus = 'MagicDNS identity-redacted probe ready';
      } else {
        this.magicDNSProbeUrl = '';
        this.magicDNSProbeStatus = magicDNSProbeUrl;
      }
      backendStopRequested = true;
      this.physicalDNS.stop();
      this.backendStatus = await nativeBridge.backendStopAsync();
      if (this.backendStatus.startsWith('FAILED')) {
        this.failVpnConnection(this.backendStatus, '连接准备失败，请重试。');
        await this.startBackend();
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
        return;
      }
      this.uiOwnsBackend = false;
      this.vpnStatus = 'Requesting HarmonyOS VPN authorization';
      this.vpnRequestStartedAtMs = Date.now();
      await vpnExtension.startVpnExtensionAbility(this.vpnWant());
      this.vpnRequestAcceptedAtMs = Date.now();
      this.vpnStatus = 'HarmonyOS VPN Extension start requested';
      this.startConnectionPolling();
    } catch (error) {
      const businessError = error as BusinessError;
      const code: number = businessError.code ?? -1;
      hilog.error(0x0000, 'TailscaleVpnUI', 'VPN start failed. code=%{public}d message=%{public}s',
        code, businessError.message ?? 'unknown');
      this.failVpnConnection(`FAILED | VPN start | code=${code}`,
        code >= 0 ? `连接失败（错误码 ${code}），请重试。` : '连接失败，请重试。');
      if (backendStopRequested) {
        // A rejected VPN authorization leaves no extension to own the core.
        // Restore the UI backend so the next Connect attempt can obtain config.
        await this.startBackend();
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      }
    }
  }

  private failVpnConnection(status: string, detail: string): void {
    this.vpnStatusUncertain = false;
    this.vpnStatus = status;
    this.connectionFailureDetail = detail;
    this.vpnFailureAtMs = Date.now();
    this.vpnRequestAcceptedAtMs = 0;
    this.clearConnectionCompletionTimer();
    this.stopConnectionPolling();
    this.setConnectInProgress(false);
  }

  private runMagicDNSProbe(): void {
    if (!this.magicDNSProbeUrl.startsWith('http://')) {
      this.magicDNSProbeStatus = 'SKIPPED | MagicDNS probe | no in-memory target';
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.magicDNSProbeStatus = 'Opening identity-redacted MagicDNS probe';
    context.openLink(this.magicDNSProbeUrl, { appLinkingOnly: false })
      .then(() => {
        this.magicDNSProbeStatus = 'MagicDNS browser probe opened';
      })
      .catch(() => {
        this.magicDNSProbeStatus = 'FAILED | MagicDNS browser probe';
      });
  }

  private stopVpnProbe(): void {
    if (this.vpnStopPending) {
      return;
    }
    this.vpnStopPending = true;
    vpnExtensionBinding.beforeManualStop();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    recordLifecycle(context.filesDir, 'ui', 'manual-disconnect');
    this.clearConnectionCompletionTimer();
    this.setConnectInProgress(false);
    vpnExtension.stopVpnExtensionAbility(this.vpnWant())
      .then(() => {
        this.vpnStatusUncertain = false;
        this.backendOwnedElsewhere = false;
        this.uiOwnsBackend = false;
        this.ignoreVpnHeartbeatBeforeMs = Date.now();
        this.vpnStatus = 'HarmonyOS VPN Extension stopped';
        this.stopConnectionPolling();
        this.startBackend();
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 1500);
      })
      .catch((error: BusinessError) => {
        this.vpnStatus = `FAILED | VPN stop | code=${error.code}`;
      })
      .finally(() => { this.vpnStopPending = false; });
  }

  private confirmLogout(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.logout_confirm_title'),
      message: $r('app.string.logout_confirm_message'),
      autoCancel: true,
      primaryButton: {
        value: $r('app.string.cancel_action'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.logout_action'),
        fontColor: $r('app.color.status_error'),
        action: () => this.logout()
      }
    });
  }

  private async logout(): Promise<void> {
    vpnExtensionBinding.beforeManualStop();
    try {
      this.logoutStatus = await nativeBridge.backendLogoutAsync();
      if (!this.logoutStatus.startsWith('FAILED')) {
        this.loginInProgress = false;
        this.hasAuthenticatedSession = false;
        this.stopLoginPolling();
        this.applyPeers([]);
        this.exitNodes = [];
        this.exitNodeStatus = '未使用出口节点';
        this.loginHandoffStatus = 'Secure Login Pending';
        this.scheduleLifecycleTask(() => this.refreshBackendStatus(), 500);
      }
    } catch (_error) {
      this.logoutStatus = 'FAILED | logout | unavailable';
    }
  }

  private markVpnStatusUncertain(): void {
    this.vpnStatusUncertain = true;
    this.vpnStatus = 'UNKNOWN | VPN session | checking ownership and activity';
    this.backendReady = true;
    this.devicesLoading = false;
    this.clearConnectionCompletionTimer();
  }

  private refreshVpnProbeStatus(): boolean {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const statusPath: string = `${context.filesDir}/vpn-probe-status.txt`;
      const persistedStatus: string = fileIo.accessSync(statusPath) ? fileIo.readTextSync(statusPath) : '';
      const observation: VpnStatusObservation = inspectVpnStatus(persistedStatus, Date.now());
      const heartbeatMs: number = observation.heartbeatMs;
      const visibleStatus: string = observation.status;
      if (heartbeatMs > 0 && heartbeatMs <= this.ignoreVpnHeartbeatBeforeMs && !this.connectInProgress) {
        // This process acquired the exclusive core lock after that record was
        // written. An old heartbeat must not resurrect the ended VPN session.
        return false;
      }
      // A previous session's file must not complete a new attempt or erase a
      // useful start error before the new extension has written its own status.
      if ((this.connectInProgress && heartbeatMs < this.connectionStartedAtMs) ||
        (this.connectionFailureDetail.length > 0 && heartbeatMs <= this.vpnFailureAtMs)) {
        this.expireMissingVpnHeartbeat(heartbeatMs);
        return false;
      }
      if (this.backendOwnedElsewhere && heartbeatMs <= this.foreignOwnerObservedAtMs &&
        (observation.kind === 'stopped' || observation.kind === 'failed')) {
        // A historical exit record cannot override the newer native proof
        // that another process still owns the core. Keep its stop action and
        // bounded ownership checks until a newer status or successful acquire.
        this.markVpnStatusUncertain();
        return false;
      }
      if (observation.kind === 'stopped') {
        this.vpnStatusUncertain = false;
        this.backendOwnedElsewhere = false;
        this.vpnStatus = visibleStatus;
        if (!this.uiOwnsBackend) {
          this.vpnBackendNeedsRestore = true;
        }
        if (!this.connectInProgress && this.extensionStartupFailed) {
          this.extensionStartupFailed = false;
        } else if (this.connectInProgress && this.vpnRequestAcceptedAtMs > 0 &&
          heartbeatMs >= this.vpnRequestStartedAtMs) {
          this.extensionStartupFailed = false;
          this.failVpnConnection('FAILED | VPN connection cancelled | extension destroyed',
            'VPN 连接已结束，请重试。');
        }
        return false;
      }
      if (observation.kind === 'failed') {
        this.extensionStartupFailed = true;
        this.failVpnConnection(visibleStatus, 'VPN 连接失败，请重试。');
        return false;
      }
      if (this.expireMissingVpnHeartbeat(heartbeatMs)) {
        return false;
      }
      if (observation.kind === 'unknown') {
        // A frozen timer, empty read, or transient snapshot failure cannot
        // prove the tunnel stopped. Native ownership resolves stale boot files.
        if (!this.uiOwnsBackend && this.connectionFailureDetail.length === 0) {
          this.markVpnStatusUncertain();
        }
        return false;
      }
      this.vpnStatusUncertain = false;
      this.uiOwnsBackend = false;
      if (observation.kind === 'running' && this.connectInProgress) {
        const remainingMs: number = MIN_CONNECTION_LOADING_MS -
          (Date.now() - this.connectionStartedAtMs);
        if (remainingMs > 0) {
          if (this.connectionCompletionTimer < 0) {
            this.connectionCompletionTimer = setTimeout(() => {
              this.commitConnectedStatus();
            }, remainingMs);
          }
          return true;
        }
      }
      this.vpnStatus = visibleStatus;
      if (observation.kind === 'running') {
        this.connectionFailureDetail = '';
        this.vpnFailureAtMs = 0;
        this.extensionStartupFailed = false;
        this.vpnBackendNeedsRestore = false;
        this.vpnRequestAcceptedAtMs = 0;
        this.clearConnectionCompletionTimer();
        this.setConnectInProgress(false);
      }
      return true;
    } catch (_error) {
      if (!this.uiOwnsBackend && this.connectionFailureDetail.length === 0) {
        this.markVpnStatusUncertain();
      }
      this.expireMissingVpnHeartbeat(0);
      return false;
    }
  }

  private expireMissingVpnHeartbeat(heartbeatMs: number): boolean {
    if (!this.connectInProgress || this.vpnRequestAcceptedAtMs <= 0) {
      return false;
    }
    const currentHeartbeat: number = heartbeatMs >= this.connectionStartedAtMs && heartbeatMs <= Date.now() ?
      heartbeatMs : 0;
    const lastActivityMs: number = Math.max(this.vpnRequestAcceptedAtMs, currentHeartbeat);
    if (Date.now() - lastActivityMs < VPN_HEARTBEAT_TIMEOUT_MS) {
      return false;
    }
    // Absence of a heartbeat does not prove that the extension exited. Keep
    // the stop-before-restore path for the next explicit connection attempt.
    this.extensionStartupFailed = true;
    this.failVpnConnection('FAILED | VPN startup | heartbeat timeout', 'VPN 连接超时，请重试。');
    return true;
  }

  private startConnectionPolling(): void {
    this.stopConnectionPolling();
    this.connectionPollTimer = setInterval(() => {
      this.refreshVpnProbeStatus();
      if (this.vpnStatus.includes('state=Running') || this.vpnStatus.startsWith('FAILED')) {
        this.stopConnectionPolling();
      }
    }, 1000);
  }

  private stopConnectionPolling(): void {
    if (this.connectionPollTimer >= 0) {
      clearInterval(this.connectionPollTimer);
      this.connectionPollTimer = -1;
    }
  }

  private clearConnectionCompletionTimer(): void {
    if (this.connectionCompletionTimer >= 0) {
      clearTimeout(this.connectionCompletionTimer);
      this.connectionCompletionTimer = -1;
    }
  }

  private commitConnectedStatus(): void {
    this.clearConnectionCompletionTimer();
    // Re-read the heartbeat: the extension may have stopped during the delay.
    this.refreshVpnProbeStatus();
    if (this.isConnected()) {
      this.stopConnectionPolling();
    }
  }

  private startHealthPolling(): void {
    this.stopHealthPolling();
    this.scheduleHealthPoll(this.lifecycleGeneration);
  }

  private scheduleHealthPoll(generation: number): void {
    this.healthPollTimer = setTimeout(() => {
      if (generation !== this.lifecycleGeneration) {
        return;
      }
      const vpnIsLive: boolean = this.refreshVpnProbeStatus();
      let refresh: Promise<void> = Promise.resolve();
      if (!vpnIsLive && !this.vpnStopPending) {
        if (this.vpnStatusUncertain && !this.connectInProgress &&
          Date.now() - this.lastOwnershipCheckMs >= 10000) {
          // This attempts only exclusive UI-core ownership; it never restarts
          // the system VPN. A BUSY result leaves the other process untouched.
          refresh = this.startBackend();
        } else if (!this.backendOwnedElsewhere && !this.vpnStatusUncertain) {
          refresh = this.refreshBackendStatus();
        }
      }
      refresh.finally(() => {
        if (generation === this.lifecycleGeneration) {
          this.scheduleHealthPoll(generation);
        }
      });
    }, 2000);
  }

  private stopHealthPolling(): void {
    if (this.healthPollTimer >= 0) {
      clearTimeout(this.healthPollTimer);
      this.healthPollTimer = -1;
    }
  }

  private isConnected(): boolean {
    return !this.vpnStatusUncertain && this.vpnStatus.includes('state=Running');
  }

  private hasActiveVpnSession(): boolean {
    return this.isConnected() || this.vpnStatusUncertain;
  }

  private isConnecting(): boolean {
    return this.connectInProgress ||
      this.vpnStatus.includes('start requested') ||
      this.vpnStatus.includes('authorization') ||
      this.vpnStatus.includes('starting');
  }

  private needsLogin(): boolean {
    return this.backendStatus.includes('NeedsLogin') ||
      this.backendStatus.includes('loginURLReady=true');
  }

  private hasConnectionProblem(): boolean {
    return this.vpnStatus.startsWith('FAILED') || this.backendStatus.startsWith('FAILED');
  }

  private isAuthenticated(): boolean {
    return this.hasAuthenticatedSession;
  }

  private isBackendLoading(): boolean {
    return !this.backendReady && !this.hasConnectionProblem();
  }

  private setConnectInProgress(inProgress: boolean): void {
    // Loading state must enter the component tree synchronously. Animating the
    // surrounding panel is handled by its modifier; delaying this assignment
    // can otherwise let a fast native failure skip the progress frame.
    this.connectInProgress = inProgress;
  }

  private onlinePeerCount(): number {
    return this.peers.filter((peer: PeerSummary) => peer.online).length;
  }

  private peerDeviceIcon(deviceType: string): Resource {
    if (deviceType === 'tablet') {
      return $r('app.media.device_tablet');
    }
    if (deviceType === 'phone' || deviceType === 'foldable') {
      return $r('app.media.device_phone');
    }
    return $r('app.media.device_laptop');
  }

  private localDeviceIcon(): Resource {
    return this.peerDeviceIcon(deviceInfo.deviceType);
  }

  private nodeNameSlug(value: string): string {
    return value.split('.')[0]
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '');
  }

  private localDeviceName(): string {
    const sourceName: string = this.accountSummary.deviceName.length > 0 ?
      this.accountSummary.deviceName : this.deviceModel();
    let nodeName: string = this.nodeNameSlug(sourceName);
    const brandName: string = this.nodeNameSlug(deviceInfo.brand);
    if (brandName.length > 0 && nodeName.startsWith(`${brandName}-`)) {
      nodeName = nodeName.substring(brandName.length + 1);
    }
    return nodeName.length > 0 ? nodeName : sourceName;
  }

  private displayOsName(os: string): string {
    switch (os.trim().toLowerCase()) {
      case 'android':
        return 'Android';
      case 'windows':
        return 'Windows';
      case 'linux':
        return 'Linux';
      case 'macos':
      case 'darwin':
        return 'macOS';
      case 'ios':
        return 'iOS';
      case 'chromeos':
        return 'ChromeOS';
      case 'freebsd':
        return 'FreeBSD';
      case 'harmonyos':
      case 'openharmony':
        return 'HarmonyOS';
      default:
        return os;
    }
  }

  private peerDeviceDescription(peer: PeerSummary): string {
    return peer.os.length > 0 ? this.displayOsName(peer.os) : peer.deviceModel;
  }

  private primaryTailscaleAddress(addresses: string[]): string {
    const ipv4Address: string | undefined = addresses.find((address: string) =>
      !address.includes(':'));
    if (ipv4Address !== undefined) {
      return ipv4Address;
    }
    return addresses.length > 0 ? addresses[0] : '';
  }

  private settingsStatusText(): string {
    return this.isConnected() ? this.vpnStatus : this.backendStatus;
  }

  private routeSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('routeAll=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('routeAll=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private magicDNSSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('corpDNS=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('corpDNS=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private exitNodeLANSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('exitNodeLAN=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('exitNodeLAN=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private exitNodeSettingState(): ResourceStr {
    const status: string = this.settingsStatusText();
    if (!status.includes('exitNode=')) {
      return $r('app.string.setting_unavailable');
    }
    return status.includes('exitNode=true') ? $r('app.string.setting_enabled') :
      $r('app.string.setting_disabled');
  }

  private connectionTitle(): ResourceStr {
    if (this.vpnStatusUncertain) {
      return $r('app.string.connection_checking');
    }
    if (this.isBackendLoading()) {
      return $r('app.string.connection_starting');
    }
    if (this.isConnected()) {
      return $r('app.string.connection_connected');
    }
    if (this.isConnecting()) {
      return $r('app.string.connection_connecting');
    }
    if (this.hasConnectionProblem()) {
      return $r('app.string.connection_problem');
    }
    if (this.needsLogin()) {
      return $r('app.string.connection_login_required');
    }
    return $r('app.string.connection_disconnected');
  }

  private connectionDescription(): ResourceStr {
    if (this.vpnStatusUncertain) {
      return $r('app.string.description_checking');
    }
    if (this.connectionFailureDetail.length > 0) {
      return this.connectionFailureDetail;
    }
    if (this.isBackendLoading()) {
      return $r('app.string.description_starting');
    }
    if (this.isConnected()) {
      return $r('app.string.description_connected');
    }
    if (this.isConnecting()) {
      return $r('app.string.description_connecting');
    }
    if (this.needsLogin()) {
      return $r('app.string.description_login_required');
    }
    if (this.hasConnectionProblem()) {
      if (this.backendStatus.includes('tls-error') || this.backendStatus.includes('x509')) {
        return $r('app.string.description_tls_problem');
      }
      if (this.backendStatus.includes('network-timeout') ||
        this.backendStatus.includes('connection-error') || this.backendStatus.includes('netUp=false')) {
        return $r('app.string.description_network_problem');
      }
      if (this.vpnStatus.includes('VPN start') || this.vpnStatus.includes('authorization')) {
        return $r('app.string.description_vpn_permission_problem');
      }
      if (this.vpnStatus.includes('status file')) {
        return $r('app.string.description_status_problem');
      }
      return $r('app.string.description_problem');
    }
    return $r('app.string.description_disconnected');
  }

  private connectionColor(): ResourceColor {
    if (this.isConnected()) {
      return $r('app.color.status_success');
    }
    if (this.isConnecting() || this.vpnStatusUncertain) {
      return $r('app.color.status_warning');
    }
    if (this.hasConnectionProblem()) {
      return $r('app.color.status_error');
    }
    return $r('app.color.status_neutral');
  }

  private glowFilePath(): string {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    return `${context.filesDir}/ui-glow-level-v2`;
  }

  private resetDiagnosticsMode(): void {
    this.diagnosticsUnlocked = false;
    this.diagnosticsExpanded = false;
    this.diagnosticsTapCount = 0;
    this.diagnosticsLastTapMs = 0;
  }

  private unlockDiagnostics(): void {
    this.diagnosticsUnlocked = true;
    this.diagnosticsExpanded = false;
  }

  private showToast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message });
    } catch (_error) {
      // Toast is immediate feedback only; failure must not block the gesture.
    }
  }

  private onAppVersionTap(): void {
    if (this.diagnosticsUnlocked) {
      this.showToast('您已进入工程模式');
      return;
    }
    const nowMs: number = Date.now();
    if (nowMs - this.diagnosticsLastTapMs > 1500) {
      this.diagnosticsTapCount = 0;
    }
    this.diagnosticsLastTapMs = nowMs;
    this.diagnosticsTapCount += 1;
    if (this.diagnosticsTapCount >= 5) {
      this.diagnosticsTapCount = 0;
      this.unlockDiagnostics();
      this.showToast('您已进入工程模式');
      return;
    }
    const remainingCount: number = 5 - this.diagnosticsTapCount;
    this.showToast(`再点击${remainingCount}次即可进入工程诊断`);
  }

  private loadGlowLevel(): void {
    try {
      const path: string = this.glowFilePath();
      if (!fileIo.accessSync(path)) {
        return;
      }
      const level: number = Number(fileIo.readTextSync(path));
      if (level >= 0 && level <= 3) {
        this.glowLevel = level;
      }
    } catch (_error) {
      this.glowLevel = 3;
    }
  }

  private setGlowLevel(level: number): void {
    if (level < 0 || level > 3) {
      return;
    }
    this.glowLevel = level;
    try {
      const file = fileIo.openSync(this.glowFilePath(),
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, level.toString());
      fileIo.closeSync(file);
    } catch (_error) {
      // Visual preferences are best-effort and never affect VPN behavior.
    }
  }

  private glowRadius(): number {
    return this.glowLevel === 0 ? 28 : (this.glowLevel === 1 ? 18 : 10);
  }

  private glowColor(): ResourceColor {
    return $r('sys.color.comp_background_emphasize');
  }

  private glowSurface(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private glowMaskColor(): ResourceColor {
    return $r('sys.color.background_primary');
  }

  private glowLightColor(): ResourceColor {
    return $r('sys.color.comp_background_emphasize');
  }

  private glowSaturation(): number {
    return this.glowLevel === 0 ? 1.38 : (this.glowLevel === 1 ? 1.2 : 1.05);
  }

  private glowBrightness(): number {
    return this.glowLevel === 0 ? 1.12 : (this.glowLevel === 1 ? 1.07 : 1.02);
  }

  private glowMaterialLevel(): hdsMaterial.MaterialLevel {
    if (this.glowLevel === 0) {
      return hdsMaterial.MaterialLevel.EXQUISITE;
    }
    if (this.glowLevel === 1) {
      return hdsMaterial.MaterialLevel.GENTLE;
    }
    if (this.glowLevel === 2) {
      return hdsMaterial.MaterialLevel.SMOOTH;
    }
    return hdsMaterial.MaterialLevel.ADAPTIVE;
  }

  private glowLevelDescription(): ResourceStr {
    if (this.glowLevel === 0) {
      return $r('app.string.glow_exquisite_description');
    }
    if (this.glowLevel === 1) {
      return $r('app.string.glow_gentle_description');
    }
    if (this.glowLevel === 2) {
      return $r('app.string.glow_smooth_description');
    }
    return $r('app.string.glow_adaptive_description');
  }

  private glowLevelLabel(): ResourceStr {
    if (this.glowLevel === 0) {
      return $r('app.string.glow_exquisite');
    }
    if (this.glowLevel === 1) {
      return $r('app.string.glow_gentle');
    }
    if (this.glowLevel === 2) {
      return $r('app.string.glow_smooth');
    }
    return $r('app.string.glow_adaptive');
  }

  private isWideNavigation(): boolean {
    return this.layoutWidth >= 840;
  }

  private pageMargin(): number {
    if (this.layoutWidth >= 840) {
      return 32;
    }
    if (this.layoutWidth >= 600) {
      return 24;
    }
    return 16;
  }

  private contentMargin(): number {
    return this.pageMargin() + 8;
  }

  private pageBottomInset(): number {
    return this.isWideNavigation() ? 32 : 120;
  }

  private groupBackground(): ResourceColor {
    return $r('sys.color.comp_background_primary');
  }

  private isPeerNameExpanded(peerKey: string): boolean {
    return this.expandedPeerKeys.includes(peerKey);
  }

  private togglePeerName(peerKey: string): void {
    if (this.isPeerNameExpanded(peerKey)) {
      this.expandedPeerKeys = this.expandedPeerKeys.filter((key: string) => key !== peerKey);
      return;
    }
    this.expandedPeerKeys = this.expandedPeerKeys.concat(peerKey);
  }

  private secondaryBackground(): ResourceColor {
    return $r('sys.color.comp_background_tertiary');
  }

  private accountInitial(): string {
    const source: string = this.accountSummary.displayName.length > 0 ?
      this.accountSummary.displayName : this.accountSummary.loginName;
    return source.length > 0 ? source.substring(0, 1).toUpperCase() : 'T';
  }

  @Builder
  private SectionHeader(title: ResourceStr, description?: ResourceStr) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (description !== undefined) {
        Text(description)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private SettingsGroupHeader(title: ResourceStr) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ top: 12, bottom: 4 })
  }

  @Builder
  private ButtonContent(label: ResourceStr, primary: boolean, loading: boolean) {
    Row({ space: 8 }) {
      if (loading) {
        LoadingProgress()
          .width(20)
          .height(20)
          .color(primary ? $r('sys.color.font_on_primary') : $r('sys.color.icon_primary'))
      }
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(primary ? $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  @Builder
  private ConnectButtonContent() {
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.action_connect'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
        .opacity(this.connectInProgress || this.isConnecting() ? 0 : 1)
      if (this.connectInProgress || this.isConnecting()) {
        Row({ space: 8 }) {
          LoadingProgress()
            .id('vpn-start-loading')
            .width(20)
            .height(20)
            .color($r('sys.color.font_on_primary'))
          Text($r('app.string.action_connecting'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  private LoginButtonContent() {
    Stack({ alignContent: Alignment.Center }) {
      Text($r('app.string.action_login'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
        .opacity(this.loginInProgress ? 0 : 1)
      if (this.loginInProgress) {
        Row({ space: 8 }) {
          LoadingProgress()
            .id('login-open-loading')
            .width(20)
            .height(20)
            .color($r('sys.color.font_on_primary'))
          Text($r('app.string.action_login'))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
        }
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
  }

  @Builder
  private ConnectButton() {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.EMPHASIZED,
      controlSize: ControlSize.NORMAL
    }) {
      this.ConnectButtonContent()
    }
      .id('vpn-start')
      .width('100%')
      .height(52)
      .enabled(!this.connectInProgress && !this.isConnecting())
      .onClick(() => this.beginVpnConnection())
  }

  @Builder
  private LoginButton() {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.EMPHASIZED,
      controlSize: ControlSize.NORMAL
    }) {
      this.LoginButtonContent()
    }
      .id('login-open')
      .width('100%')
      .height(52)
      .enabled(!this.loginInProgress)
      .onClick(() => this.openSecureLogin())
  }

  @Builder
  private ImmersiveButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false) {
    if (this.glowLevel === 3) {
      Button({
        type: ButtonType.ROUNDED_RECTANGLE,
        stateEffect: true,
        buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
        controlSize: ControlSize.NORMAL
      }) {
        this.ButtonContent(label, primary, loading)
      }
        .id(nodeId)
        .width('100%')
        .height(52)
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
          .buildEffect())
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onClick(action)
    } else {
      Button({
        type: ButtonType.ROUNDED_RECTANGLE,
        stateEffect: true,
        buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
        controlSize: ControlSize.NORMAL
      }) {
        this.ButtonContent(label, primary, loading)
      }
        .id(nodeId)
        .width('100%')
        .height(52)
        .backgroundEffect({
          radius: this.glowRadius(),
          saturation: this.glowSaturation(),
          brightness: this.glowBrightness(),
          color: primary ? $r('sys.color.comp_background_emphasize') : this.glowSurface(),
          adaptiveColor: AdaptiveColor.DEFAULT
        }, { disableSystemAdaptation: false })
        .visualEffect(new hdsEffect.HdsEffectBuilder()
          .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
          .buildEffect())
        .shadow({
          radius: this.glowLevel === 0 ? 12 : (this.glowLevel === 1 ? 8 : 4),
          color: this.glowColor(),
          offsetY: 3
        })
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onClick(action)
    }
  }

  @Builder
  private StandardActionButton(label: ResourceStr, nodeId: string, primary: boolean,
    enabled: boolean, action: () => void, loading: boolean = false) {
    Button({
      type: ButtonType.ROUNDED_RECTANGLE,
      stateEffect: true,
      buttonStyle: primary ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL,
      controlSize: ControlSize.NORMAL
    }) {
      this.ButtonContent(label, primary, loading)
    }
      .id(nodeId)
      .width('100%')
      .height(52)
      .opacity(enabled ? 1 : 0.4)
      .enabled(enabled)
      .onClick(action)
  }

  @Builder
  private ConnectionPanel() {
    Column({ space: 16 }) {
      Row({ space: 12 }) {
        Stack() {
          Image($r('app.media.connection_filled'))
            .width(28)
            .height(28)
            .fillColor(this.connectionColor())
        }
        .width(48)
        .height(48)
        .borderRadius(16)
        .backgroundColor(this.secondaryBackground())

        Column({ space: 2 }) {
          Text(this.connectionTitle())
            .id('smoke-title')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Text(this.connectionDescription())
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(18)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      if (this.hasActiveVpnSession()) {
        this.StandardActionButton($r('app.string.action_disconnect'), 'vpn-stop', false, !this.vpnStopPending,
          () => this.stopVpnProbe(), this.vpnStopPending)
      } else if (this.isBackendLoading()) {
        this.StandardActionButton($r('app.string.action_starting'), 'backend-starting', true,
          false, () => {}, true)
      } else if (this.needsLogin()) {
        this.LoginButton()
      } else {
        this.ConnectButton()
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private NetworkSettingsPanel() {
    Column({ space: 0 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_subnet_routes'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_subnet_routes_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.routeAll })
          .id('route-all-toggle')
          .enabled(!this.hasActiveVpnSession() && this.isAuthenticated())
          .opacity(!this.hasActiveVpnSession() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) => this.setNetworkSetting('routeAll', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 64 })
      .padding({ top: 8, bottom: 8 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_magicdns'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_magicdns_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.corpDNS })
          .id('tailscale-dns-toggle')
          .enabled(!this.hasActiveVpnSession() && this.isAuthenticated())
          .opacity(!this.hasActiveVpnSession() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) => this.setNetworkSetting('corpDNS', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 64 })
      .padding({ top: 8, bottom: 8 })

      Divider().color($r('sys.color.comp_divider'))

      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.setting_exit_node_lan'))
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.setting_exit_node_lan_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Toggle({ type: ToggleType.Switch, isOn: this.networkSettings.exitNodeAllowLANAccess })
          .id('exit-node-lan-toggle')
          .enabled(!this.hasActiveVpnSession() && this.isAuthenticated())
          .opacity(!this.hasActiveVpnSession() && this.isAuthenticated() ? 1 : 0.4)
          .onChange((enabled: boolean) =>
            this.setNetworkSetting('exitNodeAllowLANAccess', enabled))
      }
      .width('100%')
      .constraintSize({ minHeight: 72 })
      .padding({ top: 8, bottom: 8 })

      if (this.networkSettingStatus.startsWith('FAILED')) {
        Text($r('app.string.network_setting_failed'))
          .id('network-setting-status')
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .width('100%')
          .padding({ top: 8 })
      }
    }
    .id('network-settings-panel')
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private ExitNodeChoiceButton(label: ResourceStr, nodeId: string, selected: boolean,
    enabled: boolean, action: () => void) {
    Button() {
      Row({ space: 12 }) {
        Text(label)
          .fontSize(14)
          .fontColor(enabled ? $r('sys.color.font_primary') : $r('sys.color.font_secondary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.Start)
        if (selected) {
          SymbolGlyph($r('sys.symbol.checkmark_circle'))
            .fontSize(22)
            .fontColor([$r('sys.color.icon_emphasize')])
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .id(nodeId)
    .width('100%')
    .height(52)
    .type(ButtonType.Normal)
    .borderRadius(20)
    .backgroundColor(selected ? '#14126BFF' : this.secondaryBackground())
    .backgroundEffect({
      radius: this.glowRadius(),
      saturation: this.glowSaturation(),
      brightness: this.glowBrightness(),
      color: this.glowSurface(),
      adaptiveColor: AdaptiveColor.DEFAULT
    }, { disableSystemAdaptation: false })
    .visualEffect(new hdsEffect.HdsEffectBuilder()
      .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
      .buildEffect())
    .enabled(enabled)
    .opacity(enabled ? 1 : 0.45)
    .stateEffect(true)
    .onClick(action)
  }

  @Builder
  private ExitNodePanel() {
    Column({ space: 12 }) {
      Row() {
        Column({ space: 2 }) {
          Text($r('app.string.exit_node_title'))
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text($r('app.string.exit_node_description'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .lineHeight(18)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(this.exitNodeStatus)
          .id('exit-node-status')
          .fontSize(13)
          .fontColor(this.exitNodeStatus.startsWith('FAILED') ?
            $r('app.color.status_error') : $r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (!this.isAuthenticated()) {
        Text($r('app.string.exit_node_login_required'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .lineHeight(18)
          .width('100%')
      } else if (this.exitNodes.length === 0) {
        Text($r('app.string.exit_node_empty'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      } else {
        this.ExitNodeChoiceButton($r('app.string.exit_node_none'), 'exit-node-none',
          !this.exitNodes.some((choice: ExitNodeChoice) => choice.selected),
          !this.hasActiveVpnSession() && !this.isConnecting() && !this.connectInProgress,
          () => this.setExitNode(''))
        ForEach(this.exitNodes, (choice: ExitNodeChoice) => {
          this.ExitNodeChoiceButton(choice.name, 'exit-node-' + choice.id, choice.selected,
            choice.online && !this.hasActiveVpnSession() && !this.isConnecting() && !this.connectInProgress,
            () => this.setExitNode(choice.id))
        }, (choice: ExitNodeChoice) => choice.id)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private DevicesLoadingPanel() {
    Column({ space: 12 }) {
      this.SectionHeader($r('app.string.devices_title'), $r('app.string.action_starting'))
      Column({ space: 10 }) {
        LoadingProgress()
          .id('devices-loading')
          .width(28)
          .height(28)
          .color($r('sys.color.icon_emphasize'))
        Text($r('app.string.action_starting'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DevicesSignedOutPanel() {
    Column({ space: 12 }) {
      this.SectionHeader($r('app.string.devices_title'), '')
      Column() {
        Text($r('app.string.account_profile_unavailable'))
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width('100%')
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private LocalDeviceRow() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.localDeviceIcon())
          .width(22)
          .height(22)
          .fillColor($r('sys.color.icon_primary'))
        Row()
          .width(8)
          .height(8)
          .borderRadius(4)
          .border({ width: 2, color: this.groupBackground() })
          .backgroundColor(this.connectionColor())
      }
      .width(36)
      .height(36)
      .padding(7)
      .borderRadius(11)
      .backgroundColor(this.secondaryBackground())

      Column({ space: 1 }) {
        Row({ space: 6 }) {
          Text(this.localDeviceName())
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .layoutWeight(1)
          Text($r('app.string.local_device_badge'))
            .fontSize(9)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(7)
            .backgroundColor(this.secondaryBackground())
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        Row({ space: 5 }) {
          Text(this.connectionTitle())
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
          Text('· HarmonyOS')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        if (this.accountSummary.addresses.length > 0) {
          Text(this.primaryTailscaleAddress(this.accountSummary.addresses))
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ top: 6, right: 12, bottom: 6 })
  }

  @Builder
  private PeerDeviceRow(peer: PeerSummary) {
    Column({ space: 0 }) {
      Divider().color($r('sys.color.comp_divider'))
      Row({ space: 10 }) {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(this.peerDeviceIcon(peer.deviceType))
            .width(22)
            .height(22)
            .fillColor($r('sys.color.icon_primary'))
          Row()
            .width(8)
            .height(8)
            .borderRadius(4)
            .border({ width: 2, color: this.groupBackground() })
            .backgroundColor(peer.online ? $r('app.color.status_success') :
              $r('app.color.status_offline'))
        }
        .width(36)
        .height(36)
        .padding(7)
        .borderRadius(11)
        .backgroundColor(this.secondaryBackground())
        Column({ space: 1 }) {
          Text(peer.name)
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(this.isPeerNameExpanded(peer.key) ? 6 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .width('100%')
            .onClick(() => this.togglePeerName(peer.key))
          Row({ space: 5 }) {
            Text(peer.online ? $r('app.string.peer_online') : $r('app.string.peer_offline'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
            if (this.peerDeviceDescription(peer).length > 0) {
              Text('· ' + this.peerDeviceDescription(peer))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
            if (peer.exitNode) {
              Text($r('app.string.peer_exit_node'))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
          }
          .width('100%')
          if (peer.addresses.length > 0) {
            Text(this.primaryTailscaleAddress(peer.addresses))
              .fontSize(11)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .width('100%')
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ minHeight: 52 })
      .padding({ top: 6, right: 12, bottom: 6 })
    }
    .width('100%')
  }

  @Builder
  private DevicesPanel() {
    Column({ space: 0 }) {
      this.SectionHeader($r('app.string.devices_title'),
        $r('app.string.devices_count', this.onlinePeerCount() + (this.isConnected() ? 1 : 0),
          this.peers.length + 1))
      Text('')
        .id('peer-summary')
        .height(4)
        .fontSize(1)
        .accessibilityLevel('no')
      List() {
        ListItem() {
          this.LocalDeviceRow()
        }
        LazyForEach(this.peerDataSource, (peer: PeerSummary) => {
          ListItem() {
            this.PeerDeviceRow(peer)
          }
        }, (peer: PeerSummary) => peer.key)
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(this.peers.length + 1 > 3 ? BarState.Auto : BarState.Off)
      .scrollBarWidth(3)
      .cachedCount(5)
    }
    .width('100%')
    .layoutWeight(1)
    .constraintSize({ minHeight: 160 })
    .padding({ left: 16, right: 4, top: 14, bottom: 10 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .clip(true)
    .animation({ duration: 260, curve: Curve.EaseInOut })
  }

  @Builder
  private GlowSettingsPanel() {
    Row({ space: 12 }) {
      Text($r('app.string.glow_title'))
        .id('settings-page-title')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Select([
        { value: $r('app.string.glow_exquisite') },
        { value: $r('app.string.glow_gentle') },
        { value: $r('app.string.glow_smooth') },
        { value: $r('app.string.glow_adaptive') }
      ])
        .id('glow-select')
        .selected(this.glowLevel)
        .value(this.glowLevelLabel())
        .controlSize(ControlSize.NORMAL)
        .constraintSize({ minWidth: 112, maxWidth: 160 })
        .onSelect((index: number, _value?: string) => this.setGlowLevel(index))
    }
    .id('glow-settings')
    .width('100%')
    .constraintSize({ minHeight: 64 })
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private AccountPanel() {
    Column({ space: 10 }) {
      if (!this.isAuthenticated()) {
        Row({ space: 12 }) {
          Stack() {
            Image($r('app.media.tab_home'))
              .width(28)
              .height(28)
              .fillColor($r('sys.color.icon_secondary'))
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.secondaryBackground())
          Text($r('app.string.account_profile_unavailable'))
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
        }
        .width('100%')
        this.StandardActionButton($r('app.string.action_login'), 'account-login', true,
          !this.loginInProgress, () => this.openSecureLogin(), this.loginInProgress)
      } else {
        Row({ space: 12 }) {
          Stack() {
            if (this.accountSummary.profilePicURL.length > 0 && !this.avatarLoadFailed) {
              Image(this.accountSummary.profilePicURL)
                .id('account-avatar')
                .width(56)
                .height(56)
                .borderRadius(28)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  this.avatarLoadFailed = true;
                })
            } else {
              Text(this.accountInitial())
                .fontSize(22)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_emphasize'))
            }
          }
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.secondaryBackground())

          Column({ space: 2 }) {
            Text(this.accountSummary.displayName)
              .id('account-display-name')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.accountSummary.loginName)
              .id('account-login-name')
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')

        Divider().color($r('sys.color.comp_divider'))
        this.AccountDetailRow($r('app.string.account_tailnet'),
          this.accountSummary.tailnetName, 'account-tailnet')
        this.AccountDetailRow($r('app.string.account_device'),
          this.accountSummary.deviceName, 'account-device')

        if (!this.hasActiveVpnSession()) {
          Text($r('app.string.logout_description'))
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
          Button($r('app.string.logout_action'), {
            type: ButtonType.ROUNDED_RECTANGLE,
            stateEffect: true,
            buttonStyle: ButtonStyleMode.NORMAL,
            controlSize: ControlSize.NORMAL,
            role: ButtonRole.ERROR
          })
            .id('logout-open')
            .width('100%')
            .visualEffect(new hdsEffect.HdsEffectBuilder()
              .pressShadow(hdsEffect.PressShadowType.BLEND_WHITE)
              .buildEffect())
            .onClick(() => this.confirmLogout())
        }
      }

      if (this.logoutStatus.startsWith('FAILED')) {
        Text($r('app.string.logout_failed'))
          .id('logout-status')
          .fontSize(12)
          .fontColor($r('app.color.status_error'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private AccountDetailRow(label: ResourceStr, value: string, nodeId: string,
    action?: () => void) {
    Row({ space: 12 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
      Text(value.length > 0 ? value : '—')
        .id(nodeId)
        .fontSize(13)
        .fontColor($r('sys.color.font_primary'))
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .constraintSize({ minHeight: 44 })
    .onClick(() => {
      if (action !== undefined) {
        action();
      }
    })
  }

  @Builder
  private AppVersionActionRow() {
    Button({
      type: ButtonType.Normal,
      stateEffect: true,
      buttonStyle: ButtonStyleMode.TEXTUAL,
      controlSize: ControlSize.NORMAL
    }) {
      Row({ space: 12 }) {
        Text($r('app.string.app_version_label'))
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Text(this.appVersion)
          .id('app-version')
          .fontSize(13)
          .fontColor($r('sys.color.font_primary'))
          .textAlign(TextAlign.End)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .id('app-version-action')
    .width('100%')
    .height(44)
    .padding(0)
    .borderRadius(12)
    .onClick(() => this.onAppVersionTap())
  }

  @Builder
  private VersionPanel() {
    Column({ space: 0 }) {
      this.AppVersionActionRow()
      this.AccountDetailRow($r('app.string.tailscale_version_label'),
        this.tailscaleVersion, 'tailscale-version')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
  }

  @Builder
  private DiagnosticStatus(title: ResourceStr | string, value: string, nodeId: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')
      Text(value)
        .id(nodeId)
        .fontSize(13)
        .fontColor(value.startsWith('FAILED') ?
          $r('app.color.status_error') : $r('sys.color.font_primary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  private DiagnosticsPanel() {
    Column({ space: 8 }) {
      this.DiagnosticStatus('Go Bridge', this.nativeStatus, 'smoke-go-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Tailscale Engine', this.engineStatus, 'engine-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Control Plane', this.backendStatus, 'backend-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('VPN Extension', this.vpnStatus, 'vpn-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('MagicDNS', this.magicDNSProbeStatus, 'magicdns-status')
      Divider().color($r('sys.color.comp_divider'))
      this.DiagnosticStatus('Network configuration', this.networkSettingStatus, 'physical-dns-status')

      this.StandardActionButton('Refresh status', 'backend-refresh', false, true, () => {
        this.verifyNativeBridge();
        this.refreshBackendStatus();
        this.refreshVpnProbeStatus();
      })
      this.StandardActionButton('Probe engine', 'engine-probe', false, true,
        () => this.probeUserspaceEngine())
      this.StandardActionButton('Probe control TLS', 'control-probe', false, true,
        () => this.runControlProbe())
      this.StandardActionButton('Open MagicDNS probe', 'magicdns-probe', false,
        this.magicDNSProbeUrl.startsWith('http://'), () => this.runMagicDNSProbe())
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }

  @Builder
  private DiagnosticsDisclosure() {
    Column({ space: 0 }) {
      Button({
        type: ButtonType.Normal,
        stateEffect: true,
        buttonStyle: ButtonStyleMode.TEXTUAL,
        controlSize: ControlSize.NORMAL
      }) {
        Row({ space: 12 }) {
          Column({ space: 2 }) {
            Text($r('app.string.diagnostics_title'))
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
            Text($r('app.string.diagnostics_description'))
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(20)
            .fontColor([$r('sys.color.icon_secondary')])
            .rotate({ angle: this.diagnosticsExpanded ? 180 : 0 })
            .animation({ duration: 220, curve: Curve.EaseInOut })
        }
        .width('100%')
        .padding({ left: 4, right: 4 })
      }
      .id('diagnostics-disclosure')
      .width('100%')
      .height(64)
      .borderRadius(12)
      .onClick(() => {
        this.getUIContext().animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
          this.diagnosticsExpanded = !this.diagnosticsExpanded;
        });
      })

      if (this.diagnosticsExpanded) {
        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ left: 16, right: 16 })
        this.DiagnosticsPanel()
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.groupBackground())
    .borderRadius(16)
    .margin({ top: 16 })
  }

  @Builder
  private HomeContent() {
    Column({ space: 12 }) {
      this.ConnectionPanel()
      this.ExitNodePanel()
      if (this.isBackendLoading() || this.devicesLoading) {
        this.DevicesLoadingPanel()
      } else if (!this.isAuthenticated()) {
        this.DevicesSignedOutPanel()
      } else {
        this.DevicesPanel()
      }
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: 1200 })
    .padding({
      left: this.contentMargin(),
      right: this.contentMargin(),
      top: 8,
      bottom: this.pageBottomInset()
    })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private SettingsContent() {
    Scroll(this.settingsScroller) {
      Column() {
        GridRow({
          columns: { xs: 2, sm: 4, md: 8, lg: 12 },
          gutter: { x: 12, y: 8 }
        }) {
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.account_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.AccountPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.settings_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.NetworkSettingsPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.settings_appearance_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.GlowSettingsPanel()
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.SettingsGroupHeader($r('app.string.about_title'))
          }
          GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
            this.VersionPanel()
          }
          if (this.diagnosticsUnlocked) {
            GridCol({ span: { xs: 2, sm: 4, md: 8, lg: 12 } }) {
              this.DiagnosticsDisclosure()
            }
          }
        }
        .width('100%')
        .constraintSize({ maxWidth: 1200 })
      }
      .width('100%')
      .padding({
        left: this.contentMargin(),
        right: this.contentMargin(),
        top: 8,
        bottom: this.pageBottomInset()
      })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .edgeEffect(EdgeEffect.Spring)
    .scrollBar(BarState.Auto)
    .scrollBarWidth(4)
  }

  @Builder
  private HomePage() {
    HdsNavigation() {
      this.HomeContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.app_title'),
          subTitle: $r('app.string.app_tagline')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FULL)
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private SettingsPage() {
    HdsNavigation() {
      this.SettingsContent()
    }
    .titleBar({
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      padding: {
        start: LengthMetrics.vp(this.contentMargin()),
        end: LengthMetrics.vp(this.contentMargin())
      },
      style: {
        blurStrategy: BlurStrategy.ENABLE,
        thermoCtrl: true,
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(20)
        },
        originalStyle: {
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: $r('sys.color.background_secondary'),
            blurRadius: 24,
            maskExtraHeight: 40.0
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: this.glowMaterialLevel()
        }
      },
      content: {
        title: {
          mainTitle: $r('app.string.tab_settings'),
          subTitle: $r('app.string.settings_subtitle')
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.FREE)
    .bindToScrollable([this.settingsScroller])
    .hideBackButton(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }

  @Builder
  private MobileTabs() {
    HdsTabs({ barPosition: BarPosition.End, index: this.currentTab }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_home'), $r('app.string.tab_home'))
        .id('tab-home')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_settings'), $r('app.string.tab_settings'))
        .id('tab-settings')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))
    }
    .vertical(false)
    .scrollable(true)
    .animationDuration(320)
    .barMode(BarMode.Fixed)
    .barHeight(56)
    .barOverlap(true)
    .barBackgroundColor(Color.Transparent)
    .barFloatingStyle({
      barSideMargin: 16,
      barBottomMargin: 40,
      gradientMask: {
        maskColor: $r('sys.color.background_secondary'),
        maskHeight: 48
      },
      lightColor: this.glowLightColor(),
      barOpacity: 0.96,
      thermoCtrl: true,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: this.glowMaterialLevel()
      }
    })
    .divider({ mode: DividerMode.NONE })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .width('100%')
    .height('100%')
  }

  @Builder
  private WideTabs() {
    HdsTabs({ barPosition: BarPosition.Start, index: this.currentTab }) {
      TabContent() {
        this.HomePage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_home'), $r('app.string.tab_home'))
        .id('tab-home')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))

      TabContent() {
        this.SettingsPage()
      }
      .tabBar(new BottomTabBarStyle($r('app.media.tab_settings'), $r('app.string.tab_settings'))
        .id('tab-settings')
        .labelStyle({
          unselectedColor: $r('sys.color.font_secondary'),
          selectedColor: $r('sys.color.font_emphasize')
        })
        .iconStyle({
          unselectedColor: $r('sys.color.icon_secondary'),
          selectedColor: $r('sys.color.icon_emphasize')
        }))
    }
    .vertical(true)
    .scrollable(false)
    .animationDuration(280)
    .barMode(BarMode.Fixed)
    .barWidth(96)
    .barOverlap(false)
    .barBackgroundColor($r('sys.color.comp_background_primary'))
    .divider({ mode: DividerMode.NONE })
    .onChange((index: number) => {
      this.currentTab = index;
    })
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.isWideNavigation()) {
        this.WideTabs()
      } else {
        this.MobileTabs()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      this.layoutWidth = Number(newValue.width);
    })
  }
}
