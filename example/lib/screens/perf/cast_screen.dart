import 'dart:async';

import 'package:better_native_video_player/cast.dart';
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
  Timer? _statusPoll;
  String _status = 'idle — scan to find devices';
  String _sessionStatus = '-';
  bool _scanning = false;
  bool _looping = false;

  /// While the user drags the seek slider, show the drag position instead
  /// of the (still updating) receiver position.
  double? _dragPositionSeconds;

  /// After a seek, hold the slider at the target until the receiver
  /// confirms (statuses sent before the SEEK landed still carry the old
  /// position and would briefly snap the slider back).
  double? _pendingSeekSeconds;
  Timer? _pendingSeekClear;

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

  /// Tap on a device: connect AND start the demo video right away, so the
  /// controls below drive a live playback session on the receiver.
  Future<void> _connect(CastDevice device) async {
    setState(() => _status = 'connecting to ${device.displayName}…');
    try {
      final session = await CastSession.connect(device);
      // Be polite to whoever is near the TV: start quiet.
      await session.setVolume(0.15);
      _statusSub = session.statusStream.listen((status) {
        if (!mounted) return;
        setState(() {
          _sessionStatus = status.toString();
          final pending = _pendingSeekSeconds;
          if (pending != null &&
              (status.position.inSeconds - pending).abs() <= 2) {
            _pendingSeekSeconds = null; // receiver caught up with the seek
          }
        });
      });
      if (!mounted) {
        await session.close();
        return;
      }
      setState(() {
        _session = session;
        _status = 'connected: ${device.displayName} — loading video…';
      });
      await _load(session);
      // Receivers only push MEDIA_STATUS on state CHANGES; poll while
      // connected so the position slider tracks playback continuously.
      _statusPoll = Timer.periodic(const Duration(seconds: 1), (_) {
        unawaited(_session?.requestStatus());
      });
      if (mounted) setState(() => _status = 'playing on ${device.displayName}');
    } catch (e) {
      if (mounted) setState(() => _status = 'connect failed: $e');
    }
  }

  Future<void> _load(CastSession session) async {
    await session.loadMedia(
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

  Future<void> _disconnect() async {
    _statusPoll?.cancel();
    _statusPoll = null;
    _pendingSeekClear?.cancel();
    _pendingSeekSeconds = null;
    await _statusSub?.cancel();
    _statusSub = null;
    await _session?.close();
    if (mounted) {
      setState(() {
        _session = null;
        _sessionStatus = '-';
        _status = 'disconnected';
      });
    }
  }

  String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _statusPoll?.cancel();
    _pendingSeekClear?.cancel();
    unawaited(_statusSub?.cancel());
    unawaited(_session?.close());
    super.dispose();
  }

  /// Position slider + time labels; dragging seeks the receiver.
  Widget _buildSeekRow(CastSession session) {
    final position = session.status.position.inSeconds.toDouble();
    final duration = (session.status.duration?.inSeconds ?? 0).toDouble();
    final hasDuration = duration > 0;
    final value = (_dragPositionSeconds ?? _pendingSeekSeconds ?? position)
        .clamp(0.0, hasDuration ? duration : position);
    return Row(
      children: [
        Text(_fmt(Duration(seconds: value.round()))),
        Expanded(
          child: Slider(
            key: const ValueKey('cast_seek_slider'),
            value: value,
            max: hasDuration ? duration : (position > 0 ? position : 1),
            onChanged: hasDuration
                ? (v) => setState(() => _dragPositionSeconds = v)
                : null,
            onChangeEnd: (v) {
              // Seeking AT the duration makes the receiver finish the
              // stream (IDLE + position 0); stop just short of the end.
              final target = hasDuration ? v.clamp(0.0, duration - 1) : v;
              setState(() {
                _dragPositionSeconds = null;
                _pendingSeekSeconds = target;
              });
              _pendingSeekClear?.cancel();
              _pendingSeekClear = Timer(const Duration(seconds: 4), () {
                if (mounted) setState(() => _pendingSeekSeconds = null);
              });
              unawaited(session.seek(Duration(seconds: target.round())));
            },
          ),
        ),
        Text(hasDuration ? _fmt(Duration(seconds: duration.round())) : '--:--'),
      ],
    );
  }

  /// -15s / play-pause / +15s, mirroring the receiver's reported state.
  Widget _buildTransportRow(CastSession session) {
    final isPlaying = session.status.isPlaying;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          key: const ValueKey('cast_seek_back'),
          iconSize: 36,
          icon: const Icon(Icons.replay_10),
          onPressed: () => session.seek(
            session.status.position - const Duration(seconds: 15),
          ),
        ),
        IconButton(
          key: ValueKey(isPlaying ? 'cast_pause' : 'cast_play'),
          iconSize: 56,
          icon: Icon(
            isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
          ),
          onPressed: isPlaying ? session.pause : session.play,
        ),
        IconButton(
          key: const ValueKey('cast_seek_fwd'),
          iconSize: 36,
          icon: const Icon(Icons.forward_10),
          onPressed: () => session.seek(
            session.status.position + const Duration(seconds: 15),
          ),
        ),
      ],
    );
  }

  /// Receiver volume slider with step buttons (kept for the MCP harness).
  Widget _buildVolumeRow(CastSession session) {
    final volume = session.status.volumeLevel.clamp(0.0, 1.0);
    return Row(
      children: [
        IconButton(
          key: const ValueKey('cast_vol_down'),
          icon: const Icon(Icons.volume_down),
          onPressed: () => session.setVolume(volume - 0.05),
        ),
        Expanded(
          child: Slider(
            key: const ValueKey('cast_volume_slider'),
            value: volume,
            onChanged: (v) => unawaited(session.setVolume(v)),
          ),
        ),
        IconButton(
          key: const ValueKey('cast_vol_up'),
          icon: const Icon(Icons.volume_up),
          onPressed: () => session.setVolume(volume + 0.05),
        ),
        Text('${(volume * 100).round()}%'),
      ],
    );
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
            _buildSeekRow(session),
            _buildTransportRow(session),
            _buildVolumeRow(session),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  key: const ValueKey('cast_load'),
                  onPressed: () => _load(session),
                  child: const Text('Reload video + captions'),
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
                  onPressed: _disconnect,
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
