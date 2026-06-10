import 'package:flutter/material.dart';

import '../../services/error_counter.dart';
import '../../services/perf_metrics.dart';

/// Compact metrics bar shown on the stress screens: dump/reset buttons and a
/// live MissingPluginException counter. All elements carry [ValueKey]s so the
/// harness can be driven via Marionette.
class PerfHud extends StatelessWidget {
  const PerfHud({required this.dumpLabel, super.key});

  /// Label included in the `PERF_METRICS:` dump for this screen/scenario.
  final String dumpLabel;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black87,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: ErrorCounter.instance.missingPluginCount,
              builder: (context, count, _) => Text(
                'MPE: $count',
                key: const ValueKey('mpe_counter'),
                style: TextStyle(
                  color: count == 0 ? Colors.greenAccent : Colors.redAccent,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Spacer(),
            TextButton(
              key: const ValueKey('perf_reset_metrics'),
              onPressed: PerfMetrics.instance.reset,
              child: const Text('Reset'),
            ),
            TextButton(
              key: const ValueKey('perf_dump_metrics'),
              onPressed: () {
                final stats = PerfMetrics.instance.dump(label: dumpLabel);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Dumped ${stats['frames']} frames to log'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: const Text('Dump'),
            ),
          ],
        ),
      ),
    );
  }
}
