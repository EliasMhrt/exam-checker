import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';

/// Otsu's between-class-variance threshold over a 256-bin histogram.
///
/// Returns the bin index that maximises separability. The returned value is
/// the *lower* bound of the bright class, so callers comparing
/// `value > threshold` get the bright side.
double otsuThreshold(List<int> hist) {
  final total = hist.fold<int>(0, (a, b) => a + b);
  if (total == 0) return 128;

  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }

  double sumBackground = 0;
  var weightBackground = 0;
  var best = 0.0;
  var threshold = 128;

  for (var t = 0; t < 256; t++) {
    weightBackground += hist[t];
    if (weightBackground == 0) continue;
    final weightForeground = total - weightBackground;
    if (weightForeground == 0) break;

    sumBackground += t * hist[t];
    final meanBackground = sumBackground / weightBackground;
    final meanForeground = (sum - sumBackground) / weightForeground;
    final between = weightBackground.toDouble() *
        weightForeground.toDouble() *
        (meanBackground - meanForeground) *
        (meanBackground - meanForeground);

    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  return threshold.toDouble();
}

class Component {
  Component({
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.area,
    required this.pixels,
  });

  final int minX;
  final int minY;
  final int maxX;
  final int maxY;
  final int area;

  /// Offsets into the owning image, stored as `y * width + x`.
  final Int32List pixels;

  int get width => maxX - minX + 1;

  int get height => maxY - minY + 1;

  double get aspect => height == 0 ? 0 : width / height;

  double get extent => math.max(width, height).toDouble();

  double get density => extent == 0 ? 0 : area / (extent * extent);

  Point get center =>
      Point(minX + (width - 1) / 2, minY + (height - 1) / 2);
}

/// 8-connected component labelling over a raw planar buffer.
///
/// [isForeground] receives a pixel offset. An explicit stack is used instead of
/// recursion so large sheets cannot blow the Dart stack.
List<Component> connectedComponents(
  Float32List data, {
  required int width,
  required int height,
  required bool Function(int offset) isForeground,
  int minArea = 1,
  int maxArea = 1 << 30,
  int? offsetLimit,
}) {
  final w = width;
  final h = height;
  final n = w * h;
  final limit = offsetLimit ?? n;

  final visited = Uint8List(n);
  final stack = Int32List(n);
  final pixels = <int>[];

  final out = <Component>[];

  for (var seed = 0; seed < limit; seed++) {
    if (visited[seed] == 1) continue;
    if (!isForeground(seed)) continue;

    var sp = 0;
    stack[sp++] = seed;
    visited[seed] = 1;
    pixels.clear();

    var minX = w;
    var minY = h;
    var maxX = -1;
    var maxY = -1;
    var area = 0;

    while (sp > 0) {
      final offset = stack[--sp];
      final x = offset % w;
      final y = offset ~/ w;

      pixels.add(offset);
      area++;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;

      for (var dy = -1; dy <= 1; dy++) {
        final ny = y + dy;
        if (ny < 0 || ny >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx;
          if (nx < 0 || nx >= w) continue;
          final nOffset = ny * w + nx;
          if (visited[nOffset] == 1) continue;
          if (!isForeground(nOffset)) continue;
          visited[nOffset] = 1;
          stack[sp++] = nOffset;
        }
      }
    }

    if (area < minArea || area > maxArea) continue;
    out.add(Component(
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
      area: area,
      pixels: Int32List.fromList(pixels),
    ));
  }

  out.sort((a, b) => b.area.compareTo(a.area));
  return out;
}
