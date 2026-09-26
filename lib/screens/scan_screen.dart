import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../ai/grade_adapter.dart';
import '../ai/mock_grade_adapter.dart';
import '../models/answer_key.dart';
import '../models/grade_result.dart';

/// Full-screen live camera with no controls. While the teacher holds the
/// device over the sheet, frames are sent to the [GradeAdapter] continuously;
/// wrong answers are red-ringed on top of the live feed and current marks are
/// shown unobtrusively. Exit with a system back gesture/button.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, required this.answerKey});

  final AnswerKey answerKey;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final GradeAdapter _adapter = MockGradeAdapter();

  CameraController? _controller;
  Timer? _captureTimer;
  GradeResult? _lastResult;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      _showFatal('No camera found on this device.');
      return;
    }
    final CameraDescription back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      back,
      ResolutionPreset.high,
      enableAudio: false,
    );
    try {
      await controller.initialize();
    } catch (e) {
      await controller.dispose();
      _showFatal('Could not start camera: $e');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _controller = controller);
    _captureTimer = Timer.periodic(const Duration(milliseconds: 700), (_) {
      _captureAndGrade();
    });
  }

  Future<void> _captureAndGrade() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _busy) return;
    _busy = true;
    try {
      final XFile shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      await File(shot.path).delete();
      final result = await _adapter.grade(
        frameBytes: bytes,
        answerKey: widget.answerKey,
      );
      if (mounted) {
        setState(() => _lastResult = result);
      }
    } catch (_) {
      // Frame dropped; keep scanning.
    } finally {
      _busy = false;
    }
  }

  void _showFatal(String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Camera error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      body: controller == null || !controller.value.isInitialized
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),
                if (_lastResult != null)
                  _GradeOverlay(result: _lastResult!),
                _ScoreChip(result: _lastResult),
                _AutoHint(active: _lastResult == null),
              ],
            ),
    );
  }
}

/// Draws red markers over wrong answers inside the camera preview.
class _GradeOverlay extends StatelessWidget {
  const _GradeOverlay({required this.result});

  final GradeResult result;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _OverlayPainter(result: result),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.result});

  final GradeResult result;

  @override
  void paint(Canvas canvas, Size size) {
    final red = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5;
    final fill = Paint()..color = Colors.redAccent.withValues(alpha: 0.25);
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: size.width * 0.04,
      fontWeight: FontWeight.bold,
      shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
    );

    for (final wrong in result.wrongResults) {
      final box = wrong.normalizedBox;
      final rect = Rect.fromLTWH(
        box.left * size.width,
        box.top * size.height,
        box.width * size.width,
        box.height * size.height,
      );
      // Bubble centered in the cell.
      final r = math.min(rect.width, rect.height) * 0.34;
      final center = rect.center;
      canvas.drawCircle(center, r, fill);
      canvas.drawCircle(center, r, red);

      final label = TextPainter(
        text: TextSpan(text: '${wrong.number}', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(rect.left, rect.top - label.height));
      final x = Offset(center.dx - r * 0.35, center.dy - r * 0.35);
      final span = r * 0.7;
      final line = Paint()
        ..color = Colors.redAccent
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(x, x + Offset(span, span), line);
      canvas.drawLine(x + Offset(span, 0), x + Offset(0, span), line);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) =>
      oldDelegate.result != result;
}

/// Small translucent score pill; keeps the screen clean.
class _ScoreChip extends StatelessWidget {
  const _ScoreChip({required this.result});

  final GradeResult? result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: SafeArea(
          child: Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(24),
            ),
            child: r == null
                ? const Text(
                    'Scanning…',
                    style: TextStyle(color: Colors.white70),
                  )
                : Text(
                    '${r.correctCount}/${r.totalQuestions}  ·  ${r.percentage.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Fading hint shown only while no result exists yet.
class _AutoHint extends StatefulWidget {
  const _AutoHint({required this.active});

  final bool active;

  @override
  State<_AutoHint> createState() => _AutoHintState();
}

class _AutoHintState extends State<_AutoHint> {
  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return IgnorePointer(
      child: Align(
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'Hold the paper in front of the camera…',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ),
    );
  }
}