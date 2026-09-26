import 'dart:math' as math;

import 'grid_detector.dart';

/// How many writable cells make up one question.
enum CellGrouping {
  /// One cell per question; the student writes the answer letter in it.
  single,

  /// Four cells per question in A, B, C, D order; the student writes the
  /// letter in the cell they choose.
  options,
}

/// A per-exam record of where the writable cells are.
///
/// [cells] is in reading order, so `cells[i]` is the i-th cell on the page and
/// a question's cells are always a contiguous slice. That ordering is the whole
/// point: it means the app never has to understand what a cell *means*, only
/// where the cells are, and the teacher confirms the actual letter.
class ExamCalibration {
  ExamCalibration({
    required this.examId,
    required this.answerKey,
    required this.cells,
    required this.grouping,
    this.optionCount = 4,
    this.shortAnswerRegion,
    this.labelPrototypes = const {},
  });

  /// Stable identifier for the exam this calibration belongs to.
  final String examId;

  /// The correct answer letters, in question order.
  final List<String> answerKey;

  /// Writable cells in reading order.
  final List<CellRect> cells;

  final CellGrouping grouping;

  /// Cells per question when [grouping] is [CellGrouping.options].
  ///
  /// Explicit rather than inferred from the answer key: a key that happens to
  /// contain no "D" must not silently shrink the option row, and the teacher
  /// knows this number from the paper even when the key is incomplete.
  final int optionCount;

  /// Region containing the short-answer work. Deliberately not read
  /// automatically: it is cropped and shown to the teacher to mark by hand.
  final CellRect? shortAnswerRegion;

  /// Cluster label assignments learned from the teacher, keyed by cluster id.
  final Map<int, String> labelPrototypes;

  int get questionCount => answerKey.length;

  int get cellsPerQuestion =>
      grouping == CellGrouping.single ? 1 : math.max(1, optionCount);

  /// True when the cell count matches the key for this grouping, i.e. the
  /// calibration is internally consistent and safe to read with.
  bool get isConsistent =>
      cells.length == questionCount * cellsPerQuestion && cells.isNotEmpty;

  /// Cells belonging to [question] (1-based), empty when out of range.
  List<CellRect> cellsFor(int question) {
    if (question < 1 || question > questionCount) return const [];
    final start = (question - 1) * cellsPerQuestion;
    if (start + cellsPerQuestion > cells.length) return const [];
    return cells.sublist(start, start + cellsPerQuestion);
  }

  /// The single cell for [question] when grouping is [CellGrouping.single].
  CellRect? cellFor(int question) {
    final group = cellsFor(question);
    return group.isEmpty ? null : group.first;
  }

  /// Human-readable problem description for a calibration that cannot be used.
  String? validate() {
    if (cells.isEmpty) return 'No answer cells were marked.';
    if (answerKey.isEmpty) return 'No answer key was provided.';
    if (cells.length != questionCount * cellsPerQuestion) {
      return 'Marked ${cells.length} cells but the answer key has '
          '$questionCount questions at $cellsPerQuestion cell(s) each '
          '(expected ${questionCount * cellsPerQuestion}).';
    }
    return null;
  }

  ExamCalibration copyWith({
    String? examId,
    List<String>? answerKey,
    List<CellRect>? cells,
    CellGrouping? grouping,
    int? optionCount,
    CellRect? shortAnswerRegion,
    Map<int, String>? labelPrototypes,
  }) {
    return ExamCalibration(
      examId: examId ?? this.examId,
      answerKey: answerKey ?? this.answerKey,
      cells: cells ?? this.cells,
      grouping: grouping ?? this.grouping,
      optionCount: optionCount ?? this.optionCount,
      shortAnswerRegion: shortAnswerRegion ?? this.shortAnswerRegion,
      labelPrototypes: labelPrototypes ?? this.labelPrototypes,
    );
  }

  @override
  String toString() => 'ExamCalibration($examId, questions=$questionCount, '
      'cells=${cells.length}, grouping=$grouping)';
}

/// Derives the ordered cell list from two teacher drags.
///
/// [firstRowRect] must span every cell of the first question row and
/// [cellRect] must be a single cell. Measuring the row rather than assuming it
/// is what makes the inter-cell gap come out right, which is the difference
/// between a lattice that lands on the cells and one that drifts across the
/// page after the first few columns.
///
/// [blockRect] is optional and only used when the answers span several rows, to
/// recover the vertical pitch.
List<CellRect> deriveLattice({
  required CellRect firstRowRect,
  required CellRect cellRect,
  required int questionCount,
  CellGrouping grouping = CellGrouping.single,
  CellRect? blockRect,
  int optionCount = 4,
}) {
  if (questionCount < 1) return const [];
  if (cellRect.width <= 0 || cellRect.height <= 0) return const [];
  if (firstRowRect.width <= 0) return const [];

  final perQuestion = grouping == CellGrouping.single ? 1 : optionCount;
  final totalCells = questionCount * perQuestion;

  // Column count. With option grouping the teacher marked exactly one
  // question's row, so the count is known and must not be re-measured: a row
  // dragged slightly wide would otherwise invent extra columns and shift every
  // later cell off its mark. With single grouping there is nothing to know, so
  // the row is measured.
  final int columns;
  if (grouping == CellGrouping.options) {
    columns = math.max(1, optionCount);
  } else {
    columns = math.max(
        1, math.min((firstRowRect.width / cellRect.width).round(), totalCells));
  }

  // Evenly divide the measured row across the columns so the pitch absorbs the
  // gaps instead of assuming cells are flush against each other.
  final pitchX = firstRowRect.width / columns;

  final rows = (totalCells / columns).ceil();
  final cellWidth = cellRect.width;
  final cellHeight = cellRect.height;

  // Vertical pitch: prefer the measured block, else stack rows flush.
  var pitchY = cellHeight;
  if (blockRect != null && rows > 1 && blockRect.height > 0) {
    final measured = blockRect.height / rows;
    // A row gap can never be negative, and the pitch must at least fit the
    // cell; anything else means the block was marked loosely.
    if (measured >= cellHeight) {
      pitchY = measured;
    }
  }

  final out = <CellRect>[];
  for (var i = 0; i < totalCells; i++) {
    final row = i ~/ columns;
    final col = i % columns;
    final left = firstRowRect.left + pitchX * col;
    final top = firstRowRect.top + pitchY * row;
    out.add(CellRect(left, top, left + cellWidth, top + cellHeight));
  }
  return out;
}
