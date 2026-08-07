import 'package:xterm/xterm.dart';

enum TerminalKeyboardLayer { letters, symbols, navigation, function }

enum TerminalKeyboardMode { compose, direct }

enum TerminalModifierState { off, once, locked }

class TerminalKeyboardStroke {
  const TerminalKeyboardStroke({
    this.key,
    this.text,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  }) : assert(key != null || text != null);

  final TerminalKey? key;
  final String? text;
  final bool ctrl;
  final bool alt;
  final bool shift;
}

class TerminalKeyboardKeySpec {
  const TerminalKeyboardKeySpec.character({
    required this.id,
    required this.label,
    required this.text,
    required this.terminalKey,
    this.shiftedLabel,
    this.shiftedText,
    this.flex = 1,
  }) : alwaysTerminal = false;

  const TerminalKeyboardKeySpec.text({
    required this.id,
    required this.label,
    required this.text,
    this.flex = 1,
  }) : shiftedLabel = null,
       shiftedText = null,
       terminalKey = null,
       alwaysTerminal = false;

  const TerminalKeyboardKeySpec.terminal({
    required this.id,
    required this.label,
    required this.terminalKey,
    this.flex = 1,
  }) : text = null,
       shiftedLabel = null,
       shiftedText = null,
       alwaysTerminal = true;

  final String id;
  final String label;
  final String? shiftedLabel;
  final String? text;
  final String? shiftedText;
  final TerminalKey? terminalKey;
  final double flex;
  final bool alwaysTerminal;

  String labelFor(bool shifted) {
    return shifted ? shiftedLabel ?? label : label;
  }

  String? textFor(bool shifted) {
    return shifted ? shiftedText ?? text : text;
  }
}

abstract final class TerminalKeyboardLayouts {
  static const letters = <List<TerminalKeyboardKeySpec>>[
    [
      TerminalKeyboardKeySpec.character(
        id: 'digit_1',
        label: '1',
        shiftedLabel: '!',
        text: '1',
        shiftedText: '!',
        terminalKey: TerminalKey.digit1,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_2',
        label: '2',
        shiftedLabel: '@',
        text: '2',
        shiftedText: '@',
        terminalKey: TerminalKey.digit2,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_3',
        label: '3',
        shiftedLabel: '#',
        text: '3',
        shiftedText: '#',
        terminalKey: TerminalKey.digit3,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_4',
        label: '4',
        shiftedLabel: r'$',
        text: '4',
        shiftedText: r'$',
        terminalKey: TerminalKey.digit4,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_5',
        label: '5',
        shiftedLabel: '%',
        text: '5',
        shiftedText: '%',
        terminalKey: TerminalKey.digit5,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_6',
        label: '6',
        shiftedLabel: '^',
        text: '6',
        shiftedText: '^',
        terminalKey: TerminalKey.digit6,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_7',
        label: '7',
        shiftedLabel: '&',
        text: '7',
        shiftedText: '&',
        terminalKey: TerminalKey.digit7,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_8',
        label: '8',
        shiftedLabel: '*',
        text: '8',
        shiftedText: '*',
        terminalKey: TerminalKey.digit8,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_9',
        label: '9',
        shiftedLabel: '(',
        text: '9',
        shiftedText: '(',
        terminalKey: TerminalKey.digit9,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'digit_0',
        label: '0',
        shiftedLabel: ')',
        text: '0',
        shiftedText: ')',
        terminalKey: TerminalKey.digit0,
      ),
    ],
    [
      TerminalKeyboardKeySpec.character(
        id: 'q',
        label: 'q',
        shiftedLabel: 'Q',
        text: 'q',
        shiftedText: 'Q',
        terminalKey: TerminalKey.keyQ,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'w',
        label: 'w',
        shiftedLabel: 'W',
        text: 'w',
        shiftedText: 'W',
        terminalKey: TerminalKey.keyW,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'e',
        label: 'e',
        shiftedLabel: 'E',
        text: 'e',
        shiftedText: 'E',
        terminalKey: TerminalKey.keyE,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'r',
        label: 'r',
        shiftedLabel: 'R',
        text: 'r',
        shiftedText: 'R',
        terminalKey: TerminalKey.keyR,
      ),
      TerminalKeyboardKeySpec.character(
        id: 't',
        label: 't',
        shiftedLabel: 'T',
        text: 't',
        shiftedText: 'T',
        terminalKey: TerminalKey.keyT,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'y',
        label: 'y',
        shiftedLabel: 'Y',
        text: 'y',
        shiftedText: 'Y',
        terminalKey: TerminalKey.keyY,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'u',
        label: 'u',
        shiftedLabel: 'U',
        text: 'u',
        shiftedText: 'U',
        terminalKey: TerminalKey.keyU,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'i',
        label: 'i',
        shiftedLabel: 'I',
        text: 'i',
        shiftedText: 'I',
        terminalKey: TerminalKey.keyI,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'o',
        label: 'o',
        shiftedLabel: 'O',
        text: 'o',
        shiftedText: 'O',
        terminalKey: TerminalKey.keyO,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'p',
        label: 'p',
        shiftedLabel: 'P',
        text: 'p',
        shiftedText: 'P',
        terminalKey: TerminalKey.keyP,
      ),
    ],
    [
      TerminalKeyboardKeySpec.character(
        id: 'a',
        label: 'a',
        shiftedLabel: 'A',
        text: 'a',
        shiftedText: 'A',
        terminalKey: TerminalKey.keyA,
      ),
      TerminalKeyboardKeySpec.character(
        id: 's',
        label: 's',
        shiftedLabel: 'S',
        text: 's',
        shiftedText: 'S',
        terminalKey: TerminalKey.keyS,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'd',
        label: 'd',
        shiftedLabel: 'D',
        text: 'd',
        shiftedText: 'D',
        terminalKey: TerminalKey.keyD,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'f',
        label: 'f',
        shiftedLabel: 'F',
        text: 'f',
        shiftedText: 'F',
        terminalKey: TerminalKey.keyF,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'g',
        label: 'g',
        shiftedLabel: 'G',
        text: 'g',
        shiftedText: 'G',
        terminalKey: TerminalKey.keyG,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'h',
        label: 'h',
        shiftedLabel: 'H',
        text: 'h',
        shiftedText: 'H',
        terminalKey: TerminalKey.keyH,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'j',
        label: 'j',
        shiftedLabel: 'J',
        text: 'j',
        shiftedText: 'J',
        terminalKey: TerminalKey.keyJ,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'k',
        label: 'k',
        shiftedLabel: 'K',
        text: 'k',
        shiftedText: 'K',
        terminalKey: TerminalKey.keyK,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'l',
        label: 'l',
        shiftedLabel: 'L',
        text: 'l',
        shiftedText: 'L',
        terminalKey: TerminalKey.keyL,
      ),
    ],
    [
      TerminalKeyboardKeySpec.character(
        id: 'z',
        label: 'z',
        shiftedLabel: 'Z',
        text: 'z',
        shiftedText: 'Z',
        terminalKey: TerminalKey.keyZ,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'x',
        label: 'x',
        shiftedLabel: 'X',
        text: 'x',
        shiftedText: 'X',
        terminalKey: TerminalKey.keyX,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'c',
        label: 'c',
        shiftedLabel: 'C',
        text: 'c',
        shiftedText: 'C',
        terminalKey: TerminalKey.keyC,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'v',
        label: 'v',
        shiftedLabel: 'V',
        text: 'v',
        shiftedText: 'V',
        terminalKey: TerminalKey.keyV,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'b',
        label: 'b',
        shiftedLabel: 'B',
        text: 'b',
        shiftedText: 'B',
        terminalKey: TerminalKey.keyB,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'n',
        label: 'n',
        shiftedLabel: 'N',
        text: 'n',
        shiftedText: 'N',
        terminalKey: TerminalKey.keyN,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'm',
        label: 'm',
        shiftedLabel: 'M',
        text: 'm',
        shiftedText: 'M',
        terminalKey: TerminalKey.keyM,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'comma',
        label: ',',
        shiftedLabel: '<',
        text: ',',
        shiftedText: '<',
        terminalKey: TerminalKey.comma,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'period',
        label: '.',
        shiftedLabel: '>',
        text: '.',
        shiftedText: '>',
        terminalKey: TerminalKey.period,
      ),
      TerminalKeyboardKeySpec.character(
        id: 'slash',
        label: '/',
        shiftedLabel: '?',
        text: '/',
        shiftedText: '?',
        terminalKey: TerminalKey.slash,
      ),
    ],
  ];

  static const symbols = <List<TerminalKeyboardKeySpec>>[
    [
      TerminalKeyboardKeySpec.text(id: 'pipe', label: '|', text: '|'),
      TerminalKeyboardKeySpec.text(id: 'and', label: '&&', text: '&&'),
      TerminalKeyboardKeySpec.text(id: 'or', label: '||', text: '||'),
      TerminalKeyboardKeySpec.text(id: 'semicolon', label: ';', text: ';'),
      TerminalKeyboardKeySpec.text(id: 'background', label: '&', text: '&'),
      TerminalKeyboardKeySpec.text(id: 'dollar', label: r'$', text: r'$'),
      TerminalKeyboardKeySpec.text(id: 'backtick', label: '`', text: '`'),
    ],
    [
      TerminalKeyboardKeySpec.text(id: 'redirect', label: '>', text: '>'),
      TerminalKeyboardKeySpec.text(id: 'append', label: '>>', text: '>>'),
      TerminalKeyboardKeySpec.text(id: 'input', label: '<', text: '<'),
      TerminalKeyboardKeySpec.text(id: 'heredoc', label: '<<', text: '<<'),
      TerminalKeyboardKeySpec.text(id: 'stderr', label: '2>', text: '2>'),
      TerminalKeyboardKeySpec.text(
        id: 'stderr_merge',
        label: '2>&1',
        text: '2>&1',
      ),
    ],
    [
      TerminalKeyboardKeySpec.text(id: 'single_quote', label: "'", text: "'"),
      TerminalKeyboardKeySpec.text(id: 'double_quote', label: '"', text: '"'),
      TerminalKeyboardKeySpec.text(id: 'paren', label: '( )', text: '()'),
      TerminalKeyboardKeySpec.text(id: 'bracket', label: '[ ]', text: '[]'),
      TerminalKeyboardKeySpec.text(id: 'brace', label: '{ }', text: '{}'),
      TerminalKeyboardKeySpec.text(
        id: 'variable',
        label: r'${ }',
        text: r'${}',
      ),
      TerminalKeyboardKeySpec.text(id: 'backslash', label: r'\', text: r'\'),
    ],
    [
      TerminalKeyboardKeySpec.text(id: 'dash', label: '-', text: '-'),
      TerminalKeyboardKeySpec.text(id: 'underscore', label: '_', text: '_'),
      TerminalKeyboardKeySpec.text(id: 'equals', label: '=', text: '='),
      TerminalKeyboardKeySpec.text(id: 'plus', label: '+', text: '+'),
      TerminalKeyboardKeySpec.text(id: 'star', label: '*', text: '*'),
      TerminalKeyboardKeySpec.text(id: 'question', label: '?', text: '?'),
      TerminalKeyboardKeySpec.text(id: 'tilde', label: '~', text: '~'),
    ],
  ];

  static const navigation = <List<TerminalKeyboardKeySpec>>[
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'escape',
        label: 'Esc',
        terminalKey: TerminalKey.escape,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'tab',
        label: 'Tab',
        terminalKey: TerminalKey.tab,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'insert',
        label: 'Ins',
        terminalKey: TerminalKey.insert,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'delete',
        label: 'Del',
        terminalKey: TerminalKey.delete,
      ),
    ],
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'home',
        label: 'Home',
        terminalKey: TerminalKey.home,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'up',
        label: '↑',
        terminalKey: TerminalKey.arrowUp,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'end',
        label: 'End',
        terminalKey: TerminalKey.end,
      ),
    ],
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'left',
        label: '←',
        terminalKey: TerminalKey.arrowLeft,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'down',
        label: '↓',
        terminalKey: TerminalKey.arrowDown,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'right',
        label: '→',
        terminalKey: TerminalKey.arrowRight,
      ),
    ],
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'page_up',
        label: 'PgUp',
        terminalKey: TerminalKey.pageUp,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'page_down',
        label: 'PgDn',
        terminalKey: TerminalKey.pageDown,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'backspace',
        label: '⌫',
        terminalKey: TerminalKey.backspace,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'enter',
        label: 'Enter',
        terminalKey: TerminalKey.enter,
      ),
    ],
  ];

  static const function = <List<TerminalKeyboardKeySpec>>[
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'f1',
        label: 'F1',
        terminalKey: TerminalKey.f1,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f2',
        label: 'F2',
        terminalKey: TerminalKey.f2,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f3',
        label: 'F3',
        terminalKey: TerminalKey.f3,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f4',
        label: 'F4',
        terminalKey: TerminalKey.f4,
      ),
    ],
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'f5',
        label: 'F5',
        terminalKey: TerminalKey.f5,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f6',
        label: 'F6',
        terminalKey: TerminalKey.f6,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f7',
        label: 'F7',
        terminalKey: TerminalKey.f7,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f8',
        label: 'F8',
        terminalKey: TerminalKey.f8,
      ),
    ],
    [
      TerminalKeyboardKeySpec.terminal(
        id: 'f9',
        label: 'F9',
        terminalKey: TerminalKey.f9,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f10',
        label: 'F10',
        terminalKey: TerminalKey.f10,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f11',
        label: 'F11',
        terminalKey: TerminalKey.f11,
      ),
      TerminalKeyboardKeySpec.terminal(
        id: 'f12',
        label: 'F12',
        terminalKey: TerminalKey.f12,
      ),
    ],
  ];

  static List<List<TerminalKeyboardKeySpec>> forLayer(
    TerminalKeyboardLayer layer,
  ) {
    return switch (layer) {
      TerminalKeyboardLayer.letters => letters,
      TerminalKeyboardLayer.symbols => symbols,
      TerminalKeyboardLayer.navigation => navigation,
      TerminalKeyboardLayer.function => function,
    };
  }
}
