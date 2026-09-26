import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/answer_key.dart';
import '../omr/calibration.dart';
import '../omr/grid_detector.dart';
import 'review_screen.dart';

/// Which of the three measurements the teacher is making.
enum _DragPurpose {
  /// Across every cell of the first question row.
  firstRow,

  /// Across a single writable cell.
  singleCell,

  /// Across one whole question block, used only to measure row pitch.
  block,
}

class CalibrateScreen extends StatefulWidget {
  const CalibrateScreen({super.key, required this.answerKey});

  final AnswerKey answerKey;

  @override
  State<CalibrateScreen> createState() => _CalibrateScreenState();
}

class _CalibrateScreenState extends State<CalibrateScreen> {
  CameraController? _camera;
  String? _cameraError;
  bool _capturing = false;

  CellRect? _firstRow;
  CellRect? _singleCell;
  CellRect? _block;

  /// Grouping only changes how many cells a question has and how an answer is
  /// worked out. The lattice itself is just an ordered list either way.
  CellGrouping _grouping = CellGrouping.single;
  int _optionCount = 4;

  /// Which measurement the current drag is feeding.
  _DragPurpose? _active;
  Offset? _dragStart;

  /// Live drag rectangle in preview coordinates.
  Rect? _dragRect;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    // Android declares the camera permission in the manifest but does not grant
    // it at install time, and the camera plugin does not ask for it. Without
    // this the plugin throws CameraAccessDenied and the app looks broken rather
    // than asking the obvious question.
    if (!await _ensureCameraPermission()) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() => _cameraError = 'No camera found on this device.');
        }
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (e) {
      if (mounted) {
        setState(() => _cameraError = 'Could not start camera: $e');
      }
    }
  }

  /// Returns true when the camera may be used.
  Future<bool> _ensureCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) return true;

    if (status.isPermanentlyDenied) {
      if (mounted) {
        setState(() => _cameraError =
            'Camera access is turned off for this app. Enable it in the '
            'system settings, then reopen this screen.');
      }
      return false;
    }

    status = await Permission.camera.request();
    if (status.isGranted) return true;
    if (mounted) {
      setState(() => _cameraError =
          'This app needs the camera to read the answer sheet. Nothing is '
          'uploaded: the photo is processed on this device only.');
    }
    return false;
  }

  /// Where the sensor frame actually sits inside the preview widget.
  ///
  /// `CameraPreview` letterboxes the frame, so a normalised drag has to travel
  /// through the same fit. Skipping this shifts every cell, which is why the
  /// teacher always confirms the overlay before anything is graded.
  Rect _frameRect(Size preview) {
    final controller = _camera;
    if (controller == null || !controller.value.isInitialized) {
      return Offset.zero & preview;
    }
    final sensor = controller.value.previewSize;
    if (sensor == null || sensor.width <= 0 || sensor.height <= 0) {
      return Offset.zero & preview;
    }
    // previewSize is reported in the sensor's own orientation, so the frame's
    // aspect as displayed is height/width.
    final frameAspect = sensor.height / sensor.width;
    final previewAspect = preview.height / preview.width;
    if (previewAspect > frameAspect) {
      final scaledHeight = preview.width * frameAspect;
      return Rect.fromLTWH(0, (preview.height - scaledHeight) / 2,
          preview.width, scaledHeight);
    }
    final scaledWidth = preview.height / frameAspect;
    return Rect.fromLTRB(
        (preview.width - scaledWidth) / 2, 0, scaledWidth, preview.height);
  }

  CellRect? _toCellRect(Rect r, Size preview) {
    final frame = _frameRect(preview);
    if (frame.width <= 0 || frame.height <= 0) return null;
    final cell = CellRect(
      ((r.left - frame.left) / frame.width).clamp(0.0, 1.0),
      ((r.top - frame.top) / frame.height).clamp(0.0, 1.0),
      ((r.right - frame.left) / frame.width).clamp(0.0, 1.0),
      ((r.bottom - frame.top) / frame.height).clamp(0.0, 1.0),
    );
    // Ignore accidental taps; a real cell is a decent fraction of the page.
    if (cell.width < 0.015 || cell.height < 0.008) return null;
    return cell;
  }

  Rect? _toPreviewRect(CellRect? cell, Size preview) {
    if (cell == null) return null;
    final frame = _frameRect(preview);
    return Rect.fromLTRB(
      frame.left + cell.left * frame.width,
      frame.top + cell.top * frame.height,
      frame.left + cell.right * frame.width,
      frame.top + cell.bottom * frame.height,
    );
  }

  /// The next measurement to make, in the order the teacher is prompted for.
  _DragPurpose get _nextPurpose {
    if (_firstRow == null) return _DragPurpose.firstRow;
    if (_singleCell == null) return _DragPurpose.singleCell;
    return _DragPurpose.block;
  }

  String get _instruction {
    switch (_nextPurpose) {
      case _DragPurpose.firstRow:
        return 'Drag across the whole first row of answers, from the first '
            'cell to the last.';
      case _DragPurpose.singleCell:
        return 'Now drag across just one answer cell.';
      case _DragPurpose.block:
        return 'Optionally drag across one whole question block so the row '
            'spacing can be measured. Then check the marks.';
    }
  }

  ExamCalibration? _buildCalibration() {
    final firstRow = _firstRow;
    final cell = _singleCell;
    if (firstRow == null || cell == null) return null;
    return ExamCalibration(
      examId: 'exam-${widget.answerKey.maxNumber}',
      answerKey: widget.answerKey,
      cells: deriveLattice(
        firstRowRect: firstRow,
        cellRect: cell,
        questionCount: widget.answerKey.maxNumber,
        grouping: _grouping,
        optionCount: _optionCount,
        blockRect: _block,
      ),
      grouping: _grouping,
      optionCount: _optionCount,
    );
  }

  void _onPanStart(Offset local) {
    _dragStart = local;
    setState(() => _active = _nextPurpose);
  }

  void _onPanUpdate(Offset local) {
    final start = _dragStart;
    if (start == null) return;
    setState(() => _dragRect = Rect.fromPoints(start, local));
  }

  void _onPanEnd(Size preview) {
    final rect = _dragRect;
    final purpose = _active;
    _dragStart = null;
    _dragRect = null;
    setState(() {
      _active = null;
      final cell = rect == null ? null : _toCellRect(rect, preview);
      if (cell == null) return;
      switch (purpose) {
        case _DragPurpose.firstRow:
          _firstRow = cell;
          // The cell and block were measured against the old row, so they no
          // longer describe the same lattice.
          _singleCell = null;
          _block = null;
          break;
        case _DragPurpose.singleCell:
          _singleCell = cell;
          _block = null;
          break;
        case _DragPurpose.block:
          _block = cell;
          break;
        case null:
          break;
      }
    });
  }

  void _onPanCancel() {
    _dragStart = null;
    setState(() {
      _dragRect = null;
      _active = null;
    });
  }

  Future<void> _continue() async {
    final calibration = _buildCalibration();
    final controller = _camera;
    if (calibration == null || controller == null || _capturing) return;
    if (calibration.validate() != null) return;
    setState(() => _capturing = true);
    try {
      // Review the exact still that was calibrated, so what the teacher
      // confirms is what gets read.
      final XFile shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ReviewScreen(
            calibration: calibration,
            frameBytes: bytes,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not capture the sheet: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _camera;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Calibrate the grid'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: controller == null || !controller.value.isInitialized
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _cameraError ?? 'Starting camera…',
                  style: const TextStyle(color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size =
                          Size(constraints.maxWidth, constraints.maxHeight);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: (d) => _onPanStart(d.localPosition),
                        onPanUpdate: (d) => _onPanUpdate(d.localPosition),
                        onPanEnd: (_) => _onPanEnd(size),
                        onPanCancel: _onPanCancel,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CameraPreview(controller),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _DragPainter(
                                    firstRow: _toPreviewRect(_firstRow, size),
                                    singleCell: _toPreviewRect(_singleCell, size),
                                    block: _toPreviewRect(_block, size),
                                    live: _dragRect,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                _controls(),
              ],
            ),
    );
  }

  Widget _controls() {
    final calibration = _buildCalibration();
    final problem = calibration?.validate();
    final cellCount = calibration?.cells.length ?? 0;
    final ready = calibration != null && problem == null;

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _instruction,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _chip('1. Answer row', _firstRow != null,
                    () => setState(() => _active = _DragPurpose.firstRow)),
                _chip('2. One cell', _singleCell != null,
                    () => setState(() => _active = _DragPurpose.singleCell)),
                _chip('3. One block (optional)', _block != null,
                    () => setState(() => _active = _DragPurpose.block)),
              ],
            ),
            const SizedBox(height: 10),
            const Text('How each question is answered',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                _chip(
                  'One letter per question',
                  _grouping == CellGrouping.single,
                  () => setState(() => _grouping = CellGrouping.single),
                ),
                _chip(
                  'A B C D cells per question',
                  _grouping == CellGrouping.options,
                  () => setState(() => _grouping = CellGrouping.options),
                ),
              ],
            ),
            if (_grouping == CellGrouping.options) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Text('Options', style: TextStyle(color: Colors.white70)),
                  Expanded(
                    child: Slider(
                      value: _optionCount.toDouble(),
                      min: 2,
                      max: 8,
                      divisions: 6,
                      label: '$_optionCount',
                      onChanged: (v) => setState(() => _optionCount = v.round()),
                    ),
                  ),
                  Text('$_optionCount', style: const TextStyle(color: Colors.white)),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              calibration == null
                  ? 'Drag on the photo to mark the answer grid.'
                  : '$cellCount cells for ${widget.answerKey.maxNumber} '
                      'questions.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (problem != null) ...[
              const SizedBox(height: 6),
              Text(problem, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: ready ? _continue : null,
              child: Text(_capturing ? 'Capturing…' : 'Check the marks'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return ChoiceChip(
      selected: selected,
      backgroundColor: selected ? Colors.cyan.withValues(alpha: 0.35) : null,
      label: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 12)),
      onSelected: (_) => onTap(),
    );
  }
}

class _DragPainter extends CustomPainter {
  _DragPainter({this.firstRow, this.singleCell, this.block, this.live});

  final Rect? firstRow;
  final Rect? singleCell;
  final Rect? block;
  final Rect? live;

  @override
  void paint(Canvas canvas, Size size) {
    if (block != null) {
      _dashed(canvas, block!, Colors.amber);
      _label(canvas, block!, 'block', Colors.amber);
    }
    if (firstRow != null) {
      _box(canvas, firstRow!, Colors.cyan);
      _label(canvas, firstRow!, 'row', Colors.cyan);
    }
    if (singleCell != null) {
      _box(canvas, singleCell!, Colors.green);
      _label(canvas, singleCell!, 'cell', Colors.green);
    }
    if (live != null) {
      _box(canvas, live!, Colors.white);
    }
  }

  void _box(Canvas canvas, Rect rect, Color colour) {
    canvas.drawRect(
      rect,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  void _dashed(Canvas canvas, Rect rect, Color colour) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 2;
    const dash = 10.0;
    for (var x = rect.left; x < rect.right; x += dash * 2) {
      canvas.drawLine(Offset(x, rect.top),
          Offset((x + dash).clamp(rect.left, rect.right), rect.top), paint);
      canvas.drawLine(Offset(x, rect.bottom),
          Offset((x + dash).clamp(rect.left, rect.right), rect.bottom), paint);
    }
  }

  void _label(Canvas canvas, Rect rect, String text, Color colour) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: colour,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          shadows: const [Shadow(color: Colors.black, blurRadius: 3)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(rect.left, rect.top - painter.height - 2));
  }

  @override
  bool shouldRepaint(covariant _DragPainter old) =>
      old.firstRow != firstRow ||
      old.singleCell != singleCell ||
      old.block != block ||
      old.live != live;
}
