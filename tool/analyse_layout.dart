// Dev-only layout probe. Reports the geometric structure of a sample photo
// numerically: sheet extent, projection profiles (to find grid pitch), and a
// census of every ink blob's size and shape.
//
//   dart run tool/analyse_layout.dart <photo.jpg> [workEdge]
import 'dart:io';
import 'dart:math' as math;

import 'package:myapp/omr/geometry.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/mask.dart';
import 'package:myapp/omr/preprocess.dart';

List<double> projectX(InkMap ink) {
  final out = List<double>.filled(ink.width, 0);
  for (var y = 0; y < ink.height; y++) {
    for (var x = 0; x < ink.width; x++) {
      out[x] += ink.at(x, y);
    }
  }
  return out;
}

List<double> projectY(InkMap ink) {
  final out = List<double>.filled(ink.height, 0);
  for (var y = 0; y < ink.height; y++) {
    for (var x = 0; x < ink.width; x++) {
      out[y] += ink.at(x, y);
    }
  }
  return out;
}

/// Runs of values above [fraction] of the profile's own mean.
List<({int start, int end, int centre})> bands(
  List<double> profile,
  double fraction,
) {
  final mean = profile.reduce((a, b) => a + b) / profile.length;
  final threshold = mean * fraction;
  final bands = <({int start, int end, int centre})>[];
  int? runStart;
  for (var i = 0; i < profile.length; i++) {
    final on = profile[i] > threshold;
    if (on && runStart == null) {
      runStart = i;
    } else if (!on && runStart != null) {
      bands.add((start: runStart, end: i - 1, centre: (runStart + i - 1) ~/ 2));
      runStart = null;
    }
  }
  if (runStart != null) {
    bands.add((
      start: runStart,
      end: profile.length - 1,
      centre: (runStart + profile.length - 1) ~/ 2
    ));
  }
  return bands;
}

void reportBands(String label, List<double> profile, double fraction) {
  final b = bands(profile, fraction);
  stdout.writeln('$label: ${b.length} bands at fraction $fraction');
  if (b.length <= 40) {
    for (final band in b) {
      stdout.writeln('   centre=${band.centre}  width=${band.end - band.start + 1}');
    }
    // Spacing between centres reveals the grid pitch.
    if (b.length > 1) {
      final gaps = <int>[];
      for (var i = 1; i < b.length; i++) {
        gaps.add(b[i].centre - b[i - 1].centre);
      }
      gaps.sort();
      stdout.writeln('   gaps sorted: $gaps');
      stdout.writeln('   median gap: ${gaps[gaps.length ~/ 2]}');
    }
  }
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/analyse_layout.dart <photo.jpg> [edge]');
    exit(2);
  }
  final workEdge = args.length > 1 ? int.parse(args[1]) : 1600;
  final name = args[0].split(RegExp(r'[/\\]')).last;

  final gray =
      GrayImage.decodeJpeg(File(args[0]).readAsBytesSync()).downscaleTo(workEdge);
  stdout.writeln('=== $name ===');
  stdout.writeln('working size: ${gray.width} x ${gray.height}');

  // --- Paper extent -------------------------------------------------------
  // Paper is the bright majority; find its bounding box by column/row means.
  final colMean = List<double>.filled(gray.width, 0);
  final rowMean = List<double>.filled(gray.height, 0);
  for (var y = 0; y < gray.height; y++) {
    for (var x = 0; x < gray.width; x++) {
      final v = gray.at(x, y);
      colMean[x] += v;
      rowMean[y] += v;
    }
  }
  for (var x = 0; x < gray.width; x++) {
    colMean[x] /= gray.height;
  }
  for (var y = 0; y < gray.height; y++) {
    rowMean[y] /= gray.width;
  }

  final paperLevel = gray.median();
  int firstBrightCol() {
    for (var x = 0; x < gray.width; x++) {
      if (colMean[x] > paperLevel * 0.85) return x;
    }
    return 0;
  }

  int lastBrightCol() {
    for (var x = gray.width - 1; x >= 0; x--) {
      if (colMean[x] > paperLevel * 0.85) return x;
    }
    return gray.width - 1;
  }

  int firstBrightRow() {
    for (var y = 0; y < gray.height; y++) {
      if (rowMean[y] > paperLevel * 0.85) return y;
    }
    return 0;
  }

  int lastBrightRow() {
    for (var y = gray.height - 1; y >= 0; y--) {
      if (rowMean[y] > paperLevel * 0.85) return y;
    }
    return gray.height - 1;
  }

  final pl = firstBrightCol(), pr = lastBrightCol();
  final pt = firstBrightRow(), pb = lastBrightRow();
  stdout.writeln('paper band: x $pl..$pr   y $pt..$pb   '
      '(w=${pr - pl + 1}, h=${pb - pt + 1})');
  stdout.writeln('luma: median=${paperLevel.toStringAsFixed(1)}');

  // --- Ink structure ------------------------------------------------------
  final ink = InkMap.fromLuminance(gray, seRadius: math.max(4, gray.height ~/ 12));
  var peak = 0.0;
  for (final v in ink.ink) {
    if (v > peak) peak = v;
  }
  stdout.writeln('peak ink response: ${peak.toStringAsFixed(3)}');

  reportBands('vertical bands (x)', projectX(ink), 0.8);
  reportBands('horizontal bands (y)', projectY(ink), 0.8);

  // --- Blob census --------------------------------------------------------
  // Count marks inside the paper band only, ignoring the dark surround.
  final thr = peak * 0.35;
  final comps = connectedComponents(
    ink.ink,
    width: ink.width,
    height: ink.height,
    isForeground: (o) {
      final x = o % ink.width;
      final y = o ~/ ink.width;
      if (x < pl || x > pr || y < pt || y > pb) return false;
      return ink.ink[o] > thr;
    },
    minArea: 6,
  );
  stdout.writeln('blobs (area>=6, inside paper): ${comps.length}');

  final sizeBuckets = <String, int>{};
  final aspectBuckets = <String, int>{};
  var totalInk = 0.0;
  for (final c in comps) {
    final extent = c.extent;
    totalInk += c.area.toDouble();
    final sb = extent < 8
        ? '<8'
        : extent < 16
            ? '8-15'
            : extent < 32
                ? '16-31'
                : extent < 64
                    ? '32-63'
                    : extent < 128
                        ? '64-127'
                        : '128+';
    sizeBuckets[sb] = (sizeBuckets[sb] ?? 0) + 1;
    final a = c.aspect;
    final ab = a < 0.45
        ? 'tall'
        : a < 0.8
            ? 'vtall'
            : a < 1.25
                ? 'square'
                : a < 2.2
                    ? 'wide'
                    : 'hwide';
    aspectBuckets[ab] = (aspectBuckets[ab] ?? 0) + 1;
  }
  stdout.writeln('extent buckets: $sizeBuckets');
  stdout.writeln('aspect buckets: $aspectBuckets');
  stdout.writeln('total blob area: ${totalInk.toStringAsFixed(0)} px '
      '(${(totalInk / gray.length * 100).toStringAsFixed(2)}% of frame)');

  // The 20 largest blobs, to identify structural rules vs marks.
  stdout.writeln('largest 20 blobs (x, y, w, h, area, density):');
  for (final c in comps.take(20)) {
    stdout.writeln('   (${c.minX}, ${c.minY}) ${c.width}x${c.height} '
        'area=${c.area} density=${c.density.toStringAsFixed(2)}');
  }

  // Corner candidates for the sheet quad.
  stdout.writeln('extremity corners over the paper band:');
  final corners = quadCorners([
    Point(pl.toDouble(), pt.toDouble()),
    Point(pr.toDouble(), pt.toDouble()),
    Point(pr.toDouble(), pb.toDouble()),
    Point(pl.toDouble(), pb.toDouble()),
  ]);
  stdout.writeln('   $corners');
}
