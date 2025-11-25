import 'package:flutter/material.dart';
import 'package:better_native_video_player/better_native_video_player.dart';

/// A modal bottom sheet for selecting subtitle tracks and configuring subtitle settings
class SubtitlePickerModal extends StatefulWidget {
  const SubtitlePickerModal({
    super.key,
    required this.controller,
    this.fontSize = 16.0,
    this.onFontSizeChanged,
  });

  final NativeVideoPlayerController controller;
  final double fontSize;
  final ValueChanged<double>? onFontSizeChanged;

  @override
  State<SubtitlePickerModal> createState() => _SubtitlePickerModalState();
}

class _SubtitlePickerModalState extends State<SubtitlePickerModal> {
  List<NativeVideoPlayerSubtitleTrack> _subtitleTracks = [];
  NativeVideoPlayerSubtitleTrack? _selectedTrack;
  bool _isLoading = true;
  late double _currentFontSize;

  @override
  void initState() {
    super.initState();
    _currentFontSize = widget.fontSize;
    _loadSubtitleTracks();
  }

  Future<void> _loadSubtitleTracks() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final tracks = await widget.controller.getAvailableSubtitleTracks();

      setState(() {
        _subtitleTracks = tracks;
        _selectedTrack = tracks.firstWhere(
          (track) => track.isSelected,
          orElse: () => NativeVideoPlayerSubtitleTrack.off(),
        );
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading subtitles: $e')));
      }
    }
  }

  Future<void> _selectTrack(NativeVideoPlayerSubtitleTrack track) async {
    try {
      await widget.controller.setSubtitleTrack(track);
      setState(() {
        _selectedTrack = track;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              track.isOff
                  ? 'Subtitles disabled'
                  : 'Selected: ${track.displayName}',
            ),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error selecting subtitle: $e')));
      }
    }
  }

  void _updateFontSize(double newSize) {
    setState(() {
      _currentFontSize = newSize;
    });
    widget.onFontSizeChanged?.call(newSize);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.closed_caption, size: 24),
                const SizedBox(width: 12),
                const Text(
                  'Subtitles & Captions',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(),

          // Font Size Control
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.format_size, size: 20),
                    const SizedBox(width: 8),
                    const Text(
                      'Font Size',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_currentFontSize.toInt()}',
                      style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.remove_circle_outline, size: 20),
                    Expanded(
                      child: Slider(
                        value: _currentFontSize,
                        min: 12.0,
                        max: 32.0,
                        divisions: 20,
                        label: '${_currentFontSize.toInt()}',
                        onChanged: _updateFontSize,
                      ),
                    ),
                    const Icon(Icons.add_circle_outline, size: 20),
                  ],
                ),
              ],
            ),
          ),

          const Divider(),

          // Loading or subtitle tracks list
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(),
            )
          else if (_subtitleTracks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Column(
                children: [
                  Icon(
                    Icons.closed_caption_disabled,
                    size: 48,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No subtitles available',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                  ),
                ],
              ),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // Off option
                  _buildTrackTile(NativeVideoPlayerSubtitleTrack.off()),

                  // Available subtitle tracks
                  for (final track in _subtitleTracks) _buildTrackTile(track),
                ],
              ),
            ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildTrackTile(NativeVideoPlayerSubtitleTrack track) {
    final isSelected = track.isOff
        ? (_selectedTrack?.isOff ?? false)
        : _selectedTrack?.index == track.index;

    return ListTile(
      leading: Icon(
        track.isOff ? Icons.closed_caption_disabled : Icons.closed_caption,
        color: isSelected ? Theme.of(context).primaryColor : Colors.grey,
      ),
      title: Text(
        track.displayName,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Theme.of(context).primaryColor : null,
        ),
      ),
      subtitle: track.isOff
          ? null
          : Text(
              track.language.toUpperCase(),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
      trailing: isSelected
          ? Icon(Icons.check_circle, color: Theme.of(context).primaryColor)
          : null,
      onTap: () => _selectTrack(track),
    );
  }
}

/// Shows the subtitle picker modal
Future<void> showSubtitlePicker({
  required BuildContext context,
  required NativeVideoPlayerController controller,
  double fontSize = 16.0,
  ValueChanged<double>? onFontSizeChanged,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => SubtitlePickerModal(
      controller: controller,
      fontSize: fontSize,
      onFontSizeChanged: onFontSizeChanged,
    ),
  );
}
