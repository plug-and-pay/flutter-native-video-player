import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/platform_utils.dart';

/// Manages fullscreen state, system UI visibility, and device orientation
class FullscreenManager {
  /// Stores the current orientation preferences (tracked globally)
  static List<DeviceOrientation> _currentOrientations = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// Stores the orientation preferences before entering fullscreen
  static List<DeviceOrientation>? _savedOrientations;

  /// True while a player is in fullscreen. Used to stop a player that is
  /// constructed/mounted while another player is fullscreen from yanking the
  /// device orientation away from the active fullscreen (its preferred
  /// orientations are still recorded as the restore baseline, just not applied).
  static bool _isFullscreen = false;

  /// Enters fullscreen mode
  ///
  /// This method:
  /// - Saves current orientation preferences automatically
  /// - Hides system UI (status bar, navigation bar on Android)
  /// - Allows all orientations (or locks to landscape if specified)
  ///
  /// **Parameters:**
  /// - lockToLandscape: If true, locks orientation to landscape modes only
  static Future<void> enterFullscreen({bool lockToLandscape = true}) async {
    // Save current orientation preferences before changing them
    _savedOrientations = List.from(_currentOrientations);
    _isFullscreen = true;
    // Hide system UI
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );

    // Set orientation preferences for fullscreen
    if (lockToLandscape) {
      final landscapeOrientations = [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
      await SystemChrome.setPreferredOrientations(landscapeOrientations);
      _currentOrientations = landscapeOrientations;
    } else {
      final allOrientations = [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ];
      await SystemChrome.setPreferredOrientations(allOrientations);
      _currentOrientations = allOrientations;
    }
  }

  /// Exits fullscreen mode
  ///
  /// This method:
  /// - Restores system UI visibility
  /// - Restores original orientation preferences that were saved before entering fullscreen
  static Future<void> exitFullscreen() async {
    _isFullscreen = false;
    // Restore system UI
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    // Restore orientation preferences to what they were before fullscreen
    if (PlatformUtils.isAndroid || PlatformUtils.isIOS) {
      final orientations = _savedOrientations ?? _currentOrientations;
      await SystemChrome.setPreferredOrientations(orientations);
      _currentOrientations = orientations;
    }
  }

  /// Set orientation preferences that will be tracked by FullscreenManager
  ///
  /// Call this instead of `SystemChrome.setPreferredOrientations()` if you want
  /// FullscreenManager to automatically remember and restore these orientations
  /// when exiting fullscreen.
  ///
  /// **Example:**
  /// ```dart
  /// // Set your app to portrait only
  /// await FullscreenManager.setPreferredOrientations([
  ///   DeviceOrientation.portraitUp,
  /// ]);
  ///
  /// // Later when entering fullscreen, it will remember portrait-only
  /// await FullscreenManager.enterFullscreen();
  /// // Exits fullscreen
  /// await FullscreenManager.exitFullscreen();
  /// // Automatically restores to portrait-only
  /// ```
  static Future<void> setPreferredOrientations(
    List<DeviceOrientation> orientations,
  ) async {
    _currentOrientations = List.from(orientations);

    // Record the baseline but don't apply it while a player is fullscreen — a
    // newly constructed/mounted player (e.g. another video tile churning during
    // rotation) must not pull the device out of the active fullscreen.
    if (_isFullscreen) {
      return;
    }

    await SystemChrome.setPreferredOrientations(orientations);
  }

  /// Shows a fullscreen dialog with the provided widget
  ///
  /// This is a helper method that combines entering fullscreen mode
  /// with showing a dialog.
  ///
  /// **Parameters:**
  /// - context: BuildContext for showing the dialog
  /// - builder: Widget builder for the fullscreen content
  /// - lockToLandscape: If true, locks orientation to landscape
  /// - onExit: Optional callback when fullscreen is exited
  ///
  /// **Returns:**
  /// The result from the dialog when it's dismissed
  static Future<T?> showFullscreenDialog<T>({
    required BuildContext context,
    required Widget Function(BuildContext) builder,
    bool lockToLandscape = true,
    VoidCallback? onExit,
  }) async {
    // Enter fullscreen mode
    await enterFullscreen(lockToLandscape: lockToLandscape);

    if (!context.mounted) {
      return null;
    }

    // Show the dialog using the root navigator to avoid nested navigator issues
    // rootNavigator: true ensures we use the topmost Navigator in the widget tree
    final result = await Navigator.of(context, rootNavigator: true).push<T>(
      PageRouteBuilder<T>(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (context, _, _) => builder(context),
        transitionsBuilder: (context, animation, _, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );

    // Exit fullscreen mode
    await exitFullscreen();

    // Call exit callback if provided
    onExit?.call();

    return result;
  }
}
