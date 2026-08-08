import 'package:feature_ai/src/skills/skill_frontmatter.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/tools/tool_secret_policy.dart';

class SkillBuildResult {
  final String name;
  final String description;
  final String content;
  final List<SkillReferenceItem> references;

  const SkillBuildResult({
    required this.name,
    required this.description,
    required this.content,
    required this.references,
  });
}

class SkillChangePreview {
  final String action; // 'CREATE' or 'UPDATE'
  final String beforeName;
  final String afterName;
  final String beforeDescription;
  final String afterDescription;
  final String beforeContentSnippet;
  final String afterContentSnippet;
  final bool beforeEnabled;
  final bool afterEnabled;
  final int addedReferencesCount;
  final int removedReferencesCount;
  final int modifiedReferencesCount;

  const SkillChangePreview({
    required this.action,
    required this.beforeName,
    required this.afterName,
    required this.beforeDescription,
    required this.afterDescription,
    required this.beforeContentSnippet,
    required this.afterContentSnippet,
    required this.beforeEnabled,
    required this.afterEnabled,
    required this.addedReferencesCount,
    required this.removedReferencesCount,
    required this.modifiedReferencesCount,
  });
}

class SkillDomainService {
  final ToolSecretPolicy secretPolicy;

  const SkillDomainService({this.secretPolicy = const ToolSecretPolicy()});

  /// Coerce a concise summary from raw input by stripping whitespace and truncating
  /// to 140 chars at a word boundary if necessary.
  String coerceConciseSkillSummary(String summary) {
    final normalized = summary.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 140) {
      return normalized;
    }
    final head = normalized.substring(0, 140).trim();
    final lastWordBoundary = head.lastIndexOf(' ');
    final truncated = lastWordBoundary >= 72
        ? head.substring(0, lastWordBoundary).trim()
        : head;
    return '$truncated…';
  }

  /// Generate a default title from a summary.
  String defaultExperienceSkillTitle(String summary) {
    final lines = summary
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.isEmpty) return 'Experience note';
    final firstLine = lines.first;
    if (firstLine.length <= 30) return firstLine;
    return '${firstLine.substring(0, 27).trim()}...';
  }

  /// Clean references by trimming them, removing any with empty title or content,
  /// and deduplicating by title (preserving the first occurrence).
  List<SkillReferenceItem> cleanReferences(List<SkillReferenceItem> refs) {
    final Map<String, SkillReferenceItem> seen = {};
    for (final ref in refs) {
      final title = ref.title.trim();
      final content = ref.content.trim();
      if (title.isEmpty || content.isEmpty) {
        continue;
      }
      seen.putIfAbsent(
        title,
        () => SkillReferenceItem(title: title, content: content),
      );
    }
    return List.unmodifiable(seen.values);
  }

  /// Synchronize frontmatter name/description with the targetName/targetDesc,
  /// replacing them in the header block if the text contains yaml frontmatter.
  /// If the text doesn't contain any frontmatter, it returns the text unmodified.
  String syncFrontmatterContent({
    required String rawContent,
    required String finalName,
    required String finalDesc,
  }) {
    final fm = SkillFrontmatter.parse(rawContent);
    if (fm != null) {
      if (fm.name != finalName || fm.description != finalDesc) {
        final buffer = StringBuffer()..writeln('---');
        if (finalName.contains('\n')) {
          buffer.writeln('name: >');
          for (final line in finalName.split('\n')) {
            buffer.writeln('  $line');
          }
        } else {
          buffer.writeln('name: "${SkillFrontmatter.escapeString(finalName)}"');
        }
        if (finalDesc.contains('\n')) {
          buffer.writeln('description: >');
          for (final line in finalDesc.split('\n')) {
            buffer.writeln('  $line');
          }
        } else {
          buffer.writeln(
            'description: "${SkillFrontmatter.escapeString(finalDesc)}"',
          );
        }
        buffer.write('---');
        final generatedHeader = buffer.toString();

        final fmHeaderRegex = RegExp(r'^---\r?\n[\s\S]*?\r?\n---');
        return rawContent.replaceFirst(fmHeaderRegex, generatedHeader);
      }
      return rawContent;
    } else {
      return rawContent;
    }
  }

  /// Build a new skill record's properties with cleansed and normalized content.
  SkillBuildResult buildCreateSkill({
    String? title,
    required String summary,
    String? content,
    required List<SkillReferenceItem> references,
  }) {
    final cleanedRefs = cleanReferences(references);
    final conciseSummary = coerceConciseSkillSummary(summary);

    // If content is specified, use it as is; otherwise fallback to conciseSummary
    final String baseContent = (content != null && content.trim().isNotEmpty)
        ? content
        : conciseSummary;

    final fm = SkillFrontmatter.parse(baseContent);

    // Determine finalName
    final String finalName;
    if (title != null && title.trim().isNotEmpty) {
      finalName = title.trim();
    } else if (fm?.name.isNotEmpty == true) {
      finalName = fm!.name;
    } else {
      finalName = defaultExperienceSkillTitle(conciseSummary);
    }

    // Determine finalDesc
    final String finalDesc;
    if (summary.trim().isNotEmpty) {
      finalDesc = conciseSummary;
    } else if (fm?.description.isNotEmpty == true) {
      finalDesc = fm!.description;
    } else {
      finalDesc = '';
    }

    final targetContent = syncFrontmatterContent(
      rawContent: baseContent,
      finalName: finalName,
      finalDesc: finalDesc,
    );

    return SkillBuildResult(
      name: finalName,
      description: finalDesc,
      content: targetContent,
      references: cleanedRefs,
    );
  }

  /// Build an updated skill record's properties with cleansed and normalized content,
  /// preserving untouched fields as fallback.
  SkillBuildResult buildUpdateSkill(
    AiSkillRecord current, {
    String? name,
    String? description,
    String? content,
    List<SkillReferenceItem>? references,
  }) {
    final nameValue = (name != null && name.trim().isNotEmpty)
        ? name.trim()
        : null;
    final descValue = (description != null && description.trim().isNotEmpty)
        ? description.trim()
        : null;

    final finalContent = content ?? current.content;
    final fm = SkillFrontmatter.parse(finalContent);

    final finalName =
        nameValue ?? (fm?.name.isNotEmpty == true ? fm!.name : current.name);
    final finalDesc =
        descValue ??
        (fm?.description.isNotEmpty == true
            ? fm!.description
            : current.description);

    final targetContent = syncFrontmatterContent(
      rawContent: finalContent,
      finalName: finalName,
      finalDesc: finalDesc,
    );

    final cleanedRefs = references != null
        ? cleanReferences(references)
        : current.references;

    return SkillBuildResult(
      name: finalName,
      description: finalDesc,
      content: targetContent,
      references: cleanedRefs,
    );
  }

  /// Generate a diff preview comparing before and after records.
  SkillChangePreview generatePreview(
    AiSkillRecord? before,
    AiSkillRecord after,
  ) {
    final action = before == null ? 'CREATE' : 'UPDATE';
    final beforeName = before?.name ?? '';
    final afterName = after.name;
    final beforeDesc = before?.description ?? '';
    final afterDesc = after.description;
    final beforeEnabled = before?.enabled ?? true;
    final afterEnabled = after.enabled;

    final beforeSnippet = before == null
        ? ''
        : _makeContentSnippet(before.content);
    final afterSnippet = _makeContentSnippet(after.content);

    int added = 0;
    int removed = 0;
    int modified = 0;

    if (before == null) {
      added = after.references.length;
    } else {
      final beforeRefsMap = {
        for (final r in before.references) r.title: r.content,
      };
      final afterRefsMap = {
        for (final r in after.references) r.title: r.content,
      };

      for (final title in afterRefsMap.keys) {
        if (!beforeRefsMap.containsKey(title)) {
          added++;
        } else if (beforeRefsMap[title] != afterRefsMap[title]) {
          modified++;
        }
      }
      for (final title in beforeRefsMap.keys) {
        if (!afterRefsMap.containsKey(title)) {
          removed++;
        }
      }
    }

    return SkillChangePreview(
      action: action,
      beforeName: secretPolicy.previewText(beforeName),
      afterName: secretPolicy.previewText(afterName),
      beforeDescription: secretPolicy.previewText(beforeDesc),
      afterDescription: secretPolicy.previewText(afterDesc),
      beforeContentSnippet: secretPolicy.previewText(beforeSnippet),
      afterContentSnippet: secretPolicy.previewText(afterSnippet),
      beforeEnabled: beforeEnabled,
      afterEnabled: afterEnabled,
      addedReferencesCount: added,
      removedReferencesCount: removed,
      modifiedReferencesCount: modified,
    );
  }

  String _makeContentSnippet(String content) {
    final trimmed = content.trim();
    if (trimmed.length <= 150) return trimmed;
    return '${trimmed.substring(0, 150)}...';
  }
}
