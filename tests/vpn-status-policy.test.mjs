import assert from 'node:assert/strict';
import test from 'node:test';
import { inspectVpnStatus } from '../entry/src/main/ets/services/VpnStatusPolicy.ts';

const now = 100000;
const running = `OK | state=Running | tun=true | heartbeatMs=${now - 1000}`;

test('only a fresh running observation proves a connected tunnel', () => {
  assert.equal(inspectVpnStatus(running, now).kind, 'running');
  assert.equal(inspectVpnStatus(running, now + 6000).kind, 'unknown');
  assert.equal(inspectVpnStatus('OK | state=Running | tun=true', now).kind, 'unknown');
  assert.equal(inspectVpnStatus('OK | state=Running | tun=true | heartbeatMs=100001', now).kind, 'unknown');
});

test('an interrupted or unreadable status record never proves disconnection', () => {
  for (const value of ['', 'OK | state=', 'garbage', 'FAILED', 'VPN extension destroyed',
    `heartbeatMs=${now}`, `OK | state=Running | heartbeatMs=NaN`]) {
    assert.equal(inspectVpnStatus(value, now).kind, 'unknown', value);
  }
});

test('runtime snapshot failures remain uncertain even with a fresh heartbeat', () => {
  for (const value of ['UNKNOWN | VPN backend | status unavailable', 'FAILED | VPN backend | status unavailable',
    'FAILED | backend status | context deadline exceeded']) {
    assert.equal(inspectVpnStatus(`${value} | heartbeatMs=${now}`, now).kind, 'unknown');
  }
});

test('explicit startup failure and destruction survive heartbeat expiry', () => {
  assert.equal(inspectVpnStatus('FAILED | VPN startup | code=1 | heartbeatMs=1000', now).kind, 'failed');
  assert.equal(inspectVpnStatus('VPN extension destroyed | heartbeatMs=1000', now).kind, 'stopped');
});

test('startup status is live only while fresh, without claiming connected', () => {
  assert.equal(inspectVpnStatus(`VPN backend starting | heartbeatMs=${now}`, now).kind, 'starting');
  assert.equal(inspectVpnStatus('VPN backend starting | heartbeatMs=1000', now).kind, 'unknown');
});
