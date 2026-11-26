import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

let temporarySequence: number = 0;
const temporaryInstance: number = Math.floor(Math.random() * 0x7fffffff);

// Publish a complete file with one rename. Readers must never observe the
// empty/truncated intermediate state of a diagnostic or heartbeat write.
export function writeAtomicText(path: string, content: string): void {
  const temporaryPath: string = `${path}.tmp-${temporaryInstance}-${++temporarySequence}`;
  let file: fileIo.File | undefined = undefined;
  try {
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(content);
    file = fileIo.openSync(temporaryPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
    const count: number = fileIo.writeSync(file.fd, bytes.buffer);
    if (count !== bytes.byteLength) {
      throw new Error('Incomplete diagnostic write');
    }
    fileIo.closeSync(file);
    file = undefined;
    fileIo.renameSync(temporaryPath, path);
  } catch (_error) {
    // Diagnostics are best effort and must never tear down a working tunnel.
  } finally {
    if (file !== undefined) {
      try { fileIo.closeSync(file); } catch (_closeError) {}
    }
    try { fileIo.unlinkSync(temporaryPath); } catch (_cleanupError) {}
  }
}

// Each process role owns its file. Fixed event codes and numeric exit fields
// deliberately exclude raw system messages, credentials and device identities.
export function recordLifecycle(filesDir: string, role: string, event: string,
  lastExitReason: number = -1, lastPid: number = 0, lastExitAtMs: number = 0,
  errorCode: number = 0): void {
  if ((role !== 'ui' && role !== 'vpn') || !/^[a-z-]{1,32}$/.test(event)) {
    return;
  }
  const path: string = `${filesDir}/${role}-lifecycle-events.txt`;
  let prior: string[] = [];
  try {
    if (fileIo.statSync(path).size <= 16384) {
      prior = fileIo.readTextSync(path).trim().split('\n').slice(-31);
    }
  } catch (_readError) {}
  prior.push(`atMs=${Date.now()} event=${event} exitReason=${lastExitReason}` +
    ` exitPid=${lastPid} exitAtMs=${lastExitAtMs} errorCode=${errorCode}`);
  writeAtomicText(path, `${prior.join('\n')}\n`);
}
