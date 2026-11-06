import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  });

  group('全局开关持久化', () {
    test('顶栏「刷新云」按钮开关：无记录时默认关闭，写入后可读回', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await SSHConfig.loadTopbarRefreshEnabled(), isFalse);

      await SSHConfig.saveTopbarRefreshEnabled(true);
      expect(await SSHConfig.loadTopbarRefreshEnabled(), isTrue);

      await SSHConfig.saveTopbarRefreshEnabled(false);
      expect(await SSHConfig.loadTopbarRefreshEnabled(), isFalse);
    });
  });

  // 实例（profile）持久化是连接配置的单一事实来源，此前零测试：
  // saveProfile 的 prefs/keystore 双存储分工与"写空即删"语义全靠这里钉死。
  group('实例持久化往返', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    test('saveProfile → loadAllProfiles 全字段往返（含 keystore 敏感项）',
        () async {
      const c = SSHConfig(
        host: 'lab.example.com',
        sshPort: 2222,
        username: 'jian',
        alias: '实验室机',
        localPort: 4081,
        authType: SSHConfig.authTypeKey,
        password: 'pw!',
        privateKeyPem: 'PEM-DATA',
        keyPassphrase: 'kpp',
        remotePort: 3090,
        accessToken: 'tok-dsh',
        zcodeToken: 'tok-zc',
        workbuddyToken: 'tok-wb',
        unslothPassword: 'unsloth-pw',
      );
      await SSHConfig.saveProfile(0, c);

      final all = await SSHConfig.loadAllProfiles();
      expect(all.length, SSHConfig.maxProfiles);
      final r = all[0];
      expect(r.host, 'lab.example.com');
      expect(r.sshPort, 2222);
      expect(r.username, 'jian');
      expect(r.alias, '实验室机');
      expect(r.localPort, 4081);
      expect(r.authType, SSHConfig.authTypeKey);
      expect(r.remotePort, 3090);
      // 敏感项走 keystore（此处为内存 mock），必须原样读回
      expect(r.password, 'pw!');
      expect(r.privateKeyPem, 'PEM-DATA');
      expect(r.keyPassphrase, 'kpp');
      expect(r.accessToken, 'tok-dsh');
      expect(r.zcodeToken, 'tok-zc');
      expect(r.workbuddyToken, 'tok-wb');
      expect(r.unslothPassword, 'unsloth-pw');
      // 未落盘实例保持空默认
      expect(all[2].host, isEmpty);
    });

    test('敏感项写空即删：旧值不得滞留 keystore', () async {
      await SSHConfig.saveProfile(
        1,
        const SSHConfig(
            host: 'a', username: 'u', password: 'p1', accessToken: 'tok'),
      );
      // 二次保存把 password/accessToken 清空——keystore 里的旧值必须被删掉，
      // 否则"清空 Token"只是假象，连接时旧凭据仍会被带出去。
      await SSHConfig.saveProfile(1, const SSHConfig(host: 'a', username: 'u'));

      final all = await SSHConfig.loadAllProfiles();
      expect(all[1].password, isEmpty);
      expect(all[1].accessToken, isEmpty);
      // 非敏感字段正常覆盖
      expect(all[1].host, 'a');
    });

    test('激活实例索引往返', () async {
      await SSHConfig.setActiveIndex(2);
      expect(await SSHConfig.loadActiveIndex(), 2);
    });
  });
}
