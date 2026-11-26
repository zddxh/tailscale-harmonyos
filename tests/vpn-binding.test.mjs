import assert from 'node:assert/strict';
import test from 'node:test';
import { loadArkTS } from './load-arkts.mjs';
import { inspectVpnStatus } from '../entry/src/main/ets/services/VpnStatusPolicy.ts';

function fixture() {
  const f = { now: 100000, status: '', binds: [], unbinds: [], events: [], timers: new Map(), readError: false };
  const platform = loadArkTS('entry/src/main/ets/services/VpnExtensionBinding.ets', {
    '@kit.CoreFileKit': { fileIo: { readTextSync() { if (f.readError) throw Error('read unavailable'); return f.status; } } },
    './VpnStatusPolicy': { inspectVpnStatus },
    './LocalDiagnostics': { recordLifecycle(...args) { f.events.push(args[2]); } }
  }, {
    Date: { now: () => f.now },
    setInterval(callback) { const id = f.timers.size + 1; f.timers.set(id, callback); return id; },
    clearInterval(id) { f.timers.delete(id); }
  });
  f.context = {
    filesDir: '/test',
    connectServiceExtensionAbility(want, options) {
      const id = f.binds.length + 1;
      f.binds.push({ id, want, options });
      if (f.syncFailure) options.onFailed(1);
      if (f.bindError) throw Error('bind failed');
      return f.negativeHandle ? -1 : id;
    },
    async disconnectServiceExtensionAbility(id) { f.unbinds.push(id); }
  };
  f.manager = new platform.VpnExtensionBinding();
  f.live = () => { f.status = `OK | state=Running | tun=true | heartbeatMs=${f.now}`; };
  f.tick = () => { for (const callback of f.timers.values()) callback(); };
  return f;
}

test('binds once to a proven running TUN and retains binding through stale/failed reads', () => {
  const f = fixture(); f.live(); f.manager.start(f.context);
  assert.equal(f.binds.length, 1);
  assert.equal(f.binds[0].want.parameters.tailscaleBindOnly, true);
  f.binds[0].options.onConnect({}, {});
  f.now += 600000; f.tick();
  f.readError = true; f.tick();
  assert.equal(f.binds.length, 1);
  assert.deepEqual(f.unbinds, []);
  assert.ok(f.events.includes('vpn-bind-connected'));
});

test('does not bind stale, future, missing, or TUN-less status', () => {
  for (const status of ['', 'garbage', 'FAILED',
    'OK | state=Running | tun=false | heartbeatMs=100000',
    'OK | state=Running | tun=true | heartbeatMs=96000',
    'OK | state=Running | tun=true | heartbeatMs=100001']) {
    const f = fixture(); f.status = status; f.manager.start(f.context);
    assert.equal(f.binds.length, 0, status);
  }
});

test('failed and disconnected binds require both backoff and newer heartbeat', () => {
  const f = fixture(); f.live(); f.manager.start(f.context);
  f.binds[0].options.onFailed(1);
  f.now += 1000; f.live(); f.tick();
  assert.equal(f.binds.length, 1);
  f.now += 10000; f.tick();
  assert.equal(f.binds.length, 1);
  f.live(); f.tick();
  assert.equal(f.binds.length, 2);
  f.binds[1].options.onDisconnect({});
  f.tick(); assert.equal(f.binds.length, 2);
  f.now += 10001; f.live(); f.tick();
  assert.equal(f.binds.length, 3);
});

test('manual disconnect suppresses late rebinds until an explicit new connection', () => {
  const f = fixture(); f.live(); f.manager.start(f.context);
  const oldCallbacks = f.binds[0].options;
  f.manager.beforeManualStop();
  assert.deepEqual(f.unbinds, [1]);
  f.now += 10001; f.live(); oldCallbacks.onConnect({}, {}); oldCallbacks.onDisconnect({}); f.tick();
  assert.equal(f.binds.length, 1);
  f.manager.allowNewConnection(); f.tick();
  assert.equal(f.binds.length, 1);
  f.now++; f.live(); f.tick();
  assert.equal(f.binds.length, 2);
  oldCallbacks.onFailed(1); f.tick();
  assert.equal(f.binds.length, 2);
});

test('a synchronous refusal cannot install a stale connection handle', () => {
  const f = fixture(); f.syncFailure = true; f.live(); f.manager.start(f.context);
  assert.deepEqual(f.unbinds, [1]);
  f.syncFailure = false; f.now += 10001; f.live(); f.tick();
  assert.equal(f.binds.length, 2);
  f.manager.stop(); assert.deepEqual(f.unbinds, [1, 2]);
  assert.equal(f.timers.size, 0);
});

test('an explicit terminal record releases the existing binding', () => {
  const f = fixture(); f.live(); f.manager.start(f.context);
  f.status = `VPN extension destroyed | heartbeatMs=${f.now}`;
  f.tick(); assert.deepEqual(f.unbinds, [1]);
});

test('bind-only cold start never initializes a VPN or stops a native core', () => {
  let vpnStops = 0; let nativeStops = 0; let rpcObjects = 0;
  const events = [];
  const { default: Extension } = loadArkTS('entry/src/main/ets/vpnextensionability/TailscaleVpnExtensionAbility.ets', {
    '@kit.NetworkKit': {
      VpnExtensionAbility: class { context = { filesDir: '/test' }; },
      vpnExtension: {
        async stopVpnExtensionAbility() { vpnStops++; },
        createVpnConnection() { throw Error('cold binding must not create VPN'); }
      }
    },
    '@kit.BasicServicesKit': { deviceInfo: {} },
    '@kit.PerformanceAnalysisKit': { hilog: {} },
    '@kit.IPCKit': { rpc: { RemoteObject: class { constructor() { rpcObjects++; } } } },
    'libtailscale_ohos.so': { default: { async backendStopAsync() { nativeStops++; } } },
    '../services/PhysicalDNS': { PhysicalDNS: class {} },
    '../services/LocalDiagnostics': { recordLifecycle(...args) { events.push(args[2]); }, writeAtomicText() {} }
  });
  const extension = new Extension();
  extension.onCreate({ parameters: { tailscaleBindOnly: true } });
  const first = extension.onConnect({});
  assert.equal(extension.onConnect({}), first);
  extension.onDestroy();
  assert.equal(vpnStops, 1);
  assert.equal(nativeStops, 0);
  assert.equal(rpcObjects, 1);
  assert.deepEqual(events, []);
});
