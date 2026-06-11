import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

/// Demo + Marionette harness for the plugin's Chromecast support:
/// discovery, connect, load with metadata + captions, full transport
/// control, and a live status readout fed by the receiver's MEDIA_STATUS
/// pushes — so changes made ON the Chromecast show up here too.
class CastScreen extends StatefulWidget {
  const CastScreen({super.key});

  // Receivers must be able to FETCH these themselves (HTTPS or LAN HTTP,
  // CORS required for caption tracks). Google's gtv-videos-bucket samples
  // are the usual choice, but this network blocks googleapis — so the
  // harness serves Sintel + a VTT from the dev Mac with CORS headers
  // (python serve.py in /tmp/cast_media, port 8123).
  static const String mediaUrl = 'http://192.168.1.31:8123/trailer.mp4';
  static const String captionsUrl = 'http://192.168.1.31:8123/sample_en.vtt';
  static const String posterUrl =
      'https://i.vimeocdn.com/video/452001751-8216e0571c251a09d7a8387550942d89f7f86f6398f8ed886e639b0dd50d3c90-d';

  @override
  State<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends State<CastScreen> {
  List<CastDevice> _devices = const [];
  CastSession? _session;
  StreamSubscription<CastSessionStatus>? _statusSub;
  String _status = 'idle — scan to find devices';
  String _sessionStatus = '-';
  bool _scanning = false;
  bool _looping = false;

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _status = 'scanning…';
    });
    try {
      final devices = await CastDeviceDiscovery.discover();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _status = '${devices.length} device(s) found';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _connect(CastDevice device) async {
    setState(() => _status = 'connecting to ${device.displayName}…');
    try {
      final session = await CastSession.connect(device);
      // Be polite to whoever is near the TV: start quiet.
      await session.setVolume(0.15);
      _statusSub = session.statusStream.listen((status) {
        if (mounted) setState(() => _sessionStatus = status.toString());
      });
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _status = 'connected: ${device.displayName}';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'connect failed: $e');
    }
  }

  Future<void> _load() async {
    await _session?.loadMedia(
      contentUrl: CastScreen.mediaUrl,
      title: 'Designing for Google Cast',
      subtitle: 'better_native_video_player demo',
      imageUrl: CastScreen.posterUrl,
      textTracks: const [
        CastTextTrack(
          trackId: 1,
          url: CastScreen.captionsUrl,
          language: 'en',
          name: 'English',
        ),
      ],
    );
  }

  @override
  void dispose() {
    unawaited(_statusSub?.cancel());
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: const Text('Chromecast')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, key: const ValueKey('cast_status')),
          const SizedBox(height: 8),
          ElevatedButton(
            key: const ValueKey('cast_scan'),
            onPressed: _scanning ? null : _scan,
            child: Text(_scanning ? 'Scanning…' : 'Scan for devices'),
          ),
          Text(
            'devices: ${_devices.length}',
            key: const ValueKey('cast_device_count'),
          ),
          for (var i = 0; i < _devices.length; i++)
            ListTile(
              key: ValueKey('cast_device_$i'),
              title: Text(_devices[i].displayName),
              subtitle: Text(
                '${_devices[i].model ?? 'Cast device'} — '
                '${_devices[i].host}:${_devices[i].port}',
              ),
              trailing: const Icon(Icons.cast),
              onTap: () => _connect(_devices[i]),
            ),
          if (session != null) ...[
            const Divider(),
            Text(
              _sessionStatus,
              key: const ValueKey('cast_session_status'),
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  key: const ValueKey('cast_load'),
                  onPressed: _load,
                  child: const Text('Load video + captions'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_play'),
                  onPressed: session.play,
                  child: const Text('Play'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_pause'),
                  onPressed: session.pause,
                  child: const Text('Pause'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_seek_fwd'),
                  onPressed: () => session.seek(
                    session.status.position + const Duration(seconds: 15),
                  ),
                  child: const Text('+15s'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_vol_down'),
                  onPressed: () =>
                      session.setVolume(session.status.volumeLevel - 0.05),
                  child: const Text('Vol -'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_vol_up'),
                  onPressed: () =>
                      session.setVolume(session.status.volumeLevel + 0.05),
                  child: const Text('Vol +'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_captions_on'),
                  onPressed: () => session.setActiveTracks(const [1]),
                  child: const Text('Captions ON'),
                ),
                ElevatedButton(
                  key: const ValueKey('cast_captions_off'),
                  onPressed: () => session.setActiveTracks(const []),
                  child: const Text('Captions OFF'),
                ),
                FilterChip(
                  key: const ValueKey('cast_loop'),
                  label: const Text('Loop'),
                  selected: _looping,
                  onSelected: (value) {
                    setState(() => _looping = value);
                    session.setLooping(value);
                  },
                ),
                ElevatedButton(
                  key: const ValueKey('cast_disconnect'),
                  onPressed: () async {
                    await session.close();
                    if (mounted) {
                      setState(() {
                        _session = null;
                        _sessionStatus = '-';
                        _status = 'disconnected';
                      });
                    }
                  },
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
