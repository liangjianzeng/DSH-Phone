/**
 * 网络探测：TCP 探活、CIDR 候选生成、Tailscale peer 列表、mDNS 发现。
 *
 * 安全边界（方案 §11）：局域网扫段默认关闭，必须显式配置 CIDR；候选数量、并发、
 * 速率都有硬上限，命中即销毁 socket，不重试成打洞。
 *
 * `net` 由调用方注入，便于自测时用假实现替换。
 */

/** CIDR（或裸 IP / IP/掩码位）→ 候选 IP 列表，带总量上限。 */
export function expandCidrs(cidrs, { maxIps = 512 } = {}) {
  const out = [];
  const notes = [];
  for (const entry of cidrs ?? []) {
    const spec = String(entry ?? '').trim();
    if (!spec) continue;
    const [base, maskText] = spec.split('/');
    const octets = base.split('.').map((part) => Number(part));
    if (octets.length !== 4 || octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
      notes.push(`忽略非法 CIDR：${spec}`);
      continue;
    }
    const mask = maskText === undefined ? 32 : Number(maskText);
    if (!Number.isInteger(mask) || mask < 0 || mask > 32) {
      notes.push(`忽略非法掩码：${spec}`);
      continue;
    }
    const hostBits = 32 - mask;
    // 1 << 32 === 1、1 << 31 为负：用 2 ** hostBits（hostBits ≤ 32 内是精确整数）。
    const total = 2 ** hostBits;
    if (mask < 8) {
      // /8 以上是 1600 万个地址，绝不是"扫 adb 端口"的意图；静默截断会让人以为扫过了。
      notes.push(`忽略过大的网段：${spec}（掩码需 ≥ 8，请用 maxIps 控制规模而不是放开大类）`);
      continue;
    }
    // /31、/32 不跳网络地址与广播地址；其余跳过首尾。
    const first = hostBits > 1 ? 1 : 0;
    const last = hostBits > 1 ? total - 1 : total;
    const baseInt = ((octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]) >>> 0;
    const block = mask === 32 ? baseInt : (baseInt & ~(0xffffffff >>> mask)) >>> 0;
    for (let i = first; i < last; i += 1) {
      if (out.length >= maxIps) {
        notes.push(`候选达到上限 ${maxIps}，后续候选被截断`);
        return { ips: out, notes, truncated: true };
      }
      out.push(intToIp((block + i) >>> 0));
    }
  }
  return { ips: out, notes, truncated: false };
}

export function intToIp(value) {
  return [(value >>> 24) & 255, (value >>> 16) & 255, (value >>> 8) & 255, value & 255].join('.');
}

/**
 * 并发 + 限速的 TCP 探活。
 * @param {Array<{host: string, port: number}>} targets
 * @param {{net: typeof import('node:net'), timeoutMs?: number, concurrency?: number, ratePerSec?: number, signal?: AbortSignal}} options
 * @returns {Promise<Array<{host: string, port: number, open: boolean, ms: number, error?: string}>>}
 */
export async function tcpProbe(targets, options) {
  const {
    net,
    timeoutMs = 250,
    concurrency = 32,
    ratePerSec = 200,
    signal,
  } = options ?? {};
  if (!net?.connect) throw new Error('tcpProbe 需要注入 net 模块');
  const queue = [...(targets ?? [])];
  const results = [];
  const minGapMs = ratePerSec > 0 ? 1000 / ratePerSec : 0;
  let lastStart = 0;
  let active = 0;

  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const probeOne = (target) => new Promise((resolve) => {
    const startedAt = Date.now();
    let settled = false;
    const finish = (open, error) => {
      if (settled) return;
      settled = true;
      socket.removeAllListeners();
      socket.destroy();
      resolve({ host: target.host, port: target.port, open, ms: Date.now() - startedAt, error });
    };
    const socket = net.connect({ host: target.host, port: target.port });
    socket.setTimeout(timeoutMs);
    socket.on('connect', () => finish(true));
    socket.on('timeout', () => finish(false, 'timeout'));
    socket.on('error', (error) => finish(false, String(error?.code ?? error?.message ?? error)));
    socket.on('close', () => finish(false, 'closed'));
  });

  const workers = Array.from({ length: Math.max(1, Math.min(concurrency, 64)) }, async () => {
    while (queue.length > 0) {
      if (signal?.aborted) return;
      const gap = lastStart ? Date.now() - lastStart : minGapMs;
      if (gap < minGapMs) await wait(minGapMs - gap);
      const target = queue.shift();
      if (!target) return;
      lastStart = Date.now();
      active += 1;
      try {
        results.push(await probeOne(target));
      } finally {
        active -= 1;
      }
    }
  });

  await Promise.all(workers);
  return results;
}

/** Tailscale peer → 候选 host（只有在线 peer 参与扫描）。 */
export function tailscaleCandidates(status, { ports = [5555] } = {}) {
  const targets = [];
  for (const peer of status?.peers ?? []) {
    if (peer.online === false) continue;
    for (const ip of peer.ips ?? []) {
      if (!/^\d+\.\d+\.\d+\.\d+$/.test(ip)) continue;
      for (const port of ports) targets.push({ host: ip, port, peer: peer.name });
    }
  }
  return targets;
}

/** 组装一次全量扫描要探测的 TCP 端点集合（去重）。 */
export function buildProbeTargets({ lan, tailscaleStatus, tailnetPorts = [5555], lanPorts = [5555], mdns = [] }) {
  const seen = new Set();
  const targets = [];
  const add = (host, port, source, extra = {}) => {
    const key = `${host}:${port}`;
    if (seen.has(key)) return;
    seen.add(key);
    targets.push({ host, port, source, ...extra });
  };
  for (const item of mdns) {
    if (item.serviceType === 'connect') add(item.address, item.port, 'mdns', { instance: item.instance });
  }
  if (lan?.enabled) {
    const { ips, notes, truncated } = expandCidrs(lan.cidrs, { maxIps: lan.maxIps ?? 512 });
    for (const ip of ips) for (const port of lanPorts) add(ip, port, 'lan', { notes, truncated });
  }
  for (const target of tailscaleCandidates({ peers: tailscaleStatus?.peers ?? [] }, { ports: tailnetPorts })) {
    add(target.host, target.port, 'tailscale', { peer: target.peer });
  }
  return targets;
}
