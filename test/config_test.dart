import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/config.dart';

void main() {
  group('SSHConfig 纯逻辑', () {
    test('fallbackAppVersion 常量存在且为 v 前缀（运行时版本单一来源为 pubspec）', () {
      expect(SSHConfig.fallbackAppVersion, startsWith('v'));
      expect(SSHConfig.fallbackAppVersion, isNotEmpty);
    });

    test('isConfigured：主机/用户名/端口齐全才为已配置', () {
      const empty = SSHConfig();
      expect(empty.isConfigured, isFalse);

      const full = SSHConfig(host: '1.2.3.4', username: 'u');
      expect(full.isConfigured, isTrue);

      // 缺少用户名
      const noUser = SSHConfig(host: '1.2.3.4');
      expect(noUser.isConfigured, isFalse);
    });

    test('useKey 由认证方式决定', () {
      const byKey = SSHConfig(authType: SSHConfig.authTypeKey);
      expect(byKey.useKey, isTrue);

      const byPw = SSHConfig(authType: SSHConfig.authTypePassword);
      expect(byPw.useKey, isFalse);
    });

    test('label：别名优先，无别名回退地址，未配置显示未配置', () {
      const aliased = SSHConfig(host: '1.2.3.4', alias: '家里');
      expect(aliased.label, '家里');

      const bare = SSHConfig(host: '1.2.3.4');
      expect(bare.label, '1.2.3.4');

      const none = SSHConfig();
      expect(none.label, '未配置');
    });

    test('默认端口常量', () {
      expect(SSHConfig.defaultUnslothPort, 8888);
      expect(SSHConfig.minTimeoutSeconds, 30);
      expect(SSHConfig.maxTimeoutSeconds, 180);
    });

    test('实例数量上限为 3', () {
      expect(SSHConfig.maxProfiles, 3);
    });

    test('availableModes：DSH 恒在首位，可选模式按开关出现', () {
      const dshOnly = SSHConfig();
      expect(dshOnly.availableModes, [SSHConfig.modeDsh]);

      const zcodeOn = SSHConfig(zcodeEnabled: true);
      expect(zcodeOn.availableModes,
          [SSHConfig.modeDsh, SSHConfig.modeZcode]);

      const allOn = SSHConfig(zcodeEnabled: true, workbuddyEnabled: true);
      expect(allOn.availableModes, [
        SSHConfig.modeDsh,
        SSHConfig.modeZcode,
        SSHConfig.modeWorkbuddy,
      ]);
    });

    test('activeRemotePort：按当前模式取各自独立端口', () {
      const c = SSHConfig(
        remotePort: 3080,
        zcodeRemotePort: 18787,
        workbuddyRemotePort: 18790,
      );
      expect(c.copyWith(mode: SSHConfig.modeDsh).activeRemotePort, 3080);
      expect(c.copyWith(mode: SSHConfig.modeZcode).activeRemotePort, 18787);
      expect(
          c.copyWith(mode: SSHConfig.modeWorkbuddy).activeRemotePort, 18790);
    });

    test('activeModeToken：按当前模式取对应 Token 字段', () {
      const c = SSHConfig(
        accessToken: 't-dsh',
        zcodeToken: 't-zcode',
        workbuddyToken: 't-wb',
      );
      expect(c.copyWith(mode: SSHConfig.modeDsh).activeModeToken, 't-dsh');
      expect(c.copyWith(mode: SSHConfig.modeZcode).activeModeToken, 't-zcode');
      expect(
          c.copyWith(mode: SSHConfig.modeWorkbuddy).activeModeToken, 't-wb');
    });

    test('sanitized：mode 指向已关闭的可选模式时回退 DSH', () {
      const zcodeOff = SSHConfig(mode: SSHConfig.modeZcode);
      expect(zcodeOff.sanitized.mode, SSHConfig.modeDsh);

      const zcodeOn = SSHConfig(mode: SSHConfig.modeZcode, zcodeEnabled: true);
      expect(zcodeOn.sanitized.mode, SSHConfig.modeZcode);

      const wbOff = SSHConfig(mode: SSHConfig.modeWorkbuddy);
      expect(wbOff.sanitized.mode, SSHConfig.modeDsh);

      const dsh = SSHConfig();
      expect(identical(dsh.sanitized, dsh), isTrue);
    });
  });
}
