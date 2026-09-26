import 'dart:math' as math;
import 'dart:typed_data';

import '../models/answer_key.dart';
import '../models/grade_result.dart';
import 'grade_adapter.dart';

/// Placeholder AI that does not call any service yet.
///
/// It mimics a real checker: for every frame it picks deterministic "detected"
/// answers seeded by the frame's bytes, so grading feels live and changes as
/// the teacher moves the paper. Generated marks are stable for identical
/// frames so the result does not flicker while the camera is still.
///
/// Replace [MockGradeAdapter] with a real implementation (vision LLM) later;
/// the rest of the app does not change because everything goes through
/// [GradeAdapter].
class MockGradeAdapter implements GradeAdapter {
  @override
  Future<GradeResult> grade({
    required Uint8List frameBytes,
    required AnswerKey answerKey,
  }) async {
    final seed = frameBytes.fold<int>(
      0,
      (acc, b) => (acc + b) & 0x7fffffff,
    );
    final random = math.Random(seed);

    const letters = ['A', 'B', 'C', 'D', 'E'];

    final results = <AnswerResult>[];
    for (final entry in answerKey.entries) {
      final r = random.nextDouble();
      final String? detected;
      if (r < 0.28) {
        final wrongs = letters.where((l) => l != entry.correctAnswer).toList();
        detected = wrongs[random.nextInt(wrongs.length)];
      } else if (r < 0.32) {
        detected = null;
      } else {
        detected = entry.correctAnswer;
      }

      results.add(AnswerResult(
        number: entry.number,
        correctAnswer: entry.correctAnswer,
        detectedAnswer: detected,
        normalizedBox: AnswerKey.bubbleRect(entry.number, answerKey.count),
      ));
    }

    return GradeResult(
      totalQuestions: answerKey.count,
      totalMarks: results.where((r) => r.isCorrect).length,
      results: results,
    );
  }
}