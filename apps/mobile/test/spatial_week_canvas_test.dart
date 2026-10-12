import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/spatial_week/domain/spatial_week_models.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_canvas.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_geometry.dart';

final _entries = <SpatialWeekEntry>[
  const SpatialWeekEntry(
    key: 'course-occurrence',
    sourceId: 'course-1',
    kind: SpatialEntryKind.course,
    title: 'Course',
    detailRoute: '/course',
    segments: [
      SpatialWeekSegment(dayIndex: 1, startMinute: 600, endMinute: 720)
    ],
  ),
];

class _Harness extends StatefulWidget {
  const _Harness({required this.onSelected, required this.onCamera});
  final ValueChanged<String> onSelected;
  final ValueChanged<SpatialCamera> onCamera;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  SpatialCamera camera = const SpatialCamera();

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 320,
              child: SpatialWeekCanvas(
                entries: _entries,
                camera: camera,
                flat: true,
                onCameraChanged: (next) {
                  widget.onCamera(next);
                  setState(() => camera = next);
                },
                onSelectEntry: widget.onSelected,
              ),
            ),
          ),
        ),
      );
}

void main() {
  testWidgets('tap selects the occurrence key', (tester) async {
    String? selected;
    await tester.pumpWidget(
        _Harness(onSelected: (key) => selected = key, onCamera: (_) {}));
    final canvas = tester.getRect(find.byType(SpatialWeekCanvas));
    final projection = SpatialWeekProjection.build(
      size: canvas.size,
      entries: _entries,
      camera: const SpatialCamera(),
      flat: true,
    );
    final local =
        projection.blocks.single.surfaces.single.path.getBounds().center;
    await tester.tapAt(canvas.topLeft + local);
    await tester.pump();
    expect(selected, 'course-occurrence');
  });

  testWidgets('orbit drag changes camera and never selects an entry',
      (tester) async {
    var selections = 0;
    final cameras = <SpatialCamera>[];
    await tester.pumpWidget(_Harness(
      onSelected: (_) => selections++,
      onCamera: cameras.add,
    ));
    await tester.drag(find.byType(SpatialWeekCanvas), const Offset(48, 16));
    await tester.pump();
    expect(selections, 0);
    expect(cameras, isNotEmpty);
    expect(cameras.last.yaw.isFinite, isTrue);
    expect(cameras.last.pitch.isFinite, isTrue);
  });

  testWidgets('pinch zoom emits a finite bounded camera update',
      (tester) async {
    final cameras = <SpatialCamera>[];
    var selections = 0;
    await tester.pumpWidget(_Harness(
      onSelected: (_) => selections++,
      onCamera: cameras.add,
    ));
    final rect = tester.getRect(find.byType(SpatialWeekCanvas));
    final center = rect.center;
    final first =
        await tester.startGesture(center - const Offset(10, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(10, 0), pointer: 2);
    await first.moveTo(center - const Offset(34, 0));
    await second.moveTo(center + const Offset(34, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    expect(cameras, isNotEmpty);
    expect(cameras.last.zoom.isFinite, isTrue);
    expect(cameras.last.zoom, inInclusiveRange(0.65, 1.8));
    expect(selections, 0);
  });
}
