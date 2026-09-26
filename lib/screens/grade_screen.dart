import 'package:flutter/material.dart';

import '../models/grade_result.dart';
import '../omr/calibration.dart';
import '../omr/omr_service.dart';

/// The final marks.
///
/// This screen only displays what has already been settled by the teacher. It
/// cannot produce a score for an unconfirmed reading, because by the time it is
/// reached every cell has either been confirmed or refused.
class GradeScreen extends StatelessWidget {
  const GradeScreen({
    super.key,
    required this.calibration,
    required this.reading,
    required this.result,
  });

  final ExamCalibration calibration;
  final SheetReading reading;
  final GradeResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final complete = result.isComplete;

    return Scaffold(
      appBar: AppBar(title: const Text('Marks')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!complete)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Some cells were never confirmed. The total below covers only '
                'the questions that were settled, so it is not a final mark.',
              ),
            ),
          Row(
            children: [
              Expanded(
                child: _Stat(
                  label: 'Marks',
                  value: '${result.totalMarks}',
                  theme: theme,
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'Out of',
                  value: '${result.denominator}',
                  theme: theme,
                ),
              ),
              Expanded(
                child: _Stat(
                  label: 'Percent',
                  value: '${result.percentage.toStringAsFixed(1)}%',
                  theme: theme,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (result.withoutKey.isNotEmpty)
            Text(
              '${result.withoutKey.length} question(s) had no answer in the key '
              'and were left out of the total: '
              '${result.withoutKey.map((r) => r.number).join(', ')}.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          if (calibration.shortAnswerRegion != null) ...[
            const SizedBox(height: 12),
            _Notice(
              colour: theme.colorScheme.surfaceContainerHighest,
              icon: Icons.edit_note,
              text: 'This paper also has short-answer work. It is marked by '
                  'hand and is not included above.',
            ),
          ],
          const SizedBox(height: 16),
          Text('Per question', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final r in result.results)
            _ResultRow(result: r),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.theme,
  });

  final String label;
  final String value;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final AnswerResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color colour;
    final IconData icon;
    if (!result.hasKey) {
      colour = theme.colorScheme.outline;
      icon = Icons.help_outline;
    } else if (result.needsConfirmation) {
      colour = theme.colorScheme.error;
      icon = Icons.pending;
    } else if (result.isCorrect) {
      colour = Colors.green.shade700;
      icon = Icons.check_circle_outline;
    } else {
      colour = Colors.red.shade700;
      icon = Icons.cancel_outlined;
    }

    final read = result.detectedAnswer ??
        (result.outcome == ReadOutcome.blank ? 'blank' : 'not read');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: colour),
          const SizedBox(width: 10),
          Text('${result.number}', style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(read),
          const SizedBox(width: 14),
          SizedBox(
            width: 62,
            child: Text(
              result.correctAnswer ?? 'no key',
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
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
