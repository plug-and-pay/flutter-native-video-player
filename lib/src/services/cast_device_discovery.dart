/// Conditional-import facade for [CastDeviceDiscovery] so the package
/// stays WASM-compatible (same pattern as platform_utils/subtitle_loader).
library;

export 'cast_device_discovery_stub.dart'
    if (dart.library.io) 'cast_device_discovery_io.dart';
