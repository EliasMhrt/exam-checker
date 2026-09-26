import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/grade_result.dart';
import '../omr/calibration.dart';
import '../omr/letter_cluster.dart';
import '../omr/letter_features.dart';
import '../omr/omr_service.dart';
import 'grade_screen.dart';

/// Shows what was read and collects the teacher's confirmation.
///
/// No marks are produced on this screen. The teacher names each cluster once
/// and looks at the cells the reader was unsure about; grading happens
/// afterwards, and only over what has been settled.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.calibration,
    required this.frameBytes,
  });

  final ExamCalibration calibration;
  final Uint8List frameBytes;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  static const OmrService _service = OmrService();

  SheetReading? _reading;
  String? _error;

  /// Cluster id to the letter the teacher assigned.
  final Map<int, String> _labels = {};

  /// Cell indices the teacher has looked at.
  final Set<int> _confirmed = {};

  bool _working = true;

  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      // The whole read is synchronous CPU work over the whole page, so it runs
      // after the first frame to keep the transition from stalling visibly.
      await Future<void>.delayed(Duration.zero);
      final reading = _service.readImage(widget.frameBytes, widget.calibration);
      if (!mounted) return;
      setState(() {
        _reading = reading;
        _working = false;
      });
    } on OmrReadException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _working = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read this sheet: $e';
        _working = false;
      });
    }
  }

  LetterModel get _model => LetterModel(
        centroids: _reading!.clusters.centroids,
        labels: _labels,
      );

  /// Clusters the teacher still has to name, with one example cell each.
  List<_ClusterPrompt> get _pendingClusters {
    final reading = _reading!;
    if (reading.clusters.centroids.isEmpty) return const [];
    final model = LetterModel(
      centroids: reading.clusters.centroids,
      labels: _labels,
    );
    // Identity map from descriptor back to the cell it came from. Descriptors
    // are compared by reference, so this is exact and avoids searching.
    final cellOf = <LetterFeatures, int>{
      for (var i = 0; i < reading.samples.length; i++)
        reading.samples[i]: reading.sampleCells[i],
    };

    final exemplars = model.exemplarsByCluster(reading.samples);
    final out = <_ClusterPrompt>[];
    for (final entry in exemplars.entries) {
      if (_labels.containsKey(entry.key)) continue;
      out.add(_ClusterPrompt(
        cluster: entry.key,
        cellIndex: cellOf[entry.value.first] ?? -1,
        members: entry.value.length,
      ));
    }
    out.sort((a, b) => a.cluster.compareTo(b.cluster));
    return out;
  }

  GradeResult? get _currentResult {
    final reading = _reading;
    if (reading == null) return null;
    return _service.grade(
      reading: reading,
      calibration: widget.calibration,
      labels: _labels,
      confirmedCells: _confirmed,
    );
  }

  void _grade() {
    final reading = _reading;
    final result = _currentResult;
    if (reading == null || result == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => GradeScreen(
          calibration: widget.calibration,
          reading: reading,
          result: result,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Check the reading')),
      body: _working
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _read)
              : _body(theme),
    );
  }

  Widget _body(ThemeData theme) {
    final reading = _reading!;
    final pending = _pendingClusters;
    final result = _currentResult!;
    final options = _options(reading);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${options.length} cells with writing, '
          '${reading.blankCells.length} blank, '
          '${reading.clusters.k} groups.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'The app has not decided what any letter is yet. Name each group '
          'below by looking at one example.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 16),
        if (reading.clusters.centroids.isEmpty)
          _Notice(
            colour: theme.colorScheme.errorContainer,
            icon: Icons.error_outline,
            text: 'No writing was found in any marked cell. Check that the '
                'boxes are over the answers, not the question numbers.',
          ),
        for (final problem in widget.calibration.keyProblems) ...[
          _Notice(
            colour: theme.colorScheme.errorContainer,
            icon: Icons.warning_amber_rounded,
            text: problem,
          ),
          const SizedBox(height: 8),
        ],
        for (final prompt in pending) ...[
          _ClusterCard(
            prompt: prompt,
            onLabel: (letter) => setState(() {
              _labels[prompt.cluster] = letter;
            }),
          ),
          const SizedBox(height: 8),
        ],
        if (options.isNotEmpty) ...[
          Text('Marked cells', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final cell in options) ...[
            _CellRow(
              cell: cell,
              guess: _model.classify(cell.features),
              confirmed: _confirmed.contains(cell.cellIndex),
              onToggle: () => setState(() {
                if (_confirmed.contains(cell.cellIndex)) {
                  _confirmed.remove(cell.cellIndex);
                } else {
                  _confirmed.add(cell.cellIndex);
                }
              }),
            ),
            const SizedBox(height: 4),
          ],
        ],
        const SizedBox(height: 16),
        _Notice(
          colour: theme.colorScheme.surfaceContainerHighest,
          icon: Icons.info_outline,
          text: result.needingConfirmation.isEmpty
              ? 'Every cell has been read. ${result.denominator} questions can '
                  'be graded.'
              : '${result.needingConfirmation.length} cell(s) still need your '
                  'confirmation. Nothing is graded until they are settled.',
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: pending.isEmpty && result.needingConfirmation.isEmpty
              ? _grade
              : null,
          child: const Text('Show the marks'),
        ),
      ],
    );
  }

  /// Non-blank cells paired with the cluster the model assigned them.
  List<_LabelledCell> _options(SheetReading reading) {
    final model = _model;
    final out = <_LabelledCell>[];
    for (var i = 0; i < reading.samples.length; i++) {
      out.add(_LabelledCell(
        cellIndex: reading.sampleCells[i],
        features: reading.samples[i],
        guess: model.classify(reading.samples[i]),
      ));
    }
    return out;
  }
}

class _ClusterPrompt {
  const _ClusterPrompt({
    required this.cluster,
    required this.cellIndex,
    required this.members,
  });

  final int cluster;
  final int cellIndex;
  final int members;
}

class _LabelledCell {
  const _LabelledCell({
    required this.cellIndex,
    required this.features,
    required this.guess,
  });

  final int cellIndex;
  final LetterFeatures features;
  final LetterGuess guess;
}

/// Asks the teacher to name one cluster.
class _ClusterCard extends StatelessWidget {
  const _ClusterCard({required this.prompt, required this.onLabel});

  final _ClusterPrompt prompt;
  final ValueChanged<String> onLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const letters = ['A', 'B', 'C', 'D', 'E', 'F'];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Group ${prompt.cluster + 1}',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              '${prompt.members} cell(s) look alike. Open the photo, find cell '
              '${prompt.cellIndex + 1}, and pick the letter they all are.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final letter in letters)
                  ChoiceChip(
                    selected: false,
                    label: Text(letter),
                    onSelected: (_) => onLabel(letter),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One cell the teacher can confirm.
class _CellRow extends StatelessWidget {
  const _CellRow({
    required this.cell,
    required this.guess,
    required this.confirmed,
    required this.onToggle,
  });

  final _LabelledCell cell;
  final LetterGuess guess;
  final bool confirmed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unsure = guess.needsReview;
    return InkWell(
      onTap: onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: confirmed
              ? theme.colorScheme.surfaceContainerHighest
              : (unsure ? theme.colorScheme.errorContainer : null),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              confirmed
                  ? Icons.check_circle
                  : (unsure ? Icons.help_outline : Icons.circle_outlined),
              size: 18,
            ),
            const SizedBox(width: 10),
            Text('cell ${cell.cellIndex + 1}'),
            const Spacer(),
            Text(
              guess.label ?? 'not recognised',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 12),
            Text(
              '${(guess.confidence * 100).round()}%',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.colour,
    required this.icon,
    required this.text,
  });

  final Color colour;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
