// A heartbeat proves recent activity, but its absence cannot prove process death.
// Keep this policy independent of platform APIs so background-expiry cases can
// be tested without creating a VPN or changing device settings.
export class VpnStatusObservation {
  kind: string = 'unknown';
  status: string = '';
  heartbeatMs: number = 0;
}

export function inspectVpnStatus(record: string, nowMs: number): VpnStatusObservation {
  const result = new VpnStatusObservation();
  result.status = record.replace(/\s*\|\s*heartbeatMs=\d+/, '').trim();
  const heartbeat = record.match(/heartbeatMs=(\d+)(?:\s|$)/);
  result.heartbeatMs = heartbeat === null ? 0 : Number(heartbeat[1]);
  const fresh = result.heartbeatMs > 0 && nowMs >= result.heartbeatMs &&
    nowMs - result.heartbeatMs <= 5000;
  if (result.heartbeatMs <= 0 || result.heartbeatMs > nowMs) {
    return result;
  }
  if (result.status.startsWith('VPN extension destroyed')) {
    result.kind = 'stopped';
  } else if (result.status.startsWith('UNKNOWN') ||
    result.status.startsWith('FAILED | backend status') ||
    result.status.startsWith('FAILED | VPN backend | status unavailable')) {
    result.kind = 'unknown';
  } else if (result.status.startsWith('FAILED')) {
    result.kind = 'failed';
  } else if (fresh && /(?:^|\|\s*)state=Running(?:\s|$)/.test(result.status)) {
    result.kind = 'running';
  } else if (fresh && (result.status.startsWith('VPN ') ||
    result.status.startsWith('Removing stale application VPN instance') ||
    result.status.startsWith('OK | VPN backend starting') ||
    /(?:^|\|\s*)state=Starting(?:\s|$)/.test(result.status))) {
    result.kind = 'starting';
  }
  return result;
}
