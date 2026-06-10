import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Counts MissingPluginException reports for the performance harness.
///
/// The plugin's controller-level EventChannel failure surfaces through
/// [FlutterError.reportError] (the services library catches the failed
/// `listen` internally), so a [FlutterError.onError] hook is the only way to
/// observe it. Each hit is logged as `PERF_MPE:{...}` for log scraping.
class ErrorCounter {
  ErrorCounter._();

  static final ErrorCounter instance = ErrorCounter._();

  /// Number of MissingPluginException reports observed since startup.
  final ValueNotifier<int> missingPluginCount = ValueNotifier<int>(0);

  bool _installed = false;

  /// Chains onto [FlutterError.onError]. Safe to call multiple times.
  void install() {
    if (_installed) return;
    _installed = true;
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exception is MissingPluginException ||
          details.exceptionAsString().contains('MissingPluginException')) {
        missingPluginCount.value++;
        final summary = details
            .exceptionAsString()
            .replaceAll('"', "'")
            .replaceAll('\n', ' ');
        debugPrint(
          'PERF_MPE:{"count":${missingPluginCount.value},"error":"$summary"}',
        );
      }
      previous?.call(details);
    };
  }

  void reset() => missingPluginCount.value = 0;
}
