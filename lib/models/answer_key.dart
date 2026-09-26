import 'dart:math' as math;

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

  /// In question order. Numbers are preserved exactly as the teacher wrote
  /// them; see [isContiguous].
  final List<AnswerKeyEntry> entries;

  int get count => entries.length;

  int get maxNumber => entries.isEmpty
      ? 0
      : entries.map((e) => e.number).reduce(math.max);

  AnswerKeyEntry? entryFor(int number) {
    for (final e in entries) {
      if (e.number == number) return e;
    }
    return null;
  }

  /// Whether the numbers run 1, 2, 3 ... with nothing missing.
  ///
  /// A key with a gap cannot grade every question. The gap is kept rather than
  /// closed up, because closing it would shift every later answer onto the
  /// wrong question and quietly produce wrong marks.
  bool get isContiguous {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].number != i + 1) return false;
    }
    return true;
  }

  /// Question numbers absent from the key but expected before [maxNumber].
  List<int> get missingNumbers {
    if (entries.isEmpty) return const [];
    final present = entries.map((e) => e.number).toSet();
    return [
      for (var n = 1; n <= maxNumber; n++)
        if (!present.contains(n)) n,
    ];
  }
}

/// Outcome of reading pasted answer-key text.
class AnswerKeyParse {
  const AnswerKeyParse({required this.key, required this.problems});

  /// Null only when nothing usable could be read.
  final AnswerKey? key;

  /// Everything suspicious about the input, phrased for the teacher.
  ///
  /// Empty means the key is clean. A non-empty list does not block grading, but
  /// the teacher has to see it, because each entry describes a way the marks
  /// could be wrong.
  final List<String> problems;

  bool get ok => key != null && problems.isEmpty;
}

class AnswerKeyParser {
  const AnswerKeyParser._();

  /// A "1. A" style pair. The separator must be punctuation or whitespace, and
  /// the letter must be a whole token, so prose like "5 questions, answers"
  /// cannot be mistaken for question 5 answered "q".
  static final RegExp _numbered = RegExp(
    r'(\d+)\s*[.)\-:]\s*([A-Za-z])\b|(\d+)\s+([A-Za-z])\b',
  );

  /// A letter standing alone as a token.
  static final RegExp _loneLetter = RegExp(r'(?<![A-Za-z])([A-Za-z])(?![A-Za-z])');

  /// Reads answer-key text without ever guessing on the teacher's behalf.
  ///
  /// Two shapes are accepted:
  ///   "A B C D"            -> 1:A 2:B 3:C 4:D
  ///   "1. A  2. B  3. C"  -> 1:A 2:B 3:C
  ///
  /// Explicit numbers always win, and they are kept verbatim. The previous
  /// version renumbered anything non-sequential, so a key missing question 3
  /// became 1:A 2:B 3:D and question 4's answer was reported against question
  /// 3. That is a wrong mark presented as a right one, which is the one failure
  /// this app must never produce.
  static AnswerKeyParse parse(String text) {
    final problems = <String>[];

    final numbered = <int, String>{};
    final duplicates = <int>[];
    for (final m in _numbered.allMatches(text)) {
      final raw = m.group(1) ?? m.group(3);
      final letter = m.group(2) ?? m.group(4);
      if (raw == null || letter == null) continue;
      final n = int.tryParse(raw);
      if (n == null || n < 1) continue;
      if (numbered.containsKey(n)) {
        if (!duplicates.contains(n)) duplicates.add(n);
        continue;
      }
      numbered[n] = letter.toUpperCase();
    }

    if (numbered.isNotEmpty) {
      final numbers = numbered.keys.toList()..sort();
      for (final n in duplicates) {
        problems.add(
          'Question $n was given more than one answer. The first one was kept.',
        );
      }
      if (numbers.first != 1) {
        problems.add(
          'The key starts at question ${numbers.first} instead of 1. '
          'Everything before it has no key.',
        );
      }
      final present = numbered.keys.toSet();
      final gaps = <int>[
        for (var n = numbers.first; n <= numbers.last; n++)
          if (!present.contains(n)) n,
      ];
      if (gaps.isNotEmpty) {
        problems.add(
          'The key has no answer for question${gaps.length == 1 ? '' : 's'} '
          '${gaps.join(', ')}. Those questions cannot be graded until you add '
          'them. The remaining answers were left on their original numbers.',
        );
      }
      final entries = [
        for (final n in numbers)
          AnswerKeyEntry(number: n, correctAnswer: numbered[n]!),
      ];
      return AnswerKeyParse(key: AnswerKey(entries: entries), problems: problems);
    }

    // No numbers anywhere, so read a bare sequence of letters.
    final letters = [
      for (final m in _loneLetter.allMatches(text)) m.group(1)!.toUpperCase(),
    ];
    if (letters.isEmpty) {
      problems.add('No answers were found. Enter letters such as A B C D.');
      return AnswerKeyParse(key: null, problems: problems);
    }
    if (letters.length < 2) {
      problems.add(
        'Only one answer was found (${letters.first}). That looks like a typo '
        'rather than a one-question exam.',
      );
    }
    final entries = [
      for (var i = 0; i < letters.length; i++)
        AnswerKeyEntry(number: i + 1, correctAnswer: letters[i]),
    ];
    return AnswerKeyParse(key: AnswerKey(entries: entries), problems: problems);
  }
}
