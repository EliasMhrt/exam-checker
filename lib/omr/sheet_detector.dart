import 'dart:math' as math;
import 'dart:typed_data';

import 'geometry.dart';
import 'gray_image.dart';
import 'mask.dart';

/// A detected sheet of paper in the source image.
class SheetRegion {
  SheetRegion({
    required this.corners,
    required this.areaFraction,
    required this.coverage,
    required this.touchingEdges,
  });

  /// Corners in source pixels, ordered top-left, top-right, bottom-right,
  /// bottom-left.
  final List<Point> corners;

  /// Quad area as a fraction of the whole frame.
  final double areaFraction;

  /// Fraction of the quad that actually had paper pixels behind it. A low value
  /// means the quad is an extrapolation past the frame rather than an observed
  /// sheet boundary.
  final double coverage;

  /// Which frame edges (left, top, right, bottom) the paper reaches.
  final int touchingEdges;

  static const int edgeLeft = 1;
  static const int edgeTop = 2;
  static const int edgeRight = 4;
  static const int edgeBottom = 8;

  /// True when the sheet runs off the frame, which makes a projective fit
  /// unreliable and should be reported to the user as "reframe the shot".
  bool get isClipped => touchingEdges != 0;

  /// Usability in 0..1. Requires a large, convex, well-observed sheet.
  double get score {
    final sizeScore = ((areaFraction - 0.15) / 0.55).clamp(0.0, 1.0);
    return sizeScore * coverage;
  }

  /// Rectification target size, derived from the average edge lengths.
  int get rectifiedWidth {
    final top = corners[0].distanceTo(corners[1]);
    final bottom = corners[3].distanceTo(corners[2]);
    return math.max(16, ((top + bottom) / 2).round());
  }

  int get rectifiedHeight {
    final left = corners[0].distanceTo(corners[3]);
    final right = corners[1].distanceTo(corners[2]);
    return math.max(16, ((left + right) / 2).round());
  }

  /// Rectification target size: the quad's average edge lengths, rescaled so
  /// the longer side is exactly [maxEdge].
  (int, int) rectifiedSize(int maxEdge) {
    final w = rectifiedWidth;
    final h = rectifiedHeight;
    if (w >= h) {
      return (maxEdge, math.max(16, (h * (maxEdge / w)).round()));
    }
    return (math.max(16, (w * (maxEdge / h)).round()), maxEdge);
  }

  /// Builds the mapping that turns the detected quad into an upright rectangle.
  ///
  /// Returns `null` when the quad is degenerate.
  Homography? rectification(int maxEdge) {
    final (w, h) = rectifiedSize(maxEdge);
    final target = [
      const Point(0.0, 0.0),
      Point(w - 1.0, 0.0),
      Point(w - 1.0, h - 1.0),
      Point(0.0, h - 1.0),
    ];
    return Homography.fromCorrespondences(target, corners);
  }

  @override
  String toString() => 'SheetRegion(area=${areaFraction.toStringAsFixed(3)}, '
      'coverage=${coverage.toStringAsFixed(3)}, '
      'edges=$touchingEdges, corners=$corners)';
}

/// Finds the sheet of paper in a frame.
///
/// The sheet is the large bright region, so the brightest Otsu class is
/// labelled and the largest connected component is taken. Text punches holes in
/// that component, but the surrounding paper stays connected, so the region
/// survives. Scanning each row for its leftmost and rightmost paper pixel gives
/// the two side boundaries directly, which is far cheaper and more stable than
/// taking a convex hull of every paper pixel.
SheetRegion? detectSheet(
  GrayImage gray, {
  int workEdge = 900,
  double minAreaFraction = 0.10,
}) {
  final work = gray.width >= workEdge || gray.height >= workEdge
      ? gray.downscaleTo(workEdge)
      : gray;

  final w = work.width;
  final h = work.height;

  final threshold = otsuThreshold(work.histogram());
  final total = w * h;

  final comps = connectedComponents(
    work.data,
    width: w,
    height: h,
    isForeground: (offset) => work.data[offset] > threshold,
    minArea: (total * minAreaFraction).round(),
  );
  if (comps.isEmpty) return null;
  final paper = comps.first;

  final rowMinX = Int32List(h);
  final rowMaxX = Int32List(h);
  final rowCount = Int32List(h);
  rowMinX.fillRange(0, h, -1);

  for (final offset in paper.pixels) {
    final x = offset % w;
    final y = offset ~/ w;
    if (rowMinX[y] < 0 || x < rowMinX[y]) rowMinX[y] = x;
    if (x > rowMaxX[y]) rowMaxX[y] = x;
    rowCount[y]++;
  }

  // Boundary samples, skipping rows that only clipped a corner.
  final boundary = <Point>[];
  for (var y = 0; y < h; y++) {
    if (rowCount[y] < (w * 0.02).round()) continue;
    boundary.add(Point(rowMinX[y].toDouble(), y.toDouble()));
    boundary.add(Point(rowMaxX[y].toDouble(), y.toDouble()));
  }
  if (boundary.length < 8) return null;

  final corners = quadCorners(boundary);
  if (corners == null) return null;
  if (!isConvexQuad(corners)) return null;

  final quadArea = polygonArea(corners);
  final areaFraction = quadArea / total;
  if (areaFraction < minAreaFraction || areaFraction > 1.6) return null;

  // How much of the quad was actually backed by observed paper.
  final coverage = (paper.area / quadArea).clamp(0.0, 1.0);

  var touching = 0;
  const tolerance = 2;
  for (final c in corners) {
    if (c.x <= tolerance) touching |= SheetRegion.edgeLeft;
    if (c.y <= tolerance) touching |= SheetRegion.edgeTop;
    if (c.x >= w - 1 - tolerance) touching |= SheetRegion.edgeRight;
    if (c.y >= h - 1 - tolerance) touching |= SheetRegion.edgeBottom;
  }

  return SheetRegion(
    corners: corners,
    areaFraction: areaFraction,
    coverage: coverage,
    touchingEdges: touching,
  );
}
