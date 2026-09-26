import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/preprocess.dart';

/// Characters from lightest to darkest.
const ramp = ' .:-=+*#%@';

/// Value at the given percentile of a plane whose values live in 0..1.
double percentileOf(Float32List values, double p) {
  final bins = List<int>.filled(256, 0);
  for (final v in values) {
    final b = (v * 255).round().clamp(0, 255);
    bins[b]++;
  }
  final target = (values.length * p).floor();
  var seen = 0;
  for (var b = 0; b < 256; b++) {
    seen += bins[b];
    if (seen >= target) return b / 255.0;
  }
  return 1.0;
}

/// Renders an image's ink response as ASCII art.
///
/// Normalising against a high percentile rather than the maximum matters: a
/// single hot pixel otherwise compresses the entire page into the darkest ramp
/// character and the layout becomes unreadable.
void renderAscii(GrayImage img, int columns, {String? label}) {
  final rows = math.max(1, (columns * img.height / img.width / 2.0).round());
  var ink = InkMap.fromLuminance(
    img,
    seRadius: math.max(2, (math.min(img.width, img.height) / 6).round()),
  );
  // Printed marks are thin; a 3x3 median removes JPEG speckle without eating
  // stroke width.
  ink = ink.medianFiltered(1);
  final ref = math.max(0.02, percentileOf(ink.ink, 0.985));

  final buffer = StringBuffer();
  if (label != null) {
    buffer.writeln('$label (${img.width}x${img.height})');
  }
  for (var y = 0; y < rows; y++) {
    for (var x = 0; x < columns; x++) {
      final v = ink.at(
        math.min(img.width - 1, (x * img.width / columns).round()),
        math.min(img.height - 1, (y * img.height / rows).round()),
      );
      final norm = (v / ref).clamp(0.0, 1.0);
      final boosted = math.pow(norm, 0.55).toDouble();
      buffer.write(ramp[(boosted * (ramp.length - 1)).round()]);
    }
    buffer.writeln();
  }
  stdout.write(buffer);
}
