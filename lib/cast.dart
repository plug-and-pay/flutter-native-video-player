/// Chromecast support: device discovery (system Bonjour on iOS, pure-Dart
/// mDNS elsewhere) and a full CASTV2 session (load with metadata + caption
/// tracks, play/pause/seek/stop, volume/mute, caption switching, loop,
/// live status stream).
///
/// Deliberately a SEPARATE entrypoint from the main library:
/// `CastDevice`/`CastSession` are common names (the `cast` package uses
/// them too), so apps that mix libraries can import this one with a prefix:
///
/// ```dart
/// import 'package:better_native_video_player/cast.dart' as nvp_cast;
/// ```
library;

export 'src/models/cast_device.dart';
export 'src/services/cast/cast_session.dart';
export 'src/services/cast_device_discovery.dart';
