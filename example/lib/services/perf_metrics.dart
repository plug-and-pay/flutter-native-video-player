import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Collects frame timings and time-to-first-frame measurements for the
/// performance harness.
///
/// Results are dumped as single-line JSON prefixed with `PERF_METRICS:` /
/// `PERF_TTFF:` so they can be collected from the device logs (e.g. via the
/// Marionette MCP `get_logs` tool) and compared across runs.
class PerfMetrics {
  PerfMetrics._();

  static final PerfMetrics instance = PerfMetrics._();

  static const int _maxSamples = 5000;

  final List<FrameTiming> _timings = <FrameTiming>[];
  final Map<int, Stopwatch> _ttffWatches = <int, Stopwatch>{};
  final Map<int, int> _ttffResults = <int, int>{};
  bool _installed = false;

  /// Number of frame samples currently buffered.
  int get sampleCount => _timings.length;

  /// Starts collecting frame timings. Safe to call multiple times.
  void install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    _timings.addAll(timings);
    if (_timings.length > _maxSamples) {
      _timings.removeRange(0, _timings.length - _maxSamples);
    }
  }

  /// Clears all buffered frame samples and TTFF results.
  void reset() {
    _timings.clear();
    _ttffWatches.clear();
    _ttffResults.clear();
    debugPrint('PERF_METRICS_RESET');
  }

  /// Marks the moment `load()` is called for [controllerId].
  void markLoadStart(int controllerId) {
    _ttffWatches[controllerId] = Stopwatch()..start();
  }

  /// Marks the first `playing`/`timeUpdated` signal for [controllerId] and
  /// logs the elapsed time-to-first-frame once.
  void markFirstFrame(int controllerId) {
    final watch = _ttffWatches.remove(controllerId);
    if (watch == null) return;
    watch.stop();
    _ttffResults[controllerId] = watch.elapsedMilliseconds;
    debugPrint(
      'PERF_TTFF:${jsonEncode(<String, Object>{'id': controllerId, 'ms': watch.elapsedMilliseconds})}',
    );
  }

  /// Computes statistics over the buffered samples and logs them as a single
  /// JSON line. Returns the stats for in-app display.
  Map<String, Object> dump({String label = ''}) {
    final buildMs = _timings
        .map((t) => t.buildDuration.inMicroseconds / 1000.0)
        .toList(growable: false);
    final rasterMs = _timings
        .map((t) => t.rasterDuration.inMicroseconds / 1000.0)
        .toList(growable: false);
    final totalMs = _timings
        .map((t) => t.totalSpan.inMicroseconds / 1000.0)
        .toList(growable: false);

    final stats = <String, Object>{
      'label': label,
      'frames': _timings.length,
      'build': _stats(buildMs),
      'raster': _stats(rasterMs),
      'total': _stats(totalMs),
      'jank16': totalMs.where((ms) => ms > 16.7).length,
      'jank33': totalMs.where((ms) => ms > 33.4).length,
      'ttff': Map<String, int>.fromEntries(
        _ttffResults.entries.map((e) => MapEntry('${e.key}', e.value)),
      ),
    };
    debugPrint('PERF_METRICS:${jsonEncode(stats)}');
    return stats;
  }

  Map<String, Object> _stats(List<double> values) {
    if (values.isEmpty) {
      return <String, Object>{'avg': 0, 'p90': 0, 'p99': 0, 'max': 0};
    }
    final sorted = List<double>.of(values)..sort();
    double percentile(double p) =>
        sorted[((sorted.length - 1) * p).round().clamp(0, sorted.length - 1)];
    final avg = sorted.reduce((a, b) => a + b) / sorted.length;
    return <String, Object>{
      'avg': double.parse(avg.toStringAsFixed(2)),
      'p90': double.parse(percentile(0.90).toStringAsFixed(2)),
      'p99': double.parse(percentile(0.99).toStringAsFixed(2)),
      'max': double.parse(sorted.last.toStringAsFixed(2)),
    };
  }
}
