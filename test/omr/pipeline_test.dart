import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/models/answer_key.dart';
import 'package:myapp/models/grade_result.dart';
import 'package:myapp/omr/calibration.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/grid_detector.dart';
import 'package:myapp/omr/letter_cluster.dart';
import 'package:myapp/omr/omr_service.dart';

const _service = OmrService();

/// Builds a page of paper with one handwritten letter per cell.
///
/// The letters are drawn as thick strokes filling a cell, because the
/// descriptor resamples each cell to a fixed grid: a stroke thinner than one
/// grid cell breaks up on the way down and its enclosed regions leak away.
GrayImage sheetWithLetters(
  List<String?> letters, {
  required List<CellRect> cells,
  double paper = 235,
  double pen = 25,
}) {
  const pageWidth = 1000;
  const pageHeight = 1400;
  final page = GrayImage.filled(pageWidth, pageHeight, paper);

  for (var i = 0; i < letters.length && i < cells.length; i++) {
    final letter = letters[i];
    if (letter == null) continue;
    final c = cells[i];
    _drawLetter(
      page,
      (c.left * pageWidth).round(),
      (c.top * pageHeight).round(),
      (c.width * pageWidth).round(),
      (c.height * pageHeight).round(),
      letter,
      pen,
    );
  }
  return page;
}

/// Four skeletons matching the ones in the reader test, in normalised
/// coordinates inside a box.
const Map<String, List<List<List<double>>>> _shapes = {
  'A': [
    [
      [0.0, 1.0],
      [0.5, 0.0],
      [1.0, 1.0],
    ],
    [
      [0.18, 0.68],
      [0.82, 0.68],
    ],
  ],
  'B': [
    [
      [0.1, 0.0],
      [0.1, 1.0],
    ],
    [
      [0.1, 0.0],
      [0.75, 0.12],
      [0.75, 0.38],
      [0.1, 0.5],
    ],
    [
      [0.1, 0.5],
      [0.85, 0.62],
      [0.85, 0.88],
      [0.1, 1.0],
    ],
  ],
  'C': [
    [
      [0.9, 0.1],
      [0.4, 0.0],
      [0.1, 0.3],
      [0.1, 0.7],
      [0.4, 1.0],
      [0.9, 0.9],
    ],
  ],
  'D': [
    [
      [0.1, 0.0],
      [0.1, 1.0],
    ],
    [
      [0.1, 0.0],
      [0.7, 0.1],
      [0.95, 0.5],
      [0.7, 0.9],
      [0.1, 1.0],
    ],
  ],
};

void _drawLetter(GrayImage page, int x0, int y0, int w, int h, String letter,
    double pen) {
  final strokes = _shapes[letter];
  if (strokes == null) return;
  const pad = 0.18;
  final avail = 1.0 - 2 * pad;
  for (final stroke in strokes) {
    for (var i = 0; i < stroke.length - 1; i++) {
      _line(page,
          x0 + (pad + stroke[i][0] * avail) * w,
          y0 + (pad + stroke[i][1] * avail) * h,
          x0 + (pad + stroke[i + 1][0] * avail) * w,
          y0 + (pad + stroke[i + 1][1] * avail) * h,
          pen);
    }
  }
}

void _line(GrayImage img, double x0, double y0, double x1, double y1,
    double value, [double thickness = 5]) {
  final steps = ((x1 - x0).abs() > (y1 - y0).abs()
          ? (x1 - x0).abs()
          : (y1 - y0).abs())
      .ceil()
      .clamp(1, 4000);
  final half = thickness / 2;
  for (var s = 0; s <= steps; s++) {
    final t = s / steps;
    final cx = (x0 + (x1 - x0) * t).round();
    final cy = (y0 + (y1 - y0) * t).round();
    for (var dy = -half.ceil(); dy <= half.ceil(); dy++) {
      for (var dx = -half.ceil(); dx <= half.ceil(); dx++) {
        final x = cx + dx;
        final y = cy + dy;
        if (!img.contains(x, y)) continue;
        if (img.data[y * img.width + x] > value) {
          img.data[y * img.width + x] = value;
        }
      }
    }
  }
}

AnswerKey keyOf(List<String> letters) => AnswerKey(entries: [
      for (var i = 0; i < letters.length; i++)
        AnswerKeyEntry(number: i + 1, correctAnswer: letters[i]),
    ]);

/// Four single-answer cells in one row.
List<CellRect> singleRow(int questions) => [
      for (var i = 0; i < questions; i++)
        CellRect(0.08 + i * 0.20, 0.30, 0.08 + i * 0.20 + 0.12, 0.42),
    ];

/// Four option cells per question, two questions stacked.
List<CellRect> optionLattice(int questions, {int options = 4}) {
  final cells = <CellRect>[];
  for (var q = 0; q < questions; q++) {
    final rowTop = 0.30 + q * 0.16;
    for (var o = 0; o < options; o++) {
      final left = 0.08 + o * 0.12;
      cells.add(CellRect(left, rowTop, left + 0.09, rowTop + 0.10));
    }
  }
  return cells;
}

void main() {
  group('Reading a sheet', () {
    test('finds a handwritten letter in every marked cell', () {
      final cells = singleRow(4);
      final page = sheetWithLetters(['A', 'B', 'C', 'D'], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'A', 'A', 'A']),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      expect(reading.cells.length, 4);
      expect(reading.samples.length, 4,
          reason: 'every cell has writing, so none should read as blank');
      expect(reading.clusters.k, 4);
    });

    test('a cell with nothing in it reads as blank', () {
      final cells = singleRow(3);
      final page = sheetWithLetters(['A', null, 'C'], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C']),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      expect(reading.blankCells.length, 1);
      expect(reading.blankCells.single.cellIndex, 1);
    });

    test('refuses to read an inconsistent calibration', () {
      final cells = singleRow(3);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C', 'D', 'E']),
        cells: cells,
        grouping: CellGrouping.single,
      );
      expect(() => _service.read(GrayImage.filled(200, 200, 235), calibration),
          throwsA(isA<OmrReadException>()));
    });
  });

  group('Grading', () {
    test('an all-correct sheet scores full marks once confirmed', () {
      final cells = singleRow(4);
      final page = sheetWithLetters(['A', 'B', 'C', 'D'], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C', 'D']),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      // Stand in for the teacher naming each group by what most of it is.
      final labels = _nameClustersByTruth(reading, ['A', 'B', 'C', 'D'], cells);
      final allCells = {for (var i = 0; i < cells.length; i++) i};

      final result = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
        confirmedCells: allCells,
      );

      expect(result.totalMarks, 4);
      expect(result.denominator, 4);
      expect(result.percentage, 100);
      expect(result.isComplete, isTrue);
    });

    test('nothing is scored until the teacher confirms', () {
      // The central safety property: an unread sheet must not produce marks.
      final cells = singleRow(4);
      final page = sheetWithLetters(['A', 'B', 'C', 'D'], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'A', 'A', 'A']),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      final labels = _nameClustersByTruth(reading, ['A', 'B', 'C', 'D'], cells);

      final unconfirmed = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
      );
      expect(unconfirmed.totalMarks, 0,
          reason: 'an unconfirmed sheet must not be credited with any marks');
      expect(unconfirmed.isComplete, isFalse);
      expect(unconfirmed.needingConfirmation.length, 4);

      final confirmed = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
        confirmedCells: {0, 1, 2, 3},
      );
      expect(confirmed.isComplete, isTrue);
      expect(confirmed.totalMarks, 1, reason: 'only question 1 answered A');
    });

    test('an unlabelled cluster blocks grading rather than guessing', () {
      final cells = singleRow(4);
      final page = sheetWithLetters(['A', 'B', 'C', 'D'], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C', 'D']),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      final result = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: const {},
        confirmedCells: {0, 1, 2, 3},
      );

      // Every cell has ink but no cluster was named, so nothing is read and
      // every question goes to the teacher.
      expect(result.totalMarks, 0);
      expect(result.needingConfirmation.length, 4);
      expect(result.isComplete, isFalse);
    });

    test('a question missing from the key is excluded, not counted wrong', () {
      final cells = singleRow(3);
      final page = sheetWithLetters(['A', 'B', 'C'], cells: cells);
      // Key has a gap at question 2.
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: AnswerKey(entries: const [
          AnswerKeyEntry(number: 1, correctAnswer: 'A'),
          AnswerKeyEntry(number: 3, correctAnswer: 'C'),
        ]),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      final labels = _nameClustersByTruth(reading, ['A', 'B', 'C'], cells);
      final result = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
        confirmedCells: {0, 1, 2},
      );

      expect(result.withoutKey.map((r) => r.number), [2]);
      expect(result.denominator, 2, reason: 'only two questions are gradable');
      expect(result.totalMarks, 2);
    });

    test('a blank cell is reported as blank, not as a wrong answer', () {
      final cells = singleRow(3);
      final page = sheetWithLetters(['A', null, 'C'], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C']),
        cells: cells,
        grouping: CellGrouping.single,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      final labels = _nameClustersByTruth(reading, ['A', 'C', 'C'], cells);
      final result = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
        confirmedCells: {0, 1, 2},
      );

      final blank = result.results.firstWhere((r) => r.number == 2);
      expect(blank.outcome, ReadOutcome.blank);
      expect(blank.detectedAnswer, isNull);
      expect(result.totalMarks, 2);
    });
  });

  group('Option cells', () {
    test('the answer is the letter in the one marked cell', () {
      final cells = optionLattice(2);
      // Question 1 answered C, question 2 answered A.
      final page = sheetWithLetters([
        null, null, 'C', null, //
        'A', null, null, null, //
      ], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['C', 'A']),
        cells: cells,
        grouping: CellGrouping.options,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      expect(reading.samples.length, 2);

      final labels = _nameClustersByTruth(
          reading, ['C', 'A'], [cells[2], cells[4]]);
      final result = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
        confirmedCells: {2, 4},
      );

      expect(result.totalMarks, 2);
      expect(result.isComplete, isTrue);
    });

    test('two marked cells in one question go to the teacher', () {
      final cells = optionLattice(1);
      final page = sheetWithLetters(['B', 'C', null, null], cells: cells);
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['B']),
        cells: cells,
        grouping: CellGrouping.options,
        optionCount: 4,
      );

      final reading = _service.read(page, calibration);
      final labels = _nameClustersByTruth(reading, ['B', 'C'], [cells[0], cells[1]]);
      final result = _service.grade(
        reading: reading,
        calibration: calibration,
        labels: labels,
        confirmedCells: {0, 1},
      );

      // The student may have changed their mind or the paper is smudged.
      // Picking one of the two would be a guess presented as a mark.
      final q1 = result.results.first;
      expect(q1.outcome, ReadOutcome.unresolved);
      expect(q1.detectedAnswer, isNull);
      expect(result.totalMarks, 0);
    });
  });
}

/// Names each cluster with the letter its cells were actually drawn as.
///
/// The real app asks the teacher to do this by eye. Doing it from the known
/// truth here keeps the test focused on the pipeline rather than on the
/// clustering, which is covered separately.
Map<int, String> _nameClustersByTruth(
  SheetReading reading,
  List<String> truth,
  List<CellRect> cells,
) {
  final cellOf = <int, int>{
    for (var i = 0; i < reading.sampleCells.length; i++)
      reading.sampleCells[i]: i,
  };
  final model = LetterModel(
    centroids: reading.clusters.centroids,
    labels: const {},
  );
  final votes = <int, Map<String, int>>{};
  for (var i = 0; i < reading.samples.length; i++) {
    final cluster = model.classify(reading.samples[i]).cluster;
    final cellIndex = reading.sampleCells[i];
    final letter = truth[cellOf[cellIndex]!];
    votes.putIfAbsent(cluster, () => <String, int>{});
    votes[cluster]![letter] = (votes[cluster]![letter] ?? 0) + 1;
  }
  return votes.map((cluster, tally) => MapEntry(
      cluster, tally.entries.reduce((a, b) => a.value >= b.value ? a : b).key));
}
