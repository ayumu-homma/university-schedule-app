import 'package:flutter/material.dart';

import '../domain/spatial_week_models.dart';
import 'spatial_week_geometry.dart';

/// Decorative geometric 2.5D canvas. Its equivalent list and controls are the
/// accessible interaction surface, so this painter is intentionally excluded
/// from semantics.
class SpatialWeekCanvas extends StatefulWidget {
  static const Map<SpatialEntryKind, Color> categoryColors = {
    SpatialEntryKind.course: Color(0xff3f70c2),
    SpatialEntryKind.event: Color(0xff2d947a),
    SpatialEntryKind.routine: Color(0xff8c63b8),
    SpatialEntryKind.assignment: Color(0xffc06d2f),
    SpatialEntryKind.exam: Color(0xffbb4657),
  };

  const SpatialWeekCanvas({
    required this.entries,
    required this.camera,
    required this.onCameraChanged,
    required this.onSelectEntry,
    this.selectedEntryKey,
    this.flat = false,
    super.key,
  });

  final List<SpatialWeekEntry> entries;
  final SpatialCamera camera;
  final ValueChanged<SpatialCamera> onCameraChanged;
  final ValueChanged<String> onSelectEntry;
  final String? selectedEntryKey;
  final bool flat;

  @override
  State<SpatialWeekCanvas> createState() => _SpatialWeekCanvasState();
}

class _SpatialWeekCanvasState extends State<SpatialWeekCanvas> {
  static const double _orbitThreshold = 4;
  static const List<String> _weekdays = ['月', '火', '水', '木', '金', '土', '日'];
  double _startYaw = -0.25;
  double _startPitch = 0.85;
  double _startZoom = 1;
  Offset _startFocalPoint = Offset.zero;
  bool _moved = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final canvasSize = Size(
            size.width.isFinite && size.width > 0 ? size.width : 320,
            size.height.isFinite && size.height > 0 ? size.height : 260,
          );
          final projection = SpatialWeekProjection.build(
            size: canvasSize,
            entries: widget.entries,
            camera: widget.camera,
            flat: widget.flat,
          );
          return ExcludeSemantics(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (details) {
                _startYaw = widget.camera.yaw;
                _startPitch = widget.camera.pitch;
                _startZoom = widget.camera.zoom;
                _startFocalPoint = details.focalPoint;
                _moved = false;
              },
              onScaleUpdate: (details) {
                final delta = details.focalPoint - _startFocalPoint;
                if (delta.distance >= _orbitThreshold ||
                    (details.scale - 1).abs() > 0.025) {
                  _moved = true;
                }
                if (!_moved) return;
                final nextZoom =
                    (_startZoom * details.scale).clamp(0.65, 1.8).toDouble();
                final next = widget.camera.copyWith(
                  yaw: _startYaw - delta.dx * 0.008,
                  pitch: _startPitch + delta.dy * 0.006,
                  zoom: nextZoom,
                );
                if (next.yaw != widget.camera.yaw ||
                    next.pitch != widget.camera.pitch ||
                    next.zoom != widget.camera.zoom) {
                  widget.onCameraChanged(next);
                }
              },
              onScaleEnd: (_) {},
              onTapDown: (_) => _moved = false,
              onTapUp: (details) {
                if (_moved) return;
                final key = projection.frontmostHitTest(details.localPosition);
                if (key != null) widget.onSelectEntry(key);
              },
              child: ClipRect(
                child: CustomPaint(
                  size: canvasSize,
                  painter: _SpatialWeekPainter(
                    projection: projection,
                    entries: widget.entries,
                    selectedEntryKey: widget.selectedEntryKey,
                    weekdays: _weekdays,
                    dark: Theme.of(context).brightness == Brightness.dark,
                  ),
                ),
              ),
            ),
          );
        },
      );
}

class _SpatialWeekPainter extends CustomPainter {
  _SpatialWeekPainter({
    required this.projection,
    required this.entries,
    required this.selectedEntryKey,
    required this.weekdays,
    required this.dark,
  });

  final SpatialWeekProjection projection;
  final List<SpatialWeekEntry> entries;
  final String? selectedEntryKey;
  final List<String> weekdays;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    _paintGrid(canvas, size);
    final kinds = <String, SpatialEntryKind>{
      for (final entry in entries) entry.key: entry.kind
    };
    for (final surface in projection.paintSurfaces) {
      final base = SpatialWeekCanvas.categoryColors[kinds[surface.entryKey]] ??
          const Color(0xff527a95);
      final selected = surface.entryKey == selectedEntryKey;
      final color = switch (surface.face) {
        SpatialWeekFace.top => base,
        SpatialWeekFace.front => Color.lerp(base, Colors.black, 0.20)!,
        SpatialWeekFace.side => Color.lerp(base, Colors.black, 0.32)!,
        SpatialWeekFace.marker => base,
        SpatialWeekFace.flat => base,
      };
      canvas.drawPath(
        surface.path,
        Paint()
          ..color = selected ? const Color(0xffffc857) : color
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        surface.path,
        Paint()
          ..color = (dark ? Colors.white : Colors.black)
              .withValues(alpha: selected ? 0.85 : 0.28)
          ..strokeWidth = selected ? 2.2 : 0.8
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _paintGrid(Canvas canvas, Size size) {
    final gridColor = dark ? const Color(0xff718096) : const Color(0xff718096);
    final paint = Paint()
      ..color = gridColor.withValues(alpha: dark ? 0.48 : 0.38)
      ..strokeWidth = 0.8;
    for (var day = 0; day <= 7; day++) {
      final a = projection.projectFloor(day.toDouble(), 0);
      final b = projection.projectFloor(day.toDouble(), 1440);
      if (_finite(a) && _finite(b)) canvas.drawLine(a, b, paint);
    }
    for (var hour = 0; hour <= 24; hour += 3) {
      final a = projection.projectFloor(0, hour * 60.0);
      final b = projection.projectFloor(7, hour * 60.0);
      if (_finite(a) && _finite(b)) canvas.drawLine(a, b, paint);
      if (hour < 24) {
        final labelPoint = projection.projectFloor(0, hour * 60.0);
        if (_finite(labelPoint)) {
          _text(
              canvas,
              '${hour.toString().padLeft(2, '0')}:00',
              labelPoint + const Offset(-35, -7),
              dark ? const Color(0xffd7deea) : const Color(0xff384457),
              10);
        }
      }
    }
    for (var day = 0; day < 7; day++) {
      final label = projection.projectFloor(day + 0.5, 1440);
      if (_finite(label)) {
        _text(canvas, weekdays[day], label + const Offset(-5, 5),
            dark ? const Color(0xffe6ebf3) : const Color(0xff2d3748), 11);
      }
    }
    if (projection.hasUnmaterializedSegments) {
      _text(
          canvas,
          '+${projection.omittedSegmentCount} 件は一覧で確認',
          const Offset(8, 8),
          dark ? const Color(0xffffd58a) : const Color(0xff7a4210),
          11);
    }
  }

  static bool _finite(Offset value) => value.dx.isFinite && value.dy.isFinite;

  static void _text(
      Canvas canvas, String text, Offset position, Color color, double size) {
    final painter = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              color: color, fontSize: size, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 90);
    painter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _SpatialWeekPainter oldDelegate) =>
      oldDelegate.projection != projection ||
      oldDelegate.entries != entries ||
      oldDelegate.selectedEntryKey != selectedEntryKey ||
      oldDelegate.dark != dark;
}
