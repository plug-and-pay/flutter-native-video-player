import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Demo + Marionette harness for [VideoDownloadController]: download with
/// live progress, play the file offline, cancel, and remove.
class DownloadScreen extends StatefulWidget {
  const DownloadScreen({super.key});

  static const int controllerId = 9990;
  static const String videoId = 'sintel-trailer';
  static const String videoUrl =
      'https://media.w3.org/2010/05/sintel/trailer.mp4';

  @override
  State<DownloadScreen> createState() => _DownloadScreenState();
}

class _DownloadScreenState extends State<DownloadScreen> {
  late final NativeVideoPlayerController _player;
  VideoDownloadController? _downloads;
  StreamSubscription<VideoDownloadProgress>? _progressSub;

  String _status = 'initializing…';
  double? _fraction;
  String? _localPath;
  bool _playerVisible = false;

  @override
  void initState() {
    super.initState();
    _player = NativeVideoPlayerController(
      id: DownloadScreen.controllerId,
      autoPlay: true,
      lockToLandscape: false,
      showNativeControls: false,
    );
    unawaited(_init());
  }

  Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    _downloads = VideoDownloadController(
      directoryPath: '${docs.path}/video_downloads',
    );
    await _refresh();
  }

  Future<void> _refresh() async {
    final path = await _downloads!.localPathFor(DownloadScreen.videoId);
    if (!mounted) return;
    setState(() {
      _localPath = path;
      _status = path == null ? 'not downloaded' : 'downloaded';
      _fraction = path == null ? null : 1;
    });
  }

  void _start() {
    _progressSub?.cancel();
    _progressSub = _downloads!
        .download(id: DownloadScreen.videoId, url: DownloadScreen.videoUrl)
        .listen((progress) {
          if (!mounted) return;
          setState(() {
            _fraction = progress.fraction;
            _status = switch (progress.status) {
              VideoDownloadStatus.downloading =>
                'downloading ${progress.fraction == null ? '${progress.receivedBytes ~/ 1024} KB' : '${(progress.fraction! * 100).round()}%'}',
              VideoDownloadStatus.completed => 'downloaded',
              VideoDownloadStatus.failed => 'failed: ${progress.error}',
              VideoDownloadStatus.canceled => 'canceled',
            };
          });
          if (progress.status == VideoDownloadStatus.completed) {
            unawaited(_refresh());
          }
        });
  }

  Future<void> _play() async {
    final path = _localPath;
    if (path == null) return;
    setState(() => _playerVisible = true);
    // Give the platform view a beat to mount before loading into it.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _player.initialize();
    await _player.load(url: 'file://$path', force: true);
  }

  @override
  void dispose() {
    unawaited(_progressSub?.cancel());
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Downloads')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'status: $_status',
            key: const ValueKey('download_status'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _fraction),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                key: const ValueKey('download_start'),
                onPressed: _start,
                child: const Text('Download'),
              ),
              ElevatedButton(
                key: const ValueKey('download_cancel'),
                onPressed: () => _downloads?.cancel(DownloadScreen.videoId),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                key: const ValueKey('download_play'),
                onPressed: _localPath == null ? null : _play,
                child: const Text('Play offline'),
              ),
              ElevatedButton(
                key: const ValueKey('download_remove'),
                onPressed: () async {
                  await _downloads?.remove(DownloadScreen.videoId);
                  await _refresh();
                },
                child: const Text('Remove'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_playerVisible)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                color: Colors.black,
                child: NativeVideoPlayer(controller: _player),
              ),
            ),
        ],
      ),
    );
  }
}
