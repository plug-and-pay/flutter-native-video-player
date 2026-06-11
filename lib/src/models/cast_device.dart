import 'package:flutter/foundation.dart';

/// Thrown when the mDNS scan cannot reach the local network — on real iOS
/// devices this almost always means cellular-only connectivity or a denied
/// Local Network permission rather than "no Cast devices nearby".
class CastDiscoveryException implements Exception {
  const CastDiscoveryException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'CastDiscoveryException: $message';
}

/// A Google Cast (Chromecast) receiver found on the local network.
///
/// Returned by `CastDeviceDiscovery.discover()`; pass it to
/// `CastSession.connect()` to start controlling the receiver.
@immutable
class CastDevice {
  const CastDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    this.friendlyName,
    this.model,
  });

  /// mDNS service instance (unique per device on the network).
  final String id;

  /// Service instance name (often a device identifier).
  final String name;

  /// Human-readable name from the TXT record's `fn` entry ("Living room
  /// TV") — show this in pickers when present.
  final String? friendlyName;

  /// Device model from the TXT record's `md` entry ("Chromecast Ultra").
  final String? model;

  /// IP/hostname to connect to (CASTV2 uses TLS on [port], usually 8009).
  final String host;
  final int port;

  /// Best display label for a picker.
  String get displayName => friendlyName ?? name;

  @override
  String toString() => 'CastDevice($displayName at $host:$port)';
}
