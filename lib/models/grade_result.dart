import 'dart:ui';

class AnswerResult {
  const AnswerResult({
    required this.number,
    required this.correctAnswer,
    required this.detectedAnswer,
    required this.normalizedBox,
  });

  final int number;
  final String correctAnswer;
  final String? detectedAnswer;
  final Rect normalizedBox;

  bool get isCorrect => detectedAnswer == correctAnswer;
  bool get isBlank => detectedAnswer == null;
}

class GradeResult {
  const GradeResult({
    required this.totalQuestions,
    required this.totalMarks,
    required this.results,
  });

  final int totalQuestions;
  final int totalMarks;
  final List<AnswerResult> results;

  int get correctCount => results.where((r) => r.isCorrect).length;
  int get wrongCount => results.where((r) => !r.isCorrect).length;
  double get percentage =>
      totalQuestions == 0 ? 0 : (correctCount / totalQuestions) * 100;

  List<AnswerResult> get wrongResults =>
      results.where((r) => !r.isCorrect).toList();
}