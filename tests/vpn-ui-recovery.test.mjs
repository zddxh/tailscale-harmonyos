import assert from 'node:assert/strict';
import test from 'node:test';
import { loadArkTS } from './load-arkts.mjs';
import { inspectVpnStatus } from '../entry/src/main/ets/services/VpnStatusPolicy.ts';

function fixture() {
  const f = { now: 100000, status: '', calls: [], timers: new Map(), nextTimer: 0,
    ownerResult: 'OK | state=Running | tun=false' };
  const native = {
    backendStart() { f.calls.push('acquire'); return f.ownerResult; },
    async backendVpnConfigAsync() { f.calls.push('config'); return '{}'; },
    async backendMagicDNSProbeURLAsync() { return 'SKIPPED'; },
    async backendStopAsync() { f.calls.push('release'); return 'OK'; },
    async backendSnapshot() { throw Error('foreign owner must not be queried through local core'); }
  };
  const { BridgeStatus } = loadArkTS('entry/src/main/ets/components/BridgeStatus.ets', {
    'libtailscale_ohos.so': { default: native },
    '../services/PhysicalDNS': { PhysicalDNS: class { async start() {} stop() {} } },
    '../services/VpnStatusPolicy': { inspectVpnStatus },
    '../services/LocalDiagnostics': { recordLifecycle() {} },
    '../services/VpnExtensionBinding': { vpnExtensionBinding: { allowNewConnection() {} } },
    '@kit.AbilityKit': {},
    '@kit.BasicServicesKit': { deviceInfo: { marketName: 'test', productModel: 'test' } },
    '@kit.CoreFileKit': { fileIo: { accessSync() { return true; }, readTextSync() { return f.status; } } },
    '@kit.PerformanceAnalysisKit': { hilog: { error() {} } },
    '@kit.ArkUI': {},
    '@kit.UIDesignKit': {},
    '@kit.NetworkKit': { vpnExtension: {
      async startVpnExtensionAbility() { f.calls.push('vpn-start'); },
      async stopVpnExtensionAbility() { f.calls.push('vpn-stop'); }
    } }
  }, {
    Date: { now: () => f.now }, Scroller: class {},
    setTimeout(callback, delay) { const id = ++f.nextTimer; f.timers.set(id, { callback, delay }); return id; },
    clearTimeout(id) { f.timers.delete(id); },
    setInterval() { return 1; }, clearInterval() {}
  }, source => {
    // Execute the production controller methods and field defaults verbatim.
    // Only ArkUI rendering DSL/decorators are removed for the host runtime.
    const boundary = source.indexOf('  @Builder');
    assert.ok(boundary > 0, 'component rendering boundary must exist');
    return source.slice(0, boundary).replace('@Component\nexport struct BridgeStatus',
      'export class BridgeStatus').replaceAll('@State ', '') + '\n}';
  });
  f.ui = new BridgeStatus();
  f.ui.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/test' }) });
  f.destroyed = () => { f.status = `VPN extension destroyed | heartbeatMs=${f.now}`; };
  return f;
}

test('a warm UI restores exclusive core ownership before reconnecting after explicit destruction', async () => {
  const f = fixture();
  f.ui.vpnStatus = 'OK | state=Running | tun=true';
  f.destroyed();
  assert.equal(f.ui.refreshVpnProbeStatus(), false);
  assert.equal(f.ui.vpnBackendNeedsRestore, true);
  assert.equal(f.ui.vpnStatusUncertain, false);
  await f.ui.startVpnProbe();
  assert.deepEqual(f.calls, ['acquire', 'config', 'release', 'vpn-start']);
  assert.equal(f.ui.vpnBackendNeedsRestore, false);
});

test('BUSY during restoration retains the restore requirement and explicit disconnect state', async () => {
  const f = fixture(); f.destroyed(); f.ui.refreshVpnProbeStatus();
  f.ownerResult = 'BUSY | backend owned by another process';
  f.ui.connectInProgress = true;
  await f.ui.startVpnProbe();
  assert.deepEqual(f.calls, ['acquire']);
  assert.equal(f.ui.vpnBackendNeedsRestore, true);
  assert.equal(f.ui.vpnStatusUncertain, true);
  assert.equal(f.ui.connectInProgress, false);
  assert.equal(f.ui.hasActiveVpnSession(), true);
  assert.equal(f.ui.isConnected(), false);
  for (const terminal of ['VPN extension destroyed', 'FAILED | VPN startup | code=1']) {
    f.status = `${terminal} | heartbeatMs=${f.now}`;
    f.ui.refreshVpnProbeStatus();
    assert.equal(f.ui.vpnStatusUncertain, true, terminal);
    assert.equal(f.ui.backendOwnedElsewhere, true, terminal);
    assert.equal(f.ui.hasActiveVpnSession(), true, terminal);
  }
  f.now += 10001;
  f.ownerResult = 'OK | state=Running | tun=false';
  await f.ui.startBackend();
  assert.equal(f.ui.vpnBackendNeedsRestore, false);
  assert.equal(f.ui.vpnStatusUncertain, false);
});

test('a new explicit destruction after BUSY still ends the uncertain session', async () => {
  const f = fixture(); f.destroyed(); f.ui.refreshVpnProbeStatus();
  f.ownerResult = 'BUSY | backend owned by another process';
  await f.ui.startVpnProbe();
  f.now++; f.destroyed();
  f.ui.refreshVpnProbeStatus();
  assert.equal(f.ui.vpnStatusUncertain, false);
  assert.equal(f.ui.backendOwnedElsewhere, false);
  assert.equal(f.ui.vpnBackendNeedsRestore, true);
});

test('reappearing UI and its delayed recovery can reclaim a destroyed session despite the restore flag', async () => {
  for (const delayed of [false, true]) {
    const f = fixture(); f.destroyed(); f.ui.vpnBackendNeedsRestore = true;
    for (const method of ['loadGlowLevel', 'resetDiagnosticsMode', 'verifyNativeBridge',
      'loadAppVersion', 'startHealthPolling']) f.ui[method] = () => {};
    if (delayed) f.status = `OK | state=Running | tun=true | heartbeatMs=${f.now}`;
    f.ui.aboutToAppear();
    if (delayed) {
      // The initial status is live; destruction happens before the delayed check.
      f.now += 6000;
      f.destroyed();
      f.ui.vpnBackendNeedsRestore = true;
      const recovery = [...f.timers.values()].find(timer => timer.delay === 6000);
      assert.ok(recovery);
      recovery.callback();
    }
    await f.ui.backendStartPending;
    assert.deepEqual(f.calls, ['acquire']);
    assert.equal(f.ui.vpnBackendNeedsRestore, false);
  }
});
