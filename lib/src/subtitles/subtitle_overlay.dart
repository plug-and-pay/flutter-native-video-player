import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/native_video_player_subtitle_style.dart';

/// Subtitle layer rendering the active sidecar cue lines at the position
/// configured in [NativeVideoPlayerSubtitleStyle] (bottom-center by
/// default; any alignment supported).
///
/// Sits in the NativeVideoPlayer stack above the platform view and below
/// the custom controls overlay; never intercepts touches.
class SubtitleOverlay extends StatelessWidget {
  const SubtitleOverlay({
    required this.cueLines,
    required this.style,
    super.key,
  });

  final ValueListenable<List<String>> cueLines;
  final NativeVideoPlayerSubtitleStyle style;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: ValueListenableBuilder<List<String>>(
            valueListenable: cueLines,
            builder: (context, lines, _) {
              if (lines.isEmpty) return const SizedBox.shrink();
              return Align(
                alignment: style.alignment,
                child: Padding(
                  padding: style.padding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final line in lines)
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          color: style.backgroundColor,
                          child: Text(
                            line,
                            textAlign: style.textAlign,
                            style: TextStyle(
                              fontSize: style.fontSize,
                              fontWeight: style.fontWeight,
                              fontStyle: style.fontStyle,
                              fontFamily: style.fontFamily,
                              height: style.lineHeight,
                              color: style.textColor,
                              shadows:
                                  style.outlineColor != null &&
                                      style.outlineWidth > 0
                                  ? [
                                      for (final dx in const [-1.0, 1.0])
                                        for (final dy in const [-1.0, 1.0])
                                          Shadow(
                                            color: style.outlineColor!,
                                            offset:
                                                Offset(dx, dy) *
                                                style.outlineWidth,
                                          ),
                                    ]
                                  : null,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
