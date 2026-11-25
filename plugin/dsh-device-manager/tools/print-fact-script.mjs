#!/usr/bin/env node
/** 打印设备事实采集脚本（供 capture-fixtures.ps1 抓取 fixture 时使用）。 */
import { buildFactScript } from '../lib/adb.js';

process.stdout.write(buildFactScript());
