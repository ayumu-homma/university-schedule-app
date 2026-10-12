import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/spatial_week_models.dart';

/// Camera for the optional geometric 2.5D view. Angles are radians.
///
/// The public const constructor makes the default/reset camera usable from
/// const contexts. Call [copyWith] for user input; every supplied value is
/// normalized before it is stored.
class SpatialCamera {
  const SpatialCamera({this.yaw = -0.25, this.pitch = 0.85, this.zoom = 1});

  final double yaw;
  final double pitch;
  final double zoom;

  SpatialCamera copyWith({double? yaw, double? pitch, double? zoom}) =>
      SpatialCamera(
        yaw: _finiteClamp(yaw ?? this.yaw, -math.pi, math.pi, -0.25),
        pitch: _finiteClamp(pitch ?? this.pitch, 0.15, 1.45, 0.85),
        zoom: _finiteClamp(zoom ?? this.zoom, 0.65, 1.8, 1),
      );

  static double _finiteClamp(
      double value, double min, double max, double fallback) {
    if (!value.isFinite) return fallback;
    return value.clamp(min, max).toDouble();
  }
}

/// A single clipped, already projected face. Paint these in [paintSurfaces]
/// order and use the same list in reverse for exact visible-surface hit tests.
class SpatialWeekSurface {
  const SpatialWeekSurface({
    required this.entryKey,
    required this.path,
    required this.depth,
    required this.face,
  });

  final String entryKey;
  final Path path;
  final double depth;
  final SpatialWeekFace face;
}

enum SpatialWeekFace { top, front, side, marker, flat }

/// Projected geometry for one segment. Several blocks can share an entry key.
class SpatialWeekProjectedBlock {
  const SpatialWeekProjectedBlock({
    required this.entryKey,
    required this.segmentIndex,
    required this.surfaces,
  });

  final String entryKey;
  final int segmentIndex;
  final List<SpatialWeekSurface> surfaces;
}

/// Pixel geometry for one bounded canvas. A deliberately geometric 2.5D
/// projection: day and clock time are the data axes; block height is constant.
class SpatialWeekProjection {
  SpatialWeekProjection._({
    required this.size,
    required this.blocks,
    required this.paintSurfaces,
    required this.omittedSegmentCount,
    required Offset Function(double day, double minute) projectFloor,
  }) : _projectFloor = projectFloor;

  static const int maxMaterializedSegments = 160;
  static const double _blockHeight = 0.12;
  static const double _nearPlane = 0.08;

  final Size size;
  final List<SpatialWeekProjectedBlock> blocks;
  final List<SpatialWeekSurface> paintSurfaces;
  final int omittedSegmentCount;
  final Offset Function(double day, double minute) _projectFloor;

  bool get hasUnmaterializedSegments => omittedSegmentCount > 0;

  /// Projects an axis position, where days run 0..7 and minutes 0..1440.
  Offset projectFloor(double dayIndex, double minute) {
    if (!dayIndex.isFinite || !minute.isFinite || !_validSize(size)) {
      return Offset.infinite;
    }
    return _projectFloor(
      dayIndex.clamp(0, 7).toDouble(),
      minute.clamp(0, 1440).toDouble(),
    );
  }

  /// Returns the topmost painted entry under [point], if any.
  String? frontmostHitTest(Offset point) {
    if (!_validSize(size) ||
        !point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dy < 0 ||
        point.dx > size.width ||
        point.dy > size.height) {
      return null;
    }
    for (final surface in paintSurfaces.reversed) {
      if (surface.path.contains(point)) return surface.entryKey;
    }
    return null;
  }

  factory SpatialWeekProjection.build({
    required Size size,
    required List<SpatialWeekEntry> entries,
    required SpatialCamera camera,
    bool flat = false,
  }) {
    final safeSize = _validSize(size) ? size : Size.zero;
    final cam = camera.copyWith();
    final projector = _Projector(safeSize, cam, flat: flat);
    final blocks = <SpatialWeekProjectedBlock>[];
    final surfaces = <SpatialWeekSurface>[];
    var materialized = 0;
    var omitted = 0;

    for (final entry in entries) {
      if (!_validSize(size)) break;
      for (var segmentIndex = 0;
          segmentIndex < entry.segments.length;
          segmentIndex++) {
        final segment = entry.segments[segmentIndex];
        if (!_validSegment(segment, isDeadline: entry.isDeadline)) continue;
        if (materialized >= maxMaterializedSegments) {
          omitted++;
          continue;
        }
        materialized++;
        final built = flat
            ? _flatSegment(projector, entry, segment, segmentIndex)
            : _spatialSegment(projector, entry, segment, segmentIndex);
        if (built == null || built.surfaces.isEmpty) continue;
        blocks.add(built);
        surfaces.addAll(built.surfaces);
      }
    }

    surfaces.sort((a, b) {
      // Painter order is far-to-near so later paths match the visible top face.
      final depth = b.depth.compareTo(a.depth);
      if (depth != 0) return depth;
      // Consistent tie order keeps paint and hit testing deterministic.
      final key = a.entryKey.compareTo(b.entryKey);
      return key != 0 ? key : a.face.index.compareTo(b.face.index);
    });
    return SpatialWeekProjection._(
      size: safeSize,
      blocks: List.unmodifiable(blocks),
      paintSurfaces: List.unmodifiable(surfaces),
      omittedSegmentCount: omitted,
      projectFloor: projector.floor,
    );
  }

  static bool _validSize(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;

  static bool _validSegment(SpatialWeekSegment segment,
      {required bool isDeadline}) {
    final day = segment.dayIndex;
    final start = segment.startMinute;
    final end = segment.endMinute;
    return day >= 0 &&
        day < 7 &&
        start >= 0 &&
        start <= 1440 &&
        end >= start &&
        end <= 1440 &&
        (end > start || isDeadline);
  }

  static SpatialWeekProjectedBlock? _flatSegment(
    _Projector p,
    SpatialWeekEntry entry,
    SpatialWeekSegment segment,
    int segmentIndex,
  ) {
    final day = segment.dayIndex.toDouble();
    if (entry.isDeadline) {
      final center = p.floor(day + 0.5, segment.startMinute.toDouble());
      if (!_finiteOffset(center)) return null;
      final radius = math
          .max(4.0, math.min(p.size.width, p.size.height) * 0.012)
          .toDouble();
      final path = Path()
        ..addOval(Rect.fromCircle(center: center, radius: radius));
      final face = SpatialWeekSurface(
        entryKey: entry.key,
        path: path,
        depth: segment.startMinute.toDouble(),
        face: SpatialWeekFace.marker,
      );
      return SpatialWeekProjectedBlock(
        entryKey: entry.key,
        segmentIndex: segmentIndex,
        surfaces: List.unmodifiable([face]),
      );
    }
    final a = p.floor(day + 0.08, segment.startMinute.toDouble());
    final b = p.floor(day + 0.92, segment.endMinute.toDouble());
    if (!_finiteOffset(a) || !_finiteOffset(b)) return null;
    final rect = Rect.fromPoints(a, b);
    if (rect.width < 0.5 || rect.height < 0.5) return null;
    final surface = SpatialWeekSurface(
      entryKey: entry.key,
      path: Path()..addRect(rect),
      depth: segment.startMinute.toDouble(),
      face: SpatialWeekFace.flat,
    );
    return SpatialWeekProjectedBlock(
      entryKey: entry.key,
      segmentIndex: segmentIndex,
      surfaces: List.unmodifiable([surface]),
    );
  }

  static SpatialWeekProjectedBlock? _spatialSegment(
    _Projector p,
    SpatialWeekEntry entry,
    SpatialWeekSegment segment,
    int segmentIndex,
  ) {
    if (entry.isDeadline) {
      final center3 =
          _Vec3(segment.dayIndex + 0.5, segment.startMinute / 1440 * 7, 0.006);
      final center = p.project(center3);
      if (center == null) return null;
      final radius = math
          .max(4.0, math.min(p.size.width, p.size.height) * 0.013)
          .toDouble();
      final marker = Path()
        ..addOval(Rect.fromCircle(center: center.offset, radius: radius));
      final face = SpatialWeekSurface(
        entryKey: entry.key,
        path: marker,
        depth: center.depth,
        face: SpatialWeekFace.marker,
      );
      return SpatialWeekProjectedBlock(
        entryKey: entry.key,
        segmentIndex: segmentIndex,
        surfaces: List.unmodifiable([face]),
      );
    }

    final x0 = segment.dayIndex.toDouble();
    final x1 = x0 + 1;
    final t0 = segment.startMinute / 1440 * 7;
    final t1 = segment.endMinute / 1440 * 7;
    if (t1 - t0 < 0.00001) return null;
    final z0 = 0.0;
    final z1 = _blockHeight;
    final v = <_Vec3>[
      _Vec3(x0, t0, z0),
      _Vec3(x1, t0, z0),
      _Vec3(x1, t1, z0),
      _Vec3(x0, t1, z0),
      _Vec3(x0, t0, z1),
      _Vec3(x1, t0, z1),
      _Vec3(x1, t1, z1),
      _Vec3(x0, t1, z1),
    ];
    final faces = <(SpatialWeekFace, List<int>)>[
      (SpatialWeekFace.top, [4, 5, 6, 7]),
      (SpatialWeekFace.front, [0, 1, 5, 4]),
      (SpatialWeekFace.side, [1, 2, 6, 5]),
      (SpatialWeekFace.front, [2, 3, 7, 6]),
      (SpatialWeekFace.side, [3, 0, 4, 7]),
    ];
    final projected = <SpatialWeekSurface>[];
    for (final (face, indices) in faces) {
      final clipped = p.clipAndProject(indices.map((i) => v[i]).toList());
      if (clipped.length < 3) continue;
      final path = Path()
        ..moveTo(clipped.first.offset.dx, clipped.first.offset.dy);
      for (final point in clipped.skip(1)) {
        path.lineTo(point.offset.dx, point.offset.dy);
      }
      path.close();
      final depth =
          clipped.map((point) => point.depth).reduce((a, b) => a + b) /
              clipped.length;
      projected.add(SpatialWeekSurface(
          entryKey: entry.key, path: path, depth: depth, face: face));
    }
    if (projected.isEmpty) return null;
    return SpatialWeekProjectedBlock(
      entryKey: entry.key,
      segmentIndex: segmentIndex,
      surfaces: List.unmodifiable(projected),
    );
  }
}

class _Vec3 {
  const _Vec3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;
  _Vec3 operator +(_Vec3 b) => _Vec3(x + b.x, y + b.y, z + b.z);
  _Vec3 operator -(_Vec3 b) => _Vec3(x - b.x, y - b.y, z - b.z);
  _Vec3 operator *(double s) => _Vec3(x * s, y * s, z * s);
  double dot(_Vec3 b) => x * b.x + y * b.y + z * b.z;
  double get length => math.sqrt(dot(this));
  _Vec3 normalized() {
    final len = length;
    return len > 0 && len.isFinite ? this * (1 / len) : const _Vec3(0, 0, 1);
  }
}

class _Projected {
  const _Projected(this.offset, this.depth);
  final Offset offset;
  final double depth;
}

class _Projector {
  _Projector(this.size, SpatialCamera camera, {this.flat = false})
      : yaw = camera.yaw.isFinite
            ? camera.yaw.clamp(-math.pi, math.pi).toDouble()
            : -0.25,
        pitch = camera.pitch.isFinite
            ? camera.pitch.clamp(0.15, 1.45).toDouble()
            : 0.85,
        zoom =
            camera.zoom.isFinite ? camera.zoom.clamp(0.65, 1.8).toDouble() : 1;

  final Size size;
  final double yaw;
  final double pitch;
  final double zoom;
  final bool flat;
  late final _Vec3 target = const _Vec3(3.5, 3.5, 0.06);
  late final _Vec3 cameraPosition = target +
      _Vec3(
        math.sin(yaw) * math.cos(pitch) * 8,
        -math.cos(yaw) * math.cos(pitch) * 8,
        math.sin(pitch) * 8,
      );
  late final _Vec3 forward = (target - cameraPosition).normalized();
  late final _Vec3 right = _cross(forward, const _Vec3(0, 0, 1)).normalized();
  late final _Vec3 up = _cross(right, forward).normalized();
  late final Rect _viewBounds = _computeViewBounds();
  late final double _plotLeft = math.min(44.0, size.width * 0.14).toDouble();
  late final double _plotRight =
      (size.width - math.min(12.0, size.width * 0.04)).toDouble();
  late final double _plotTop = math.min(8.0, size.height * 0.025).toDouble();
  late final double _plotBottom =
      (size.height - math.min(34.0, size.height * 0.11)).toDouble();
  late final double _fitFocal = _computeFitFocal();
  late final double focal = _fitFocal * zoom;
  late final double centerX = (_plotLeft + _plotRight) / 2;
  late final double centerY = (_plotTop + _plotBottom) / 2;

  static _Vec3 _cross(_Vec3 a, _Vec3 b) => _Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
      );

  double depth(_Vec3 point) => (point - cameraPosition).dot(forward);

  Offset _normalizedViewPoint(_Vec3 point) {
    final relative = point - cameraPosition;
    final z = relative.dot(forward);
    return Offset(relative.dot(right) / z, -relative.dot(up) / z);
  }

  Rect _computeViewBounds() {
    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    for (final day in [0.0, 7.0]) {
      for (final minute in [0.0, 7.0]) {
        for (final height in [0.0, SpatialWeekProjection._blockHeight]) {
          final point = _normalizedViewPoint(_Vec3(day, minute, height));
          minX = math.min(minX, point.dx).toDouble();
          maxX = math.max(maxX, point.dx).toDouble();
          minY = math.min(minY, point.dy).toDouble();
          maxY = math.max(maxY, point.dy).toDouble();
        }
      }
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  double _computeFitFocal() {
    final width = math.max(1.0, _plotRight - _plotLeft).toDouble();
    final height = math.max(1.0, _plotBottom - _plotTop).toDouble();
    final rangeX = math.max(1e-6, _viewBounds.width).toDouble();
    final rangeY = math.max(1e-6, _viewBounds.height).toDouble();
    return math.min(width / rangeX, height / rangeY).toDouble();
  }

  _Projected? project(_Vec3 point) {
    final relative = point - cameraPosition;
    final z = relative.dot(forward);
    if (!z.isFinite || z < SpatialWeekProjection._nearPlane) return null;
    final px =
        centerX + (relative.dot(right) / z - _viewBounds.center.dx) * focal;
    final py =
        centerY + (-relative.dot(up) / z - _viewBounds.center.dy) * focal;
    if (!px.isFinite ||
        !py.isFinite ||
        px.abs() > 100000 ||
        py.abs() > 100000) {
      return null;
    }
    return _Projected(Offset(px, py), z);
  }

  Offset floor(double day, double minute) {
    if (!SpatialWeekProjection._validSize(size)) {
      return Offset.infinite;
    }
    if (flat) {
      final x = 46 + (size.width - 58) * (day / 7);
      final y = 12 + (size.height - 44) * (minute / 1440);
      return Offset(x, y);
    }
    final point = project(_Vec3(day, minute / 1440 * 7, 0));
    if (point == null) return Offset.infinite;
    return point.offset;
  }

  List<_Projected> clipAndProject(List<_Vec3> polygon) {
    if (polygon.isEmpty) return const [];
    final output = <_Vec3>[];
    var previous = polygon.last;
    var previousDepth = depth(previous);
    for (final current in polygon) {
      final currentDepth = depth(current);
      final currentInside = currentDepth >= SpatialWeekProjection._nearPlane;
      final previousInside = previousDepth >= SpatialWeekProjection._nearPlane;
      if (currentInside != previousInside) {
        final denominator = currentDepth - previousDepth;
        if (denominator.abs() > 1e-12 && denominator.isFinite) {
          final t =
              ((SpatialWeekProjection._nearPlane - previousDepth) / denominator)
                  .clamp(0, 1);
          output.add(previous + (current - previous) * t.toDouble());
        }
      }
      if (currentInside) output.add(current);
      previous = current;
      previousDepth = currentDepth;
    }
    return output.map(project).whereType<_Projected>().toList(growable: false);
  }
}

bool _finiteOffset(Offset value) => value.dx.isFinite && value.dy.isFinite;
