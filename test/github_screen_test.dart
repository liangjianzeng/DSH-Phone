import 'package:dsh_phone/github_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GitHub 访问地址展示（令牌绝不外泄）', () {
    test('令牌登录地址剥掉 userinfo，界面/日志里看不到 PAT', () {
      const secret = 'github_pat_11ABCDEF0123456789_abcdefghijklmnop';
      final shown =
          githubDisplayTarget('https://x-access-token:$secret@github.com');
      expect(shown, isNot(contains(secret)));
      expect(shown, isNot(contains('x-access-token')));
      expect(shown, contains('github.com'));
      expect(shown, startsWith('https://'));
    });

    test('普通地址原样返回（错误卡片要显示真实目标，才好判断代理/镜像问题）', () {
      expect(githubDisplayTarget('https://github.com'), 'https://github.com');
      expect(githubDisplayTarget('https://ghe.corp.internal/liang/repo'),
          'https://ghe.corp.internal/liang/repo');
    });

    test('自定义账号密码前缀同样被剥掉', () {
      final shown = githubDisplayTarget('https://user:pw@example.com/a/b');
      expect(shown, isNot(contains('pw')));
      expect(shown, contains('example.com/a/b'));
    });
  });
}
