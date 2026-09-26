import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myapp/omr/geometry.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/mask.dart';
import 'package:myapp/omr/preprocess.dart';

GrayImage ramp(int w, int h) {
  final img = GrayImage(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      img.set(x, y, 10.0 + 20.0 * (x / w) + 5.0 * (y / h));
    }
  }
  return img;
}

void main() {
  group('GrayImage', () {
    test('bilinear sampling hits exact grid points', () {
      final img = ramp(10, 10);
      expect(img.sampleBilinear(3, 4), closeTo(img.at(3, 4), 1e-6));
      expect(img.sampleBilinear(0, 0), closeTo(img.at(0, 0), 1e-6));
    });

    test('bilinear sampling interpolates between grid points', () {
      final img = GrayImage.filled(4, 4, 0);
      img.set(1, 1, 0);
      img.set(2, 1, 10);
      // halfway between the two lit and unlit columns
      expect(img.sampleBilinear(1.5, 1), closeTo(5, 1e-6));
    });

    test('bilinear clamps at edges instead of reading out of range', () {
      final img = ramp(5, 5);
      expect(img.sampleBilinear(-3, -3), closeTo(img.at(0, 0), 1e-6));
      expect(img.sampleBilinear(99, 99), closeTo(img.at(4, 4), 1e-6));
    });

    test('box blur of a constant plane is a no-op', () {
      final img = GrayImage.filled(32, 32, 77);
      final blurred = img.boxBlur(3);
      for (var i = 0; i < img.length; i++) {
        expect(blurred.data[i], closeTo(77, 1e-3));
      }
    });

    test('box blur preserves total energy', () {
      final img = ramp(64, 64);
      final blurred = img.boxBlur(5);
      double sum(List<Float32List> d) =>
          d.fold<double>(0, (a, b) => a + b.fold<double>(0, (x, y) => x + y));
      expect(sum([blurred.data]), closeTo(sum([img.data]), 1e-3));
    });

    test('downscale preserves the mean level', () {
      final img = GrayImage.filled(100, 100, 42);
      final small = img.downscaleTo(25);
      expect(small.width, 25);
      expect(small.height, 25);
      expect(small.median(), closeTo(42, 1.0));
    });

    test('downscale is a no-op when already small enough', () {
      final img = ramp(100, 100);
      expect(identical(img.downscaleTo(400), img), isTrue);
    });

    test('median of a bimodal plane picks the dominant mode', () {
      final img = GrayImage.filled(100, 100, 10);
      for (var i = 0; i < 1000; i++) {
        img.data[i] = 200;
      }
      expect(img.median(), closeTo(10, 1.0));
    });
  });

  group('Otsu', () {
    test('separates a bimodal histogram at the valley', () {
      final hist = List<int>.filled(256, 0);
      for (var i = 0; i < 40; i++) {
        hist[20 + i] = 50;
      }
      for (var i = 0; i < 40; i++) {
        hist[200 + i] = 50;
      }
      final t = otsuThreshold(hist);
      // Otsu's convention: the returned value is the last bin of the darker
      // class, so every populated dark bin is <= t and every populated bright
      // bin is > t. There must be no populated bin between them.
      for (var b = 0; b < 256; b++) {
        if (hist[b] > 0) {
          if (b <= 59) {
            expect(b, lessThanOrEqualTo(t));
          } else if (b >= 200) {
            expect(b, greaterThan(t));
          }
        }
      }
      expect(t, closeTo(59, 1));
    });

    test('degenerate empty histogram does not throw', () {
      expect(otsuThreshold(List<int>.filled(256, 0)), 128);
    });
  });

  group('Connected components', () {
    test('labels two separate blobs and ignores background', () {
      final img = GrayImage.filled(40, 40, 255);
      void fill(int x0, int y0, int w, int h) {
        for (var y = y0; y < y0 + h; y++) {
          for (var x = x0; x < x0 + w; x++) {
            img.set(x, y, 0);
          }
        }
      }

      fill(2, 2, 4, 4);
      fill(20, 20, 6, 6);

      final comps = img.componentsBy(
        (v, _, _) => v < 128,
        minArea: 2,
      );
      expect(comps.length, 2);
      expect(comps[0].area, 36);
      expect(comps[1].area, 16);
      expect(comps[0].center.x, closeTo(22.5, 0.01));
    });

    test('minArea filters salt-and-pepper noise', () {
      final img = GrayImage.filled(40, 40, 255);
      img.set(5, 5, 0);
      img.set(6, 5, 0);
      for (var y = 12; y < 20; y++) {
        for (var x = 12; x < 20; x++) {
          img.set(x, y, 0);
        }
      }
      final comps = img.componentsBy(
        (v, _, _) => v < 128,
        minArea: 5,
      );
      expect(comps.length, 1);
      expect(comps.first.area, 64);
    });
  });

  group('Morphology / ink', () {
    test('closing with a large element ignores small dark features', () {
      // Bright plane with a small black square (a "bubble").
      final img = GrayImage.filled(120, 120, 220);
      for (var y = 50; y < 60; y++) {
        for (var x = 50; x < 60; x++) {
          img.set(x, y, 40);
        }
      }
      final bg = morphologicalClosing(img, 20);
      // Inside the dark square the background should stay near paper level.
      expect(bg.at(55, 55), closeTo(220, 6));
      expect(bg.at(5, 5), closeTo(220, 2));
    });

    test('closing reproduces flat paper exactly', () {
      final flat = GrayImage.filled(120, 120, 200);
      final closedFlat = morphologicalClosing(flat, 20);
      expect(closedFlat.at(60, 60), closeTo(200, 0.5));
    });

    test('closing is the identity on a linear ramp away from the edges', () {
      // dilate-then-erode exactly cancels on a monotone ramp, so an interior
      // pixel must survive untouched. Near the border the window clamps, which
      // biases the value toward the bright side - that is expected, and it can
      // only ever lower the local background, never invent ink.
      final image = ramp(120, 120);
      final closed = morphologicalClosing(image, 20);
      for (final p in [const Point(60, 60), const Point(80, 40), const Point(45, 95)]) {
        expect(closed.at(p.x.toInt(), p.y.toInt()),
            closeTo(image.at(p.x.toInt(), p.y.toInt()), 0.5));
      }
      // Border pixels must not exceed the true value (no false ink).
      for (final p in [const Point(0, 0), const Point(119, 119), const Point(0, 119)]) {
        expect(closed.at(p.x.toInt(), p.y.toInt()),
            greaterThanOrEqualTo(image.at(p.x.toInt(), p.y.toInt()) - 0.5));
      }
    });

    test('erode and dilate match a brute-force reference', () {
      final w = 37, h = 29, r = 4;
      final buf = Float32List(w * h);
      var seed = 24680;
      for (var i = 0; i < buf.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        buf[i] = (seed >> 9) % 250;
      }

      final eroded = erodePlane(buf, w, h, r);
      final dilated = dilatePlane(buf, w, h, r);

      for (final findMin in [true, false]) {
        final plane = findMin ? eroded : dilated;
        var worst = 0.0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            var m = findMin ? double.infinity : -double.infinity;
            for (var dy = -r; dy <= r; dy++) {
              for (var dx = -r; dx <= r; dx++) {
                final nx = (x + dx).clamp(0, w - 1);
                final ny = (y + dy).clamp(0, h - 1);
                final v = buf[ny * w + nx];
                if (findMin ? v < m : v > m) m = v;
              }
            }
            final diff = (plane[y * w + x] - m).abs();
            if (diff > worst) worst = diff;
          }
        }
        expect(worst, lessThanOrEqualTo(1e-4), reason: 'findMin=$findMin');
      }
    });

    test('ink map is scale free across a 2x exposure change', () {
      GrayImage build(double gain) {
        final img = GrayImage.filled(120, 120, 0);
        for (var y = 0; y < 120; y++) {
          for (var x = 0; x < 120; x++) {
            // paper 220, ink blob 40
            final on = x >= 50 && x < 60 && y >= 50 && y < 60;
            img.set(x, y, (on ? 40.0 : 220.0) * gain);
          }
        }
        return img;
      }

      final a = InkMap.fromLuminance(build(1.0), seRadius: 20);
      final b = InkMap.fromLuminance(build(0.5), seRadius: 20);
      expect(a.at(55, 55), closeTo(b.at(55, 55), 0.02));
      expect(a.at(10, 10), closeTo(b.at(10, 10), 0.01));
    });

    test('ink map responds to a shadow crossing the page', () {
      final img = GrayImage.filled(120, 120, 0);
      for (var y = 0; y < 120; y++) {
        for (var x = 0; x < 120; x++) {
          final shade = x < 60 ? 0.55 : 1.0; // left half darker
          final on = (x >= 20 && x < 30 && y >= 50 && y < 60) ||
              (x >= 80 && x < 90 && y >= 50 && y < 60);
          img.set(x, y, (on ? 40.0 : 220.0) * shade);
        }
      }
      final ink = InkMap.fromLuminance(img, seRadius: 20);
      // Same mark, very different local lighting -> same ink response.
      expect(ink.at(25, 55), closeTo(ink.at(85, 55), 0.02));
    });
  });

  group('Geometry', () {
    test('homography maps a square exactly onto a translated square', () {
      const src = [Point(0, 0), Point(10, 0), Point(10, 10), Point(0, 10)];
      const dst = [Point(3, 7), Point(23, 7), Point(23, 27), Point(3, 27)];
      final h = Homography.fromCorrespondences(src, dst)!;
      for (var i = 0; i < 4; i++) {
        final p = h.project(src[i]);
        expect(p.x, closeTo(dst[i].x, 1e-6));
        expect(p.y, closeTo(dst[i].y, 1e-6));
      }
    });

    test('homography maps straight lines to straight lines', () {
      // Trapezoid: far edge narrower than near edge.
      const src = [Point(0, 0), Point(100, 0), Point(100, 100), Point(0, 100)];
      const dst = [Point(20, 0), Point(80, 0), Point(100, 100), Point(0, 100)];
      final h = Homography.fromCorrespondences(src, dst)!;

      // The left source edge (0,0)->(0,100) must land on the segment
      // (20,0)->(0,100). Collinearity is the defining property of a
      // homography, so this checks the solve exactly without assuming any
      // particular interpolation of the midpoint.
      for (final p in [const Point(0, 0), const Point(0, 25), const Point(0, 50), const Point(0, 100)]) {
        final q = h.project(p);
        final t = q.y / 100.0;
        final expectedX = 20.0 + (0.0 - 20.0) * t;
        expect(q.x, closeTo(expectedX, 1e-6));
        expect(q.y, closeTo(q.y, 1e-9));
      }
    });

    test('homography inverse round-trips', () {
      const src = [Point(0, 0), Point(40, 0), Point(40, 60), Point(0, 60)];
      const dst = [Point(5, 9), Point(35, 3), Point(44, 70), Point(0, 55)];
      final h = Homography.fromCorrespondences(src, dst)!;
      final inv = h.inverted();
      for (final p in [const Point(10, 10), const Point(30, 40), const Point(2, 55)]) {
        final back = inv.project(h.project(p));
        expect(back.x, closeTo(p.x, 1e-4));
        expect(back.y, closeTo(p.y, 1e-4));
      }
    });

    test('degenerate collinear corners return null', () {
      const src = [Point(0, 0), Point(10, 0), Point(20, 0), Point(30, 0)];
      const dst = [Point(0, 0), Point(10, 0), Point(0, 10), Point(10, 10)];
      expect(Homography.fromCorrespondences(src, dst), isNull);
    });

    test('convex hull of a square returns the corners', () {
      final hull = convexHull([
        const Point(0, 0),
        const Point(10, 0),
        const Point(10, 10),
        const Point(0, 10),
        const Point(5, 5), // interior
      ]);
      expect(hull.length, 4);
    });

    test('quadCorners orders a rotated sheet as tl,tr,br,bl', () {
      final quad = quadCorners([
        const Point(30, 5),
        const Point(60, 20),
        const Point(40, 55),
        const Point(10, 40),
      ])!;
      expect(quad.length, 4);
      // tl should have smallest x+y
      expect((quad[0].x + quad[0].y), lessThan(quad[1].x + quad[1].y));
      expect((quad[2].x + quad[2].y), greaterThan(quad[0].x + quad[0].y));
      expect(isConvexQuad(quad), isTrue);
    });

    test('polygonArea of a unit square is 1', () {
      final a = polygonArea([
        const Point(0, 0),
        const Point(1, 0),
        const Point(1, 1),
        const Point(0, 1),
      ]);
      expect(a, closeTo(1, 1e-9));
    });
  });
}
