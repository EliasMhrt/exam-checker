import 'dart:math' as math;
import 'dart:typed_data';

import 'gray_image.dart';

/// Separable sliding-window extremum filter with a square structuring element.
///
/// The sweep is causal over a line padded with replicated edges, and the result
/// is written at the *centre* of each window rather than at its leading edge.
/// Concretely, at padded index `i` the window is `[i - 2*radius, i]` and the
/// output lands on centre `i - radius`, so the effective window in source
/// coordinates is a correctly centred `(2*radius + 1)` square. The line is
/// padded by `2*radius` on the leading side and `radius` on the trailing side
/// to cover that window at both ends.
Float32List _slidingExtreme(
  Float32List src,
  int w,
  int h,
  int radius, {
  required bool horizontal,
  required bool findMin,
}) {
  final out = Float32List(w * h);
  final lineCount = horizontal ? h : w;
  final lineLength = horizontal ? w : h;
  final leftPad = 2 * radius;
  final rightPad = radius;
  final padded = Float32List(lineLength + leftPad + rightPad);

  for (var line = 0; line < lineCount; line++) {
    for (var i = 0; i < lineLength; i++) {
      padded[leftPad + i] =
          horizontal ? src[line * w + i] : src[i * w + line];
    }
    for (var i = 1; i <= leftPad; i++) {
      padded[leftPad - i] = padded[leftPad];
    }
    for (var i = 0; i < rightPad; i++) {
      padded[leftPad + lineLength + i] = padded[leftPad + lineLength - 1];
    }

    final deque = Int32List(padded.length);
    var head = 0;
    var tail = 0;
    for (var i = 0; i < padded.length; i++) {
      final v = padded[i];
      while (tail > head) {
        final bv = padded[deque[tail - 1]];
        // Keep the deque monotonic: ascending for a minimum (so the front is
        // the smallest), descending for a maximum.
        if (findMin ? bv >= v : bv <= v) {
          tail--;
        } else {
          break;
        }
      }
      deque[tail++] = i;

      final lowest = i - 2 * radius;
      while (tail > head && deque[head] < lowest) {
        head++;
      }

      // Source index `k` lives at padded index `k + leftPad`, so the window
      // [i - 2*radius, i] corresponds to source
      // [i - 2*radius - leftPad, i - leftPad] and its centre is
      // `i - radius - leftPad`.
      final centerIndex = i - radius - leftPad;
      if (centerIndex >= 0 && centerIndex < lineLength) {
        out[horizontal ? line * w + centerIndex : centerIndex * w + line] =
            padded[deque[head]];
      }
    }
  }
  return out;
}

/// Grayscale erosion by a rectangular structuring element.
///
/// A radius of 0 on an axis makes that axis a no-op, which yields a 1-D line
/// element - exactly what is needed to keep only structures that are long in
/// one direction (table rules) and short in the other.
Float32List erodePlane(
  Float32List src,
  int w,
  int h, [
  int? radiusOrX,
  int? radiusYArg,
]) {
  final rx = radiusOrX ?? 0;
  final ry = radiusYArg ?? radiusOrX ?? 0;
  if (rx < 1 && ry < 1) return Float32List.fromList(src);
  var current = Float32List.fromList(src);
  if (rx >= 1) {
    current = _slidingExtreme(current, w, h, rx, horizontal: true, findMin: true);
  }
  if (ry >= 1) {
    current =
        _slidingExtreme(current, w, h, ry, horizontal: false, findMin: true);
  }
  return current;
}

/// Grayscale dilation by a rectangular structuring element.
Float32List dilatePlane(
  Float32List src,
  int w,
  int h, [
  int? radiusOrX,
  int? radiusYArg,
]) {
  final rx = radiusOrX ?? 0;
  final ry = radiusYArg ?? radiusOrX ?? 0;
  if (rx < 1 && ry < 1) return Float32List.fromList(src);
  var current = Float32List.fromList(src);
  if (rx >= 1) {
    current =
        _slidingExtreme(current, w, h, rx, horizontal: true, findMin: false);
  }
  if (ry >= 1) {
    current =
        _slidingExtreme(current, w, h, ry, horizontal: false, findMin: false);
  }
  return current;
}

/// Grayscale morphological **closing**: erosion of dilation.
///
/// Closing is the operator that annihilates *dark* features smaller than the
/// structuring element, which is exactly what a printed bubble is. (Opening is
/// the mirror image and would leave the bubbles intact, which is the classic
/// way to accidentally build an OMR reader that measures nothing.)
///
/// With a structuring element larger than any printed bubble, the result is a
/// background plane that is *provably* blind to the marks being measured,
/// which a plain blur cannot guarantee across a dense answer grid.
GrayImage morphologicalClosing(GrayImage src, int radius) {
  if (radius < 1) return src;
  final dilated = dilatePlane(src.data, src.width, src.height, radius);
  final closed = erodePlane(dilated, src.width, src.height, radius);
  return GrayImage(src.width, src.height, closed);
}

/// Scale-free ink response.
///
/// For every pixel this is the *relative* darkening against the local paper
/// brightness, `(background - pixel) / background`. Dividing by the background
/// is what makes one global threshold work under auto-exposure, vignetting and
/// a shadow falling across one corner of the page — a fixed absolute threshold
/// is the single most common cause of misreads in naive OMR.
/// Estimates local paper brightness as a high local percentile.
///
/// Implemented as a max filter (grayscale dilation) followed by a wide box blur.
/// The max filter keeps only the brightest samples in each window, so text and
/// rules are ignored; the blur then interpolates those bright samples into a
/// smooth paper estimate.
///
/// This replaces plain morphological closing as the background model, which is
/// only safe for sparse content. On a dense printed form the closing's
/// structuring element is larger than the inter-word gaps, so it starts
/// filling in text and drags the "paper" level down onto the glyphs - every
/// pixel then reports a large ink response and the whole page looks like noise.
GrayImage percentileBackground(GrayImage gray, {int? radius, int? smooth}) {
  // Deliberately far smaller than a closing element: the max filter only needs
  // to clear typical word and line spacing. A window that large instead picks
  // up specular highlights and pushes the paper estimate above the true level,
  // which inflates the ink response everywhere.
  final r = radius ?? math.max(4, (gray.width / 120).round());
  final s = smooth ?? math.max(12, (gray.width / 30).round());
  final peak = dilatePlane(gray.data, gray.width, gray.height, r, r);
  return GrayImage(gray.width, gray.height, peak).boxBlur(s);
}

class InkMap {
  InkMap({
    required this.width,
    required this.height,
    required this.ink,
    required this.background,
  });

  final int width;
  final int height;

  /// Ink response in 0..1 (values slightly above 1 are possible on noise).
  final Float32List ink;

  /// Local paper brightness, useful for debugging and for quality gating.
  final Float32List background;

  double at(int x, int y) => ink[y * width + x];

  /// Builds the ink plane from a luminance image.
  ///
  /// [seRadius] is the radius of the background estimator's max filter.
  ///
  /// [closingBackground] selects the old morphological-closing background.
  /// It is only appropriate for sparse content; dense printed forms need
  /// [percentileBackground], because a large closing element begins absorbing
  /// the text it is supposed to sit above.
  static InkMap fromLuminance(
    GrayImage gray, {
    int? seRadius,
    int? backgroundRadius,
    int? backgroundSmooth,
    bool closingBackground = false,
  }) {
    final radius = seRadius ??
        math.max(4, (math.min(gray.width, gray.height) / 12).round());

    final background = closingBackground
        ? morphologicalClosing(gray, radius)
        : percentileBackground(gray,
            radius: backgroundRadius, smooth: backgroundSmooth);
    final ink = Float32List(gray.length);
    for (var i = 0; i < ink.length; i++) {
      final bg = background.data[i];
      final diff = bg - gray.data[i];
      ink[i] = diff <= 0 ? 0 : diff / (bg < 1 ? 1 : bg);
    }
    return InkMap(
      width: gray.width,
      height: gray.height,
      ink: ink,
      background: background.data,
    );
  }

  /// Median-filtered copy, used to reject isolated sensor speckle before
  /// thresholding without destroying thin bubble outlines.
  InkMap medianFiltered(int radius) {
    if (radius < 1) return this;
    final out = Float32List(ink.length);
    // The neighbourhood is (2*radius+1)^2 pixels, not a line.
    final side = 2 * radius + 1;
    final buffer = Float32List(side * side);
    final w = width;
    final h = height;

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var count = 0;
        for (var dy = -radius; dy <= radius; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -radius; dx <= radius; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= w) continue;
            buffer[count++] = ink[ny * w + nx];
          }
        }
        final slice = Float32List.sublistView(buffer, 0, count)..sort();
        out[y * w + x] = slice[count ~/ 2];
      }
    }
    return InkMap(
      width: width,
      height: height,
      ink: out,
      background: background,
    );
  }
}
