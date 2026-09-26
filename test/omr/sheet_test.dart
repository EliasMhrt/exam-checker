import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/omr/geometry.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/sheet_detector.dart';

GrayImage _flat(int w, int h, double value) {
  final data = Float32List(w * h);
  for (var i = 0; i < data.length; i++) {
    data[i] = value;
  }
  return GrayImage(w, h, data);
}

void _fillRect(GrayImage img, int x0, int y0, int x1, int y1, double value) {
  for (var y = y0; y <= y1; y++) {
    for (var x = x0; x <= x1; x++) {
      img.set(x, y, value);
    }
  }
}

void main() {
  group('Sheet detection', () {
    test('finds a bright sheet on a dark surface', () {
      final img = _flat(400, 600, 20.0);
      _fillRect(img, 50, 80, 350, 520, 235.0);

      final sheet = detectSheet(img);
      expect(sheet, isNotNull);
      expect(sheet!.areaFraction, greaterThan(0.5));
      expect(sheet.coverage, greaterThan(0.95));
      expect(sheet.isClipped, isFalse);
      expect(sheet.corners[0].x, closeTo(50, 3));
      expect(sheet.corners[0].y, closeTo(80, 3));
      expect(sheet.corners[1].x, closeTo(350, 3));
      expect(sheet.corners[2].y, closeTo(520, 3));
      expect(sheet.corners[3].y, closeTo(520, 3));
    });

    test('rejects a frame with no distinct sheet', () {
      final img = _flat(400, 600, 20.0);
      // A patch far too small to be a page.
      _fillRect(img, 20, 20, 60, 60, 235.0);
      expect(detectSheet(img), isNull);
    });

    test('flags a sheet that runs off the frame', () {
      final img = _flat(400, 600, 20.0);
      // Larger than the frame on the left, top and right.
      _fillRect(img, 0, 0, 399, 520, 235.0);

      final sheet = detectSheet(img);
      expect(sheet, isNotNull);
      expect(sheet!.isClipped, isTrue);
    });
  });

  group('Perspective warp', () {
    test('identity mapping reproduces the source', () {
      final values = <double>[];
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          values.add((y * 8 + x) * 9.0);
        }
      }
      final img = GrayImage(8, 4, Float32List.fromList(values));


      final identity = Homography.fromCorrespondences(
        [
          const Point(0.0, 0.0),
          const Point(7.0, 0.0),
          const Point(7.0, 3.0),
          const Point(0.0, 3.0),
        ],
        [
          const Point(0.0, 0.0),
          const Point(7.0, 0.0),
          const Point(7.0, 3.0),
          const Point(0.0, 3.0),
        ],
      );
      expect(identity, isNotNull);

      final out = img.warp(identity!, 8, 4);
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 8; x++) {
          expect(out.at(x, y), closeTo(img.at(x, y), 1e-3),
              reason: 'at $x,$y');
        }
      }
    });

    test('samples outside the source take the fill value', () {
      final img = _flat(10, 10, 128.0);
      // Maps a rect strictly inside the destination onto a rect that only
      // partially overlaps the source, so part of the output must be filled.
      final h = Homography.fromCorrespondences(
        [
          const Point(0.0, 0.0),
          const Point(9.0, 0.0),
          const Point(9.0, 9.0),
          const Point(0.0, 9.0),
        ],
        [
          const Point(5.0, 5.0),
          const Point(14.0, 5.0),
          const Point(14.0, 14.0),
          const Point(5.0, 14.0),
        ],
      );
      final out = img.warp(h!, 10, 10, fill: -1.0);
      // Destination (0,0) samples source (5,5), which is inside.
      expect(out.at(0, 0), 128.0);
      // Destination (9,9) samples source (14,14), which is past the edge.
      expect(out.at(9, 9), -1.0);

    });
  });
}
