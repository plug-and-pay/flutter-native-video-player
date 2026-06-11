import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import '../models/cast_device.dart';

/// Discovers Google Cast (Chromecast) receivers on the local network via
/// mDNS (`_googlecast._tcp`). Pure Dart — no Cast SDK.
///
/// iOS 14+ real devices require Info.plist entries before the OS lets the
/// app send multicast queries:
///
/// ```xml
/// <key>NSLocalNetworkUsageDescription</key>
/// <string>Used to find Cast devices on your network.</string>
/// <key>NSBonjourServices</key>
/// <array><string>_googlecast._tcp</string></array>
/// ```
class CastDeviceDiscovery {
  CastDeviceDiscovery._();

  static const String _service = '_googlecast._tcp.local';

  /// One-shot scan; resolves after [timeout] with every device seen.
  static Future<List<CastDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = MDnsClient();
    final found = <String, CastDevice>{};
    await client.start();
    try {
      await for (final PtrResourceRecord ptr
          in client
              .lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer(_service),
              )
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
        final instance = ptr.domainName;

        String host = '';
        var port = 8009;
        await for (final SrvResourceRecord srv
            in client
                .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(instance),
                )
                .timeout(
                  const Duration(seconds: 2),
                  onTimeout: (sink) => sink.close(),
                )) {
          host = srv.target;
          port = srv.port;
          break;
        }
        if (host.isEmpty) continue;

        // Prefer a resolved IPv4 over the .local hostname when available.
        await for (final IPAddressResourceRecord ip
            in client
                .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(host),
                )
                .timeout(
                  const Duration(seconds: 2),
                  onTimeout: (sink) => sink.close(),
                )) {
          host = ip.address.address;
          break;
        }

        String? friendlyName;
        String? model;
        await for (final TxtResourceRecord txt
            in client
                .lookup<TxtResourceRecord>(ResourceRecordQuery.text(instance))
                .timeout(
                  const Duration(seconds: 2),
                  onTimeout: (sink) => sink.close(),
                )) {
          for (final line in txt.text.split('\n')) {
            final eq = line.indexOf('=');
            if (eq == -1) continue;
            final key = line.substring(0, eq).trim();
            final value = line.substring(eq + 1).trim();
            if (key == 'fn') friendlyName = value;
            if (key == 'md') model = value;
          }
          break;
        }

        final name = instance.endsWith('.$_service')
            ? instance.substring(0, instance.length - _service.length - 1)
            : instance;
        found[instance] = CastDevice(
          id: instance,
          name: name,
          friendlyName: friendlyName,
          model: model,
          host: host,
          port: port,
        );
      }
    } finally {
      client.stop();
    }
    return found.values.toList();
  }
}
