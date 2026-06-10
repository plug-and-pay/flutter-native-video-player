import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:better_native_video_player/src/services/playback_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHandle implements PlayableHandle {
  FakeHandle(
    this.id, {
    this.isPipActive = false,
    this.isAirPlayConnected = false,
  });

  @override
  final int id;

  @override
  bool isPipActive;

  @override
  bool isAirPlayConnected;

  int pauseForCapCalls = 0;

  /// When set, pauseForCap synchronously reports the resulting paused
  /// transition back to the coordinator (re-entrancy simulation).
  PlaybackCoordinator? reportPauseTo;

  @override
  Future<void> pauseForCap() async {
    pauseForCapCalls++;
    reportPauseTo?.onStoppedPlaying(this);
  }
}

void main() {
  late PlaybackCoordinator coordinator;

  setUp(() {
    coordinator = PlaybackCoordinator.forTesting();
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
  });

  tearDown(() {
    NativeVideoPlayerConfig.global = const NativeVideoPlayerConfig();
  });

  void setCap(int? cap) {
    NativeVideoPlayerConfig.global = NativeVideoPlayerConfig(
      maxConcurrentPlayingPlayers: cap,
    );
  }

  test('no cap (default): never pauses anyone', () {
    final handles = List.generate(10, FakeHandle.new);
    for (final h in handles) {
      coordinator.onPlaying(h);
    }
    expect(coordinator.playingCount, 10);
    expect(handles.every((h) => h.pauseForCapCalls == 0), isTrue);
  });

  test('cap=2: least-recently-played is paused', () {
    setCap(2);
    final a = FakeHandle(1);
    final b = FakeHandle(2);
    final c = FakeHandle(3);
    coordinator
      ..onPlaying(a)
      ..onPlaying(b)
      ..onPlaying(c);

    expect(a.pauseForCapCalls, 1);
    expect(b.pauseForCapCalls, 0);
    expect(c.pauseForCapCalls, 0);
    expect(coordinator.playingCount, 2);
  });

  test('re-playing moves a handle to most-recently-played', () {
    setCap(2);
    final a = FakeHandle(1);
    final b = FakeHandle(2);
    final c = FakeHandle(3);
    coordinator
      ..onPlaying(a)
      ..onPlaying(b)
      ..onPlaying(a) // refresh A; LRU is now B
      ..onPlaying(c);

    expect(b.pauseForCapCalls, 1);
    expect(a.pauseForCapCalls, 0);
  });

  test('cap larger than playing count pauses nobody', () {
    setCap(4);
    final handles = List.generate(4, FakeHandle.new);
    for (final h in handles) {
      coordinator.onPlaying(h);
    }
    expect(handles.every((h) => h.pauseForCapCalls == 0), isTrue);
    expect(coordinator.playingCount, 4);
  });

  test('PiP players are exempt; next non-exempt is paused instead', () {
    setCap(2);
    final pip = FakeHandle(1, isPipActive: true);
    final b = FakeHandle(2);
    final c = FakeHandle(3);
    coordinator
      ..onPlaying(pip)
      ..onPlaying(b)
      ..onPlaying(c);

    expect(pip.pauseForCapCalls, 0);
    expect(b.pauseForCapCalls, 1);
  });

  test('AirPlay players are exempt', () {
    setCap(2);
    final airplay = FakeHandle(1, isAirPlayConnected: true);
    final b = FakeHandle(2);
    final c = FakeHandle(3);
    coordinator
      ..onPlaying(airplay)
      ..onPlaying(b)
      ..onPlaying(c);

    expect(airplay.pauseForCapCalls, 0);
    expect(b.pauseForCapCalls, 1);
  });

  test('soft cap: all candidates exempt -> nobody paused, cap exceeded', () {
    setCap(1);
    final pipA = FakeHandle(1, isPipActive: true);
    final airplayB = FakeHandle(2, isAirPlayConnected: true);
    coordinator
      ..onPlaying(pipA)
      ..onPlaying(airplayB);

    expect(pipA.pauseForCapCalls, 0);
    expect(airplayB.pauseForCapCalls, 0);
    expect(coordinator.playingCount, 2);
  });

  test('external pause removes from playing set without coordinator pause', () {
    setCap(2);
    final a = FakeHandle(1);
    final b = FakeHandle(2);
    final c = FakeHandle(3);
    coordinator
      ..onPlaying(a)
      ..onPlaying(b)
      ..onStoppedPlaying(a) // user paused A
      ..onPlaying(c);

    expect(a.pauseForCapCalls, 0);
    expect(b.pauseForCapCalls, 0);
    expect(coordinator.playingCount, 2);
  });

  test('unregister removes handle; no pause callbacks to dead handles', () {
    setCap(1);
    final a = FakeHandle(1);
    final b = FakeHandle(2);
    coordinator
      ..onPlaying(a)
      ..unregister(a)
      ..onPlaying(b);

    expect(a.pauseForCapCalls, 0);
    expect(coordinator.playingCount, 1);
  });

  test('runtime cap change enforced on next transition', () {
    setCap(4);
    final handles = List.generate(4, FakeHandle.new);
    for (final h in handles) {
      coordinator.onPlaying(h);
    }
    expect(coordinator.playingCount, 4);

    setCap(1);
    final e = FakeHandle(5);
    coordinator.onPlaying(e);

    // 5 playing, cap 1 -> 4 pauses, LRU-first; the new player keeps playing.
    expect(handles.every((h) => h.pauseForCapCalls == 1), isTrue);
    expect(e.pauseForCapCalls, 0);
    expect(coordinator.playingCount, 1);
  });

  test('re-entrant pause reports do not corrupt the playing list', () {
    setCap(1);
    final a = FakeHandle(1)..reportPauseTo = coordinator;
    final b = FakeHandle(2)..reportPauseTo = coordinator;
    final c = FakeHandle(3)..reportPauseTo = coordinator;
    coordinator
      ..onPlaying(a)
      ..onPlaying(b)
      ..onPlaying(c);

    expect(a.pauseForCapCalls, 1);
    expect(b.pauseForCapCalls, 1);
    expect(c.pauseForCapCalls, 0);
    expect(coordinator.playingCount, 1);
  });

  test('double-pause never happens for the same transition', () {
    setCap(1);
    final a = FakeHandle(1);
    final b = FakeHandle(2);
    coordinator
      ..onPlaying(a)
      ..onPlaying(b)
      // The pause issued for A eventually comes back as a paused event:
      ..onStoppedPlaying(a)
      // Another unrelated transition must not pause A again.
      ..onPlaying(b);

    expect(a.pauseForCapCalls, 1);
  });
}
