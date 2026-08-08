enum LlmApiFormat {
  openAiChatCompletions('openai_chat_completions'),
  openAiResponses('openai_responses'),
  anthropicMessages('anthropic_messages'),
  geminiNative('gemini_native'),
  geminiOpenAiCompatible('gemini_openai_compatible');

  final String value;
  const LlmApiFormat(this.value);

  static LlmApiFormat fromValue(String? value) {
    if (value == null) return LlmApiFormat.openAiChatCompletions;
    return LlmApiFormat.values.firstWhere(
      (e) => e.value == value,
      orElse: () => LlmApiFormat.openAiChatCompletions,
    );
  }
}
