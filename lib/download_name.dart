import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 下载保存文件名工具：为下载完成的资源生成带时间戳指纹的保存文件名。
///
/// 规则：取当前时间（微秒）的 MD5 十六进制后 6 位，插入扩展名之前，
/// 如 `APK-release.apk` → `APK-release-3f9a2c.apk`。每次调用生成不同
/// 后缀，用于避免同名文件互相覆盖、便于区分多次下载。适用于全部
/// 资源类型（apk/zip/rar/pdf/mp4/exe…任意扩展名）。
///
/// 注意：MD5 十六进制仅含 0-9a-f，不会出现其它字符。
String applyTimestampSuffix(String fileName) {
  final now = DateTime.now().microsecondsSinceEpoch.toString();
  final hash = md5.convert(utf8.encode(now)).toString();
  final suffix = hash.substring(hash.length - 6);
  final dot = fileName.lastIndexOf('.');
  // 无扩展名或扩展名在首位（隐藏文件）：后缀直接追加在末尾
  if (dot <= 0) return '$fileName-$suffix';
  return '${fileName.substring(0, dot)}-$suffix${fileName.substring(dot)}';
}
