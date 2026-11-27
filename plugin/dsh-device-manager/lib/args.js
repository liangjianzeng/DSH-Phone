/**
 * 入参清洗：面板、HTTP 路由与模型给的 JSON 都会往 `serials` 里塞各种形态，
 * 这里统一收成"安全字符串数组"，并挡住会进 adb 命令行的怪值。
 *
 * 实测过的形态（全部要能吃下）：
 *   ["8b1e8747"]                     面板与工具正常形态
 *   "[\"8b1e8747\"]"                 模型把数组当 JSON 字符串传（整个值）
 *   ["[\"8b1e8747\"]"]               数组**元素内部**又是 JSON 串（verify 实测出现）
 *   "8b1e8747,192.168.1.151:5555"    逗号串
 *   ["8b1e8747, 192.168.1.151:5555"] 数组元素内部是逗号串
 *   "8b1e8747"                       单个字符串
 */

// 序列号/端点会进 adb 命令行（子进程不经 shell，但仍限定字符集挡掉 "--*" 之类）。
const SERIAL_RE = /^[A-Za-z0-9._:[\]@-]{1,128}$/;
// 至少要有一个字母或数字，挡掉 ".."、"::" 这种纯符号值。
const HAS_ALNUM = /[A-Za-z0-9]/;
const MAX_DEPTH = 3;

/** 把一个可能还裹着 JSON 数组、对象或逗号串的条目摊平成原子字符串。 */
function flatten(item, depth, out) {
  if (typeof item === 'number' && Number.isFinite(item)) {
    out.push(String(item));
    return;
  }
  if (Array.isArray(item)) {
    if (depth >= MAX_DEPTH) return;
    for (const nested of item) flatten(nested, depth + 1, out);
    return;
  }
  if (typeof item !== 'string') {
    // 整个 {"serials":[...]} 当参数传进来的形态
    if (item && typeof item === 'object' && depth < MAX_DEPTH) {
      for (const value of Object.values(item)) flatten(value, depth + 1, out);
    }
    return;
  }
  const text = item.trim();
  if (!text) return;
  if (depth < MAX_DEPTH) {
    if (text.startsWith('[') || text.startsWith('{')) {
      try {
        const parsed = JSON.parse(text);
        if (Array.isArray(parsed) || (parsed && typeof parsed === 'object')) {
          flatten(parsed, depth + 1, out);
          return;
        }
      } catch { /* 不是 JSON，继续按逗号串处理 */ }
    }
    if (text.includes(',')) {
      for (const nested of text.split(',')) flatten(nested, depth + 1, out);
      return;
    }
  }
  out.push(text);
}

/**
 * 接受：数组、逗号串、JSON 字符串、数组元素里再套上面任何一种。
 * @param {unknown} value
 * @returns {string[]} 去空白、去重、通过白名单校验后的序列号
 */
export function toSerialList(value) {
  if (value === undefined || value === null) return [];
  const atoms = [];
  if (Array.isArray(value)) {
    for (const item of value) flatten(item, 0, atoms);
  } else {
    flatten(value, 0, atoms);
  }
  const seen = new Set();
  const out = [];
  for (const atom of atoms) {
    const serial = atom.trim();
    // 拒绝：空、含空白、以 - 开头（会被 adb 当成选项）、纯符号、超白名单、重复。
    if (!serial
      || serial.startsWith('-')
      || /\s/.test(serial)
      || !HAS_ALNUM.test(serial)
      || !SERIAL_RE.test(serial)
      || seen.has(serial)) continue;
    seen.add(serial);
    out.push(serial);
  }
  return out;
}

/**
 * 「设备称呼」白名单：除了 adb 序列号 / host:port，还要能吃下用户起的别名
 * （`小米13`、`小米 13`、`Redmi K30 备用`）。这类值**只用于查注册表**，
 * 真正进 adb 命令行的目标一律取自注册表里的 transport.adbTarget，不经这里。
 */
const REF_RE = /^[\p{L}\p{N}][\p{L}\p{N}\p{M} .,:_'\u2019·+@/()\[\]-]{0,63}$/u;
// 挡掉控制符与任何可能被下游 shell / JSON / URL 重新解释的字符（纵深防御，即使现在不经 shell）。
const REF_FORBIDDEN = /[\u0000-\u001f\u007f|;&`$<>*?\\"]/;

/**
 * 与 toSerialList 同样的摊平能力（数组 / 逗号串 / JSON 字符串 / 嵌套），
 * 但允许 Unicode 字母、数字与空格，用来接"小米13"这种口语称呼。
 * @param {unknown} value
 * @returns {string[]}
 */
export function toRefList(value) {
  if (value === undefined || value === null) return [];
  const atoms = [];
  if (Array.isArray(value)) {
    for (const item of value) flatten(item, 0, atoms);
  } else {
    flatten(value, 0, atoms);
  }
  const seen = new Set();
  const out = [];
  for (const atom of atoms) {
    const ref = atom.replace(/\s+/g, ' ').trim();
    if (!ref
      || ref.startsWith('-')
      || !REF_RE.test(ref)
      || REF_FORBIDDEN.test(ref)
      || !/[\p{L}\p{N}]/u.test(ref)
      || seen.has(ref)) continue;
    seen.add(ref);
    out.push(ref);
  }
  return out;
}

/** 数字入参夹紧到区间，非法值回落到默认。 */
export function toInt(value, { min, max, fallback }) {
  const num = Number(value);
  if (!Number.isFinite(num)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(num)));
}
