import 'package:flutter/material.dart';

import '../models/answer_key.dart';
import 'calibrate_screen.dart';

class AnswerKeyScreen extends StatefulWidget {
  const AnswerKeyScreen({super.key});

  @override
  State<AnswerKeyScreen> createState() => _AnswerKeyScreenState();
}

class _AnswerKeyScreenState extends State<AnswerKeyScreen> {
  final TextEditingController _controller = TextEditingController();
  AnswerKeyParse? _parse;

  void _reparse(String text) {
    setState(() => _parse = text.trim().isEmpty ? null : AnswerKeyParser.parse(text));
  }

  /// A key with gaps can still be corrected later, so it opens calibration.
  /// What it must never do is open grading and quietly count a missing answer
  /// as a wrong one, which the review screen prevents.
  bool get _canContinue => (_parse?.key?.entries.isNotEmpty ?? false);

  void _continue() {
    final parse = _parse;
    if (parse?.key == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CalibrateScreen(answerKey: parse!.key!),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final parse = _parse;
    return Scaffold(
      appBar: AppBar(title: const Text('Answer key')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Enter the correct answers. Paste them as numbered lines '
              '(1. A, 2. C, ...) or a plain letter sequence (A C B D A ...).',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _controller,
                onChanged: _reparse,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '1. A\n2. C\n3. B\n...',
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (parse == null)
              Text(
                'Nothing entered yet.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              )
            else
              _ParseReport(parse: parse),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _canContinue ? _continue : null,
              child: const Text('Mark the answer grid'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows what was read, and anything the teacher needs to fix first.
///
/// The parsed letters are always shown even when there is a problem. The
/// teacher has to be able to see what the app thinks it read and correct it,
/// rather than being told only that something is wrong.
class _ParseReport extends StatelessWidget {
  const _ParseReport({required this.parse});

  final AnswerKeyParse parse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = parse.key;
    final problems = parse.problems;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (key != null && key.entries.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${key.count} of question ${key.maxNumber} answered',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  key.entries
                      .map((e) => '${e.number}. ${e.correctAnswer}')
                      .join('   '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final problem in problems)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 18, color: theme.colorScheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            problem,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
