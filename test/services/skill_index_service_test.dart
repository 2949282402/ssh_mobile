import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/services/skill/skill_index_service.dart';

void main() {
  group('SkillIndexService Tests', () {
    late SkillIndexService indexService;

    setUp(() {
      indexService = SkillIndexService();
    });

    test('updateIndex indexes enabled skills and ignores disabled ones', () {
      final skills = [
        AiSkillRecord(
          id: 'skill-1',
          name: 'Docker Deploy',
          description: 'Deploy docker containers',
          content: 'Run docker compose up -d',
          enabled: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        AiSkillRecord(
          id: 'skill-2',
          name: 'Ignored Skill',
          description: 'This is disabled',
          content: 'Hidden content',
          enabled: false,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      indexService.updateIndex(skills);

      expect(indexService.entries.length, 1);
      expect(indexService.entries.first.id, 'skill-1');
    });

    test('token extraction handles english parts and paths/dots correctly', () {
      final skills = [
        AiSkillRecord(
          id: 'skill-1',
          name: 'Path config',
          description: 'Nginx config',
          content: 'Edit /etc/nginx/nginx.conf file.',
          enabled: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      indexService.updateIndex(skills);
      final entry = indexService.entries.first;

      expect(entry.tokens.contains('nginx'), isTrue);
      expect(entry.tokens.contains('/etc/nginx/nginx.conf'), isTrue);
    });

    test('token extraction handles Chinese characters with bigram slide window',
        () {
      final skills = [
        AiSkillRecord(
          id: 'skill-1',
          name: '机器学习运维',
          description: '部署模型',
          content: '使用 Docker 容器。',
          enabled: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      indexService.updateIndex(skills);
      final entry = indexService.entries.first;

      // "机器学习运维" -> "机器学习运维" (length>=2)
      // "学习" (length>=2), "机器" (bigram), "器学" (bigram), "学习" (bigram), "习运" (bigram), "运维" (bigram)
      expect(entry.tokens.contains('机器学习运维'), isTrue);
      expect(entry.tokens.contains('机器'), isTrue);
      expect(entry.tokens.contains('学习'), isTrue);
      expect(entry.tokens.contains('运维'), isTrue);
    });

    test('search calculates score matching path weighting rules', () {
      final skills = [
        AiSkillRecord(
          id: 'skill-1',
          name: 'Nginx config',
          description: 'Manage /etc/nginx/nginx.conf',
          content: 'Save custom configurations.',
          enabled: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        AiSkillRecord(
          id: 'skill-2',
          name: 'Simple Note',
          description: 'Just normal text description without paths',
          content: 'Simple content Nginx.',
          enabled: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      indexService.updateIndex(skills);

      // Search keyword with path: "/etc/nginx/nginx.conf"
      final hits1 = indexService.search({'/etc/nginx/nginx.conf'});
      expect(hits1.length, 1);
      expect(hits1.first.skill.id, 'skill-1');
      expect(hits1.first.score, 2.0); // contains '/' or '.' -> +2

      // Search keyword: "nginx"
      final hits2 = indexService.search({'nginx'});
      expect(hits2.length, 2);
      // Both should match but scores are 1.0 (no path chars in 'nginx')
      expect(hits2[0].score, 1.0);
      expect(hits2[1].score, 1.0);
    });

    test('performance benchmark with 100, 500, and 1000 mock skills', () {
      final mockSkills = List.generate(1000, (i) {
        return AiSkillRecord(
          id: 'skill-$i',
          name: 'Skill Title $i containing docker and nginx',
          description:
              'Description for skill $i with path /var/log/nginx/error.log',
          content:
              'This is the detailed body content for mock skill $i, deploying containers.',
          enabled: true,
          references: [
            SkillReferenceItem(
                title: 'Ref title $i', content: 'Instruction code config $i'),
          ],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
      });

      // Benchmark 100 skills
      indexService.updateIndex(mockSkills.take(100).toList());
      final hits100 =
          indexService.search({'docker', 'nginx', '/var/log/nginx/error.log'});
      expect(hits100.length, 100);

      // Benchmark 500 skills
      indexService.updateIndex(mockSkills.take(500).toList());
      final hits500 =
          indexService.search({'docker', 'nginx', '/var/log/nginx/error.log'});
      expect(hits500.length, 500);

      // Benchmark 1000 skills
      indexService.updateIndex(mockSkills);
      final watchSearch3 = Stopwatch()..start();
      final hits1000 =
          indexService.search({'docker', 'nginx', '/var/log/nginx/error.log'});
      watchSearch3.stop();
      final search1000Time = watchSearch3.elapsedMilliseconds;

      expect(hits1000.length, 1000);

      // Verify search times are well within acceptable bounds (typically <10ms for 1000 items in-memory)
      expect(search1000Time, lessThan(250)); // Extremely safe threshold
    });

    test('does not rebuild index when revision key matches', () {
      final skills = [
        AiSkillRecord(
          id: 'skill-1',
          name: 'Docker Deploy',
          description: 'Deploy docker containers',
          content: 'Run docker compose up -d',
          enabled: true,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ];

      indexService.updateIndex(skills);
      final firstEntries = indexService.entries;

      // Call updateIndex again with same list
      indexService.updateIndex(skills);
      final secondEntries = indexService.entries;

      // Identity check: should be the exact same list instance (cached)
      expect(identical(firstEntries, secondEntries), isTrue);
    });
  });
}
