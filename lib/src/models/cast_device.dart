import 'package:flutter/foundation.dart';

/// A Google Cast (Chromecast) receiver found on the local network.
///
/// Discovery-only: the plugin lists devices so apps can show a picker; the
/// cast session itself (CASTV2 protocol, LOAD messages) stays app-side —
/// e.g. via the `cast` package — see HUDDLE_FINDINGS.md for the protocol
/// guidance (subtitle tracks, media-controls routing).
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
