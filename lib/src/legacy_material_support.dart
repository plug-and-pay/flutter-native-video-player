// The player is built on `package:material_ui`, but apps that still build on
// the SDK's `package:flutter/material.dart` keep working: Flutter treats the
// two as different libraries, so their `Theme` and `Material` widgets don't
// see each other. Everything that has to look at the app's own Material lives
// here. Remove this file once the SDK library is gone.
import 'package:flutter/material.dart' as legacy;
import 'package:material_ui/material_ui.dart';

/// The slider colours of the app around the player, read from whichever
/// Material library the app is on.
@immutable
class HostSliderColors {
  const HostSliderColors({
    required this.primary,
    this.activeTrack,
    this.secondaryActiveTrack,
    this.inactiveTrack,
    this.thumb,
  });

  /// An app on `material_ui` has its `Theme` widget above the player; an app
  /// on the SDK library only has the SDK one. An app halfway through the move
  /// (with `MaterialUiCompatibilityBridge`) has both and reads `material_ui`.
  factory HostSliderColors.of(BuildContext context) {
    if (context.findAncestorWidgetOfExactType<Theme>() != null) {
      final SliderThemeData sliderTheme = SliderTheme.of(context);
      return HostSliderColors(
        primary: Theme.of(context).colorScheme.primary,
        activeTrack: sliderTheme.activeTrackColor,
        secondaryActiveTrack: sliderTheme.secondaryActiveTrackColor,
        inactiveTrack: sliderTheme.inactiveTrackColor,
        thumb: sliderTheme.thumbColor,
      );
    }

    final legacy.SliderThemeData sliderTheme = legacy.SliderTheme.of(context);
    return HostSliderColors(
      primary: legacy.Theme.of(context).colorScheme.primary,
      activeTrack: sliderTheme.activeTrackColor,
      secondaryActiveTrack: sliderTheme.secondaryActiveTrackColor,
      inactiveTrack: sliderTheme.inactiveTrackColor,
      thumb: sliderTheme.thumbColor,
    );
  }

  final Color primary;
  final Color? activeTrack, secondaryActiveTrack, inactiveTrack, thumb;
}

/// A see-through SDK `Material` for the app's controls in Dart fullscreen.
///
/// The fullscreen page is a `material_ui` `Scaffold`, which is the `Material`
/// that `material_ui` ink widgets look for. An `InkWell` or `IconButton` from
/// an app still on the SDK library looks for the SDK `Material` instead and
/// would assert with "No Material widget found" without this one.
class LegacyMaterialAncestor extends StatelessWidget {
  const LegacyMaterialAncestor({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      legacy.Material(type: legacy.MaterialType.transparency, child: child);
}
