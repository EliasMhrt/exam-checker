import 'dart:io';
import 'dart:math' as math;

import 'package:myapp/omr/grid_detector.dart';
import 'package:myapp/omr/gray_image.dart';
import 'package:myapp/omr/preprocess.dart';

/// Detects the printed table lattice on a real sheet and reports it.
///
/// Usage: `dart run tool/probe_grid.dart <file> [maxEdge] [minSpanFraction]`
/// `[inkThreshold]`
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: probe_grid <file> [maxEdge] [minSpanFraction] [inkThreshold]');
    exit(64);
  }
  final maxEdge = args.length > 1 ? int.parse(args[1]) : 1000;
  final minSpan = args.length > 2 ? double.parse(args[2]) : 0.10;
  final inkThreshold = args.length > 3 ? double.parse(args[3]) : null;

  final img = GrayImage.decode(File(args[0]).readAsBytesSync());
  stdout.writeln('source: ${img.width}x${img.height}');

  final work = img.width >= maxEdge && img.height >= maxEdge
      ? img.downscaleTo(maxEdge)
      : img;
  stdout.writeln('working: ${work.width}x${work.height}');

  final ink = InkMap.fromLuminance(
    work,
    seRadius: math.max(4, (math.min(work.width, work.height) / 12).round()),
  );

  final grid = detectTableGrid(ink,
      minSpanFraction: minSpan, inkThreshold: inkThreshold, trace: (stage, detail) {
    stdout.writeln('[$stage] $detail');
  });
  if (grid == null) {
    stdout.writeln('NO GRID (minSpanFraction=$minSpan)');
    return;
  }

  stdout.writeln('grid: ${grid.columns.length} vertical rules, '
      '${grid.rows.length} horizontal rules');
  stdout.writeln('cells: ${grid.columnCount} x ${grid.rowCount} '
      '= ${grid.cellCount}');
  stdout.writeln('snap: ${grid.snapFraction.toStringAsFixed(3)}  '
      'score: ${grid.score.toStringAsFixed(3)}');

  void dump(String label, List<double> positions, int extent) {
    final gaps = <String>[];
    for (var i = 1; i < positions.length; i++) {
      gaps.add(((positions[i] - positions[i - 1]) * extent).toStringAsFixed(1));
    }
    stdout.writeln('\n$label (${positions.length}):');
    for (var i = 0; i < positions.length; i++) {
      final px = (positions[i] * extent).toStringAsFixed(1);
      final gap = i == 0 ? '-' : gaps[i - 1];
      stdout.writeln('  [$i] norm=${positions[i].toStringAsFixed(4)} '
          'px=$px  gap=$gap');
    }
  }

  dump('columns (x)', grid.columns, work.width);
  dump('rows (y)', grid.rows, work.height);
}
