import '../models/cast_device.dart';

/// Web/WASM stub: mDNS discovery needs dart:io sockets.
class CastDeviceDiscovery {
  CastDeviceDiscovery._();

  static Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) => throw UnsupportedError(
    'CastDeviceDiscovery is not supported on this platform '
    '(requires dart:io).',
  );
}
