import 'dart:math' as math;
import 'dart:typed_data';

import 'gray_image.dart';
import 'preprocess.dart';

/// Dimension of the normalised density grid used as the dominant feature.
const letterGridSize = 16;

/// Number of structural features appended after the grid: 8 row masses,
/// 8 column masses, then 10 scalars.
const letterFeatureCount = 42;

/// A scale- and translation-invariant description of the ink in one cell.
class LetterFeatures {
  LetterFeatures({
    required this.vector,
    required this.grid,
    required this.inkFraction,
    required this.holes,
    required this.aspect,
    required this.centroidY,
    required this.topMass,
    required this.midMass,
    required this.bottomMass,
  }) : assert(
          vector.length == grid.length + letterFeatureCount,
          'vector must be the grid followed by the structural features; a '
          'mismatch makes dimension disagree with vector.length, and every '
          'model call then rejects the descriptor for looking malformed',
        );

  /// Full feature vector: the density grid followed by weighted structure.
  final Float32List vector;

  /// The `letterGridSize` x `letterGridSize` normalised ink density.
  final Float32List grid;

  /// Ink response relative to the whole cell, used to detect a blank cell.
  final double inkFraction;

  /// Enclosed regions: 0 for C, 1 for A and D, 2 for B.
  final int holes;

  /// Width over height of the tight ink bounding box.
  final double aspect;

  /// Vertical centroid in 0..1, 0 at the top of the ink.
  final double centroidY;

  /// Ink mass in the top, middle and bottom thirds of the ink, each 0..1.
  final double topMass;
  final double midMass;
  final double bottomMass;

  static const double _structuralWeight = 3.0;

  int get dimension => grid.length + letterFeatureCount;
}

/// Extracts features for a single cell crop.
///
/// The crop is reduced to its tight ink bounding box and resampled into a
/// square density grid. That removes the two nuisances that otherwise swamp a
/// hand-written letter: where in the cell the student happened to write, and
/// how large or small they wrote it. Both would otherwise make the same letter
/// land in a different cluster per student.
LetterFeatures? extractLetterFeatures(
  GrayImage cell, {
  double blankInkFraction = 0.004,
  double? inkThresholdOverride,
}) {
  if (cell.width < 4 || cell.height < 4) return null;

  final ink = InkMap.fromLuminance(cell);
  final area = cell.width * cell.height;

  var totalInk = 0.0;
  for (final v in ink.ink) {
    if (v > 0) totalInk += v;
  }
  final inkFraction = totalInk / area;

  final threshold = inkThresholdOverride ??
      math.max(otsuOf(ink.ink) * 0.6, _percentile(ink.ink, 0.985) * 0.45);
  if (threshold <= 0) return null;

  // Tight bounding box of the real marks, ignoring speckle.
  var minX = cell.width, minY = cell.height, maxX = -1, maxY = -1;
  for (var y = 0; y < cell.height; y++) {
    for (var x = 0; x < cell.width; x++) {
      if (ink.at(x, y) <= threshold) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < minX || maxY < minY) return null;

  // Too little ink to be a letter.
  if (inkFraction < blankInkFraction) return null;

  final boxWidth = maxX - minX + 1;
  final boxHeight = maxY - minY + 1;
  final span = math.max(boxWidth, boxHeight).toDouble();

  // Resample the ink plane, not the binary, so stroke weight survives.
  // The square is centred on the ink, not anchored at its top-left corner:
  // padding one side only would shift the horizontal projection for every
  // letter whose aspect differs from the box.
  final n = letterGridSize;
  final centerX = (minX + maxX) / 2.0;
  final centerY = (minY + maxY) / 2.0;
  final originX = centerX - span / 2.0;
  final originY = centerY - span / 2.0;

  final grid = Float32List(n * n);
  var peak = 0.0;
  for (var gy = 0; gy < n; gy++) {
    for (var gx = 0; gx < n; gx++) {
      final fx = originX + (gx + 0.5) * span / n;
      final fy = originY + (gy + 0.5) * span / n;
      final v = _sampleInk(ink, fx, fy);
      grid[gy * n + gx] = v;
      if (v > peak) peak = v;
    }
  }
  if (peak <= 0) return null;
  // Normalising by the peak makes the descriptor immune to how dark the pen
  // was and how hard the page was lit.
  for (var i = 0; i < grid.length; i++) {
    grid[i] = (grid[i] / peak).clamp(0.0, 1.0);
  }

  // Stroke width still scales with the letter: the same hand written small
  // produces proportionally fatter strokes once resampled into the grid.
  // Blurring the descriptor before comparison removes most of that, so a
  // letter is recognised by its shape rather than by how big it was.
  final smoothed = _blurGrid(grid, n);

  final rowMass = Float64List(n);
  final colMass = Float64List(n);
  var total = 0.0;
  for (var gy = 0; gy < n; gy++) {
    for (var gx = 0; gx < n; gx++) {
      final v = grid[gy * n + gx];
      rowMass[gy] += v;
      colMass[gx] += v;
      total += v;
    }
  }

  final binary = Float32List(n * n);
  for (var i = 0; i < binary.length; i++) {
    binary[i] = grid[i] > 0.35 ? 1 : 0;
  }
  final holes = countHoles(binary, n, n);

  double massOf(bool Function(int gy) belongs) {
    var sum = 0.0;
    for (var i = 0; i < n * n; i++) {
      if (belongs(i ~/ n)) sum += grid[i];
    }
    return total <= 0 ? 0.0 : sum / total;
  }

  final topMass = massOf((gy) => gy < n / 3);
  final midMass = massOf((gy) => gy >= n / 3 && gy < 2 * n / 3);
  final bottomMass = massOf((gy) => gy >= 2 * n / 3);

  var weightedY = 0.0;
  var weightedX = 0.0;
  for (var gy = 0; gy < n; gy++) {
    for (var gx = 0; gx < n; gx++) {
      final v = grid[gy * n + gx];
      weightedY += v * gy;
      weightedX += v * gx;
    }
  }
  final centroidY = total <= 0 ? 0.5 : weightedY / total / (n - 1);
  final centroidX = total <= 0 ? 0.5 : weightedX / total / (n - 1);

  var symmetry = 0.0;
  for (var gy = 0; gy < n; gy++) {
    for (var gx = 0; gx < n; gx++) {
      symmetry += (grid[gy * n + gx] - grid[gy * n + (n - 1 - gx)]).abs();
    }
  }
  symmetry = total <= 0 ? 0.0 : symmetry / (2 * total);

  final vector = Float32List(n * n + letterFeatureCount);
  vector.setRange(0, n * n, smoothed);
  var k = n * n;
  void put(double v) {
    vector[k++] = v * LetterFeatures._structuralWeight;
  }

  for (var gy = 0; gy < n; gy++) {
    put(total <= 0 ? 0.0 : rowMass[gy] / total);
  }
  for (var gx = 0; gx < n; gx++) {
    put(total <= 0 ? 0.0 : colMass[gx] / total);
  }
  put(holes / 3.0);
  put(boxWidth / boxHeight);
  put(centroidX);
  put(centroidY);
  put(topMass);
  put(midMass);
  put(bottomMass);
  put(symmetry);
  put((rowMass[0] / (total <= 0 ? 1 : total)) -
      (rowMass[n - 1] / (total <= 0 ? 1 : total)));
  // Stroke density inside the letter's own bounding box, not the cell. The
  // cell-relative figure moves whenever a student writes larger or smaller,
  // which would make size masquerade as shape.
  put(_boxDensity(ink, threshold, minX, minY, maxX, maxY));

  return LetterFeatures(
    vector: vector,
    grid: grid,
    inkFraction: inkFraction,
    holes: holes,
    aspect: boxWidth / boxHeight,
    centroidY: centroidY,
    topMass: topMass,
    midMass: midMass,
    bottomMass: bottomMass,
  );
}

/// Mean ink response inside a tight bounding box, in 0..1.
double _boxDensity(InkMap ink, double threshold, int minX, int minY, int maxX,
    int maxY) {
  var sum = 0.0;
  var count = 0;
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      if (ink.at(x, y) > threshold) sum += 1;
      count++;
    }
  }
  if (count <= 0) return 0;
  // sum is a count of marked pixels; scale by the peak ink seen in the box.
  var peak = 0.0;
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      final v = ink.at(x, y);
      if (v > peak) peak = v;
    }
  }
  return peak <= 0 ? 0.0 : (sum / count / peak).clamp(0.0, 1.0);
}

/// Separable 3x3 box blur over a square plane.
Float32List _blurGrid(Float32List src, int n) {
  final tmp = Float32List(n * n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      var sum = 0.0;
      var count = 0;
      for (var d = -1; d <= 1; d++) {
        final px = x + d;
        if (px < 0 || px >= n) continue;
        sum += src[y * n + px];
        count++;
      }
      tmp[y * n + x] = sum / count;
    }
  }
  final out = Float32List(n * n);
  for (var y = 0; y < n; y++) {
    for (var x = 0; x < n; x++) {
      var sum = 0.0;
      var count = 0;
      for (var d = -1; d <= 1; d++) {
        final py = y + d;
        if (py < 0 || py >= n) continue;
        sum += tmp[py * n + x];
        count++;
      }
      out[y * n + x] = sum / count;
    }
  }
  return out;
}

/// Samples the ink plane with bilinear interpolation, zero outside.
double _sampleInk(InkMap ink, double fx, double fy) {
  final x = fx.floor();
  final y = fy.floor();
  final tx = fx - x;
  final ty = fy - y;
  double at(int px, int py) {
    if (px < 0 || py < 0 || px >= ink.width || py >= ink.height) return 0.0;
    return ink.ink[py * ink.width + px];
  }

  return at(x, y) * (1 - tx) * (1 - ty) +
      at(x + 1, y) * tx * (1 - ty) +
      at(x, y + 1) * (1 - tx) * ty +
      at(x + 1, y + 1) * tx * ty;
}

/// Number of enclosed background regions inside a binary plane.
///
/// A flood fill from the border marks every background pixel that is reachable
/// from outside; whatever background is left over is enclosed. The one-pixel
/// pad is what stops a stroke touching the crop edge from sealing the whole
/// outside.
int countHoles(Float32List binary, int width, int height) {
  final w = width + 2;
  final h = height + 2;
  final n = w * h;
  final outside = Uint8List(n);
  final stack = Int32List(n);
  var sp = 0;

  // The one-pixel pad is background by definition. Reading it through an index
  // calculation instead would go negative on the border ring, so it is short
  // circuited here.
  double valueAt(int paddedOffset) {
    final py = paddedOffset ~/ w;
    final px = paddedOffset % w;
    if (px < 1 || py < 1 || px > w - 2 || py > h - 2) return 0.0;
    return binary[(py - 1) * width + (px - 1)];
  }

  bool isBackground(int offset) => valueAt(offset) == 0;

  // Seed the border.
  for (var x = 0; x < w; x++) {
    for (final y in [0, h - 1]) {
      final o = y * w + x;
      if (outside[o] == 0 && isBackground(o)) {
        outside[o] = 1;
        stack[sp++] = o;
      }
    }
  }
  for (var y = 0; y < h; y++) {
    for (final x in [0, w - 1]) {
      final o = y * w + x;
      if (outside[o] == 0 && isBackground(o)) {
        outside[o] = 1;
        stack[sp++] = o;
      }
    }
  }

  while (sp > 0) {
    final o = stack[--sp];
    final x = o % w;
    final y = o ~/ w;
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dy == 0) continue;
        final nx = x + dx;
        final ny = y + dy;
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        final no = ny * w + nx;
        if (outside[no] == 1 || !isBackground(no)) continue;
        outside[no] = 1;
        stack[sp++] = no;
      }
    }
  }

  var holes = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = y * w + x;
      if (outside[o] == 1) continue;
      if (valueAt(o) != 0) continue;
      // Unreached background: a new hole. Flood it so it counts once.
      holes++;
      outside[o] = 1;
      sp = 0;
      stack[sp++] = o;
      while (sp > 0) {
        final c = stack[--sp];
        final cx = c % w;
        final cy = c ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx;
            final ny = cy + dy;
            if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
            final no = ny * w + nx;
            if (outside[no] == 1 || valueAt(no) != 0) continue;
            outside[no] = 1;
            stack[sp++] = no;
          }
        }
      }
    }
  }
  return holes;
}

double otsuOf(Float32List values) {
  final hist = List<int>.filled(256, 0);
  for (final v in values) {
    hist[(v * 255).round().clamp(0, 255)]++;
  }
  // Local Otsu on the ink plane: bright class is ink.
  var total = 0;
  for (final c in hist) {
    total += c;
  }
  var sum = 0.0;
  for (var i = 0; i < 256; i++) {
    sum += i * hist[i];
  }
  var sumBackground = 0.0;
  var weightBackground = 0;
  var best = -1.0;
  var threshold = 128;
  for (var t = 0; t < 256; t++) {
    weightBackground += hist[t];
    if (weightBackground == 0) continue;
    final weightForeground = total - weightBackground;
    if (weightForeground == 0) break;
    sumBackground += t * hist[t];
    final meanBackground = sumBackground / weightBackground;
    final meanForeground = (sum - sumBackground) / weightForeground;
    final between = weightBackground * weightForeground *
        (meanBackground - meanForeground) * (meanBackground - meanForeground);
    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  return threshold / 255.0;
}

double _percentile(Float32List values, double p) {
  final hist = List<int>.filled(256, 0);
  for (final v in values) {
    hist[(v * 255).round().clamp(0, 255)]++;
  }
  final target = (values.length * p).floor();
  var seen = 0;
  for (var b = 0; b < 256; b++) {
    seen += hist[b];
    if (seen >= target) return b / 255.0;
  }
  return 1.0;
}
