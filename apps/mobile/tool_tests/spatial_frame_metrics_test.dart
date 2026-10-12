import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/spatial_frame_metrics.dart';

void main() {
  FrameTiming sample(int id, int vsync, int build) => FrameTiming(
        vsyncStart: vsync,
        buildStart: vsync + 100,
        buildFinish: vsync + 100 + build,
        rasterStart: vsync + 200 + build,
        rasterFinish: vsync + 400 + build,
        rasterFinishWallTime: vsync + 400 + build,
        frameNumber: id,
      );

  test(
      'uses frame identity despite presentation-vsync offset; counts each once',
      () {
    final first = sample(11, 1000, 1000);
    final output = summarizeSpatialFrames(
      frames: [
        sample(9, 500, 9000),
        sample(10, 700, 9000),
        first,
        first,
        sample(12, 2000, 3000),
        sample(13, 3000, 9000)
      ],
      startFrameNumber: 10,
      endFrameNumber: 12,
      startPresentationMicros: 10000,
      endPresentationMicros: 20000,
      elapsedMicros: 50000,
    );
    expect(output['status'], 'MEASURED');
    expect(output['sample_count'], 2);
    expect(output['scenario_elapsed_ms'], 50);
    expect(
        output['build_ms'], {'mean': 2.0, 'p90_nearest_rank': 3.0, 'max': 3.0});
    expect((output['frames'] as List).length, 2);
  });

  test('unavailable frame timings retain unknown statistics', () {
    final output = summarizeSpatialFrames(
      frames: const [],
      startFrameNumber: 10,
      endFrameNumber: 20,
      startPresentationMicros: 10000,
      endPresentationMicros: 20000,
      elapsedMicros: 500,
    );
    expect(output['status'], 'NOT_MEASURED');
    expect(output['sample_count'], 0);
    expect(output['build_ms'], isNull);
    expect(output['raster_ms'], isNull);
    expect(output['total_span_ms'], isNull);
  });

  test('missing frame identifiers never fall back to timestamp membership', () {
    for (final start in [null, -1, 20]) {
      final output = summarizeSpatialFrames(
        frames: [sample(11, 15000, 1000)],
        startFrameNumber: start,
        endFrameNumber: 20,
        startPresentationMicros: 10000,
        endPresentationMicros: 20000,
        elapsedMicros: 500,
      );
      expect(output['status'], 'NOT_MEASURED');
      expect(output['sample_count'], 0);
      expect(output['build_ms'], isNull);
      expect(output['unmeasured_reason'], 'frame_ids_unavailable_or_invalid');
    }
  });
}
