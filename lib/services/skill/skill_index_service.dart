import '../../utils/skill_frontmatter.dart';
import '../storage_service.dart';

class SkillIndexEntry {
  final String id;
  final AiSkillRecord skill;
  final String searchableText;
  final Set<String> tokens;

  const SkillIndexEntry({
    required this.id,
    required this.skill,
    required this.searchableText,
    required this.tokens,
  });
}

class SkillSearchHit {
  final AiSkillRecord skill;
  final double score;

  const SkillSearchHit({
    required this.skill,
    required this.score,
  });
}

class SkillIndexService {
  List<SkillIndexEntry> _entries = const [];
  String? _currentRevisionKey;

  List<SkillIndexEntry> get entries => _entries;

  /// Update the in-memory index from the current list of skills.
  /// Only indexes enabled skills. Rebuilds index only when revision key changes.
  void updateIndex(List<AiSkillRecord> skills) {
    final buffer = StringBuffer();
    for (final s in skills) {
      buffer.write(
          '${s.id}:${s.updatedAt.millisecondsSinceEpoch}:${s.enabled}:${s.content.length}:${s.references.length};');
    }
    final revisionKey = buffer.toString();
    if (_currentRevisionKey == revisionKey && _entries.isNotEmpty) {
      return; // Revision matches, skip rebuilding index
    }
    _currentRevisionKey = revisionKey;

    final newEntries = <SkillIndexEntry>[];
    for (final skill in skills) {
      if (!skill.enabled) continue;

      final fm = SkillFrontmatter.parse(skill.content);
      final fmName = fm?.name ?? '';
      final fmDesc = fm?.description ?? '';
      final fmBody = fm?.body ?? skill.content;

      final refBuffer = StringBuffer();
      for (final ref in skill.references) {
        refBuffer.writeln(ref.title);
        refBuffer.writeln(ref.content);
      }

      final searchableText =
          '${skill.name}\n${skill.description}\n$fmName\n$fmDesc\n$fmBody\n${refBuffer.toString()}'
              .toLowerCase();
      final tokens = _extractTokens(searchableText);

      newEntries.add(
        SkillIndexEntry(
          id: skill.id,
          skill: skill,
          searchableText: searchableText,
          tokens: tokens,
        ),
      );
    }
    _entries = List.unmodifiable(newEntries);
  }

  /// Search indexed skills using the set of query keywords.
  List<SkillSearchHit> search(Set<String> keywords) {
    if (keywords.isEmpty) return const [];

    final hits = <SkillSearchHit>[];
    for (final entry in _entries) {
      // Pre-filter check to see if there is potential overlap with keywords
      final hasOverlap = keywords.any(
          (k) => entry.tokens.contains(k) || entry.searchableText.contains(k));
      if (!hasOverlap) continue;

      double score = 0.0;
      for (final keyword in keywords) {
        if (!entry.searchableText.contains(keyword)) continue;
        if (keyword.contains('/') || keyword.contains('.')) {
          score += 2;
        } else {
          score += 1;
        }
      }

      if (score > 0) {
        hits.add(
          SkillSearchHit(
            skill: entry.skill,
            score: score,
          ),
        );
      }
    }
    return hits;
  }

  Set<String> _extractTokens(String text) {
    final lower = text.toLowerCase();
    final tokens = <String>{};

    final englishParts = lower.split(RegExp(r'[^a-z0-9_./:-]+'));
    for (final part in englishParts) {
      final trimmed = part.trim();
      if (trimmed.length >= 2) {
        tokens.add(trimmed);
      }
    }

    final chineseRegex = RegExp(r'[一-龥]+');
    final matches = chineseRegex.allMatches(lower);
    for (final match in matches) {
      final block = match.group(0)!;
      if (block.length >= 2) {
        tokens.add(block);
        if (block.length > 2) {
          for (var i = 0; i <= block.length - 2; i++) {
            tokens.add(block.substring(i, i + 2));
          }
        }
      }
    }

    return tokens;
  }
}
