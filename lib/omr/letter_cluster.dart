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

  int get dimension => centroids.isEmpty ? 0 : centroids.first.length;

  /// Members of each cluster, nearest to the centroid first, for showing the
  /// teacher one example to label.
  ///
  /// Assignment uses this model's own centroids rather than clustering the
  /// samples again. A fresh clustering produces a different set of clusters
  /// whose ids mean nothing here, so the teacher could name cluster 2 while
  /// every cell the app later reads as cluster 2 is really a different letter.
  Map<int, List<LetterFeatures>> exemplarsByCluster(
      List<LetterFeatures> samples) {
    final out = <int, List<(LetterFeatures, double)>>{};
    for (final s in samples) {
      if (centroids.isEmpty || s.dimension != dimension) continue;
      final nearest = _nearestCentroid(centroids, s.vector);
      out.putIfAbsent(nearest.index, () => []).add((s, nearest.distance));
    }
    final sorted = <int, List<LetterFeatures>>{};
    out.forEach((cluster, members) {
      // Closest to the centroid first: the most typical member of the cluster
      // and the easiest one for the teacher to name.
      members.sort((a, b) => a.$2.compareTo(b.$2));
      sorted[cluster] = [for (final m in members) m.$1];
    });
    return sorted;
  }

  /// Whether every cluster the given samples actually land in has a label.
  ///
  /// A centroid that no sample is nearest to is a phantom left by a split
  /// cluster. It cannot be labelled, because there is nothing to show the
  /// teacher, so it must not block grading the cells that were read correctly.
  bool isUsableFor(List<LetterFeatures> samples) {
    if (centroids.isEmpty) return false;
    final populated = exemplarsByCluster(samples).keys.toSet();
    return populated.isNotEmpty && populated.every(labels.containsKey);
  }

  /// Cluster ids with no label, restricted to those the samples use.
  Set<int> unlabelledClusters(List<LetterFeatures> samples) => exemplarsByCluster(
          samples)
      .keys
      .toSet()
      .difference(labels.keys.toSet());

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

/// Index of and squared distance to the closest centroid.
({int index, double distance}) _nearestCentroid(
    List<Float32List> centroids, Float32List vector) {
  var best = 0;
  var bestDist = double.infinity;
  for (var c = 0; c < centroids.length; c++) {
    final d = _squaredDistance(vector, centroids[c]);
    if (d < bestDist) {
      bestDist = d;
      best = c;
    }
  }
  return (index: best, distance: bestDist);
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
