import 'dart:async';
import 'package:flutter/material.dart';
import 'package:feature_ai/src/domain/ai_compat.dart';
import 'package:feature_ai/src/skills/skill_domain_service.dart';
import 'package:feature_ai/src/skills/skill_frontmatter.dart';

class AiSkillsViewModel extends ChangeNotifier {
  final AiStoragePort _storageService;
  final AppSettings _appSettings;
  final SkillDomainService _skillDomainService;

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
    required this._storageService,
    required this._appSettings,
    SkillDomainService? skillDomainService,
  }) : _skillDomainService = skillDomainService ?? const SkillDomainService();

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

  void selectSkill(AiSkillRecord skill) {
    final isSameId = _selectedId == skill.id;
    _selectedId = skill.id;
    _enabled = skill.enabled;
    _dirty = false;
    _references = skill.references;
    _hasReferences = skill.references.isNotEmpty;
    if (!isSameId) {
      final fm = SkillFrontmatter.parse(skill.content);
      nameController.text = skill.name.isNotEmpty
          ? skill.name
          : (fm?.name ?? '');
      descriptionController.text = skill.description.isNotEmpty
          ? skill.description
          : (fm?.description ?? '');
      contentController.text = skill.content;
    }
    notifyListeners();
  }

  String get defaultName =>
      language == AppLanguage.en ? 'New Skill' : '新 Skill';

  String get defaultContentTemplate {
    final now = DateTime.now();
    final name = defaultName;
    if (language == AppLanguage.en) {
      return '''---
name: $name
description: ""
---

# $name

## When To Use

- Describe the trigger, scenario, or user request this skill supports.

## Workflow

1. Inspect the current context.
2. Follow the project-specific steps.
3. Update related references when behavior changes.

<!-- Created ${now.toIso8601String()} -->
''';
    } else {
      return '''---
name: $name
description: ""
---

# $name

## 使用场景

- 描述此 skill 支持的触发条件、场景或用户请求。

## 工作流

1. 检查当前上下文。
2. 遵循特定于项目的步骤。
3. 行为变更时更新相关 references。

<!-- Created ${now.toIso8601String()} -->
''';
    }
  }

  void newSkill() {
    _selectedId = null;
    nameController.text = defaultName;
    descriptionController.text = '';
    contentController.text = defaultContentTemplate;
    _references = const [];
    _hasReferences = false;
    _enabled = true;
    _dirty = true;
    notifyListeners();
  }

  Future<void> saveSkill() async {
    final now = DateTime.now();
    final current = selectedSkill;
    final isNew = current == null;
    final activeReferences = _hasReferences
        ? _references
        : const <SkillReferenceItem>[];

    final inputName = nameController.text.trim();
    final inputDesc = descriptionController.text.trim();
    final rawContent = contentController.text;

    final buildResult = isNew
        ? _skillDomainService.buildCreateSkill(
            title: inputName,
            summary: inputDesc,
            content: rawContent,
            references: activeReferences,
          )
        : _skillDomainService.buildUpdateSkill(
            current,
            name: inputName,
            description: inputDesc,
            content: rawContent,
            references: activeReferences,
          );

    final finalName = buildResult.name;
    final finalDesc = buildResult.description;
    final targetContent = buildResult.content;
    final cleanedRefs = buildResult.references;

    // 更新 Controller 展现
    if (contentController.text != targetContent) {
      contentController.text = targetContent;
    }
    if (nameController.text != finalName) {
      nameController.text = finalName;
    }
    if (descriptionController.text != finalDesc) {
      descriptionController.text = finalDesc;
    }

    final skill = isNew
        ? AiSkillRecord(
            id: 'skill-${now.microsecondsSinceEpoch}',
            name: finalName,
            description: finalDesc,
            content: targetContent,
            enabled: _enabled,
            references: cleanedRefs,
            createdAt: now,
            updatedAt: now,
          )
        : current.copyWith(
            name: finalName,
            description: finalDesc,
            content: targetContent,
            enabled: _enabled,
            references: cleanedRefs,
            updatedAt: now,
          );

    await _storageService.saveAiSkill(skill);
    final data = await _storageService.loadAiSkills();
    _skills = data;
    _selectedId = skill.id;
    _dirty = false;

    if (isNew) {
      final saved = data.firstWhere(
        (item) => item.id == skill.id,
        orElse: () => skill,
      );
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
    _references = const [];
    _hasReferences = false;
    _enabled = true;
    _dirty = false;

    if (data.isNotEmpty) {
      selectSkill(data.first);
    } else {
      notifyListeners();
    }
  }

  void toggleReferences(bool enabled) {
    if (_hasReferences == enabled) return;
    _hasReferences = enabled;
    if (enabled && _references.isEmpty) {
      _references = const [
        SkillReferenceItem(
          title: 'Example reference document',
          content:
              'Put detailed rules, commands, or troubleshooting instructions here.',
        ),
      ];
    }
    _dirty = true;
    notifyListeners();
  }

  void addReference(String title, [String content = '']) {
    final trimmedTitle = title.trim();
    final trimmedContent = content.trim();
    if (trimmedTitle.isEmpty) return;

    final exists = _references.any((ref) => ref.title == trimmedTitle);
    if (exists) return;

    _references = [
      ..._references,
      SkillReferenceItem(title: trimmedTitle, content: trimmedContent),
    ];
    _dirty = true;
    notifyListeners();
  }

  void removeReference(int index) {
    if (index < 0 || index >= _references.length) return;
    final list = [..._references]..removeAt(index);
    _references = List.unmodifiable(list);
    _dirty = true;
    notifyListeners();
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
