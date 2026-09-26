import 'dart:typed_data';

import '../models/answer_key.dart';
import '../models/grade_result.dart';

/// How the app talks to an AI grading engine.
///
/// A [GradeAdapter] receives the current camera frame plus the answer key and
/// returns which questions were answered right/wrong and where each question
/// sits on the page (normalized 0..1 box), so the UI can overlay red markers.
abstract class GradeAdapter {
  /// Grades the latest frame. [frameBytes] is an encoded image (jpeg/png).
  Future<GradeResult> grade({
    required Uint8List frameBytes,
    required AnswerKey answerKey,
  });
}