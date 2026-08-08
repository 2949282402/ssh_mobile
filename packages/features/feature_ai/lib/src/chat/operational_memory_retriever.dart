import 'package:feature_ai/src/skills/skill_frontmatter.dart';
import 'package:feature_ai/src/chat/text_chunker.dart';
import 'package:app_core/app_core.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/skills/skill_index_service.dart';

class OperationalMemoryHit {
  final String sourceType;
  final String title;
  final String content;
  final double score;

  const OperationalMemoryHit({
    required this.sourceType,
    required this.title,
    required this.content,
    required this.score,
  });
}

class OperationalMemoryBundle {
  final List<RagChunk> ragChunks;
  final List<OperationalMemoryHit> hits;

  const OperationalMemoryBundle({
    this.ragChunks = const [],
    this.hits = const [],
  });

  List<String> get sourceTypes => {
    if (ragChunks.isNotEmpty) 'rag',
    ...hits.map((hit) => hit.sourceType),
  }.toList(growable: false);
}

class OperationalMemoryRetriever {
  final StorageService storageService;
  final RagCapability? ragService;
  final SkillIndexService skillIndexService;

  OperationalMemoryRetriever({
    required this.storageService,
    this.ragService,
    SkillIndexService? skillIndexService,
  }) : skillIndexService = skillIndexService ?? SkillIndexService();

  Future<OperationalMemoryBundle> retrieve({
    required String query,
    Set<String> selectedConnectionIds = const {},
    bool ragEnabled = false,
    int ragLimit = 3,
    String ragSearchMode = 'bm25',
    String ragAliyunApiKey = '',
    int hitLimit = 4,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return const OperationalMemoryBundle();
    }

    final keywords = _keywords(trimmedQuery);
    final ragChunks = <RagChunk>[];
    if (ragEnabled && ragService != null) {
      try {
        ragChunks.addAll(
          (await ragService!.retrieve(
            RagQuery(
              query: trimmedQuery,
              limit: ragLimit,
              searchMode: ragSearchMode,
              apiKey: ragAliyunApiKey,
            ),
          )).map(ragChunkFromCapability),
        );
      } catch (e) {
        AppLogService.instance.warning(
          'Operational memory RAG retrieval failed',
          details: '$e',
        );
      }
    }

    final hits = <OperationalMemoryHit>[
      ...await _skillHits(keywords),
      ...await _todoHistoryHits(keywords, selectedConnectionIds),
      ...await _playbookHits(keywords, selectedConnectionIds),
      ...await _traceHits(keywords, selectedConnectionIds),
    ];
    hits.sort((a, b) => b.score.compareTo(a.score));

    final deduped = <OperationalMemoryHit>[];
    final seen = <String>{};
    for (final hit in hits) {
      final key = '${hit.sourceType}:${hit.title}:${hit.content}';
      if (!seen.add(key)) continue;
      deduped.add(hit);
      if (deduped.length >= hitLimit) break;
    }

    return OperationalMemoryBundle(ragChunks: ragChunks, hits: deduped);
  }

  Future<List<OperationalMemoryHit>> _skillHits(Set<String> keywords) async {
    try {
      final skills = await storageService.loadAiSkills();
      final index = skillIndexService;
      index.updateIndex(skills);
      final indexHits = index.search(keywords);

      final hits = <OperationalMemoryHit>[];
      for (final hit in indexHits) {
        final skill = hit.skill;
        final fm = SkillFrontmatter.parse(skill.content);
        final fmName = fm?.name ?? '';

        final matchedRefs = <String>[];
        for (final ref in skill.references) {
          final refText = '${ref.title}\n${ref.content}'.toLowerCase();
          final refScore = _keywordScore(refText, keywords);
          if (refScore > 0) {
            matchedRefs.add('### Reference: ${ref.title}\n${ref.content}');
          }
        }

        final String finalContent;
        if (matchedRefs.isNotEmpty) {
          final limitRefs = matchedRefs.take(3).join('\n\n');
          finalContent = _clip(limitRefs);
        } else {
          finalContent = _clip(
            skill.content.isNotEmpty ? skill.content : skill.description,
          );
        }

        hits.add(
          OperationalMemoryHit(
            sourceType: 'skill',
            title: skill.name.isNotEmpty
                ? skill.name
                : (fmName.isNotEmpty ? fmName : 'Skill'),
            content: finalContent,
            score: hit.score + 1.5,
          ),
        );
      }
      return hits;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Operational memory skill index retrieval failed, falling back to legacy scan',
        error: e,
        stackTrace: stackTrace,
      );
      return _skillHitsLegacyFallback(keywords);
    }
  }

  Future<List<OperationalMemoryHit>> _skillHitsLegacyFallback(
    Set<String> keywords,
  ) async {
    final hits = <OperationalMemoryHit>[];
    for (final skill in await storageService.loadAiSkills()) {
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

      final haystack =
          '${skill.name}\n${skill.description}\n$fmName\n$fmDesc\n$fmBody\n${refBuffer.toString()}'
              .toLowerCase();
      final score = _keywordScore(haystack, keywords);
      if (score <= 0) continue;

      final matchedRefs = <String>[];
      for (final ref in skill.references) {
        final refText = '${ref.title}\n${ref.content}'.toLowerCase();
        final refScore = _keywordScore(refText, keywords);
        if (refScore > 0) {
          matchedRefs.add('### Reference: ${ref.title}\n${ref.content}');
        }
      }

      final String finalContent;
      if (matchedRefs.isNotEmpty) {
        final limitRefs = matchedRefs.take(3).join('\n\n');
        finalContent = _clip(limitRefs);
      } else {
        finalContent = _clip(
          skill.content.isNotEmpty ? skill.content : skill.description,
        );
      }

      hits.add(
        OperationalMemoryHit(
          sourceType: 'skill',
          title: skill.name.isNotEmpty
              ? skill.name
              : (fmName.isNotEmpty ? fmName : 'Skill'),
          content: finalContent,
          score: score + 1.5,
        ),
      );
    }
    return hits;
  }

  Future<List<OperationalMemoryHit>> _todoHistoryHits(
    Set<String> keywords,
    Set<String> selectedConnectionIds,
  ) async {
    final hits = <OperationalMemoryHit>[];
    final chats = await storageService.loadAiChats();
    for (final chat in chats.take(20)) {
      for (final message in chat.messages.reversed) {
        if (message.todoSteps.isEmpty) continue;
        final buffer = StringBuffer();
        var matched = false;
        var score = 0.0;
        for (final step in message.todoSteps) {
          final text = '${step.name}\n${step.description}\n${step.command}'
              .toLowerCase();
          final stepScore = _keywordScore(text, keywords);
          if (stepScore <= 0) continue;
          matched = true;
          score += stepScore;
          if (selectedConnectionIds.contains(step.connectionId)) {
            score += 2;
          }
          buffer.writeln('- ${step.name}: ${step.command}');
        }
        if (!matched) continue;
        hits.add(
          OperationalMemoryHit(
            sourceType: 'todo_history',
            title: chat.title,
            content: _clip(buffer.toString().trim()),
            score: score,
          ),
        );
      }
    }
    return hits;
  }

  Future<List<OperationalMemoryHit>> _playbookHits(
    Set<String> keywords,
    Set<String> selectedConnectionIds,
  ) async {
    final hits = <OperationalMemoryHit>[];
    for (final playbook in await storageService.loadPlaybooks()) {
      final buffer = StringBuffer()
        ..writeln(playbook.name)
        ..writeln(playbook.description);
      var score = _keywordScore(
        '${playbook.name}\n${playbook.description}'.toLowerCase(),
        keywords,
      );
      if (selectedConnectionIds.contains(playbook.lastConnectionId)) {
        score += 2;
      }
      for (final step in playbook.steps) {
        buffer.writeln('- ${step.name}: ${step.command}');
        score += _keywordScore(
          '${step.name}\n${step.description}\n${step.command}'.toLowerCase(),
          keywords,
        );
      }
      if (score <= 0) continue;
      hits.add(
        OperationalMemoryHit(
          sourceType: 'playbook',
          title: playbook.name,
          content: _clip(buffer.toString().trim()),
          score: score,
        ),
      );
    }
    return hits;
  }

  Future<List<OperationalMemoryHit>> _traceHits(
    Set<String> keywords,
    Set<String> selectedConnectionIds,
  ) async {
    final hits = <OperationalMemoryHit>[];
    final chats = await storageService.loadAiChats();
    for (final chat in chats.take(12)) {
      for (final message in chat.messages.reversed) {
        if (message.role != 'assistant') continue;
        for (final trace in message.traces.reversed) {
          if (trace.kind == 'rag_context') continue;
          final haystack = '${trace.title}\n${trace.content}'.toLowerCase();
          var score = _keywordScore(haystack, keywords);
          if (score <= 0) continue;
          for (final step in message.todoSteps) {
            if (selectedConnectionIds.contains(step.connectionId)) {
              score += 1;
              break;
            }
          }
          hits.add(
            OperationalMemoryHit(
              sourceType: 'trace',
              title: trace.title,
              content: _clip(trace.content),
              score: score,
            ),
          );
        }
      }
    }
    return hits;
  }

  Set<String> _keywords(String text) {
    final lower = text.toLowerCase();
    final keywords = <String>{};

    final englishParts = lower.split(RegExp(r'[^a-z0-9_./:-]+'));
    for (final part in englishParts) {
      final trimmed = part.trim();
      if (trimmed.length >= 2) {
        keywords.add(trimmed);
      }
    }

    final chineseRegex = RegExp(r'[一-龥]+');
    final matches = chineseRegex.allMatches(lower);
    for (final match in matches) {
      final block = match.group(0)!;
      if (block.length >= 2) {
        keywords.add(block);
        if (block.length > 2) {
          for (var i = 0; i <= block.length - 2; i++) {
            keywords.add(block.substring(i, i + 2));
          }
        }
      }
    }

    return keywords.take(20).toSet();
  }

  double _keywordScore(String haystack, Set<String> keywords) {
    var score = 0.0;
    for (final keyword in keywords) {
      if (!haystack.contains(keyword)) continue;
      if (keyword.contains('/') || keyword.contains('.')) {
        score += 2;
      } else {
        score += 1;
      }
    }
    return score;
  }

  String _clip(String text) {
    final trimmed = text.trim();
    if (trimmed.length <= 1200) return trimmed;
    return '${trimmed.substring(0, 1200)}\n...[truncated]';
  }
}
