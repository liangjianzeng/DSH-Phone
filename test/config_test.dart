import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_phone/config.dart';

void main() {
  group('SSHConfig 纯逻辑', () {
    test('appVersion 常量存在且为 v 前缀', () {
      expect(SSHConfig.appVersion, startsWith('v'));
      expect(SSHConfig.appVersion, isNotEmpty);
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
  });
}
