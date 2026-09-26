import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:myapp/omr/gray_image.dart';

void main() {
  final files = [
    r'photos\20260925_224439.jpg',
    r'blank sheet\20260925_231459.jpg',
    r'blank sheet\Screenshot 2026-09-25 231953.png',
  ];
  for (final f in files) {
    final bytes = File(f).readAsBytesSync();
    final raw = img.decodeImage(bytes);
    final rawDims = raw == null
        ? 'decode failed'
        : '${raw.width}x${raw.height} '
            'orientation=${raw.exif.imageIfd.orientation ?? 1}';
    final baked = img.bakeOrientation(raw!);
    final bakedDims = '${baked.width}x${baked.height}';
    final gray = GrayImage.decode(bytes);
    stdout.writeln(f);
    stdout.writeln('   raw:     $rawDims');
    stdout.writeln('   baked:   $bakedDims');
    stdout.writeln('   gray:    ${gray.width}x${gray.height}');
  }
}
