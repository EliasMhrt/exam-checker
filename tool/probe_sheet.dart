import 'dart:io';

import 'package:myapp/omr/grid_detector.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/preprocess.dart';
import 'package:myapp/omr/sheet_detector.dart';

import 'ascii_render.dart';

/// Detects the sheet, rectifies it, then detects the table lattice on the
/// upright page. This is the full front half of the reading pipeline.
///
/// Usage: `dart run tool/probe_sheet.dart <file> [workEdge] [maxEdge]`
/// `[minSpanFraction] [render]`
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: probe_sheet <file> [workEdge] [maxEdge] [minSpanFraction] '
        '[render]');
    exit(64);
  }
  final workEdge = args.length > 1 ? int.parse(args[1]) : 900;
  final maxEdge = args.length > 2 ? int.parse(args[2]) : 1200;
  final minSpan = args.length > 3 ? double.parse(args[3]) : 0.05;
  final shouldRender = args.length <= 4 || args[4] != '0';

  final source = GrayImage.decode(File(args[0]).readAsBytesSync());
  stdout.writeln('source: ${source.width}x${source.height}');

  final sheet = detectSheet(source, workEdge: workEdge);
  if (sheet == null) {
    stdout.writeln('NO SHEET DETECTED');
    return;
  }
  stdout.writeln(sheet.toString());
  if (sheet.isClipped) {
    stdout.writeln('WARNING: sheet reaches the frame edge; a projective fit '
        'from clipped corners is unreliable, so reframe the shot.');
  }

  final toSource = sheet.rectification(maxEdge);
  if (toSource == null) {
    stdout.writeln('DEGENERATE QUAD');
    return;
  }
  // Fill with a paper-level value so the region outside the sheet does not
  // register as heavy ink and dominate the ink statistics.
  final (outW, outH) = sheet.rectifiedSize(maxEdge);
  final rectified = source.warp(toSource, outW, outH, fill: 240.0);

  if (shouldRender) {
    renderAscii(rectified, 116, label: 'RECTIFIED');
  }

  final ink = InkMap.fromLuminance(rectified);
  stdout.writeln('[ink] p50=${percentileOf(ink.ink, 0.5).toStringAsFixed(3)} '
      'p90=${percentileOf(ink.ink, 0.9).toStringAsFixed(3)} '
      'p99=${percentileOf(ink.ink, 0.99).toStringAsFixed(3)}');

  final grid = detectTableGrid(ink,
      minSpanFraction: minSpan, trace: (stage, detail) {
    stdout.writeln('[$stage] $detail');
  });
  if (grid == null) {
    stdout.writeln('NO GRID');
    return;
  }
  stdout.writeln('grid: ${grid.columns.length} x rules, '
      '${grid.rows.length} y rules -> '
      '${grid.columnCount} x ${grid.rowCount} cells '
      '(${grid.cellCount} total)');
  stdout.writeln('snap=${grid.snapFraction.toStringAsFixed(2)} '
      'score=${grid.score.toStringAsFixed(2)}');
}
