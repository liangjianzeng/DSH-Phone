import 'dart:convert';

import 'package:dsh_phone/device_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _listEnvelope({
  List<Map<String, dynamic>> devices = const [],
  int lastScanAt = 0,
}) {
  return {
    'ok': true,
    'text': '',
    'data': {
      'devices': devices,
      'counts': {'total': devices.length, 'transports': devices.length},
      'lastScanAt': lastScanAt,
      'hostName': 'test-host',
      'adbPath': 'adb',
      'adbVersion': '1.0.41',
    },
  };
}

Map<String, dynamic> _bridgeResponse(Map<String, dynamic> envelope) {
  return {'ok': true, 'status': 200, 'body': jsonEncode(envelope), 'error': ''};
}

void main() {
  testWidgets('曾有扫描记录但无设备时仍显示扫描入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DevicePanelPage(
            request:
                (method, path, [body]) async =>
                    _bridgeResponse(_listEnvelope(lastScanAt: 123)),
            inject: (text) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('没有已知设备'), findsOneWidget);
    expect(find.text('扫描可用设备'), findsOneWidget);
    expect(find.widgetWithIcon(IconButton, Icons.radar), findsOneWidget);
  });

  testWidgets('扫描 snapshot 回传后解除忙碌并显示设备', (tester) async {
    final calls = <Map<String, String>>[];
    final device = <String, dynamic>{
      'serial': 'emulator-5554',
      'model': 'Pixel 8',
      'android': '14',
      'health': 'ok',
      'summary': '测试机',
      'transports': <dynamic>[],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DevicePanelPage(
            request: (method, path, [body]) async {
              calls.add({'method': method, 'path': path});
              if (method == 'POST') {
                return _bridgeResponse({
                  'ok': true,
                  'text': '扫描完成：1 台设备',
                  'data': {
                    'snapshot': {
                      'devices': [device],
                      'counts': {'total': 1, 'transports': 1},
                    },
                    'lastScanAt': 456,
                    'hostName': 'test-host',
                    'adbPath': 'adb',
                    'adbVersion': '1.0.41',
                  },
                });
              }
              return _bridgeResponse(_listEnvelope(lastScanAt: 123));
            },
            inject: (text) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('扫描可用设备'));
    await tester.pumpAndSettle();

    expect(find.text('Pixel 8 · Android 14'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(calls.where((call) => call['method'] == 'POST'), hasLength(1));
    expect(calls.where((call) => call['method'] == 'GET'), hasLength(1));
    final scanButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.radar),
    );
    expect(scanButton.onPressed, isNotNull);
  });

  testWidgets('RPC 双层信封 {ok,value:{ok,text,data}} 也能渲染设备', (tester) async {
    final device = <String, dynamic>{
      'serial': '98fc9410',
      'model': '2211133C',
      'android': '16',
      'health': 'ok',
      'transports': <dynamic>[],
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DevicePanelPage(
            request: (method, path, [body]) async => _bridgeResponse({
              'ok': true,
              'value': _listEnvelope(devices: [device], lastScanAt: 789),
            }),
            inject: (text) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2211133C · Android 16'), findsOneWidget);
    expect(find.textContaining('1 台设备 / 1 条通道'), findsOneWidget);
  });

  testWidgets('内层 ok=false 时按失败处理，不当空列表渲染', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DevicePanelPage(
            request: (method, path, [body]) async => _bridgeResponse({
              'ok': true,
              'value': {'ok': false, 'text': '没有可注入的设备'},
            }),
            inject: (text) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('没有可注入的设备'), findsOneWidget);
  });
}
