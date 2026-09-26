import 'dart:math' as math;
import 'dart:typed_data';

import 'mask.dart';
import 'preprocess.dart';

/// A rectangle in normalised sheet coordinates, where 0 is the top/left edge of
/// the rectified sheet and 1 is the bottom/right edge.
class CellRect {
  const CellRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  double get area => math.max(0, width) * math.max(0, height);

  CellRect inset(double dx, double dy) => CellRect(
        left + dx,
        top + dy,
        right - dx,
        bottom - dy,
      );

  CellRect shrunk(double fraction) {
    final dx = width * fraction / 2;
    final dy = height * fraction / 2;
    return inset(dx, dy);
  }

  @override
  String toString() =>
      'CellRect(${(left * 100).toStringAsFixed(1)}%, '
      '${(top * 100).toStringAsFixed(1)}% -> '
      '${(right * 100).toStringAsFixed(1)}%, '
      '${(bottom * 100).toStringAsFixed(1)}%)';
}

/// One lattice intersection region, addressed by rule index rather than by
/// question number. Mapping lattice cells to question numbers is a separate,
/// layout-specific calibration step.
class GridCell {
  GridCell({required this.column, required this.row, required this.rect});

  /// Index of the bounding vertical rule pair; 0 is the leftmost cell column.
  final int column;

  /// Index of the bounding horizontal rule pair; 0 is the topmost cell row.
  final int row;

  final CellRect rect;

  @override
  String toString() => 'GridCell(col=$column,row=$row,$rect)';
}

/// A detected table lattice: the positions of the printed rules, normalised to
/// the sheet. Cells are the rectangles between adjacent rules.
class TableGrid {
  TableGrid({
    required this.columns,
    required this.rows,
    required this.ruleFraction,
    required this.snapFraction,
  });

  /// Normalised x of each vertical rule, ascending.
  final List<double> columns;

  /// Normalised y of each horizontal rule, ascending.
  final List<double> rows;

  /// Fraction of the raw line-response maximum required to accept a rule.
  final double ruleFraction;

  /// Fraction of lattice slots matched to a detected rule, 0..1. Low values mean
  /// the rules are irregular and the grid should not be trusted.
  final double snapFraction;

  int get columnCount => math.max(0, columns.length - 1);
  int get rowCount => math.max(0, rows.length - 1);
  int get cellCount => columnCount * rowCount;

  /// Overall usability in 0..1. A grid needs a real lattice and regular
  /// spacing before it is worth handing to a reader.
  double get score {
    if (columns.length < 3 || rows.length < 3) return 0;
    final regularity = (snapFraction * 0.6 + 0.4).clamp(0.0, 1.0);
    return regularity.clamp(0.0, 1.0);
  }

  /// Enumerates every cell, top-to-bottom then left-to-right.
  List<GridCell> cells() {
    final out = <GridCell>[];
    for (var r = 0; r < rowCount; r++) {
      for (var c = 0; c < columnCount; c++) {
        out.add(GridCell(
          column: c,
          row: r,
          rect: CellRect(columns[c], rows[r], columns[c + 1], rows[r + 1]),
        ));
      }
    }
    return out;
  }

  GridCell? cell(int column, int row) {
    if (column < 0 || row < 0) return null;
    if (column >= columnCount || row >= rowCount) return null;
    return GridCell(
      column: column,
      row: row,
      rect: CellRect(columns[column], rows[row],
          columns[column + 1], rows[row + 1]),
    );
  }

  @override
  String toString() => 'TableGrid(cols=$columns, rows=$rows, '
      'cells=${columns.length - 1}x${rows.length - 1}, '
      'snap=${snapFraction.toStringAsFixed(2)})';
}

/// Detects a printed table lattice from a flat-field-corrected ink response.
///
/// The strategy deliberately avoids assuming anything about the exam: printed
/// rules are the only marks that are long, straight and evenly spaced, so they
/// are isolated with 1-D morphological erosion by a line structuring element.
/// Handwriting and printed glyphs are short in both directions and vanish,
/// leaving only the rules to project into a peak profile.
TableGrid? detectTableGrid(
  InkMap ink, {
  double ruleFraction = 0.30,
  double minSpanFraction = 0.10,
  double slotToleranceFraction = 0.020,
  double? inkThreshold,
  void Function(String stage, String detail)? trace,
}) {
  final w = ink.width;
  final h = ink.height;
  if (w < 32 || h < 32) return null;

  trace?.call('ink', 'p50=${_percentile(ink.ink, 0.50).toStringAsFixed(3)} '
      'p75=${_percentile(ink.ink, 0.75).toStringAsFixed(3)} '
      'p90=${_percentile(ink.ink, 0.90).toStringAsFixed(3)} '
      'p95=${_percentile(ink.ink, 0.95).toStringAsFixed(3)} '
      'p99=${_percentile(ink.ink, 0.99).toStringAsFixed(3)}');

  final mask = _binarise(ink, inkThreshold);
  var inkPixels = 0;
  for (final v in mask) {
    if (v > 0) inkPixels++;
  }
  trace?.call('mask', 'threshold=${inkThreshold?.toStringAsFixed(3) ?? 'otsu'} '
      'inkPixels=$inkPixels (${(inkPixels / (w * h) * 100).toStringAsFixed(2)}%)');

  // Bridge 1-2px JPEG dropouts in a thin rule before measuring run length,
  // otherwise a single weak pixel splits a rule into two shorter segments.
  final bridged = erodePlane(dilatePlane(mask, w, h, 2, 2), w, h, 2, 2);

  // A rule must span at least this fraction of the sheet in its own axis.
  final spanX = math.max(8, (w * minSpanFraction).round());
  final spanY = math.max(8, (h * minSpanFraction).round());
  trace?.call('span', 'spanX=$spanX spanY=$spanY');

  // A long run along y is what distinguishes a vertical rule, so the tall line
  // element is applied on y here. Getting these two the wrong way round yields
  // an empty projection, because a vertical rule is only 1-3px wide.
  final verticalRules = erodePlane(bridged, w, h, 0, spanY);
  final horizontalRules = erodePlane(bridged, w, h, spanX, 0);
  trace?.call('longrun', 'verticalRulePixels=${_countPositive(verticalRules)} '
      'horizontalRulePixels=${_countPositive(horizontalRules)}');

  final cols = _rulePositions(verticalRules, w, h, vertical: true,
      ruleFraction: ruleFraction);
  final rows = _rulePositions(horizontalRules, w, h, vertical: false,
      ruleFraction: ruleFraction);
  trace?.call('peaks', 'raw columns=${cols.length} raw rows=${rows.length}');
  trace?.call('peaks.cols', _describe(cols));
  trace?.call('peaks.rows', _describe(rows));

  if (cols.length < 3 || rows.length < 3) return null;

  final colTol = w * slotToleranceFraction;
  final rowTol = h * slotToleranceFraction;
  final snappedCols = _fitLattice(cols, colTol);
  final snappedRows = _fitLattice(rows, rowTol);
  trace?.call('lattice', 'cols=${snappedCols.positions.length} '
      '(snap=${snappedCols.fraction.toStringAsFixed(2)}) '
      'rows=${snappedRows.positions.length} '
      '(snap=${snappedRows.fraction.toStringAsFixed(2)})');

  if (snappedCols.positions.length < 3 || snappedRows.positions.length < 3) {
    return null;
  }

  return TableGrid(
    columns: snappedCols.positions
        .map((p) => (p / (w - 1)).clamp(0.0, 1.0))
        .toList(growable: false),
    rows: snappedRows.positions
        .map((p) => (p / (h - 1)).clamp(0.0, 1.0))
        .toList(growable: false),
    ruleFraction: ruleFraction,
    snapFraction: math.min(snappedCols.fraction, snappedRows.fraction),
  );
}

int _countPositive(Float32List src) {
  var n = 0;
  for (final v in src) {
    if (v > 0) n++;
  }
  return n;
}

String _describe(List<double> positions) {
  if (positions.isEmpty) return '(none)';
  final buffer = StringBuffer();
  for (var i = 0; i < positions.length && i < 40; i++) {
    if (i > 0) buffer.write(' ');
    buffer.write(positions[i].toStringAsFixed(0));
  }
  if (positions.length > 40) buffer.write(' ...');
  return buffer.toString();
}

class _Lattice {
  _Lattice(this.positions, this.fraction);

  final List<double> positions;
  final double fraction;
}

/// Thresholds the ink plane into 0/1.
///
/// [threshold] is expressed in the same 0..1 units as the ink response. When
/// omitted, Otsu is used with a floor to suppress compression noise. Rules are
/// the darkest continuous marks on the page, so callers searching specifically
/// for rules should pass a deliberately high threshold: a permissive mask keeps
/// paper texture, whose long horizontal runs then dominate the projection.
Float32List _binarise(InkMap ink, double? threshold) {
  final t = threshold ??
      math.max(otsuThreshold(_histogram(ink.ink)) / 255.0, 0.20);
  final out = Float32List(ink.ink.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = ink.ink[i] > t ? 1 : 0;
  }
  return out;
}

List<int> _histogram(Float32List values) {
  final hist = List<int>.filled(256, 0);
  for (final v in values) {
    final b = (v * 255).round().clamp(0, 255);
    hist[b]++;
  }
  return hist;
}

double _percentile(Float32List values, double p) {
  final hist = _histogram(values);
  final total = values.length;
  final target = (total * p).floor();
  var seen = 0;
  for (var b = 0; b < 256; b++) {
    seen += hist[b];
    if (seen >= target) return b / 255.0;
  }
  return 1.0;
}

Float32List _boxSmooth(Float32List src, int radius) {
  if (radius < 1) return src;
  final n = src.length;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    var sum = 0.0;
    var count = 0;
    for (var j = i - radius; j <= i + radius; j++) {
      if (j < 0 || j >= n) continue;
      sum += src[j];
      count++;
    }
    out[i] = sum / count;
  }
  return out;
}

/// Projects the surviving long-run mask onto one axis and returns the
/// intensity-weighted centre of each peak above [ruleFraction] of the maximum.
List<double> _rulePositions(
  Float32List lines,
  int w,
  int h, {
  required bool vertical,
  required double ruleFraction,
}) {
  final n = vertical ? w : h;
  final proj = Float32List(n);
  for (var y = 0; y < h; y++) {
    final base = y * w;
    for (var x = 0; x < w; x++) {
      final v = lines[base + x];
      if (v <= 0) continue;
      if (vertical) {
        proj[x] += v;
      } else {
        proj[y] += v;
      }
    }
  }

  // A rule that is briefly interrupted produces two adjacent peaks; smoothing
  // merges them into one before peak picking.
  final sm = _boxSmooth(proj, 2);

  var peak = 0.0;
  for (final v in sm) {
    if (v > peak) peak = v;
  }
  if (peak <= 0) return const [];

  final threshold = peak * ruleFraction;
  final out = <double>[];
  var i = 0;
  while (i < n) {
    if (sm[i] < threshold) {
      i++;
      continue;
    }
    var j = i;
    var weighted = 0.0;
    var total = 0.0;
    while (j < n && sm[j] >= threshold) {
      weighted += sm[j] * j;
      total += sm[j];
      j++;
    }
    if (total > 0) out.add(weighted / total);
    i = j;
  }
  return out;
}

/// Fits an evenly-spaced lattice to noisy detections and reports how much of
/// the lattice the detections actually support.
///
/// Rules on a real form are near-uniformly pitched, so a median-pitch lattice
/// is a far stronger prior than "accept whatever peaks appeared". Slots with no
/// nearby detection are dropped, and a doubled gap afterwards is re-split so a
/// single missed rule does not silently merge two columns.
_Lattice _fitLattice(List<double> detected, double tolerance) {
  if (detected.length < 3) {
    return _Lattice(detected, 0);
  }

  final diffs = <double>[];
  for (var i = 1; i < detected.length; i++) {
    diffs.add(detected[i] - detected[i - 1]);
  }
  final sorted = List<double>.from(diffs)..sort();
  var pitch = sorted[sorted.length ~/ 2];
  if (pitch <= tolerance) return _Lattice(detected, 0);

  // Median-of-ratios refinement: a single outlier gap should not tilt the pitch.
  final ratios = <double>[];
  for (final d in diffs) {
    ratios.add(d / pitch);
  }
  ratios.sort();
  final medianRatio = ratios[ratios.length ~/ 2];
  if (medianRatio > 1.5) pitch = pitch * 2;

  final slots = <double>[];
  var p = detected.first;
  while (p <= detected.last + tolerance) {
    slots.add(p);
    p += pitch;
  }

  final matched = <double>[];
  for (final slot in slots) {
    double? best;
    var bestDist = tolerance;
    for (final d in detected) {
      final dist = (d - slot).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = d;
      }
    }
    if (best != null) matched.add(best);
  }

  final filled = _splitDoubleGaps(matched, pitch);
  if (filled.length < 3) return _Lattice(detected, 0);

  // Fraction of the *emitted* lattice that came from a real detection, minus a
  // penalty for slots that were skipped entirely.
  final missing = math.max(0, slots.length - matched.length);
  final fraction = (matched.length / (filled.length + missing))
      .clamp(0.0, 1.0);
  return _Lattice(filled, fraction);
}

List<double> _splitDoubleGaps(List<double> positions, double pitch) {
  final out = <double>[];
  for (var i = 0; i < positions.length; i++) {
    if (i > 0) {
      final gap = positions[i] - positions[i - 1];
      if (gap > pitch * 1.6) {
        final mid = (positions[i] + positions[i - 1]) / 2;
        out.add(mid);
      }
    }
    out.add(positions[i]);
  }
  return out;
}
