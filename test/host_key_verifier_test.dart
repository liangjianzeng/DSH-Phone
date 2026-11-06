import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:dsh_phone/host_key_verifier.dart';

Uint8List fp(List<int> bytes) => Uint8List.fromList(bytes);

/// TOFU 严格化的核心回归面：算法集合钉扎（防"未记录算法被静默信任"的
/// 降级绕过）+ 原有指纹比对 + 各种损坏记录下的 fail-closed 姿态。
void main() {
  const verifier = HostKeyVerifier();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HostKeyVerifier（TOFU 严格化）', () {
    test('绝对首连：记录指纹与算法集合并信任', () async {
      bool? mismatch;
      final ok = await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]),
          onMismatch: () => mismatch = true);
      expect(ok, isTrue);
      expect(mismatch, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ssh_hostkey_h1_22_ssh-ed25519'), '01:02:03');
      expect(jsonDecode(prefs.getString('ssh_hostkey_algos_h1_22')!),
          contains('ssh-ed25519'));
    });

    test('同算法同指纹重连信任；指纹被篡改则拒绝并回调 onMismatch', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      expect(await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3])),
          isTrue);

      var mismatched = 0;
      final ok = await verifier.verify('h1', 22, 'ssh-ed25519', fp([9, 9, 9]),
          onMismatch: () => mismatched++);
      expect(ok, isFalse);
      expect(mismatched, 1);
    });

    test('未记录过的算法一律拒绝（防算法降级绕过），且不落新记录', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      var mismatched = 0;
      final ok = await verifier.verify('h1', 22, 'ssh-rsa', fp([4, 5, 6]),
          onMismatch: () => mismatched++);
      expect(ok, isFalse);
      expect(mismatched, 1);

      // 被拒的攻击者算法/指纹绝不能写盘——否则下次就成了"已记录"。
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('ssh_hostkey_h1_22_ssh-rsa'), isNull);
      expect(jsonDecode(prefs.getString('ssh_hostkey_algos_h1_22')!),
          isNot(contains('ssh-rsa')));
    });

    test('clearAll 重置 TOFU：合法换算法清指纹后可重新钉扎', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      expect(await verifier.verify('h1', 22, 'ssh-rsa', fp([4, 5, 6])), isFalse);

      await HostKeyVerifier.clearAll();
      expect(await verifier.verify('h1', 22, 'ssh-rsa', fp([4, 5, 6])), isTrue);
    });

    test('算法集合记录被写坏（坏 JSON）：全拒而非退回首连信任', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ssh_hostkey_algos_h1_22', 'not-json');
      // 即便指纹与既有记录一致也不能放行：集合损坏可能就是攻击者抹的。
      expect(await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3])),
          isFalse);
    });

    test('空集合"[]"（合法 JSON 但零记录）：视为已有记录，全拒', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('ssh_hostkey_algos_h1_22', '[]');
      expect(await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3])),
          isFalse);
    });

    test('algos 有记录但指纹键丢失（记录损坏）：拒绝而非重新信任', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('ssh_hostkey_h1_22_ssh-ed25519');
      expect(await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3])),
          isFalse);
    });

    test('host:port 分户记录互不干扰', () async {
      await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3]));
      // 同 host 不同端口 = 另一个服务端点，走各自的首连 TOFU。
      expect(await verifier.verify('h1', 2222, 'ssh-rsa', fp([4, 5, 6])),
          isTrue);
      expect(await verifier.verify('h2', 22, 'ssh-ed25519', fp([7, 8])),
          isTrue);
      // 原记录不受影响。
      expect(await verifier.verify('h1', 22, 'ssh-ed25519', fp([1, 2, 3])),
          isTrue);
    });
  });
}
