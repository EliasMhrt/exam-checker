/// What the reader made of one cell.
enum ReadOutcome {
  /// A labelled cluster was matched and the teacher has not disputed it.
  read,

  /// No ink above the blank threshold. The student may have skipped the
  /// question, or written so faintly it was missed, so it is shown but never
  /// assumed.
  blank,

  /// Ink is present but no cluster could be named, or two clusters were almost
  /// equally close. The teacher must resolve this one.
  unresolved,
}

/// The outcome for a single question.
///
/// A result carries no marks of its own. [GradeResult] refuses to total
/// anything that still needs the teacher, so a half-read sheet cannot be
/// published as a score.
class AnswerResult {
  const AnswerResult({
    required this.number,
    required this.cellIndex,
    required this.correctAnswer,
    required this.detectedAnswer,
    required this.outcome,
    required this.confidence,
    this.teacherConfirmed = false,
  });

  /// Question number, matching the answer key's own numbering.
  final int number;

  /// Index into the calibration's cell list, so the UI can highlight the cell.
  final int cellIndex;

  /// Null when the key has no entry for this question. Such a question is never
  /// counted as right or wrong.
  final String? correctAnswer;

  /// Null unless [outcome] is [ReadOutcome.read].
  final String? detectedAnswer;

  final ReadOutcome outcome;

  /// How decisively the nearest cluster beat the runner-up, in 0..1.
  final double confidence;

  /// Set once the teacher has looked at this cell.
  final bool teacherConfirmed;

  bool get hasKey => correctAnswer != null;

  /// True when this question must be looked at before the sheet can be scored.
  ///
  /// A confirmed blank is fine: the teacher has seen that nothing was written.
  /// An unresolved or unconfirmed reading is not, because guessing here is
  /// exactly the failure the app exists to avoid.
  bool get needsConfirmation =>
      outcome == ReadOutcome.unresolved || !teacherConfirmed;

  bool get isCorrect => hasKey && detectedAnswer == correctAnswer;

  AnswerResult confirm() => AnswerResult(
        number: number,
        cellIndex: cellIndex,
        correctAnswer: correctAnswer,
        detectedAnswer: detectedAnswer,
        outcome: outcome,
        confidence: confidence,
        teacherConfirmed: true,
      );

  @override
  String toString() => '#$number key=${correctAnswer ?? '-'} '
      'read=${detectedAnswer ?? '-'} $outcome';
}

class GradeResult {
  const GradeResult({required this.results});

  final List<AnswerResult> results;

  /// Questions that have both a key entry and a settled reading.
  List<AnswerResult> get scored =>
      results.where((r) => r.hasKey && !r.needsConfirmation).toList();

  List<AnswerResult> get needingConfirmation =>
      results.where((r) => r.needsConfirmation).toList();

  List<AnswerResult> get withoutKey => results.where((r) => !r.hasKey).toList();

  /// Questions that can actually contribute to a mark.
  int get gradableCount => results.where((r) => r.hasKey).length;

  int get totalMarks => scored.where((r) => r.isCorrect).length;

  /// Denominator for [percentage]. Counts only questions with a key, so a gap
  /// in the key lowers the number of gradable questions instead of silently
  /// counting as wrong.
  int get denominator => gradableCount;

  double get percentage =>
      denominator == 0 ? 0 : (totalMarks / denominator) * 100;

  /// True when nothing is left for the teacher to resolve.
  bool get isComplete => results.every((r) => !r.needsConfirmation);

  List<AnswerResult> get wrongResults =>
      scored.where((r) => !r.isCorrect).toList();
}
