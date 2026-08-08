import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_ai/ai_chat.dart';

void main() {
  testWidgets('system back closes visible chat history before the route', (
    tester,
  ) async {
    var closeCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ChatHistoryBackScope(
          historyVisible: true,
          onCloseHistory: () => closeCount += 1,
          child: const Scaffold(body: Text('Chat body')),
        ),
      ),
    );

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();

    expect(handled, isTrue);
    expect(closeCount, 1);
    expect(find.text('Chat body'), findsOneWidget);
  });
}
