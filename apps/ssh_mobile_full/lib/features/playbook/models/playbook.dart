enum StepStatus { pending, running, success, failed, skipped }

class PlaybookStep {
  final String id;
  final String name;
  final String command;
  final String description;
  final String? expectedOutcomeRegex;
  StepStatus status;
  String? stdout;
  String? stderr;
  int? exitCode;

  PlaybookStep({
    required this.id,
    required this.name,
    required this.command,
    required this.description,
    this.expectedOutcomeRegex,
    this.status = StepStatus.pending,
    this.stdout,
    this.stderr,
    this.exitCode,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'command': command,
      'description': description,
      'expectedOutcomeRegex': expectedOutcomeRegex,
      'status': status.name,
      'stdout': stdout,
      'stderr': stderr,
      'exitCode': exitCode,
    };
  }

  factory PlaybookStep.fromJson(Map<String, dynamic> json) {
    return PlaybookStep(
      id: json['id'] as String,
      name: json['name'] as String,
      command: json['command'] as String,
      description: json['description'] as String,
      expectedOutcomeRegex: json['expectedOutcomeRegex'] as String?,
      status: StepStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => StepStatus.pending,
      ),
      stdout: json['stdout'] as String?,
      stderr: json['stderr'] as String?,
      exitCode: json['exitCode'] as int?,
    );
  }

  PlaybookStep copyWith({
    String? id,
    String? name,
    String? command,
    String? description,
    String? expectedOutcomeRegex,
    StepStatus? status,
    String? stdout,
    String? stderr,
    int? exitCode,
  }) {
    return PlaybookStep(
      id: id ?? this.id,
      name: name ?? this.name,
      command: command ?? this.command,
      description: description ?? this.description,
      expectedOutcomeRegex: expectedOutcomeRegex ?? this.expectedOutcomeRegex,
      status: status ?? this.status,
      stdout: stdout ?? this.stdout,
      stderr: stderr ?? this.stderr,
      exitCode: exitCode ?? this.exitCode,
    );
  }
}

class Playbook {
  final String id;
  final String name;
  final String description;
  final List<PlaybookStep> steps;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? lastConnectionId;

  Playbook({
    required this.id,
    required this.name,
    required this.description,
    required this.steps,
    required this.createdAt,
    required this.updatedAt,
    this.lastConnectionId,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'steps': steps.map((s) => s.toJson()).toList(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'lastConnectionId': lastConnectionId,
    };
  }

  factory Playbook.fromJson(Map<String, dynamic> json) {
    return Playbook(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      steps: (json['steps'] as List)
          .map((s) => PlaybookStep.fromJson(s as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      lastConnectionId: json['lastConnectionId'] as String?,
    );
  }

  Playbook copyWith({
    String? id,
    String? name,
    String? description,
    List<PlaybookStep>? steps,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? lastConnectionId,
  }) {
    return Playbook(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      steps: steps ?? this.steps,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      lastConnectionId: lastConnectionId ?? this.lastConnectionId,
    );
  }
}
