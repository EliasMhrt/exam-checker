// Dev-only inspector. Renders sample photos as text so the sheet layout can be
// characterised numerically without an image viewer.
//
//   dart run tool/inspect_photos.dart <photo.jpg> [columns] [x0 y0 x1 y1]
//
// Crop values are fractions of width/height (0..1), applied after downscale.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/mask.dart';
import 'package:myapp/omr/preprocess.dart';

const ramp = ' .:-=+*#%@';

GrayImage cropTo(GrayImage src, double x0, double y0, double x1, double y1) {
  final left = (src.width * x0).round().clamp(0, src.width - 1);
  final top = (src.height * y0).round().clamp(0, src.height - 1);
  final right = (src.width * x1).round().clamp(left + 1, src.width);
  final bottom = (src.height * y1).round().clamp(top + 1, src.height);
  final w = right - left;
  final h = bottom - top;
  final out = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      out[y * w + x] = src.at(left + x, top + y);
    }
  }
  return GrayImage(w, h, out);
}

double percentile(InkMap ink, double p) {
  final bins = List<int>.filled(256, 0);
  for (final v in ink.ink) {
    final b = (v * 255).round().clamp(0, 255);
    bins[b]++;
  }
  final target = (ink.ink.length * p).floor();
  var c = 0;
  for (var b = 0; b < 256; b++) {
    c += bins[b];
    if (c >= target) return b / 255.0;
  }
  return 1.0;
}

void renderAscii(GrayImage img, int columns) {
  final rows = math.max(1, (columns * img.height / img.width / 2.0).round());
  var ink = InkMap.fromLuminance(
    img,
    seRadius: math.max(2, (math.min(img.width, img.height) / 6).round()),
  );
  // Printed marks are thin; a 3x3 median removes JPEG speckle without eating
  // stroke width, and a high percentile instead of the max stops one hot
  // pixel from crushing the whole dynamic range.
  ink = ink.medianFiltered(1);
  final ref = math.max(0.02, percentile(ink, 0.985));

  final buffer = StringBuffer();
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

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: dart run tool/inspect_photos.dart <photo.jpg> [columns] [x0 y0 x1 y1]');
    exit(2);
  }
  final path = args[0];
  final columns = args.length > 1 ? int.parse(args[1]) : 96;

  final bytes = File(path).readAsBytesSync();
  var gray = GrayImage.decode(bytes).downscaleTo(1600);

  if (args.length >= 6) {
    gray = cropTo(
      gray,
      double.parse(args[2]),
      double.parse(args[3]),
      double.parse(args[4]),
      double.parse(args[5]),
    );
    stdout.writeln('cropped to ${gray.width}x${gray.height}');
  } else {
    stdout.writeln('working: ${gray.width}x${gray.height}');
  }

  final hist = gray.histogram();
  stdout.writeln('luma median=${gray.median().toStringAsFixed(1)} '
      'otsu=${otsuThreshold(hist).toStringAsFixed(0)}');

  renderAscii(gray, columns);
}
