import assert from 'node:assert/strict';
import test from 'node:test';
import { loadArkTS } from './load-arkts.mjs';

function fixture() {
  const f = { files: new Map([['/test/status', 'old complete status']]), open: new Map(), order: [], short: false };
  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2 },
    openSync(path) { const file = { fd: f.open.size + 1 }; f.open.set(file.fd, path); return file; },
    writeSync(fd, data) {
      const bytes = new Uint8Array(data);
      assert.equal(f.files.get('/test/status'), 'old complete status');
      f.order.push('write');
      f.files.set(f.open.get(fd), new TextDecoder().decode(bytes));
      return f.short ? bytes.length - 1 : bytes.length;
    },
    closeSync() { f.order.push('close'); },
    renameSync(from, to) { f.order.push('rename'); f.files.set(to, f.files.get(from)); f.files.delete(from); },
    unlinkSync(path) { f.files.delete(path); },
    statSync(path) { if (!f.files.has(path)) throw Error('missing'); return { size: f.files.get(path).length }; },
    readTextSync(path) { return f.files.get(path); }
  };
  Object.assign(f, loadArkTS('entry/src/main/ets/services/LocalDiagnostics.ets', {
    '@kit.CoreFileKit': { fileIo },
    '@kit.ArkTS': { util: { TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } } } }
  }));
  return f;
}

test('publishes a complete UTF-8 status only after closing the temporary file', () => {
  const f = fixture();
  f.writeAtomicText('/test/status', '新的 complete status');
  assert.equal(f.files.get('/test/status'), '新的 complete status');
  assert.deepEqual(f.order, ['write', 'close', 'rename']);
  assert.equal(f.files.size, 1);
});

test('failed/partial writes retain the previous published status', () => {
  const f = fixture(); f.short = true;
  f.writeAtomicText('/test/status', 'new complete status');
  assert.equal(f.files.get('/test/status'), 'old complete status');
  assert.ok(!f.order.includes('rename'));
  assert.equal(f.files.size, 1);
});

test('lifecycle journal retains a bounded role-specific history and fixed numeric diagnostics', () => {
  const f = fixture();
  for (let i = 0; i < 40; i++) f.recordLifecycle('/test', 'ui', 'foreground');
  f.recordLifecycle('/test', 'ui', 'created', 7, 100, 1234);
  const lines = f.files.get('/test/ui-lifecycle-events.txt').trim().split('\n');
  assert.equal(lines.length, 32);
  assert.match(lines.at(-1), /event=created exitReason=7 exitPid=100 exitAtMs=1234 errorCode=0$/);
  f.recordLifecycle('/test', 'vpn', 'created');
  assert.ok(f.files.has('/test/vpn-lifecycle-events.txt'));
  f.recordLifecycle('/test', '../bad', 'created');
  f.recordLifecycle('/test', 'ui', 'raw user message');
  assert.equal(f.files.size, 3);
});
