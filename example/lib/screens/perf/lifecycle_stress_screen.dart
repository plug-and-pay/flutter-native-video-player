import 'dart:async';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import 'perf_hud.dart';

/// Rapid init/release/dispose cycles (B6 scenario) — the
/// MissingPluginException reproduction harness.
///
/// Three stressors:
/// - construct/dispose: bare controller lifecycle without any platform view
///   (catches the constructor-time `listen` race),
/// - full cycle: create → mount → initialize → load → releaseResources →
///   recreate with the SAME id → dispose (the shared-ID reattachment path),
/// - mount toggle: repeatedly attach/detach a platform view on one controller.
class LifecycleStressScreen extends StatefulWidget {
  const LifecycleStressScreen({super.key});

  @override
  State<LifecycleStressScreen> createState() => _LifecycleStressScreenState();
}

class _LifecycleStressScreenState extends State<LifecycleStressScreen> {
  static const int _fullCycleId = 9300;
  static const int _mountToggleId = 9301;
  static const String _testUrl =
      'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';

  int _nextFreshId = 9200;
  int _cyclesDone = 0;
  bool _busy = false;

  // Controller/widget slot used by the full-cycle and mount-toggle stressors.
  NativeVideoPlayerController? _slotController;
  bool _slotMounted = false;

  void _bumpCycles() => setState(() => _cyclesDone++);

  Future<void> _runGuarded(Future<void> Function() body) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Bare construct → (jitter) → dispose with a fresh controller ID.
  Future<void> _constructDisposeCycle(int count) => _runGuarded(() async {
    for (var i = 0; i < count; i++) {
      final controller = NativeVideoPlayerController(
        id: _nextFreshId++,
        showNativeControls: false,
      );
      // Jitter 50-250ms without dart:math (deterministic, reproducible).
      await Future<void>.delayed(Duration(milliseconds: 50 + (i % 5) * 50));
      await controller.dispose();
      _bumpCycles();
    }
  });

  Future<void> _mountSlot(NativeVideoPlayerController controller) async {
    setState(() {
      _slotController = controller;
      _slotMounted = true;
    });
    // Give the platform view a frame to be created.
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> _unmountSlot() async {
    setState(() => _slotMounted = false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Full lifecycle: create → mount → initialize+load → releaseResources →
  /// recreate SAME id → mount → initialize → dispose.
  Future<void> _fullCycle(int count) => _runGuarded(() async {
    for (var i = 0; i < count; i++) {
      var controller = NativeVideoPlayerController(
        id: _fullCycleId,
        showNativeControls: false,
      );
      await _mountSlot(controller);
      try {
        await controller.initialize();
        await controller.load(url: _testUrl);
      } catch (e) {
        debugPrint('LifecycleStress full cycle $i load error: $e');
      }
      await Future<void>.delayed(Duration(milliseconds: 100 + (i % 3) * 75));
      await _unmountSlot();
      await controller.releaseResources();

      // Recreate with the same controller ID (shared-player reattachment).
      controller = NativeVideoPlayerController(
        id: _fullCycleId,
        showNativeControls: false,
      );
      await _mountSlot(controller);
      try {
        await controller.initialize();
      } catch (e) {
        debugPrint('LifecycleStress full cycle $i reattach error: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _unmountSlot();
      await controller.dispose();
      _slotController = null;
      _bumpCycles();
    }
  });

  /// Repeatedly attach/detach a platform view on one live controller.
  Future<void> _mountToggle(int count) => _runGuarded(() async {
    final controller = NativeVideoPlayerController(
      id: _mountToggleId,
      showNativeControls: false,
    );
    await _mountSlot(controller);
    try {
      await controller.initialize();
      await controller.load(url: _testUrl);
    } catch (e) {
      debugPrint('LifecycleStress mount toggle load error: $e');
    }
    for (var i = 0; i < count; i++) {
      await _unmountSlot();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await _mountSlot(controller);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      _bumpCycles();
    }
    await _unmountSlot();
    await controller.dispose();
    _slotController = null;
  });

  @override
  void dispose() {
    final controller = _slotController;
    if (controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slotController = _slotController;
    return Scaffold(
      appBar: AppBar(title: const Text('Lifecycle stress')),
      body: Column(
        children: [
          const PerfHud(dumpLabel: 'lifecycle_stress'),
          SizedBox(
            height: 180,
            child: Container(
              color: Colors.black,
              child: (_slotMounted && slotController != null)
                  ? NativeVideoPlayer(controller: slotController)
                  : const Center(
                      child: Text(
                        'no player mounted',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'cycles done: $_cyclesDone',
              key: const ValueKey('stress_cycles_done'),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                key: const ValueKey('stress_cycle_once'),
                onPressed: _busy ? null : () => _constructDisposeCycle(1),
                child: const Text('Construct/dispose ×1'),
              ),
              ElevatedButton(
                key: const ValueKey('stress_cycle_x20'),
                onPressed: _busy ? null : () => _constructDisposeCycle(20),
                child: const Text('Construct/dispose ×20'),
              ),
              ElevatedButton(
                key: const ValueKey('stress_full_cycle_x10'),
                onPressed: _busy ? null : () => _fullCycle(10),
                child: const Text('Full cycle ×10'),
              ),
              ElevatedButton(
                key: const ValueKey('stress_mount_toggle_x20'),
                onPressed: _busy ? null : () => _mountToggle(20),
                child: const Text('Mount toggle ×20'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
