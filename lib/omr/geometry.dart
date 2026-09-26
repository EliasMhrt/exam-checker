import 'dart:math' as math;

class Point {
  const Point(this.x, this.y);

  final double x;
  final double y;

  Point operator +(Point other) => Point(x + other.x, y + other.y);

  Point operator -(Point other) => Point(x - other.x, y - other.y);

  Point operator *(double s) => Point(x * s, y * s);

  double distanceTo(Point other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  double get length => math.sqrt(x * x + y * y);

  @override
  String toString() =>
      '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// Planar projective transform, stored row-major as
/// `[h0..h7]` with the implicit `h8 = 1`.
class Homography {
  const Homography(this.h);

  final List<double> h;

  /// Solves the 8-unknown system for the mapping [from] -> [to].
  ///
  /// Returns `null` when the correspondences are degenerate (collinear or
  /// coincident corners), so callers can fall back instead of producing
  /// nonsense geometry.
  static Homography? fromCorrespondences(
    List<Point> from,
    List<Point> to,
  ) {
    if (from.length != 4 || to.length != 4) return null;

    final a = List.generate(8, (_) => List<double>.filled(9, 0));
    for (var i = 0; i < 4; i++) {
      final p = from[i];
      final q = to[i];

      final r1 = a[2 * i];
      r1[0] = p.x;
      r1[1] = p.y;
      r1[2] = 1;
      r1[6] = -p.x * q.x;
      r1[7] = -p.y * q.x;
      r1[8] = q.x;

      final r2 = a[2 * i + 1];
      r2[3] = p.x;
      r2[4] = p.y;
      r2[5] = 1;
      r2[6] = -p.x * q.y;
      r2[7] = -p.y * q.y;
      r2[8] = q.y;
    }

    final solution = _solve(a);
    if (solution == null) return null;
    return Homography(solution);
  }

  Homography inverted() => Homography(_invert3x3());

  Point project(Point p) {
    final w = h[6] * p.x + h[7] * p.y + 1.0;
    if (w.abs() < 1e-12) {
      return const Point(double.nan, double.nan);
    }
    return Point(
      (h[0] * p.x + h[1] * p.y + h[2]) / w,
      (h[3] * p.x + h[4] * p.y + h[5]) / w,
    );
  }

  List<double> _invert3x3() {
    final m = [
      [h[0], h[1], h[2]],
      [h[3], h[4], h[5]],
      [h[6], h[7], 1.0],
    ];
    final det = _det3(m);
    if (det.abs() < 1e-12) {
      return List<double>.filled(8, 0);
    }
    // Cofactors, then adjugate (transpose). adj[i][j] = C[j][i].
    final inv = [
      [
        (m[1][1] * m[2][2] - m[1][2] * m[2][1]) / det,
        (m[0][2] * m[2][1] - m[0][1] * m[2][2]) / det,
        (m[0][1] * m[1][2] - m[0][2] * m[1][1]) / det,
      ],
      [
        (m[1][2] * m[2][0] - m[1][0] * m[2][2]) / det,
        (m[0][0] * m[2][2] - m[0][2] * m[2][0]) / det,
        (m[0][2] * m[1][0] - m[0][0] * m[1][2]) / det,
      ],
      [
        (m[1][0] * m[2][1] - m[1][1] * m[2][0]) / det,
        (m[0][1] * m[2][0] - m[0][0] * m[2][1]) / det,
        (m[0][0] * m[1][1] - m[0][1] * m[1][0]) / det,
      ],
    ];

    // The matrix is stored as 8 coefficients with the last one implicitly 1, so
    // the inverse must be renormalised to that same convention. A projective
    // transform is scale invariant, so dividing the first two rows by the
    // bottom-right entry changes nothing geometrically.
    final scale = inv[2][2];
    if (scale.abs() < 1e-12) {
      return List<double>.filled(8, 0);
    }
    return [
      inv[0][0] / scale, inv[0][1] / scale, inv[0][2] / scale,
      inv[1][0] / scale, inv[1][1] / scale, inv[1][2] / scale,
      inv[2][0] / scale, inv[2][1] / scale,
    ];
  }

  static double _det3(List<List<double>> m) => m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
      m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
      m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
}

/// Gaussian elimination with partial pivoting. Mutates [a].
List<double>? _solve(List<List<double>> a) {
  final n = a.length;
  for (var col = 0; col < n; col++) {
    var pivotRow = col;
    var best = a[col][col].abs();
    for (var r = col + 1; r < n; r++) {
      final v = a[r][col].abs();
      if (v > best) {
        best = v;
        pivotRow = r;
      }
    }
    if (best < 1e-12) return null;
    if (pivotRow != col) {
      final tmp = a[col];
      a[col] = a[pivotRow];
      a[pivotRow] = tmp;
    }
    final pivot = a[col][col];
    for (var r = col + 1; r < n; r++) {
      final factor = a[r][col] / pivot;
      if (factor == 0) continue;
      for (var c = col; c <= n; c++) {
        a[r][c] -= factor * a[col][c];
      }
    }
  }

  final x = List<double>.filled(n, 0);
  for (var r = n - 1; r >= 0; r--) {
    var sum = a[r][n];
    for (var c = r + 1; c < n; c++) {
      sum -= a[r][c] * x[c];
    }
    x[r] = sum / a[r][r];
  }
  for (final v in x) {
    if (v.isNaN || v.isInfinite) return null;
  }
  return x;
}

/// Andrew's monotone chain convex hull, counter-clockwise.
List<Point> convexHull(List<Point> input) {
  if (input.length < 3) return List.of(input);
  final points = List.of(input)
    ..sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));

  List<Point> half(List<Point> src) {
    final out = <Point>[];
    for (final p in src) {
      while (out.length >= 2) {
        final o = out[out.length - 1];
        final q = out[out.length - 2];
        final cross = (o.x - q.x) * (p.y - q.y) - (o.y - q.y) * (p.x - q.x);
        if (cross <= 0) {
          out.removeLast();
        } else {
          break;
        }
      }
      out.add(p);
    }
    out.removeLast();
    return out;
  }

  final lower = half(points);
  final upper = half(points.reversed.toList());
  return [...lower, ...upper];
}

double polygonArea(List<Point> poly) {
  var sum = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i];
    final b = poly[(i + 1) % poly.length];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum.abs() / 2;
}

/// Reduces a point cloud to four ordered corners: top-left, top-right,
/// bottom-right, bottom-left.
///
/// Uses the extremity method (min/max of x+y and x-y), which is exact for a
/// convex quad and stays correct when the sheet is rotated on the desk.
List<Point>? quadCorners(List<Point> points) {
  if (points.length < 4) return null;
  final hull = convexHull(points);
  if (hull.length < 4) return null;

  Point topLeft = hull.first;
  Point topRight = hull.first;
  Point bottomRight = hull.first;
  Point bottomLeft = hull.first;
  var minSum = double.infinity;
  var maxSum = -double.infinity;
  var minDiff = double.infinity;
  var maxDiff = -double.infinity;

  for (final p in hull) {
    final sum = p.x + p.y;
    final diff = p.x - p.y;
    if (sum < minSum) {
      minSum = sum;
      topLeft = p;
    }
    if (sum > maxSum) {
      maxSum = sum;
      bottomRight = p;
    }
    if (diff > maxDiff) {
      maxDiff = diff;
      topRight = p;
    }
    if (diff < minDiff) {
      minDiff = diff;
      bottomLeft = p;
    }
  }

  return [topLeft, topRight, bottomRight, bottomLeft];
}

bool isConvexQuad(List<Point> quad) {
  if (quad.length != 4) return false;
  var sign = 0;
  for (var i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    final c = quad[(i + 2) % 4];
    final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    final s = cross.sign.toInt();
    if (s == 0) continue;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}
