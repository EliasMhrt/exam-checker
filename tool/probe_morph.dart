import 'dart:io';
import 'dart:typed_data';

import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/preprocess.dart';

Float32List bruteExtreme(Float32List s, int w, int h, int r, bool findMin) {
  final o = Float32List(s.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var m = findMin ? double.infinity : -double.infinity;
      for (var dy = -r; dy <= r; dy++) {
        for (var dx = -r; dx <= r; dx++) {
          final nx = (x + dx).clamp(0, w - 1).toInt();
          final ny = (y + dy).clamp(0, h - 1).toInt();
          final v = s[ny * w + nx];
          if (findMin ? v < m : v > m) m = v;
        }
      }
      o[y * w + x] = m;
    }
  }
  return o;
}

void main() {
  // --- Verify the sliding-window filters against brute force --------------
  final w = 41, h = 33, r = 5;
  final buf = Float32List(w * h);
  var seed = 987654321;
  for (var i = 0; i < buf.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    buf[i] = (seed >> 7) % 250;
  }

  final eroded = erodePlane(buf, w, h, r);
  final erodedRef = bruteExtreme(buf, w, h, r, true);
  var maxErr = 0.0;
  for (var i = 0; i < buf.length; i++) {
    final d = (eroded[i] - erodedRef[i]).abs();
    if (d > maxErr) maxErr = d;
  }
  stdout.writeln('erode   max abs error vs brute force: $maxErr');

  final dilated = dilatePlane(buf, w, h, r);
  final dilatedRef = bruteExtreme(buf, w, h, r, false);
  maxErr = 0.0;
  for (var i = 0; i < buf.length; i++) {
    final d = (dilated[i] - dilatedRef[i]).abs();
    if (d > maxErr) maxErr = d;
  }
  stdout.writeln('dilate  max abs error vs brute force: $maxErr');

  // --- 1D ramp through a 2D filter ---------------------------------------
  final img = GrayImage(120, 8);
  for (var y = 0; y < 8; y++) {
    for (var x = 0; x < 120; x++) {
      img.set(x, y, 100.0 + x);
    }
  }
  final closed = morphologicalClosing(img, 20);
  stdout.writeln('1D ramp along x, closing radius 20:');
  for (final x in [0, 10, 30, 60, 90, 110, 119]) {
    stdout.writeln('  x=$x in=${img.at(x, 4).toStringAsFixed(1)} '
        'out=${closed.at(x, 4).toStringAsFixed(1)}');
  }

  // --- 2D diagonal ramp ---------------------------------------------------
  final img2 = GrayImage(120, 120);
  for (var y = 0; y < 120; y++) {
    for (var x = 0; x < 120; x++) {
      img2.set(x, y, 100.0 + x + y);
    }
  }
  final closed2 = morphologicalClosing(img2, 20);
  stdout.writeln('2D diagonal ramp, closing radius 20:');
  for (final p in [
    [10, 10],
    [60, 60],
    [110, 110]
  ]) {
    stdout.writeln('  (${p[0]},${p[1]}) in=${img2.at(p[0], p[1]).toStringAsFixed(1)} '
        'out=${closed2.at(p[0], p[1]).toStringAsFixed(1)}');
  }

  // --- closing must erase a dark bar narrower than the element -----------
  final flat = GrayImage.filled(120, 8, 200);
  for (var x = 50; x < 60; x++) {
    for (var y = 0; y < 8; y++) {
      flat.set(x, y, 20);
    }
  }
  final closedFlat = morphologicalClosing(flat, 20);
  stdout.writeln('flat + 10px dark bar, closing radius 20 (bar must vanish):');
  for (final x in [45, 50, 55, 59, 60, 65]) {
    stdout.writeln('  x=$x in=${flat.at(x, 4).toStringAsFixed(0)} '
        'out=${closedFlat.at(x, 4).toStringAsFixed(1)}');
  }
}
