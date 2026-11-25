#!/usr/bin/env node
/**
 * 打插件安装包：按各插件 package.json 的 `files` 清单生成
 * plugin/dist/<name>-<version>.tar.gz，并写 dist/SHA256SUMS.txt。
 *
 * 只依赖系统 tar（Windows 自带 bsdtar、Git Bash / Linux 都有），不引第三方包。
 * 用法：node plugin/tools/pack.mjs [插件目录名...]（缺省打 plugin/ 下全部）
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PLUGIN_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const DIST_DIR = join(PLUGIN_ROOT, 'dist');

/** 待打包目录：命令行参数优先，否则扫 plugin/ 下带 package.json 的子目录。 */
function targets() {
  const args = process.argv.slice(2);
  if (args.length > 0) return args.map((a) => join(PLUGIN_ROOT, a));
  return readdirSync(PLUGIN_ROOT, { withFileTypes: true })
    .filter((e) => e.isDirectory() && !['tools', 'install', 'dist'].includes(e.name))
    .map((e) => join(PLUGIN_ROOT, e.name))
    .filter((p) => existsSync(join(p, 'package.json')));
}

/** package.json.files 决定装什么；没有该字段就整目录打包（排除依赖与缓存）。 */
function fileListOf(dir) {
  const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
  const name = String(pkg.name).split('/').pop();
  if (Array.isArray(pkg.files)) {
    const files = pkg.files
      .filter((f) => !f.includes('*'))
      .map((f) => `${name}/${f}`)
      .filter((rel) => existsSync(join(PLUGIN_ROOT, rel)));
    if (files.length > 0) return { pkg, files };
  }
  const walk = (abs, rel) => {
    const out = [];
    for (const entry of readdirSync(abs, { withFileTypes: true })) {
      if (['node_modules', '.git'].includes(entry.name)) continue;
      const childAbs = join(abs, entry.name);
      const childRel = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) out.push(...walk(childAbs, childRel));
      else out.push(childRel);
    }
    return out;
  };
  return { pkg, files: walk(dir, name) };
}

function sha256(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

mkdirSync(DIST_DIR, { recursive: true });
const rows = [];
for (const dir of targets()) {
  if (!existsSync(join(dir, 'package.json'))) {
    console.error(`跳过（没有 package.json）：${dir}`);
    continue;
  }
  const { pkg, files } = fileListOf(dir);
  const name = String(pkg.name).split('/').pop();
  // 全部用相对路径：Git Bash 的 tar 会把 "E:\..." 里的冒号当成 host:path 解析失败。
  const relOut = `dist/${name}-${pkg.version}.tar.gz`;
  const relList = `.${name}.filelist`;
  writeFileSync(join(PLUGIN_ROOT, relList), files.join('\n') + '\n');
  const r = spawnSync('tar', ['-czf', relOut, '-T', relList], { cwd: PLUGIN_ROOT, stdio: 'inherit' });
  rmSync(join(PLUGIN_ROOT, relList), { force: true });
  const out = join(PLUGIN_ROOT, relOut);
  if (r.status !== 0) {
    console.error(`打包失败：${name}（tar 退出码 ${r.status}）`);
    process.exitCode = 1;
    continue;
  }
  rows.push({ name, version: pkg.version, files: files.length, bytes: statSync(out).size, sha256: sha256(out) });
}

writeFileSync(
  join(DIST_DIR, 'SHA256SUMS.txt'),
  rows.map((x) => `${x.sha256}  ${x.name}-${x.version}.tar.gz`).join('\n') + '\n',
);
for (const x of rows) {
  console.log(`${x.name}-${x.version}.tar.gz  ${x.files} 文件  ${x.bytes} B  ${x.sha256.slice(0, 12)}…`);
}
console.log(`共 ${rows.length} 个安装包 → ${DIST_DIR}`);
