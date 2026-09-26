import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/omr/grid_detector.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/preprocess.dart';

/// Builds a page of paper with printed rules at the requested positions.
GrayImage _ruledPage({
  required int width,
  required int height,
  required List<double> columnRules,
  required List<double> rowRules,
  double ruleThickness = 2,
}) {
  final data = Float32List(width * height);
  for (var i = 0; i < data.length; i++) {
    data[i] = 235.0;
  }
  final img = GrayImage(width, height, data);

  final half = (ruleThickness / 2).floor();
  for (final x in columnRules) {
    for (var y = rowRules.first.toInt(); y <= rowRules.last.toInt(); y++) {
      for (var d = -half; d <= half; d++) {
        img.set(x.toInt() + d, y, 20.0);
      }
    }
  }
  for (final y in rowRules) {
    for (var x = columnRules.first.toInt(); x <= columnRules.last.toInt(); x++) {
      for (var d = -half; d <= half; d++) {
        img.set(x, y.toInt() + d, 20.0);
      }
    }
  }
  return img;
}

TableGrid? _detect(GrayImage img) {
  final ink = InkMap.fromLuminance(img);
  return detectTableGrid(ink, inkThreshold: 0.30);
}

void main() {
  group('Table lattice detection', () {
    test('finds the rules of a clean grid', () {
      final img = _ruledPage(
        width: 400,
        height: 600,
        columnRules: [50, 150, 250, 350],
        rowRules: [100, 200, 300, 400, 500],
      );

      final grid = _detect(img);
      expect(grid, isNotNull);
      expect(grid!.columns.length, 4);
      expect(grid.rows.length, 5);
      expect(grid.columnCount, 3);
      expect(grid.rowCount, 4);
      expect(grid.cellCount, 12);
      expect(grid.snapFraction, greaterThan(0.5));
    });

    test('recovers a rule the threshold missed', () {
      // A gap of double pitch in the detections must be re-split, otherwise two
      // question columns silently merge into one cell.
      final img = _ruledPage(
        width: 500,
        height: 600,
        columnRules: [50, 150, 250, 350, 450],
        rowRules: [100, 300, 500],
      );
      // Rub out the middle rule.
      for (var y = 100; y <= 500; y++) {
        for (var d = -1; d <= 1; d++) {
          img.set(250 + d, y, 0.95);
        }
      }

      final grid = _detect(img);
      expect(grid, isNotNull);
      expect(grid!.columns.length, 5,
          reason: 'the missing rule should be restored at the midpoint');
    });

    test('ignores short marks that are not rules', () {
      // Text-like blobs: tall enough to look like rules individually, but they
      // never span the sheet, so no coherent lattice may be reported.
      final data = Float32List(400 * 600);
      for (var i = 0; i < data.length; i++) {
        data[i] = 235.0;
      }
      final img = GrayImage(400, 600, data);
      for (var i = 0; i < 30; i++) {
        final x = 40 + i * 11;
        for (var y = 80; y < 140; y++) {
          for (var d = 0; d <= 2; d++) {
            img.set(x + d, y, 20.0);
          }
        }
      }

      expect(_detect(img), isNull);
    });

    test('cells tile the space between adjacent rules', () {
      final grid = TableGrid(
        columns: [0.0, 0.25, 0.5, 1.0],
        rows: [0.0, 0.5, 1.0],
        ruleFraction: 0.3,
        snapFraction: 1.0,
      );
      final cells = grid.cells();
      expect(cells.length, 6);
      expect(cells.first.rect.left, 0.0);
      expect(cells.first.rect.right, 0.25);
      expect(cells.first.rect.centerY, 0.25);
      expect(cells.last.rect.right, 1.0);
      expect(cells.last.rect.bottom, 1.0);
    });

    test('score is zero without a real lattice', () {
      final grid = TableGrid(
        columns: [0.0, 0.5],
        rows: [0.0, 0.5],
        ruleFraction: 0.3,
        snapFraction: 0.5,
      );
      expect(grid.score, 0);
      expect(grid.columnCount, 1);
    });
  });
}
