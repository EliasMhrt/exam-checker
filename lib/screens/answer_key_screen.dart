import 'package:flutter/material.dart';

import '../models/answer_key.dart';
import 'scan_screen.dart';

class AnswerKeyScreen extends StatefulWidget {
  const AnswerKeyScreen({super.key});

  @override
  State<AnswerKeyScreen> createState() => _AnswerKeyScreenState();
}

class _AnswerKeyScreenState extends State<AnswerKeyScreen> {
  final TextEditingController _controller = TextEditingController();
  AnswerKey? _parsed;

  void _reparse(String text) {
    final key = AnswerKey.fromText(text);
    setState(() {
      _parsed = key.entries.isNotEmpty ? key : null;
    });
  }

  void _startScanning() {
    final key = _parsed;
    if (key == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ScanScreen(answerKey: key)),
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
            if (_parsed != null)
              _ParsedPreview(answerKey: _parsed!)
            else
              Text(
                'Nothing parsed yet.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _parsed == null ? null : _startScanning,
              child: const Text('Open smart camera'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParsedPreview extends StatelessWidget {
  const _ParsedPreview({required this.answerKey});

  final AnswerKey answerKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chip = answerKey.entries
        .map((e) => '${e.number}. ${e.correctAnswer}')
        .join('  ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${answerKey.count} questions:  $chip',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}