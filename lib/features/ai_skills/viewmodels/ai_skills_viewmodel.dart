import 'dart:async';
import 'package:flutter/material.dart';
import '../../../services/app_settings.dart';
import '../../../services/storage_service.dart';

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
    _selectedId = skill.id;
    nameController.text = skill.name;
    descriptionController.text = skill.description;
    contentController.text = skill.content;
    _enabled = skill.enabled;
    _dirty = false;
    notifyListeners();
  }

  void newSkill(String defaultNameTemplate, String initialMarkdownTemplate) {
    _selectedId = null;
    nameController.text = defaultNameTemplate;
    descriptionController.text = '';
    contentController.text = initialMarkdownTemplate;
    _enabled = true;
    _dirty = true;
    notifyListeners();
  }

  Future<void> saveSkill(String defaultName) async {
    final now = DateTime.now();
    final current = selectedSkill;
    final skill = current == null
        ? AiSkillRecord(
            id: 'skill-${now.microsecondsSinceEpoch}',
            name: nameController.text.trim().isEmpty
                ? defaultName
                : nameController.text.trim(),
            description: descriptionController.text.trim(),
            content: contentController.text,
            enabled: _enabled,
            createdAt: now,
            updatedAt: now,
          )
        : current.copyWith(
            name: nameController.text.trim().isEmpty
                ? defaultName
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

    for (final item in data) {
      if (item.id == skill.id) {
        selectSkill(item);
        break;
      }
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
