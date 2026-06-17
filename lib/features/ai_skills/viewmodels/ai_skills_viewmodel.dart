import 'dart:async';
import 'package:flutter/material.dart';
import '../../../services/app_settings.dart';
import '../../../services/storage_service.dart';

class SkillReferenceItem {
  final String path;
  final String description;

  const SkillReferenceItem({
    required this.path,
    this.description = '',
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillReferenceItem &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          description == other.description;

  @override
  int get hashCode => path.hashCode ^ description.hashCode;
}

class AiSkillsViewModel extends ChangeNotifier {
  final StorageService _storageService;
  final AppSettings _appSettings;

  final TextEditingController nameController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();
  final TextEditingController contentController = TextEditingController();

  List<AiSkillRecord> _skills = const [];
  String? _selectedId;
  bool _enabled = true;
  bool _loading = true;
  bool _dirty = false;
  bool _hasReferences = false;
  List<SkillReferenceItem> _references = const [];

  AiSkillsViewModel({
    required StorageService storageService,
    required AppSettings appSettings,
  })  : _storageService = storageService,
        _appSettings = appSettings;

  @override
  void dispose() {
    nameController.dispose();
    descriptionController.dispose();
    contentController.dispose();
    super.dispose();
  }

  // Getters
  List<AiSkillRecord> get skills => _skills;
  String? get selectedId => _selectedId;
  bool get enabled => _enabled;
  bool get loading => _loading;
  bool get dirty => _dirty;
  AppLanguage get language => _appSettings.language;
  bool get hasReferences => _hasReferences;
  List<SkillReferenceItem> get references => _references;

  AiSkillRecord? get selectedSkill {
    for (final skill in _skills) {
      if (skill.id == _selectedId) return skill;
    }
    return null;
  }

  bool get canSave {
    return nameController.text.trim().isNotEmpty ||
        descriptionController.text.trim().isNotEmpty ||
        contentController.text.trim().isNotEmpty;
  }

  Future<void> loadSkills() async {
    _loading = true;
    notifyListeners();
    final data = await _storageService.loadAiSkills();
    _skills = data;
    _loading = false;
    if (data.isNotEmpty) {
      selectSkill(data.first);
    } else {
      notifyListeners();
    }
  }

  void parseReferencesFromContent() {
    final text = contentController.text;
    final match = RegExp(
      r'^(## (?:References|参考资料[^\n]*))\s*\n+((?:\s*-\s*[^\n]*(?:\n|$))*)',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text);

    if (match != null) {
      _hasReferences = true;
      final listText = match.group(2) ?? '';

      final rawLines = RegExp(r'^\s*-\s*([^\n]+)', multiLine: true)
          .allMatches(listText)
          .map((m) => m.group(1)!.trim())
          .where((line) => line.isNotEmpty);

      _references = rawLines.map((line) {
        // 1. 支持超链接格式: - [description](path)
        final linkMatch = RegExp(r'^\[([^\]]*)\]\(([^\)]+)\)$').firstMatch(line);
        if (linkMatch != null) {
          final desc = linkMatch.group(1)?.trim() ?? '';
          final path = linkMatch.group(2)?.trim() ?? '';
          return SkillReferenceItem(path: path, description: desc);
        }

        // 2. 支持注释格式: - path # description
        final hashIndex = line.indexOf('#');
        if (hashIndex != -1) {
          final path = line.substring(0, hashIndex).trim();
          final desc = line.substring(hashIndex + 1).trim();
          return SkillReferenceItem(path: path, description: desc);
        }

        // 3. 支持冒号分割格式: - path: description
        final colonIndex = line.indexOf(':');
        if (colonIndex != -1) {
          final path = line.substring(0, colonIndex).trim();
          final desc = line.substring(colonIndex + 1).trim();
          return SkillReferenceItem(path: path, description: desc);
        }

        // 4. 支持中文冒号分割格式: - path：description
        final cnColonIndex = line.indexOf('：');
        if (cnColonIndex != -1) {
          final path = line.substring(0, cnColonIndex).trim();
          final desc = line.substring(cnColonIndex + 1).trim();
          return SkillReferenceItem(path: path, description: desc);
        }

        // 5. 纯文件路径 fallback
        return SkillReferenceItem(path: line);
      }).toList();
    } else {
      _hasReferences = false;
      _references = const [];
    }
  }

  void updateContentWithReferences() {
    var text = contentController.text.trimRight();
    final regExp = RegExp(
      r'\n*## (?:References|参考资料[^\n]*)\s*\n+(?:\s*-\s*[^\n]*(?:\n|$))*',
      caseSensitive: false,
    );
    final hasExisting = regExp.hasMatch(text);

    if (!_hasReferences) {
      text = text.replaceAll(regExp, '').trimRight();
      _references = const [];
    } else {
      final buffer = StringBuffer('\n\n## References\n');
      if (_references.isEmpty) {
        buffer.writeln('- references/example.md # Example reference document');
      } else {
        for (final ref in _references) {
          if (ref.description.isNotEmpty) {
            buffer.writeln('- ${ref.path} # ${ref.description}');
          } else {
            buffer.writeln('- ${ref.path}');
          }
        }
      }
      final newSection = buffer.toString().trimRight();

      if (hasExisting) {
        text = text.replaceAll(regExp, newSection);
      } else {
        text = '$text$newSection';
      }
    }

    contentController.text = text;
    _dirty = true;
    notifyListeners();
  }

  void toggleReferences(bool enabled) {
    if (_hasReferences == enabled) return;
    _hasReferences = enabled;
    if (enabled && _references.isEmpty) {
      _references = const [
        SkillReferenceItem(
          path: 'references/example.md',
          description: 'Example reference document',
        )
      ];
    }
    updateContentWithReferences();
  }

  void addReference(String path, [String description = '']) {
    final trimmedPath = path.trim();
    final trimmedDesc = description.trim();
    if (trimmedPath.isEmpty) return;

    final exists = _references.any((ref) => ref.path == trimmedPath);
    if (exists) return;

    _references = [
      ..._references,
      SkillReferenceItem(path: trimmedPath, description: trimmedDesc),
    ];
    updateContentWithReferences();
  }

  void removeReference(int index) {
    if (index < 0 || index >= _references.length) return;
    final list = [..._references]..removeAt(index);
    _references = List.unmodifiable(list);
    updateContentWithReferences();
  }

  void selectSkill(AiSkillRecord skill) {
    final isSameId = _selectedId == skill.id;
    _selectedId = skill.id;
    _enabled = skill.enabled;
    _dirty = false;
    if (!isSameId) {
      nameController.text = skill.name;
      descriptionController.text = skill.description;
      contentController.text = skill.content;
    }
    parseReferencesFromContent();
    notifyListeners();
  }

  String get defaultName => language == AppLanguage.en ? 'New Skill' : '新 Skill';

  String get defaultContentTemplate {
    final now = DateTime.now();
    final name = defaultName;
    if (language == AppLanguage.en) {
      return '''---
name: $name
description: Describe when this skill should be used.
---

# $name

## When To Use

- Describe the trigger, scenario, or user request this skill supports.

## Workflow

1. Inspect the current context.
2. Follow the project-specific steps.
3. Update related references when behavior changes.

## References

- references/example.md

<!-- Created ${now.toIso8601String()} -->
''';
    } else {
      return '''---
name: $name
description: 描述此 skill 在何种情况下应当被使用。
---

# $name

## 使用场景

- 描述此 skill 支持的触发条件、场景或用户请求。

## 工作流

1. 检查当前上下文。
2. 遵循特定于项目的步骤。
3. 行为变更时更新相关 references。

## 参考资料 (References)

- references/example.md

<!-- Created ${now.toIso8601String()} -->
''';
    }
  }

  void newSkill() {
    _selectedId = null;
    nameController.text = defaultName;
    descriptionController.text = '';
    contentController.text = defaultContentTemplate;
    _enabled = true;
    _dirty = true;
    parseReferencesFromContent();
    notifyListeners();
  }

  Future<void> saveSkill() async {
    final now = DateTime.now();
    final current = selectedSkill;
    final isNew = current == null;
    final fallbackName = defaultName;
    final skill = isNew
        ? AiSkillRecord(
            id: 'skill-${now.microsecondsSinceEpoch}',
            name: nameController.text.trim().isEmpty
                ? fallbackName
                : nameController.text.trim(),
            description: descriptionController.text.trim(),
            content: contentController.text,
            enabled: _enabled,
            createdAt: now,
            updatedAt: now,
          )
        : current.copyWith(
            name: nameController.text.trim().isEmpty
                ? fallbackName
                : nameController.text.trim(),
            description: descriptionController.text.trim(),
            content: contentController.text,
            enabled: _enabled,
            updatedAt: now,
          );

    await _storageService.saveAiSkill(skill);
    final data = await _storageService.loadAiSkills();
    _skills = data;
    _selectedId = skill.id;
    _dirty = false;

    if (isNew) {
      final saved = data.firstWhere((item) => item.id == skill.id, orElse: () => skill);
      selectSkill(saved);
    } else {
      notifyListeners();
    }
  }

  Future<void> setSkillEnabled(AiSkillRecord skill, bool value) async {
    final updated = skill.copyWith(enabled: value, updatedAt: DateTime.now());
    await _storageService.saveAiSkill(updated);
    final data = await _storageService.loadAiSkills();
    _skills = data;
    if (_selectedId == skill.id) {
      selectSkill(updated);
    } else {
      notifyListeners();
    }
  }

  Future<void> deleteSkill() async {
    final skill = selectedSkill;
    if (skill == null) return;
    await _storageService.deleteAiSkill(skill.id);
    final data = await _storageService.loadAiSkills();
    _skills = data;
    _selectedId = null;
    nameController.clear();
    descriptionController.clear();
    contentController.clear();
    _enabled = true;
    _dirty = false;

    if (data.isNotEmpty) {
      selectSkill(data.first);
    } else {
      notifyListeners();
    }
  }

  void updateEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    _dirty = true;
    notifyListeners();
  }

  void markDirty() {
    if (_dirty) return;
    _dirty = true;
    notifyListeners();
  }
}
