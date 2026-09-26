import 'dart:io';
import 'dart:typed_data';

// Standalone replica of the sliding-extremum sweep, compared to brute force
// on a tiny line so the discrepancy is visible.
List<double> sliding(List<double> src, int radius, bool findMin) {
  final lineLength = src.length;
  final leftPad = 2 * radius;
  final rightPad = radius;
  final padded = List<double>.filled(lineLength + leftPad + rightPad, 0);

  for (var i = 0; i < lineLength; i++) {
    padded[leftPad + i] = src[i];
  }
  for (var i = 1; i <= leftPad; i++) {
    padded[leftPad - i] = padded[leftPad];
  }
  for (var i = 0; i < rightPad; i++) {
    padded[leftPad + lineLength + i] = padded[leftPad + lineLength - 1];
  }

  final out = List<double>.filled(lineLength, double.nan);
  final deque = Int32List(padded.length);
  var head = 0;
  var tail = 0;
  for (var i = 0; i < padded.length; i++) {
    final v = padded[i];
    while (tail > head) {
      final bv = padded[deque[tail - 1]];
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
    final c = i - radius - leftPad;
    if (c >= 0 && c < lineLength) {
      out[c] = padded[deque[head]];
    }
  }
  return out;
}

List<double> brute(List<double> src, int radius, bool findMin) {
  final out = <double>[];
  for (var c = 0; c < src.length; c++) {
    var m = findMin ? double.infinity : -double.infinity;
    for (var k = c - radius; k <= c + radius; k++) {
      final kk = k.clamp(0, src.length - 1).toInt();
      final v = src[kk];
      if (findMin ? v < m : v > m) m = v;
    }
    out.add(m);
  }
  return out;
}

void main() {
  const radius = 2;
  final src = [5.0, 1.0, 9.0, 3.0, 7.0, 2.0, 8.0, 0.0, 4.0, 6.0];
  for (final findMin in [true, false]) {
    final mine = sliding(src, radius, findMin);
    final ref = brute(src, radius, findMin);
    final label = findMin ? 'MIN' : 'MAX';
    stdout.writeln('$label radius=$radius');
    for (var i = 0; i < src.length; i++) {
      final flag = mine[i] == ref[i] ? '   ' : ' <<';
      stdout.writeln('  src[$i]=${src[i]}  mine=${mine[i]}  ref=${ref[i]}$flag');
    }
  }
}
