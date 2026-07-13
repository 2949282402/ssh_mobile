class ParsedPlanCommand {
  final String arguments;

  const ParsedPlanCommand({required this.arguments});

  bool get hasArguments => arguments.isNotEmpty;
}

/// Parses an exact `/plan` slash command, optionally followed by arguments.
///
/// The command is case-insensitive and must be the complete first token, so
/// inputs such as `/planner` and `/plan-mode` are not treated as Plan Mode.
ParsedPlanCommand? parsePlanCommand(String input) {
  final normalized = input.trim();
  final match = RegExp(
    r'^/plan(?:\s+([\s\S]*))?$',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (match == null) return null;
  return ParsedPlanCommand(arguments: (match.group(1) ?? '').trim());
}
