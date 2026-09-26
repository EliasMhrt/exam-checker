import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/models/answer_key.dart';
import 'package:myapp/omr/calibration.dart';
import 'package:myapp/omr/grid_detector.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/letter_cluster.dart';
import 'package:myapp/omr/letter_features.dart';

const paper = 235.0;
const pen = 25.0;

GrayImage _cell({int w = 90, int h = 110}) {
  final data = Float32List(w * h);
  for (var i = 0; i < data.length; i++) {
    data[i] = paper;
  }
  return GrayImage(w, h, data);
}

void _dot(GrayImage img, int x, int y, int thickness) {
  final half = thickness ~/ 2;
  for (var dy = -half; dy <= half; dy++) {
    for (var dx = -half; dx <= half; dx++) {
      final px = x + dx;
      final py = y + dy;
      if (px >= 0 && py >= 0 && px < img.width && py < img.height) {
        img.set(px, py, pen);
      }
    }
  }
}

/// Draws a polyline given in normalised 0..1 cell coordinates.
///
/// The default pen width is chosen so a stroke still covers a whole cell of the
/// 16x16 feature grid. A stroke thinner than the grid cell breaks up during
/// downsampling, which opens the enclosed regions of A, B and D and destroys
/// the hole count - an artefact of the descriptor, not of the letter.
void _stroke(GrayImage img, List<List<double>> points,
    {double thickness = 5}) {
  final t = thickness.round();
  for (var i = 0; i + 1 < points.length; i++) {
    final x0 = points[i][0] * (img.width - 1);
    final y0 = points[i][1] * (img.height - 1);
    final x1 = points[i + 1][0] * (img.width - 1);
    final y1 = points[i + 1][1] * (img.height - 1);
    final steps = math.max(
        1, math.max((x1 - x0).abs(), (y1 - y0).abs()).ceil());
    for (var s = 0; s <= steps; s++) {
      final f = s / steps;
      _dot(img, (x0 + (x1 - x0) * f).round(), (y0 + (y1 - y0) * f).round(), t);
    }
  }
}

/// Canonical skeletons for the four option letters, in 0..1 coordinates.
/// Only the topology matters here: A and D enclose one region, B encloses two,
/// C encloses none.
const Map<String, List<List<List<double>>>> skeletons = {
  'A': [
    [
      [0.0, 1.0],
      [0.5, 0.0],
      [1.0, 1.0]
    ],
    [
      [0.18, 0.68],
      [0.82, 0.68]
    ],
  ],
  'B': [
    [
      [0.0, 0.0],
      [0.0, 1.0]
    ],
    [
      [0.0, 0.0],
      [0.55, 0.08],
      [0.6, 0.4],
      [0.0, 0.48]
    ],
    [
      [0.0, 0.48],
      [0.6, 0.56],
      [0.65, 0.9],
      [0.0, 1.0]
    ],
  ],
  'C': [
    [
      [0.95, 0.12],
      [0.55, 0.0],
      [0.1, 0.2],
      [0.0, 0.5],
      [0.1, 0.8],
      [0.55, 1.0],
      [0.95, 0.88]
    ],
  ],
  'D': [
    [
      [0.0, 0.0],
      [0.0, 1.0]
    ],
    [
      [0.0, 0.0],
      [0.5, 0.1],
      [0.8, 0.5],
      [0.5, 0.9],
      [0.0, 1.0]
    ],
  ],
};

/// Draws [letter] into a cell, inset by [pad] and scaled by [scale], so the
/// same letter can be rendered small, large, and off-centre.
LetterFeatures? _render(String letter,
    {double pad = 0.18, double scale = 1.0, double dx = 0.0, double dy = 0.0}) {
  final img = _cell();
  // The skeleton spans 0..1; inset it by `pad` and scale within what is left,
  // so the letter is fully inside the cell at any scale.
  final avail = 1.0 - 2 * pad;
  for (final stroke in skeletons[letter]!) {
    _stroke(img, stroke
        .map((p) =>
            [pad + p[0] * avail * scale + dx, pad + p[1] * avail * scale + dy])
        .toList());
  }
  return extractLetterFeatures(img);
}

double _distance(LetterFeatures a, LetterFeatures b) {
  var sum = 0.0;
  for (var i = 0; i < a.vector.length; i++) {
    final d = a.vector[i] - b.vector[i];
    sum += d * d;
  }
  return math.sqrt(sum);
}

/// A well-formed key from plain letters, numbered from 1.
AnswerKey keyOf(List<String> letters) => AnswerKey(entries: [
      for (var i = 0; i < letters.length; i++)
        AnswerKeyEntry(number: i + 1, correctAnswer: letters[i]),
    ]);

void main() {
  group('Hole counting', () {
    Float32List plane(List<String> rows) {
      final h = rows.length;
      final w = rows.first.length;
      final out = Float32List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          out[y * w + x] = rows[y][x] == '#' ? 1 : 0;
        }
      }
      return out;
    }

    test('a solid bar has no holes', () {
      final p = plane([
        '#####',
        '#####',
        '#####',
      ]);
      expect(countHoles(p, 5, 3), 0);
    });

    test('a ring has one hole', () {
      final p = plane([
        '#####',
        '#...#',
        '#####',
      ]);
      expect(countHoles(p, 5, 3), 1);
    });

    test('two stacked rings have two holes', () {
      final p = plane([
        '#####',
        '#...#',
        '#####',
        '#...#',
        '#####',
      ]);
      expect(countHoles(p, 5, 5), 2);
    });

    test('a stroke touching the edge does not seal the page', () {
      final p = plane([
        '#....',
        '#....',
        '.....',
      ]);
      expect(countHoles(p, 5, 3), 0);
    });
  });

  group('Letter features', () {
    test('a blank cell yields no features', () {
      expect(extractLetterFeatures(_cell()), isNull);
    });

    test('recognises the topological difference between the letters', () {
      // This is the property the four-way decision leans on hardest: A and D
      // both enclose one region, B encloses two, C encloses none.
      expect(_render('A')!.holes, 1);
      expect(_render('B')!.holes, 2);
      expect(_render('C')!.holes, 0);
      expect(_render('D')!.holes, 1);
    });

    test('is invariant to where and how large the letter is written', () {
      final reference = _render('A')!;
      final variants = [
        _render('A', scale: 0.55)!,
        _render('A', scale: 0.9)!,
        _render('A', dx: 0.12, dy: -0.1)!,
        _render('A', scale: 0.7, dx: -0.12, dy: 0.1)!,
      ];
      for (final v in variants) {
        final sameLetter = _distance(reference, v);
        final differentLetter = _distance(reference, _render('B')!);
        // The descriptor is not perfectly scale-invariant: a letter written
        // small still has proportionally fatter strokes once resampled into a
        // fixed grid, which peak normalisation and blurring only partly
        // remove. The residual leaves roughly a 2x margin, and the clustering
        // layer absorbs what is left, so this asserts a clear separation
        // rather than exact equality.
        expect(sameLetter, lessThan(differentLetter * 0.7),
            reason: 'scale/position variant drifted toward a different letter');
      }
    });

    test('separates different letters', () {
      final a = _render('A')!;
      final b = _render('B')!;
      final c = _render('C')!;
      final d = _render('D')!;
      expect(_distance(a, b), greaterThan(1.0));
      expect(_distance(a, d), greaterThan(1.0));
      expect(_distance(b, c), greaterThan(1.0));
      expect(_distance(c, d), greaterThan(1.0));
    });
  });

  group('Unsupervised letter model', () {
    /// A synthetic descriptor with a real, self-consistent dimension.
    ///
    /// LetterFeatures.dimension is grid.length + letterFeatureCount, so a
    /// fixture that pairs a short grid with a short vector is malformed. Every
    /// model call rejects it on the dimension check, which makes such a test
    /// pass while asserting nothing. This keeps the two in step.
    LetterFeatures synthetic(double marker) {
      final gridLength = letterGridSize * letterGridSize;
      final vector = Float32List(gridLength + letterFeatureCount);
      vector[0] = marker;
      return LetterFeatures(
        vector: vector,
        grid: Float32List(gridLength),
        inkFraction: 0.1,
        holes: 0,
        aspect: 1,
        centroidY: 0.5,
        topMass: 0.3,
        midMass: 0.3,
        bottomMass: 0.4,
      );
    }

    List<Float32List> markers(List<double> values) =>
        [for (final v in values) synthetic(v).vector];

    test('recovers the four letters without being told what they are', () {

      const letters = ['A', 'B', 'C', 'D'];
      final samples = <LetterFeatures>[];
      final truth = <String>[];
      for (final letter in letters) {
        for (final variant in [
          _render(letter),
          _render(letter, scale: 0.7),
          _render(letter, scale: 0.9, dx: 0.08),
          _render(letter, scale: 0.6, dy: 0.1),
          _render(letter, scale: 0.85, dx: -0.08, dy: -0.06),
        ]) {
          samples.add(variant!);
          truth.add(letter);
        }
      }

      final clusters =
          kMeans(samples.map((s) => s.vector).toList(), k: 4, seed: 7);
      expect(clusters.centroids.length, 4);

      // Stand in for the teacher: name each cluster by what most of its
      // members actually were.
      final votes = <int, Map<String, int>>{};
      for (var i = 0; i < samples.length; i++) {
        final a = clusters.assignments[i];
        votes.putIfAbsent(a, () => <String, int>{});
        votes[a]![truth[i]] = (votes[a]![truth[i]] ?? 0) + 1;
      }
      expect(votes.length, 4, reason: 'each letter should form its own cluster');

      final labels = <int, String>{};
      votes.forEach((cluster, tally) {
        labels[cluster] = tally.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      });

      final model = LetterModel(
          centroids: clusters.centroids, labels: labels);
      expect(model.isUsableFor(samples), isTrue);

      for (var i = 0; i < samples.length; i++) {
        final guess = model.classify(samples[i]);
        expect(guess.label, truth[i],
            reason: 'sample $i (${truth[i]}) read as ${guess.label}');
        expect(guess.needsReview, isFalse);
      }
    });

    test('an unlabelled cluster is always sent to the teacher', () {
      final clusters = kMeans(markers([0.0, 1.0, 0.2, 0.9]), k: 2);
      final model = LetterModel(centroids: clusters.centroids, labels: const {});
      final sample = synthetic(0.0);
      final guess = model.classify(sample);
      // The model has real centroids, so the cluster is identified; it is the
      // missing label that must block grading.
      expect(guess.cluster, isNot(-1));
      expect(guess.label, isNull);
      expect(guess.needsReview, isTrue);
      expect(model.isUsableFor([sample]), isFalse);
      expect(model.unlabelledClusters([sample]), isNotEmpty);
    });

    test('exemplars come from the model centroids, not a fresh clustering', () {
      // Regression: exemplarsByCluster used to re-run k-means with its own
      // seed. Those cluster ids mean nothing to this model, so the teacher
      // could name cluster 2 while every cell the app reads as cluster 2 was
      // really a different letter.
      final clusters = kMeans(markers([0.0, 1.0, 0.1, 0.9]), k: 2, seed: 1);
      final samples = [synthetic(0.0), synthetic(1.0)];
      final model =
          LetterModel(centroids: clusters.centroids, labels: const {});

      final exemplars = model.exemplarsByCluster(samples);
      expect(exemplars, isNotEmpty);
      // The cluster each sample lands in must equal what classify() reports,
      // because that is the id the teacher labels.
      for (final s in samples) {
        final cluster = model.classify(s).cluster;
        expect(exemplars[cluster], isNotNull,
            reason: 'exemplar map has no entry for cluster $cluster');
        expect(exemplars[cluster]!.first.vector, s.vector);
      }
    });

    test('an empty centroid cluster does not block grading', () {
      // Three centroids, but the samples only ever land on two of them. The
      // phantom cannot be labelled because there is nothing to show, so it
      // must not make the whole model unusable.
      final samples = [synthetic(0.0), synthetic(0.1), synthetic(10.0), synthetic(10.1)];
      final centroids = [
        synthetic(0.0).vector,
        synthetic(10.0).vector,
        synthetic(99.0).vector,
      ];
      final model = LetterModel(
          centroids: centroids, labels: const {0: 'A', 1: 'B'});
      expect(model.isUsableFor(samples), isTrue);
      expect(model.unlabelledClusters(samples), isEmpty);
    });
  });

  group('Answer key parsing', () {
    test('reads a plain letter sequence', () {
      final parse = AnswerKeyParser.parse('A C B D A');
      expect(parse.ok, isTrue);
      expect(parse.key!.count, 5);
      expect(parse.key!.entryFor(3)!.correctAnswer, 'B');
    });

    test('reads numbered answers typed on one line', () {
      // Regression: the parser anchored its number regex to the start of a
      // line, so a single-line key matched only "1. A" and silently threw
      // away every later answer.
      final parse = AnswerKeyParser.parse('1. A 2. B 3. C 4. D');
      expect(parse.ok, isTrue);
      expect(parse.key!.count, 4);
      expect(parse.key!.entryFor(2)!.correctAnswer, 'B');
      expect(parse.key!.entryFor(4)!.correctAnswer, 'D');
    });

    test('keeps original numbers when the key has a gap', () {
      // Regression: non-sequential input was renumbered 1,2,3, which reported
      // question 4's answer against question 3. That is a wrong mark shown as
      // a right one, so the gap has to survive and be reported.
      final parse = AnswerKeyParser.parse('1. A\n2. B\n4. D');
      final key = parse.key!;
      expect(key.entryFor(3), isNull);
      expect(key.entryFor(4)!.correctAnswer, 'D');
      expect(key.maxNumber, 4);
      expect(key.isContiguous, isFalse);
      expect(key.missingNumbers, [3]);
      expect(parse.ok, isFalse);
      expect(parse.problems.join(' '), contains('3'));
    });

    test('does not read prose as a numbered answer', () {
      // "5 questions" must not become question 5 answered "q".
      final parse = AnswerKeyParser.parse('5 questions, answers A B C D');
      expect(parse.problems.where((p) => p.contains('starts at')), isEmpty);
      expect(parse.key!.maxNumber, 4);
    });

    test('reports a duplicated question number', () {
      final parse = AnswerKeyParser.parse('1. A\n1. B\n2. C');
      expect(parse.problems.join(' '), contains('more than one'));
      expect(parse.key!.count, 2);
    });

    test('reports that nothing was found', () {
      final parse = AnswerKeyParser.parse('   ');
      expect(parse.key, isNull);
      expect(parse.ok, isFalse);
    });
  });

  group('Calibration', () {
    test('derives a multi-row lattice from two drags', () {
      // A question row spanning four option cells 0.1 wide with 0.02 gaps.
      final firstRow = const CellRect(0.10, 0.20, 0.58, 0.24);
      final cell = const CellRect(0.10, 0.20, 0.18, 0.24);
      final block = const CellRect(0.10, 0.20, 0.58, 0.30);

      final cells = deriveLattice(
        firstRowRect: firstRow,
        cellRect: cell,
        questionCount: 5,
        grouping: CellGrouping.options,
        optionCount: 4,
        blockRect: block,
      );

      expect(cells.length, 20);
      // Four columns, evenly spread across the measured row so the inter-cell
      // gap is absorbed by the pitch.
      expect(cells[0].left, closeTo(0.10, 1e-9));
      expect(cells[1].left, closeTo(0.22, 1e-9));
      expect(cells[3].left, closeTo(0.46, 1e-9));
      expect(cells[3].right, lessThanOrEqualTo(0.58));
      // Second row starts one measured row pitch down.
      expect(cells[4].top, closeTo(0.24, 1e-9));
    });

    test('an over-wide drag cannot invent extra option columns', () {
      // A row dragged 50% too wide must still yield exactly four columns,
      // otherwise every cell after the first drifts off its mark.
      final cells = deriveLattice(
        firstRowRect: const CellRect(0.10, 0.20, 0.90, 0.24),
        cellRect: const CellRect(0.10, 0.20, 0.18, 0.24),
        questionCount: 3,
        grouping: CellGrouping.options,
        optionCount: 4,
      );
      expect(cells.length, 12);
      expect(cells[3].left, closeTo(0.10 + 0.8 * 3 / 4, 1e-9));
    });

    test('a single-cell-per-question sheet needs no row pitch', () {
      final cells = deriveLattice(
        firstRowRect: const CellRect(0.1, 0.3, 0.9, 0.34),
        cellRect: const CellRect(0.1, 0.3, 0.14, 0.34),
        questionCount: 4,
      );
      expect(cells.length, 4);
      for (final c in cells) {
        expect(c.top, closeTo(0.3, 1e-9));
      }
    });

    test('maps questions onto their cells', () {
      final cells = deriveLattice(
        firstRowRect: const CellRect(0.1, 0.3, 0.9, 0.34),
        cellRect: const CellRect(0.1, 0.3, 0.14, 0.34),
        questionCount: 4,
      );
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C', 'D']),
        cells: cells,
        grouping: CellGrouping.single,
      );
      expect(calibration.isConsistent, isTrue);
      expect(calibration.validate(), isNull);
      expect(calibration.cellFor(1)!.left, closeTo(0.1, 1e-9));
      expect(calibration.cellFor(4)!.left, closeTo(cells[3].left, 1e-9));
      expect(calibration.cellFor(0), isNull);
      expect(calibration.cellFor(99), isNull);
    });

    test('rejects a calibration whose cell count contradicts the key', () {
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C', 'D', 'E']),
        cells: deriveLattice(
          firstRowRect: const CellRect(0.1, 0.3, 0.9, 0.34),
          cellRect: const CellRect(0.1, 0.3, 0.14, 0.34),
          questionCount: 4,
        ),
        grouping: CellGrouping.single,
      );
      expect(calibration.isConsistent, isFalse);
      expect(calibration.validate(), contains('expected 5'));
    });

    test('option grouping spans four cells per question', () {
      final cells = deriveLattice(
        firstRowRect: const CellRect(0.1, 0.3, 0.5, 0.34),
        cellRect: const CellRect(0.1, 0.3, 0.14, 0.34),
        questionCount: 3,
        grouping: CellGrouping.options,
        optionCount: 4,
      );
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'B', 'C']),
        cells: cells,
        grouping: CellGrouping.options,
        optionCount: 4,
      );
      expect(cells.length, 12);
      expect(calibration.cellsPerQuestion, 4);
      expect(calibration.cellsFor(2).length, 4);
      expect(calibration.isConsistent, isTrue);
    });

    test('option count is explicit, not guessed from the key', () {
      // A key that happens to contain no "D" must not shrink the option row.
      final cells = deriveLattice(
        firstRowRect: const CellRect(0.1, 0.3, 0.5, 0.34),
        cellRect: const CellRect(0.1, 0.3, 0.14, 0.34),
        questionCount: 2,
        grouping: CellGrouping.options,
        optionCount: 4,
      );
      final calibration = ExamCalibration(
        examId: 'e1',
        answerKey: keyOf(['A', 'C']),
        cells: cells,
        grouping: CellGrouping.options,
      );
      expect(calibration.cellsPerQuestion, 4);
      expect(calibration.isConsistent, isTrue);
    });
  });
}
