import 'dart:math' as math;
import 'dart:typed_data';

import 'letter_features.dart';

/// The result of clustering a batch of cell descriptors.
class LetterClusters {
  LetterClusters({
    required this.centroids,
    required this.assignments,
    required this.distances,
    required this.inertia,
  });

  final List<Float32List> centroids;
  final List<int> assignments;

  /// Squared distance from each sample to its assigned centroid.
  final Float64List distances;

  /// Total within-cluster sum of squares. Lower is a better fit.
  final double inertia;

  int get k => centroids.length;
}

/// The outcome of classifying one cell.
class LetterGuess {
  const LetterGuess({
    required this.cluster,
    required this.label,
    required this.confidence,
    required this.runnerUpLabel,
  });

  /// Nearest cluster, or -1 when the model is unusable.
  final int cluster;

  /// Teacher-assigned label for [cluster], or null while unlabelled.
  final String? label;

  /// How decisively the nearest cluster beat the runner-up, in 0..1.
  final double confidence;

  final String? runnerUpLabel;

  /// A reading that must not be trusted without the teacher.
  bool get needsReview => label == null || confidence < 0.12;
}

/// A nearest-centroid letter model.
///
/// The clusters are learned without labels, so the app never has to guess what
/// a letter is: the teacher names each cluster once by looking at a single
/// example, and every cell is then read by distance.
class LetterModel {
  LetterModel({
    required this.centroids,
    required this.labels,
    this.blankInkFraction = 0.004,
  });

  final List<Float32List> centroids;

  /// Cluster id to letter. Missing entries are unlabelled.
  final Map<int, String> labels;

  final double blankInkFraction;

  bool get isUsable => centroids.isNotEmpty && labels.length == centroids.length;

  int get dimension => centroids.isEmpty ? 0 : centroids.first.length;

  /// Members of each cluster, for showing the teacher one example to label.
  Map<int, List<LetterFeatures>> exemplarsByCluster(
      List<LetterFeatures> samples) {
    final clusters = kMeans(samples.map((s) => s.vector).toList(),
        k: centroids.length, seed: 7);
    final out = <int, List<LetterFeatures>>{};
    for (var i = 0; i < samples.length; i++) {
      out.putIfAbsent(clusters.assignments[i], () => []).add(samples[i]);
    }
    return out;
  }

  LetterGuess classify(LetterFeatures features) {
    if (centroids.isEmpty || features.dimension != dimension) {
      return const LetterGuess(
          cluster: -1, label: null, confidence: 0, runnerUpLabel: null);
    }

    final dists = <int, double>{};
    for (var c = 0; c < centroids.length; c++) {
      dists[c] = _squaredDistance(features.vector, centroids[c]);
    }
    final ranked = dists.keys.toList()
      ..sort((a, b) => dists[a]!.compareTo(dists[b]!));
    final best = ranked.first;
    final bestDist = dists[best]!;
    final second = ranked.length > 1 ? ranked[1] : -1;
    final secondDist = second >= 0 ? dists[second]! : bestDist * 2;

    // Margin in 0..1. A cell sitting almost equidistant from two clusters is
    // exactly the ambiguous case the teacher must resolve, so this is reported
    // as low confidence rather than rounded up to a decision.
    final confidence = secondDist <= 0
        ? 0.0
        : ((secondDist - bestDist) / secondDist).clamp(0.0, 1.0);

    return LetterGuess(
      cluster: best,
      label: labels[best],
      confidence: confidence,
      runnerUpLabel: second >= 0 ? labels[second] : null,
    );
  }

  LetterModel withLabels(Map<int, String> newLabels) => LetterModel(
        centroids: centroids,
        labels: {...labels, ...newLabels},
        blankInkFraction: blankInkFraction,
      );
}

/// k-means with deterministic k-means++ seeding.
///
/// Determinism matters here: the cluster a cell lands in becomes the identity
/// the teacher labels, so an unstable init would relabel the teacher's work on
/// every rebuild.
LetterClusters kMeans(
  List<Float32List> samples, {
  required int k,
  int iterations = 60,
  int seed = 1,
}) {
  if (samples.isEmpty || k < 1) {
    return LetterClusters(
      centroids: const [],
      assignments: const [],
      distances: Float64List(0),
      inertia: 0,
    );
  }
  final dim = samples.first.length;
  final effectiveK = math.min(k, samples.length);

  final random = math.Random(seed);
  final centroids = <Float32List>[];

  // k-means++ seeding.
  centroids.add(Float32List.fromList(samples[random.nextInt(samples.length)]));
  while (centroids.length < effectiveK) {
    final weights = <double>[];
    var total = 0.0;
    for (final s in samples) {
      var nearest = double.infinity;
      for (final c in centroids) {
        final d = _squaredDistance(s, c);
        if (d < nearest) nearest = d;
      }
      total += nearest;
      weights.add(nearest);
    }
    if (total <= 0) break;
    var pick = random.nextDouble() * total;
    var chosen = samples.length - 1;
    for (var i = 0; i < weights.length; i++) {
      pick -= weights[i];
      if (pick <= 0) {
        chosen = i;
        break;
      }
    }
    centroids.add(Float32List.fromList(samples[chosen]));
  }

  final assignments = List<int>.filled(samples.length, 0);
  final distances = Float64List(samples.length);
  var inertia = 0.0;

  for (var iter = 0; iter < iterations; iter++) {
    inertia = 0;
    var moved = 0;
    for (var i = 0; i < samples.length; i++) {
      var best = 0;
      var bestDist = double.infinity;
      for (var c = 0; c < centroids.length; c++) {
        final d = _squaredDistance(samples[i], centroids[c]);
        if (d < bestDist) {
          bestDist = d;
          best = c;
        }
      }
      if (assignments[i] != best) moved++;
      assignments[i] = best;
      distances[i] = bestDist;
      inertia += bestDist;
    }

    final sums = List.generate(
        centroids.length, (_) => Float64List(dim));
    final counts = List<int>.filled(centroids.length, 0);
    for (var i = 0; i < samples.length; i++) {
      final a = assignments[i];
      counts[a]++;
      final s = sums[a];
      final v = samples[i];
      for (var d = 0; d < dim; d++) {
        s[d] += v[d];
      }
    }
    for (var c = 0; c < centroids.length; c++) {
      if (counts[c] == 0) continue;
      final out = Float32List(dim);
      final s = sums[c];
      for (var d = 0; d < dim; d++) {
        out[d] = (s[d] / counts[c]).toDouble();
      }
      centroids[c] = out;
    }
    if (moved == 0) break;
  }

  return LetterClusters(
    centroids: centroids,
    assignments: assignments,
    distances: distances,
    inertia: inertia,
  );
}

double _squaredDistance(Float32List a, Float32List b) {
  final n = math.min(a.length, b.length);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    sum += d * d;
  }
  return sum;
}
