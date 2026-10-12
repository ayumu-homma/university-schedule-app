import 'dart:math' as math;
import 'dart:ui';

/// Test-only raw engine frame accounting. A callback may contain several
/// frames; each frame is deduplicated and counted separately.
Map<String, Object?> summarizeSpatialFrames({
  required Iterable<FrameTiming> frames,
  required int? startFrameNumber,
  required int? endFrameNumber,
  required int? startPresentationMicros,
  required int? endPresentationMicros,
  required int elapsedMicros,
}) {
  final collected = frames.toList();
  final validIds = startFrameNumber != null &&
      endFrameNumber != null &&
      startFrameNumber >= 0 &&
      endFrameNumber > startFrameNumber &&
      collected.every((frame) => frame.frameNumber >= 0);
  final unique = <int, FrameTiming>{};
  if (validIds) {
    for (final frame in collected) {
      if (frame.frameNumber <= startFrameNumber ||
          frame.frameNumber > endFrameNumber) {
        continue;
      }
      unique.putIfAbsent(frame.frameNumber, () => frame);
    }
  }
  final samples = unique.values.toList()
    ..sort((a, b) => a.frameNumber.compareTo(b.frameNumber));
  return {
    'status': samples.isEmpty ? 'NOT_MEASURED' : 'MEASURED',
    'window_membership': 'startFrameNumber < frameNumber <= endFrameNumber',
    if (!validIds) 'unmeasured_reason': 'frame_ids_unavailable_or_invalid',
    'sample_count': samples.length,
    'scenario_elapsed_ms': elapsedMicros / 1000,
    'window_start_frame_number': startFrameNumber,
    'window_end_frame_number': endFrameNumber,
    // Presentation timestamps are metadata, not FrameTiming.vsyncStart.
    'window_start_presentation_us': startPresentationMicros,
    'window_end_presentation_us': endPresentationMicros,
    'build_ms': _statistics(samples.map((frame) => frame.buildDuration)),
    'raster_ms': _statistics(samples.map((frame) => frame.rasterDuration)),
    'total_span_ms': _statistics(samples.map((frame) => frame.totalSpan)),
    'frames': [
      for (final frame in samples)
        {
          'frame_number': frame.frameNumber,
          'vsync_us': frame.timestampInMicroseconds(FramePhase.vsyncStart),
          'build_us': frame.buildDuration.inMicroseconds,
          'raster_us': frame.rasterDuration.inMicroseconds,
          'total_span_us': frame.totalSpan.inMicroseconds,
        },
    ],
  };
}

Map<String, double>? _statistics(Iterable<Duration> durations) {
  final values = durations
      .map((duration) => duration.inMicroseconds / 1000)
      .toList()
    ..sort();
  if (values.isEmpty) return null;
  return {
    'mean': values.reduce((a, b) => a + b) / values.length,
    'p90_nearest_rank': values[math.max(0, (values.length * 0.9).ceil() - 1)],
    'max': values.last,
  };
}
