import 'package:flutter/material.dart';

import 'screens/answer_key_screen.dart';

void main() {
  runApp(const ExamCheckerApp());
}

class ExamCheckerApp extends StatelessWidget {
  const ExamCheckerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Exam Checker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const AnswerKeyScreen(),
    );
  }
}