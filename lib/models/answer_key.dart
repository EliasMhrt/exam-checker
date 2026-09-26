import 'dart:math' as math;
import 'dart:ui';

class AnswerKeyEntry {
  const AnswerKeyEntry({required this.number, required this.correctAnswer});

  final int number;
  final String correctAnswer;

  String get display => correctAnswer;

  @override
  String toString() => '#$number: $correctAnswer'.toUpperCase();
}

class AnswerKey {
  const AnswerKey({required this.entries});

  final List<AnswerKeyEntry> entries;

  int get count => entries.length;

  AnswerKeyEntry? entryFor(int number) {
    for (final e in entries) {
      if (e.number == number) return e;
    }
    return null;
  }

  static AnswerKey fromText(String text) {
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final entries = <AnswerKeyEntry>[];

    // Pattern 1: sequential letters, e.g. "A B C D A B E..." -> 1.A 2.B 3.C ...
    final letterOnly = lines.join(' ');
    final letterMatches = RegExp(r'\b([A-E])\b', caseSensitive: false)
        .allMatches(letterOnly)
        .toList();

    if (lines.length == 1 && letterMatches.length >= 2 && !lines.first.contains(RegExp(r'\d'))) {
      for (var i = 0; i < letterMatches.length; i++) {
        entries.add(AnswerKeyEntry(
          number: i + 1,
          correctAnswer: letterMatches[i].group(1)!.toUpperCase(),
        ));
      }
      return AnswerKey(entries: entries);
    }

    // Pattern 2: numbered lines, e.g. "1. A" / "1) A" / "1 - A"
    for (final line in lines) {
      final numbered = RegExp(
        r'^\s*(\d+)\s*[.)\-:]\s*([A-E])\b',
        caseSensitive: false,
      ).firstMatch(line);
      if (numbered != null) {
        entries.add(AnswerKeyEntry(
          number: int.parse(numbered.group(1)!),
          correctAnswer: numbered.group(2)!.toUpperCase(),
        ));
      }
    }
    if (entries.isNotEmpty) {
      entries.sort((a, b) => a.number.compareTo(b.number));
      if (_isSequential(entries)) {
        return AnswerKey(entries: entries);
      }
    }
    // Fall back to letters-only grid if some lines matched numbers.
    entries.clear();
    for (final line in lines) {
      final letter = RegExp(r'\b([A-E])\b', caseSensitive: false).firstMatch(line);
      if (letter != null) {
        entries.add(AnswerKeyEntry(
          number: entries.length + 1,
          correctAnswer: letter.group(1)!.toUpperCase(),
        ));
      }
    }
    return AnswerKey(entries: entries);
  }

  static bool _isSequential(List<AnswerKeyEntry> entries) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].number != i + 1) return false;
    }
    return true;
  }

  /// Lay out the bubbles of an answer sheet in a C-column grid and return the
  /// normalized rectangle (0..1 in both axes) where question [number] sits.
  static Rect bubbleRect(int questionNumber, int totalQuestions) {
    const cols = 5;
    const rows = 5;
    const marginX = 0.06;
    const sheetTop = 0.22;
    const sheetHeight = 0.62;
    const gapX = 0.015;
    const gapY = 0.012;

    final idx = questionNumber - 1;
    final col = (idx % cols).toDouble();
    final row = (idx ~/ cols).toDouble();
    final effectiveRows = math.max(1, (totalQuestions / cols).ceil());
    final cellW = (1.0 - 2 * marginX - (cols - 1) * gapX) / cols;
    final cellH =
        totalQuestions <= rows * cols
            ? (sheetHeight - (rows - 1) * gapY) / rows
            : (sheetHeight - (effectiveRows - 1) * gapY) / effectiveRows;

    final left = marginX + col * (cellW + gapX);
    final top = sheetTop + row * (cellH + gapY);
    return Rect.fromLTWH(left, top, cellW, cellH);
  }
}