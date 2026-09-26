import 'dart:math' as math;
import 'dart:typed_data';

import '../models/answer_key.dart';
import '../models/grade_result.dart';
import 'calibration.dart';
import 'gray_image.dart';
import 'grid_detector.dart';
import 'letter_cluster.dart';
import 'letter_features.dart';

/// What was read from one writable cell.
class CellReading {
  const CellReading({
    required this.cellIndex,
    required this.questionNumber,
    required this.slot,
    required this.rect,
    required this.features,
  });

  /// Index into the calibration's cell list.
  final int cellIndex;

  /// 1-based question this cell belongs to.
  final int questionNumber;

  /// 0-based position within the question's cells.
  final int slot;

  final CellRect rect;

  /// Null when the cell held no ink above the blank threshold.
  final LetterFeatures? features;

  bool get isBlank => features == null;
}

/// Everything one photograph says, before the teacher has interpreted it.
class SheetReading {
  SheetReading({
    required this.cells,
    required this.clusters,
    required this.samples,
    required this.sampleCells,
  });

  final List<CellReading> cells;

  /// Unsupervised groups of similar cells. Ids are meaningless until the
  /// teacher names them.
  final LetterClusters clusters;

  /// Descriptors of the non-blank cells, the input to [clusters].
  final List<LetterFeatures> samples;

  /// Cell index of each entry in [samples], so a cluster can be traced back to
  /// the cells on the page.
  final List<int> sampleCells;

  List<CellReading> get blankCells =>
      [for (final c in cells) if (c.isBlank) c];
}

/// Turns a photograph plus a calibration into grades, on device.
///
/// Nothing here talks to a network. The pipeline is deliberately staged so the
/// teacher always sees the raw reading before any mark exists: crop cells,
/// describe them, group them, let the teacher name the groups, and only then
/// compare against the key.
class OmrService {
  const OmrService();

  /// Decodes an encoded image file and reads every calibrated cell.
  SheetReading readImage(Uint8List bytes, ExamCalibration calibration) =>
      read(GrayImage.decode(bytes), calibration);

  /// Reads every calibrated cell out of an already-decoded luminance plane.
  ///
  /// [calibration] cells are normalised rectangles over the image, so the same
  /// calibration works for any photo taken from roughly the same position.
  SheetReading read(GrayImage gray, ExamCalibration calibration) {
    final problem = calibration.validate();
    if (problem != null) {
      throw OmrReadException(problem);
    }

    final cells = <CellReading>[];
    final samples = <LetterFeatures>[];
    final sampleCells = <int>[];

    for (var i = 0; i < calibration.cells.length; i++) {
      final rect = calibration.cells[i];
      final crop = _cropNormalized(gray, rect);
      final features = extractLetterFeatures(crop);
      cells.add(CellReading(
        cellIndex: i,
        questionNumber: i ~/ calibration.cellsPerQuestion + 1,
        slot: i % calibration.cellsPerQuestion,
        rect: rect,
        features: features,
      ));
      if (features != null) {
        samples.add(features);
        sampleCells.add(i);
      }
    }

    // One alphabet is shared by the whole sheet: the same student wrote every
    // letter, so grouping all cells together is what makes a single set of
    // teacher labels enough for the entire page.
    final k = math.max(1, math.min(calibration.optionCount, samples.length));
    final clusters = samples.isEmpty
        ? LetterClusters(
            centroids: const [],
            assignments: const [],
            distances: Float64List(0),
            inertia: 0,
          )
        : kMeans(samples.map((s) => s.vector).toList(), k: k);

    return SheetReading(
      cells: cells,
      clusters: clusters,
      samples: samples,
      sampleCells: sampleCells,
    );
  }

  /// A cell crop for a normalised rectangle, in pixels.
  GrayImage _cropNormalized(GrayImage gray, CellRect rect) {
    final x = (rect.left * gray.width).round();
    final y = (rect.top * gray.height).round();
    final w = (rect.width * gray.width).round();
    final h = (rect.height * gray.height).round();
    return gray.crop(x, y, w < 1 ? 1 : w, h < 1 ? 1 : h);
  }

  /// Compares a reading against the key and produces marks.
  ///
  /// [labels] names each cluster, as the teacher assigned. [confirmedCells] are
  /// the cell indices the teacher has personally looked at; everything else
  /// stays flagged for review and is excluded from the totals.
  ///
  /// There is one result per question. With [CellGrouping.single] that is one
  /// per cell. With [CellGrouping.options] the four cells of a question are one
  /// answer between them, so they collapse into a single result pointing at
  /// whichever cell was marked.
  GradeResult grade({
    required SheetReading reading,
    required ExamCalibration calibration,
    required Map<int, String> labels,
    Set<int> confirmedCells = const {},
  }) {
    final model = LetterModel(
        centroids: reading.clusters.centroids, labels: labels);
    final perCell = <int, LetterGuess>{};
    for (var i = 0; i < reading.samples.length; i++) {
      perCell[reading.sampleCells[i]] = model.classify(reading.samples[i]);
    }

    final results = <AnswerResult>[];

    if (calibration.grouping == CellGrouping.single) {
      for (final cell in reading.cells) {
        final guess = perCell[cell.cellIndex];
        ReadOutcome outcome;
        String? detected;
        var confidence = 0.0;

        if (cell.isBlank) {
          outcome = ReadOutcome.blank;
        } else if (guess == null || guess.label == null) {
          outcome = ReadOutcome.unresolved;
        } else {
          outcome = ReadOutcome.read;
          detected = guess.label;
          confidence = guess.confidence;
        }

        results.add(AnswerResult(
          number: cell.questionNumber,
          cellIndex: cell.cellIndex,
          correctAnswer: calibration.answerKey.entryFor(cell.questionNumber)
              ?.correctAnswer,
          detectedAnswer: detected,
          outcome: outcome,
          confidence: confidence,
          teacherConfirmed: confirmedCells.contains(cell.cellIndex),
        ));
      }
      return GradeResult(results: results);
    }

    for (var question = 1; question <= calibration.questionCount; question++) {
      final resolved =
          _resolveOptionQuestion(question: question, reading: reading, guesses: perCell);
      results.add(AnswerResult(
        number: question,
        cellIndex: resolved.cellIndex,
        correctAnswer: calibration.answerKey.entryFor(question)?.correctAnswer,
        detectedAnswer: resolved.answer,
        outcome: resolved.outcome,
        confidence: resolved.confidence,
        teacherConfirmed: confirmedCells.contains(resolved.cellIndex),
      ));
    }
    return GradeResult(results: results);
  }

  /// Works out the answer for a question whose options are separate cells.
  ///
  /// The student writes the chosen letter inside that option's cell, so the
  /// answer is the label of the single marked cell. Two marked cells mean the
  /// student changed their mind or the paper is smudged, and that is a question
  /// for the teacher, not something to resolve by picking one.
  ({
    String? answer,
    ReadOutcome outcome,
    double confidence,
    int cellIndex,
  }) _resolveOptionQuestion({
    required int question,
    required SheetReading reading,
    required Map<int, LetterGuess> guesses,
  }) {
    final cells = <CellReading>[
      for (final c in reading.cells)
        if (c.questionNumber == question) c,
    ];
    if (cells.isEmpty) {
      return (
        answer: null,
        outcome: ReadOutcome.blank,
        confidence: 0,
        cellIndex: -1
      );
    }

    final marked = <CellReading>[
      for (final c in cells)
        if (!c.isBlank) c,
    ];

    if (marked.isEmpty) {
      return (
        answer: null,
        outcome: ReadOutcome.blank,
        confidence: 0,
        cellIndex: cells.first.cellIndex
      );
    }
    if (marked.length > 1) {
      return (
        answer: null,
        outcome: ReadOutcome.unresolved,
        confidence: 0,
        cellIndex: marked.first.cellIndex
      );
    }

    final only = marked.first;
    final guess = guesses[only.cellIndex];
    if (guess == null || guess.label == null) {
      return (
        answer: null,
        outcome: ReadOutcome.unresolved,
        confidence: 0,
        cellIndex: only.cellIndex
      );
    }
    return (
      answer: guess.label,
      outcome: ReadOutcome.read,
      confidence: guess.confidence,
      cellIndex: only.cellIndex
    );
  }
}

/// Thrown when a reading cannot be attempted at all, as opposed to a reading
/// that needs the teacher to look at a few cells.
class OmrReadException implements Exception {
  OmrReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Convenience for building a calibration from a freshly typed key.
ExamCalibration calibrationFromKey({
  required String examId,
  required AnswerKey answerKey,
  required List<CellRect> cells,
  required CellGrouping grouping,
  int optionCount = 4,
  CellRect? shortAnswerRegion,
}) {
  return ExamCalibration(
    examId: examId,
    answerKey: answerKey,
    cells: cells,
    grouping: grouping,
    optionCount: optionCount,
    shortAnswerRegion: shortAnswerRegion,
  );
}
