import 'dart:convert';

bool containsSubsequence(List<int> bytes, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (bytes[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

List<int> codecFrame(int eventField, List<int> payload) => <int>[
  ...bytesField(1, utf8.encode('event-a')),
  ...varintField(2, 123),
  ...varintField(3, 2),
  ...bytesField(eventField, payload),
];

List<int> varintField(int fieldNumber, int value) => <int>[
  ...varint(fieldNumber << 3),
  ...varint(value),
];

List<int> bytesField(int fieldNumber, List<int> value) => <int>[
  ...varint((fieldNumber << 3) | 2),
  ...varint(value.length),
  ...value,
];

List<int> varint(int value) {
  final bytes = <int>[];
  var remaining = value;
  do {
    final next = remaining & 0x7f;
    remaining >>= 7;
    bytes.add(remaining == 0 ? next : next | 0x80);
  } while (remaining != 0);
  return bytes;
}

List<int> unknownFields() => <int>[
  ...varintField(50, 1),
  ...varint((51 << 3) | 1),
  ...List<int>.filled(8, 0xab),
  ...bytesField(52, <int>[0xcd, 0xef]),
  ...varint((53 << 3) | 5),
  ...List<int>.filled(4, 0x12),
];
