import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'geometry.dart';
import 'mask.dart';


/// A single-channel luminance plane stored as a row-major [Float32List].
///
/// All OMR geometry runs on this type rather than on an RGBA image so that
/// shading thresholds, sub-pixel bubble centroids and multi-frame medians can
/// be computed in full float precision without repeated format conversion.
///
/// Every value in [data] is in 0..255, matching the 256-bin [histogram] and the
/// Otsu convention used across this package. Note that this differs from
/// `InkMap.ink`, which is a ratio in 0..1.
class GrayImage {
  GrayImage(this.width, this.height, [Float32List? data])
      : data = data ?? Float32List(width * height) {
    if (data != null && data.length != width * height) {
      throw ArgumentError('data length ${data.length} != $width*$height');
    }
  }

  final int width;
  final int height;

  /// Luminance in the 0..255 range.
  final Float32List data;

  /// Builds a plane from a decoded RGB/RGBA image using Rec. 601 luma.
  ///
  /// Luma is preferred over a flat channel average because pencil and black
  /// ink both depress luma, while a red or blue correction pen does not move
  /// it as much, which keeps marked bubbles separable from paper.
  static GrayImage fromImage(img.Image image) {
    final data = image.data;
    if (data == null) {
      return GrayImage(image.width, image.height);
    }
    final w = image.width;
    final h = image.height;
    // Request a known channel order so the packing is 3 bytes per pixel
    // regardless of what the decoder produced.
    final bytes = data.getBytes(order: img.ChannelOrder.rgb);
    // Rows may carry padding, so honour rowStride when the returned buffer
    // actually spans it; otherwise fall back to a tightly packed assumption.
    final packedStride = w * 3;
    final stride = (data.rowStride >= packedStride &&
            bytes.length >= data.rowStride * h)
        ? data.rowStride
        : packedStride;

    final out = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      final base = y * stride;
      for (var x = 0; x < w; x++) {
        final p = base + x * 3;
        out[y * w + x] = 0.299 * bytes[p] + 0.587 * bytes[p + 1] + 0.114 * bytes[p + 2];
      }
    }
    return GrayImage(w, h, out);
  }

  /// Decodes JPEG bytes to a luminance plane.
  static GrayImage decodeJpeg(Uint8List bytes) {
    final decoded = img.decodeJpg(bytes);
    if (decoded == null) {
      throw const FormatException('Could not decode JPEG frame');
    }
    return fromImage(decoded);
  }

  /// Decodes any supported format, auto-detecting it.
  ///
  /// Honours EXIF orientation. Camera frames are commonly stored landscape in
  /// the file with an orientation tag of 6, so a decoder that ignores EXIF
  /// silently transposes the whole sheet - which would invalidate every
  /// coordinate calibrated from a reference image.
  static GrayImage decode(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Could not decode image');
    }
    return fromImage(img.bakeOrientation(decoded));
  }

  static GrayImage filled(int width, int height, double value) {
    final data = Float32List(width * height);
    data.fillRange(0, data.length, value);
    return GrayImage(width, height, data);
  }

  int get length => data.length;

  double at(int x, int y) => data[y * width + x];

  void set(int x, int y, double value) => data[y * width + x] = value;

  bool contains(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  /// Bilinear sample with edge clamping. Sub-pixel accuracy matters here: a
  /// half-pixel bias on a bubble centroid shifts the sampled disc enough to
  /// bias the shading measurement.
  double sampleBilinear(double fx, double fy) {
    final x0 = fx.floor();
    final y0 = fy.floor();
    final tx = fx - x0;
    final ty = fy - y0;
    final x1 = _clampInt(x0 + 1, width);
    final y1 = _clampInt(y0 + 1, height);
    final cx0 = _clampInt(x0, width);
    final cy0 = _clampInt(y0, height);

    final v00 = at(cx0, cy0);
    final v10 = at(x1, cy0);
    final v01 = at(cx0, y1);
    final v11 = at(x1, y1);

    final top = v00 + (v10 - v00) * tx;
    final bottom = v01 + (v11 - v01) * tx;
    return top + (bottom - top) * ty;
  }

  /// Area-average downscale.
  ///
  /// Box averaging (rather than nearest-neighbour or bilinear) is required
  /// because downsampling is the first big noise reduction step; aliased
  /// sampling can drop an entire thin bubble outline and lose the grid.
  GrayImage downscaleTo(int maxEdge) {
    final longest = math.max(width, height);
    if (longest <= maxEdge) return this;

    final scale = maxEdge / longest;
    final dstW = math.max(1, (width * scale).round());
    final dstH = math.max(1, (height * scale).round());
    final out = Float32List(dstW * dstH);

    final xRatio = width / dstW;
    final yRatio = height / dstH;

    for (var dy = 0; dy < dstH; dy++) {
      final sy0 = dy * yRatio;
      final sy1 = (dy + 1) * yRatio;
      final y0 = sy0.floor();
      final y1 = math.min(height - 1, sy1.ceil() - 1);
      for (var dx = 0; dx < dstW; dx++) {
        final sx0 = dx * xRatio;
        final sx1 = (dx + 1) * xRatio;
        final x0 = sx0.floor();
        final x1 = math.min(width - 1, sx1.ceil() - 1);
        var sum = 0.0;
        var count = 0;
        for (var y = y0; y <= y1; y++) {
          final row = y * width;
          for (var x = x0; x <= x1; x++) {
            sum += data[row + x];
            count++;
          }
        }
        out[dy * dstW + dx] = count == 0 ? 0 : sum / count;
      }
    }
    return GrayImage(dstW, dstH, out);
  }

  /// Separable box blur. Returns a new plane; the input is untouched.
  ///
  /// Used for background/illumination estimation, so it is deliberately a box
  /// filter: a Gaussian would be smoother but a box estimate is cheaper and the
  /// residual ink map is what carries the signal.
  GrayImage boxBlur(int radius) {
    if (radius <= 0) return this;

    final tmp = Float32List(width * height);
    final out = Float32List(width * height);
    final norm = 1.0 / (2 * radius + 1);

    for (var y = 0; y < height; y++) {
      final row = y * width;
      var sum = 0.0;
      for (var x = -radius; x <= radius; x++) {
        sum += at(_clampInt(x, width), y);
      }
      for (var x = 0; x < width; x++) {
        tmp[row + x] = sum * norm;
        sum += at(_clampInt(x + radius + 1, width), y) -
            at(_clampInt(x - radius, width), y);
      }
    }

    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      for (var y = -radius; y <= radius; y++) {
        sum += tmp[_clampInt(y, height) * width + x];
      }
      for (var y = 0; y < height; y++) {
        out[y * width + x] = sum * norm;
        sum += tmp[_clampInt(y + radius + 1, height) * width + x] -
            tmp[_clampInt(y - radius, height) * width + x];
      }
    }
    return GrayImage(width, height, out);
  }

  /// Exact 256-bin histogram. Relies on [data] being 0..255.
  List<int> histogram() {
    final bins = List<int>.filled(256, 0);
    for (var i = 0; i < data.length; i++) {
      final v = data[i];
      final b = v.isNaN ? 0 : v.round();
      bins[b < 0 ? 0 : (b > 255 ? 255 : b)]++;
    }
    return bins;
  }

  /// Median of all pixels. O(n) via histogram, so it is cheap enough to call
  /// on every frame.
  double median() {
    final bins = histogram();
    final target = data.length ~/ 2;
    var cumulative = 0;
    for (var i = 0; i < 256; i++) {
      cumulative += bins[i];
      if (cumulative > target) return i.toDouble();
    }
    return 255.0;
  }

  GrayImage clone() => GrayImage(width, height, Float32List.fromList(data));

  /// A sub-rectangle, clamped to the image and at least 1x1.
  ///
  /// Pixels outside the image come back as [fill] rather than being dropped, so
  /// a calibration cell that hangs off the edge of a slightly-off photo still
  /// yields a correctly sized crop and reads as blank instead of shifting every
  /// later cell.
  GrayImage crop(int left, int top, int cropWidth, int cropHeight,
      {double fill = 255}) {
    final x0 = left.clamp(0, width);
    final y0 = top.clamp(0, height);
    final x1 = (left + cropWidth).clamp(0, width);
    final y1 = (top + cropHeight).clamp(0, height);
    final w = (x1 - x0) < 1 ? 1 : x1 - x0;
    final h = (y1 - y0) < 1 ? 1 : y1 - y0;

    final out = Float32List(w * h);
    for (var i = 0; i < out.length; i++) {
      out[i] = fill;
    }
    for (var y = 0; y < h; y++) {
      final sy = y0 + y;
      if (sy < 0 || sy >= height) continue;
      for (var x = 0; x < w; x++) {
        final sx = x0 + x;
        if (sx < 0 || sx >= width) continue;
        out[y * w + x] = data[sy * width + sx];
      }
    }
    return GrayImage(w, h, out);
  }

  /// Resamples this image through [toSource], a mapping from destination pixel
  /// coordinates back to this image's coordinates.
  ///
  /// Inverse mapping is deliberate: iterating destination pixels guarantees
  /// every output sample is written exactly once with no holes, whereas
  /// forward-mapping source pixels would double-write near stretched regions
  /// and leave gaps in compressed ones. Samples landing outside the image take
  /// [fill], which is what makes a detected-but-smaller-than-frame sheet
  /// rectify cleanly instead of smearing edge pixels inward.
  GrayImage warp(
    Homography toSource,
    int outWidth,
    int outHeight, {
    double fill = 0.0,
  }) {
    final out = Float32List(outWidth * outHeight);
    for (var y = 0; y < outHeight; y++) {
      for (var x = 0; x < outWidth; x++) {
        final p = toSource.project(Point(x.toDouble(), y.toDouble()));
        if (p.x.isNaN || p.y.isNaN) continue;
        if (p.x < -0.5 || p.y < -0.5 ||
            p.x > width - 0.5 || p.y > height - 0.5) {
          out[y * outWidth + x] = fill;
          continue;
        }
        out[y * outWidth + x] = sampleBilinear(p.x, p.y);
      }
    }
    return GrayImage(outWidth, outHeight, out);
  }

  /// Convenience wrapper around [connectedComponents] for this plane.
  List<Component> componentsBy(
    bool Function(double value, int x, int y) isForeground, {
    int minArea = 1,
    int maxArea = 1 << 30,
  }) =>
      connectedComponents(
        data,
        width: width,
        height: height,
        isForeground: (o) => isForeground(data[o], o % width, o ~/ width),
        minArea: minArea,
        maxArea: maxArea,
      );

  static int _clampInt(int v, int limit) => v < 0 ? 0 : (v >= limit ? limit - 1 : v);
}
