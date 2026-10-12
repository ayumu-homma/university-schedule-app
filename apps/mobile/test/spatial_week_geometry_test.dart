import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_schedule_mobile/features/spatial_week/domain/spatial_week_models.dart';
import 'package:university_schedule_mobile/features/spatial_week/presentation/spatial_week_geometry.dart';

SpatialWeekEntry _entry(
  String key, {
  SpatialEntryKind kind = SpatialEntryKind.course,
  List<SpatialWeekSegment>? segments,
}) =>
    SpatialWeekEntry(
      key: key,
      sourceId: 'source-$key',
      kind: kind,
      title: key,
      detailRoute: '/$key',
      segments: segments ??
          const [
            SpatialWeekSegment(dayIndex: 1, startMinute: 600, endMinute: 660)
          ],
    );

void main() {
  group('SpatialCamera', () {
    test('copyWith bounds finite values and replaces NaN or infinity safely',
        () {
      const camera = SpatialCamera();
      final extreme = camera.copyWith(yaw: 100000, pitch: -100, zoom: 99);
      expect(extreme.yaw, math.pi);
      expect(extreme.pitch, 0.15);
      expect(extreme.zoom, 1.8);
      final invalid = camera.copyWith(
          yaw: double.nan,
          pitch: double.infinity,
          zoom: double.negativeInfinity);
      expect(invalid.yaw, -0.25);
      expect(invalid.pitch, 0.85);
      expect(invalid.zoom, 1);
    });
  });

  group('SpatialWeekProjection', () {
    test('keeps source data immutable and splits an occurrence across days',
        () {
      final originalSegments = <SpatialWeekSegment>[
        const SpatialWeekSegment(
            dayIndex: 0, startMinute: 1380, endMinute: 1440),
        const SpatialWeekSegment(dayIndex: 1, startMinute: 0, endMinute: 90),
      ];
      final entry = _entry('overnight', segments: originalSegments);
      final entries = <SpatialWeekEntry>[entry];
      final projection = SpatialWeekProjection.build(
        size: const Size(360, 320),
        entries: entries,
        camera: const SpatialCamera(),
      );
      expect(projection.blocks.map((block) => block.entryKey),
          ['overnight', 'overnight']);
      expect(projection.blocks.map((block) => block.segmentIndex), [0, 1]);
      expect(originalSegments, hasLength(2));
      expect(entries, hasLength(1));
    });

    test(
        'deadline remains a point marker and is selectable without busy duration',
        () {
      final entry = _entry(
        'deadline',
        kind: SpatialEntryKind.assignment,
        segments: const [
          SpatialWeekSegment(dayIndex: 2, startMinute: 720, endMinute: 720)
        ],
      );
      final projection = SpatialWeekProjection.build(
        size: const Size(360, 320),
        entries: [entry],
        camera: const SpatialCamera(),
        flat: true,
      );
      expect(projection.blocks, hasLength(1));
      expect(projection.blocks.single.surfaces.single.face,
          SpatialWeekFace.marker);
      final bounds = projection.blocks.single.surfaces.single.path.getBounds();
      expect(projection.frontmostHitTest(bounds.center), 'deadline');
    });

    test('only the topmost painted overlap wins hit testing', () {
      final projection = SpatialWeekProjection.build(
        size: const Size(360, 320),
        entries: [_entry('first'), _entry('second')],
        camera: const SpatialCamera(),
        flat: true,
      );
      final overlap =
          projection.blocks.first.surfaces.single.path.getBounds().center;
      expect(projection.frontmostHitTest(overlap),
          projection.paintSurfaces.last.entryKey);
      expect(projection.frontmostHitTest(const Offset(-100, -100)), isNull);
    });

    test(
        'handles invalid dimensions, malformed segments, extreme camera and near-plane clipping',
        () {
      final invalidSize = SpatialWeekProjection.build(
        size: const Size(double.infinity, -4),
        entries: [
          _entry('bad', segments: const [
            SpatialWeekSegment(dayIndex: 9, startMinute: 1, endMinute: 2)
          ])
        ],
        camera: const SpatialCamera(
            yaw: double.nan, pitch: double.infinity, zoom: double.nan),
      );
      expect(invalidSize.paintSurfaces, isEmpty);
      expect(invalidSize.frontmostHitTest(Offset.zero), isNull);

      final projection = SpatialWeekProjection.build(
        size: const Size(320, 300),
        entries: [
          _entry('edge', segments: const [
            SpatialWeekSegment(dayIndex: 6, startMinute: 0, endMinute: 1440)
          ])
        ],
        camera: const SpatialCamera(yaw: 500, pitch: 100, zoom: 500),
      );
      for (final surface in projection.paintSurfaces) {
        final bounds = surface.path.getBounds();
        expect(
            bounds.left.isFinite &&
                bounds.top.isFinite &&
                bounds.right.isFinite &&
                bounds.bottom.isFinite,
            isTrue);
      }
    });

    test(
        'default camera fits weekday/noon positions, floor corners, and axis labels',
        () {
      for (final size in const [
        Size(360, 320),
        Size(412, 320),
        Size(412, 760),
        Size(768, 900),
      ]) {
        final projection = SpatialWeekProjection.build(
          size: size,
          entries: const [],
          camera: const SpatialCamera(),
        );
        void expectUsable(Offset point, String label) {
          expect(point.dx.isFinite && point.dy.isFinite, isTrue,
              reason: '$size $label finite');
          expect(point.dx, inInclusiveRange(0, size.width),
              reason: '$size $label x');
          expect(point.dy, inInclusiveRange(0, size.height),
              reason: '$size $label y');
        }

        for (var day = 0; day < 7; day++) {
          expectUsable(
              projection.projectFloor(day + 0.5, 720), 'day $day noon');
        }
        for (final day in [0.0, 7.0]) {
          for (final minute in [0.0, 1440.0]) {
            expectUsable(projection.projectFloor(day, minute),
                'floor corner $day/$minute');
          }
        }
        for (var hour = 0; hour < 24; hour += 3) {
          final label = projection.projectFloor(0, hour * 60.0);
          expect(label.dx - 35, greaterThanOrEqualTo(0),
              reason: '$size clock label $hour left');
          expect(label.dx + 40, lessThanOrEqualTo(size.width),
              reason: '$size clock label $hour right');
          expectUsable(label, 'clock tick $hour');
        }
        for (var day = 0; day < 7; day++) {
          final label = projection.projectFloor(day + 0.5, 1440);
          expect(label.dx - 5, greaterThanOrEqualTo(0),
              reason: '$size weekday $day left');
          expect(label.dx + 12, lessThanOrEqualTo(size.width),
              reason: '$size weekday $day right');
          expectUsable(label, 'weekday label $day');
        }
      }
    });

    test('default Monday and Sunday course surfaces can be hit-selected', () {
      for (final day in [0, 6]) {
        final entry = _entry(
          'day-$day',
          segments: [
            SpatialWeekSegment(dayIndex: day, startMinute: 660, endMinute: 720)
          ],
        );
        final projection = SpatialWeekProjection.build(
          size: const Size(360, 320),
          entries: [entry],
          camera: const SpatialCamera(),
        );
        final visibleSamples = <Offset>[];
        for (final surface in projection.blocks.single.surfaces
            .where((s) => s.face == SpatialWeekFace.top)) {
          final bounds = surface.path.getBounds();
          for (var ix = 1; ix < 6; ix++) {
            for (var iy = 1; iy < 6; iy++) {
              final sample = Offset(
                bounds.left + bounds.width * ix / 6,
                bounds.top + bounds.height * iy / 6,
              );
              if (surface.path.contains(sample)) visibleSamples.add(sample);
            }
          }
        }
        expect(visibleSamples, isNotEmpty,
            reason: 'day $day has a visible top face');
        expect(
          visibleSamples
              .any((point) => projection.frontmostHitTest(point) == entry.key),
          isTrue,
          reason: 'day $day course can be selected in the default overview',
        );
      }
    });

    test(
        'caps materialization and reports every omitted segment for the list fallback',
        () {
      final entries = List.generate(
        SpatialWeekProjection.maxMaterializedSegments + 3,
        (i) => _entry('entry-$i'),
      );
      final projection = SpatialWeekProjection.build(
        size: const Size(360, 320),
        entries: entries,
        camera: const SpatialCamera(),
      );
      expect(projection.blocks,
          hasLength(SpatialWeekProjection.maxMaterializedSegments));
      expect(projection.omittedSegmentCount, 3);
      expect(projection.hasUnmaterializedSegments, isTrue);
      expect(entries,
          hasLength(SpatialWeekProjection.maxMaterializedSegments + 3));
    });
  });
}
