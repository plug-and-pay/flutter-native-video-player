import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/cast_device.dart';
import 'cast_protocol.dart';

/// State pushed by the receiver (also when changed from the TV remote or
/// another sender) — listen to [CastSession.statusStream] to keep app UI
/// in sync.
@immutable
class CastSessionStatus {
  const CastSessionStatus({
    this.playerState = 'IDLE',
    this.position = Duration.zero,
    this.duration,
    this.volumeLevel = 1.0,
    this.muted = false,
    this.activeTrackIds = const <int>[],
    this.idleReason,
  });

  /// IDLE / BUFFERING / PLAYING / PAUSED (receiver vocabulary).
  final String playerState;
  final Duration position;
  final Duration? duration;

  /// Receiver volume 0..1.
  final double volumeLevel;
  final bool muted;

  /// Currently active media tracks (e.g. enabled caption track ids).
  final List<int> activeTrackIds;

  /// FINISHED / CANCELLED / ERROR when [playerState] is IDLE.
  final String? idleReason;

  bool get isPlaying => playerState == 'PLAYING';

  CastSessionStatus copyWith({
    String? playerState,
    Duration? position,
    Duration? duration,
    double? volumeLevel,
    bool? muted,
    List<int>? activeTrackIds,
    String? idleReason,
  }) => CastSessionStatus(
    playerState: playerState ?? this.playerState,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    volumeLevel: volumeLevel ?? this.volumeLevel,
    muted: muted ?? this.muted,
    activeTrackIds: activeTrackIds ?? this.activeTrackIds,
    idleReason: idleReason,
  );

  @override
  String toString() =>
      'CastSessionStatus($playerState'
      '${idleReason == null ? '' : '($idleReason)'} ${position.inSeconds}s'
      '${duration == null ? '' : '/${duration!.inSeconds}s'} '
      'vol ${(volumeLevel * 100).round()}% tracks $activeTrackIds)';
}

/// A sidecar text track for the receiver (same VTT files as the plugin's
/// sidecar subtitles — the receiver fetches the URL itself, so it must be
/// HTTPS and CORS-readable).
@immutable
class CastTextTrack {
  const CastTextTrack({
    required this.trackId,
    required this.url,
    required this.language,
    this.name,
    this.contentType = 'text/vtt',
  });

  final int trackId;
  final String url;
  final String language;
  final String? name;
  final String contentType;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'trackId': trackId,
    'type': 'TEXT',
    'subtype': 'SUBTITLES',
    'trackContentId': url,
    'trackContentType': contentType,
    'language': language,
    if (name != null) 'name': name,
  };
}

/// A live connection to one Chromecast: launches the default media
/// receiver and exposes full transport control — load (with metadata and
/// caption tracks), play/pause/seek/stop, volume/mute, caption switching,
/// loop — plus [statusStream] so the app reacts to receiver-side changes.
///
/// Pure Dart (CASTV2 over TLS, hand-framed protobuf — see
/// cast_protocol.dart). No Cast SDK, works from any isolate with dart:io.
class CastSession {
  CastSession._(this.device, this._socket);

  /// Default media receiver app.
  static const String _appId = 'CC1AD845';
  static const String _nsConnection =
      'urn:x-cast:com.google.cast.tp.connection';
  static const String _nsHeartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const String _nsReceiver = 'urn:x-cast:com.google.cast.receiver';
  static const String _nsMedia = 'urn:x-cast:com.google.cast.media';

  final CastDevice device;
  final SecureSocket _socket;
  final CastFrameBuffer _frames = CastFrameBuffer();
  final StreamController<CastSessionStatus> _status =
      StreamController<CastSessionStatus>.broadcast();

  CastSessionStatus _lastStatus = const CastSessionStatus();
  int _requestId = 0;
  String? _transportId;
  int? _mediaSessionId;
  Timer? _heartbeat;
  bool _closed = false;
  bool _looping = false;
  Map<String, dynamic>? _lastLoadPayload;
  Completer<void>? _launched;

  /// Receiver state updates; also fires for changes made on the TV or by
  /// other senders.
  Stream<CastSessionStatus> get statusStream => _status.stream;

  /// Most recent known status.
  CastSessionStatus get status => _lastStatus;

  bool get isConnected => !_closed;

  /// Connects, launches the media receiver app, and starts heartbeats.
  static Future<CastSession> connect(
    CastDevice device, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final socket = await SecureSocket.connect(
      device.host,
      device.port,
      timeout: timeout,
      // Cast devices use self-signed certificates by design.
      onBadCertificate: (_) => true,
    );
    final session = CastSession._(device, socket);
    session._start();
    session._send(_nsConnection, 'receiver-0', {'type': 'CONNECT'});
    session._launched = Completer<void>();
    session._send(_nsReceiver, 'receiver-0', {
      'type': 'LAUNCH',
      'appId': _appId,
      'requestId': session._nextRequestId(),
    });
    await session._launched!.future.timeout(timeout);
    return session;
  }

  void _start() {
    _socket.listen(
      (chunk) {
        for (final message in _frames.addChunk(chunk)) {
          _handle(message);
        }
      },
      onError: (Object _) => _shutdown(),
      onDone: _shutdown,
    );
    _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
      _send(_nsHeartbeat, 'receiver-0', {'type': 'PING'});
    });
  }

  int _nextRequestId() => ++_requestId;

  void _send(String namespace, String destination, Map<String, dynamic> data) {
    if (_closed) return;
    _socket.add(
      CastProtocolCodec.encodeFrame(
        CastChannelMessage(
          sourceId: 'sender-0',
          destinationId: destination,
          namespace: namespace,
          payload: jsonEncode(data),
        ),
      ),
    );
  }

  void _sendMedia(Map<String, dynamic> data) {
    final transport = _transportId;
    if (transport == null) return;
    _send(_nsMedia, transport, data);
  }

  void _handle(CastChannelMessage message) {
    final Map<String, dynamic> data;
    try {
      data = message.payloadJson;
    } catch (_) {
      return;
    }
    switch (data['type']) {
      case 'PING':
        _send(_nsHeartbeat, message.sourceId, {'type': 'PONG'});
      case 'RECEIVER_STATUS':
        _onReceiverStatus(data);
      case 'MEDIA_STATUS':
        _onMediaStatus(data);
      case 'CLOSE':
        _shutdown();
      case 'LAUNCH_ERROR':
        _launched?.completeError(
          StateError('Cast LAUNCH_ERROR: ${data['reason']}'),
        );
    }
  }

  void _onReceiverStatus(Map<String, dynamic> data) {
    final receiverStatus = data['status'] as Map<String, dynamic>? ?? const {};
    final volume = receiverStatus['volume'] as Map<String, dynamic>?;
    if (volume != null) {
      _emit(
        _lastStatus.copyWith(
          volumeLevel: (volume['level'] as num?)?.toDouble(),
          muted: volume['muted'] as bool?,
          idleReason: _lastStatus.idleReason,
        ),
      );
    }
    final apps = receiverStatus['applications'] as List?;
    final app = apps
        ?.cast<Map<String, dynamic>>()
        .where((a) => a['appId'] == _appId)
        .firstOrNull;
    if (app != null && _transportId == null) {
      _transportId = app['transportId'] as String;
      _send(_nsConnection, _transportId!, {'type': 'CONNECT'});
      if (!(_launched?.isCompleted ?? true)) _launched?.complete();
      // Ask for an initial media status so streams settle.
      _sendMedia({'type': 'GET_STATUS', 'requestId': _nextRequestId()});
    }
  }

  void _onMediaStatus(Map<String, dynamic> data) {
    final statuses = (data['status'] as List?)?.cast<Map<String, dynamic>>();
    if (statuses == null || statuses.isEmpty) return;
    final s = statuses.first;
    _mediaSessionId = (s['mediaSessionId'] as num?)?.toInt() ?? _mediaSessionId;
    final media = s['media'] as Map<String, dynamic>?;
    final durationSeconds = (media?['duration'] as num?)?.toDouble();
    final playerState = s['playerState'] as String? ?? _lastStatus.playerState;
    final idleReason = s['idleReason'] as String?;
    // Receivers omit currentTime from some status pushes (e.g. track edits);
    // treat "absent" as "unchanged", NOT as position zero.
    final currentTimeSeconds = (s['currentTime'] as num?)?.toDouble();

    _emit(
      _lastStatus.copyWith(
        playerState: playerState,
        position: currentTimeSeconds == null
            ? _lastStatus.position
            : Duration(milliseconds: (currentTimeSeconds * 1000).round()),
        duration: durationSeconds == null
            ? _lastStatus.duration
            : Duration(milliseconds: (durationSeconds * 1000).round()),
        activeTrackIds:
            (s['activeTrackIds'] as List?)
                ?.cast<num>()
                .map((n) => n.toInt())
                .toList() ??
            _lastStatus.activeTrackIds,
        idleReason: idleReason,
      ),
    );

    // Client-side loop: replay when the receiver reports a natural finish.
    if (_looping &&
        playerState == 'IDLE' &&
        idleReason == 'FINISHED' &&
        _lastLoadPayload != null) {
      final replay = Map<String, dynamic>.from(_lastLoadPayload!);
      replay['requestId'] = _nextRequestId();
      replay['currentTime'] = 0;
      _sendMedia(replay);
    }
  }

  void _emit(CastSessionStatus next) {
    _lastStatus = next;
    if (!_status.isClosed) _status.add(next);
  }

  /// Loads media on the receiver — with Now-Playing-style metadata and
  /// optional caption tracks (enable via [activeTrackIds] here or
  /// [setActiveTracks] later).
  Future<void> loadMedia({
    required String contentUrl,
    String contentType = 'video/mp4',
    String streamType = 'BUFFERED',
    String? title,
    String? subtitle,
    String? imageUrl,
    List<CastTextTrack> textTracks = const <CastTextTrack>[],
    List<int> activeTrackIds = const <int>[],
    bool autoplay = true,
    Duration startAt = Duration.zero,
  }) async {
    final payload = <String, dynamic>{
      'type': 'LOAD',
      'requestId': _nextRequestId(),
      'autoplay': autoplay,
      'currentTime': startAt.inMilliseconds / 1000,
      if (activeTrackIds.isNotEmpty) 'activeTrackIds': activeTrackIds,
      'media': <String, dynamic>{
        'contentId': contentUrl,
        'contentType': contentType,
        'streamType': streamType,
        if (textTracks.isNotEmpty)
          'tracks': textTracks.map((t) => t.toJson()).toList(),
        if (textTracks.isNotEmpty)
          'textTrackStyle': <String, dynamic>{'fontScale': 1.0},
        if (title != null || subtitle != null || imageUrl != null)
          'metadata': <String, dynamic>{
            'metadataType': 0, // GENERIC
            if (title != null) 'title': title,
            if (subtitle != null) 'subtitle': subtitle,
            if (imageUrl != null)
              'images': <Map<String, dynamic>>[
                {'url': imageUrl},
              ],
          },
      },
    };
    _lastLoadPayload = payload;
    _sendMedia(payload);
  }

  Map<String, dynamic> _mediaCommand(String type) => <String, dynamic>{
    'type': type,
    'requestId': _nextRequestId(),
    if (_mediaSessionId != null) 'mediaSessionId': _mediaSessionId,
  };

  Future<void> play() async => _sendMedia(_mediaCommand('PLAY'));

  Future<void> pause() async => _sendMedia(_mediaCommand('PAUSE'));

  Future<void> stop() async => _sendMedia(_mediaCommand('STOP'));

  Future<void> seek(Duration position) async => _sendMedia(
    _mediaCommand('SEEK')..['currentTime'] = position.inMilliseconds / 1000,
  );

  /// Receiver volume 0..1 (the TV/speaker volume for this device).
  Future<void> setVolume(double level) async =>
      _send(_nsReceiver, 'receiver-0', {
        'type': 'SET_VOLUME',
        'requestId': _nextRequestId(),
        'volume': {'level': level.clamp(0.0, 1.0)},
      });

  Future<void> setMuted(bool muted) async => _send(_nsReceiver, 'receiver-0', {
    'type': 'SET_VOLUME',
    'requestId': _nextRequestId(),
    'volume': {'muted': muted},
  });

  /// Enables/disables caption tracks ([] turns captions off).
  Future<void> setActiveTracks(List<int> trackIds) async => _sendMedia(
    _mediaCommand('EDIT_TRACKS_INFO')..['activeTrackIds'] = trackIds,
  );

  /// Replay the loaded media when it finishes (client-side loop — the
  /// default receiver has no single-item repeat).
  // ignore: avoid_positional_boolean_parameters
  void setLooping(bool looping) => _looping = looping;

  /// Asks the receiver to push a fresh MEDIA_STATUS.
  Future<void> requestStatus() async =>
      _sendMedia({'type': 'GET_STATUS', 'requestId': _nextRequestId()});

  Future<void> close() async {
    if (_closed) return;
    final transport = _transportId;
    if (transport != null) {
      _send(_nsConnection, transport, {'type': 'CLOSE'});
    }
    _send(_nsConnection, 'receiver-0', {'type': 'CLOSE'});
    _shutdown();
  }

  void _shutdown() {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    _socket.destroy();
    _status.close();
  }
}
