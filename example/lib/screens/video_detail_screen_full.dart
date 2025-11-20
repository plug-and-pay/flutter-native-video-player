import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../widgets/custom_video_overlay.dart';

class VideoDetailScreenFull extends StatefulWidget {
  final VideoItem video;
  final bool useCustomOverlay;
  final NativeVideoPlayerController? controller;

  const VideoDetailScreenFull({
    super.key,
    required this.video,
    this.controller,
    this.useCustomOverlay = false,
  });

  @override
  State<VideoDetailScreenFull> createState() => _VideoDetailScreenFullState();
}

class _VideoDetailScreenFullState extends State<VideoDetailScreenFull> {
  late NativeVideoPlayerController _controller;
  bool _ownsController = false;
  PlayerActivityState state = PlayerActivityState.idle;
  Duration _currentPosition = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  double _volume = 1.0;
  double _playbackSpeed = 1.0;
  List<NativeVideoPlayerQuality> _qualities = [];
  NativeVideoPlayerQuality? _currentQuality;
  bool _isSeeking = false;
  bool _isPipAvailable = false;
  bool _isInPipMode = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      // Use the existing controller from the list
      _controller = widget.controller!;
      _ownsController = false;

      // Add listeners FIRST before reading state
      _controller.addActivityListener(_handleActivityEvent);
      _controller.addControlListener(_handleControlEvent);

      // Do after frame to ensure widget is fully built
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // Get current state from controller immediately
        _updateStateFromController();

        // If video was playing in the list, resume playback after navigation
        // This ensures automatic PiP can work from this screen
        final wasPlaying = _controller.activityState.isPlaying;
        debugPrint('🎬 Detail screen loaded, video was playing: $wasPlaying');
        if (wasPlaying) {
          debugPrint('🎬 Resuming playback in detail screen');
          // Wait longer for the new platform view to be fully ready
          await Future.delayed(const Duration(milliseconds: 500));
          await _controller.play();
          debugPrint('🎬 Playback resumed');
        }
      });
    } else {
      // Create a new controller
      _ownsController = true;
      _initializePlayer();
    }
  }

  Future<void> _isPipAvailableCheck() async {
    final isPipAvailable = await _controller.isPictureInPictureAvailable();

    if (mounted) {
      setState(() {
        _isPipAvailable = isPipAvailable;
      });
    }
  }

  /// Updates all state variables from the current controller state
  void _updateStateFromController() {
    if (!mounted) return;

    // Set initial status
    setState(() {
      _currentPosition = _controller.currentPosition;
      _duration = _controller.duration;
      _bufferedPosition = _controller.bufferedPosition;
      _qualities = _controller.qualities;
      state = _controller.activityState;
    });

    // Check PiP availability after controller state is updated
    _isPipAvailableCheck();
  }

  Future<void> _initializePlayer() async {
    _controller = NativeVideoPlayerController(
      id: widget.video.id,
      autoPlay: widget.video.autoPlay,
      mediaInfo: NativeVideoPlayerMediaInfo(
        title: widget.video.title,
        subtitle: widget.video.description,
      ),
    );

    _controller.addActivityListener(_handleActivityEvent);
    _controller.addControlListener(_handleControlEvent);
    await _controller.initialize();
    await _controller.load(url: widget.video.url);

    // Check PiP availability after loading
    await _isPipAvailableCheck();

    if (mounted) {
      setState(() {
        state = _controller.activityState;
      });
    }
  }

  void _handleActivityEvent(PlayerActivityEvent event) {
    if (!mounted) return;

    setState(() {
      state = event.state;

      // Handle buffering with buffered position
      if (event.state == PlayerActivityState.buffering) {
        if (event.data != null && event.data!['buffered'] != null) {
          _bufferedPosition = Duration(milliseconds: event.data!['buffered']);
        }
      }

      // Handle error
      if (event.state == PlayerActivityState.error) {
        state = PlayerActivityState.error;
        debugPrint('Video Player Error: ${event.data}');
      }
    });

    // Check PiP availability when video is loaded
    if (event.state == PlayerActivityState.loaded) {
      _isPipAvailableCheck();
    }
  }

  void _handleControlEvent(PlayerControlEvent event) {
    if (!mounted) return;

    setState(() {
      // Handle time update events
      if (event.state == PlayerControlState.timeUpdated) {
        if (!_isSeeking && event.data != null) {
          final position = event.data!['position'] as int?;
          final duration = event.data!['duration'] as int?;
          final bufferedPosition = event.data!['bufferedPosition'] as int?;

          if (position != null) {
            _currentPosition = Duration(milliseconds: position);
          }
          if (duration != null) {
            _duration = Duration(milliseconds: duration);
          }
          if (bufferedPosition != null) {
            _bufferedPosition = Duration(milliseconds: bufferedPosition);
          }
        }
      }

      // Handle seek events
      if (event.state == PlayerControlState.seeked) {
        if (event.data != null) {
          final seekPosition = event.data!['position'] as int?;
          if (seekPosition != null) {
            _currentPosition = Duration(milliseconds: seekPosition);
            _isSeeking = false;
          }
        }
      }

      // Handle quality change events
      if (event.state == PlayerControlState.qualityChanged) {
        if (event.data != null) {
          if (event.data!['quality'] != null) {
            _currentQuality = NativeVideoPlayerQuality.fromMap(
              Map<String, dynamic>.from(event.data!['quality'] as Map),
            );
          }
          if (event.data!['qualities'] != null) {
            final newQualities = (event.data!['qualities'] as List)
                .map(
                  (q) => NativeVideoPlayerQuality.fromMap(
                    Map<String, dynamic>.from(q as Map),
                  ),
                )
                .toList();

            _qualities = newQualities.toSet().toList();

            if (_currentQuality == null && _qualities.isNotEmpty) {
              _currentQuality = _qualities.first;
            }
          }
        }
      }

      // Handle PiP events
      if (event.state == PlayerControlState.pipStarted) {
        _isInPipMode = true;
      }
      if (event.state == PlayerControlState.pipStopped) {
        _isInPipMode = false;
      }
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  Widget _buildPlayPauseButton() {
    // Show loading indicator when buffering or loading
    if (state == PlayerActivityState.buffering ||
        state == PlayerActivityState.loading) {
      return const Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
      );
    }

    // Show play/pause button for other states
    return IconButton(
      icon: Icon(
        state.isPlaying ? Icons.pause : Icons.play_arrow,
        color: Colors.white,
      ),
      iconSize: 36,
      onPressed: () {
        if (state.isPlaying) {
          _controller.pause();
        } else {
          _controller.play();
        }
      },
    );
  }

  @override
  void dispose() {
    _controller.removeActivityListener(_handleActivityEvent);
    _controller.removeControlListener(_handleControlEvent);
    // Only dispose if we created the controller
    if (_ownsController) {
      _controller.releaseResources();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              // Video Player
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  children: [
                    NativeVideoPlayer(
                      key: ValueKey('native_video_player_${_controller.id}'),
                      controller: _controller,
                      overlayBuilder: widget.useCustomOverlay
                          ? (context, controller) => CustomVideoOverlay(
                              key: ValueKey('custom_overlay_${controller.id}'),
                              controller: controller,
                            )
                          : null,
                    ),
                    // Back Button - hide in PiP mode
                    if (!_isInPipMode)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.5),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                              ),
                              padding: EdgeInsets.zero,
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              Container(
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Video Info
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.video.title,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            widget.video.description,
                            style: TextStyle(
                              fontSize: 15,
                              color: Colors.grey[700],
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Divider(height: 1),

                    // Playback Controls
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Playback Controls',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Play/Pause/Skip
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.replay_10),
                                iconSize: 32,
                                onPressed: () => _controller.seekTo(
                                  _currentPosition -
                                      const Duration(seconds: 10),
                                ),
                              ),
                              const SizedBox(width: 20),
                              Container(
                                width: 64,
                                height: 64,
                                decoration: BoxDecoration(
                                  color: Theme.of(context).primaryColor,
                                  shape: BoxShape.circle,
                                ),
                                child: _buildPlayPauseButton(),
                              ),
                              const SizedBox(width: 20),
                              IconButton(
                                icon: const Icon(Icons.forward_10),
                                iconSize: 32,
                                onPressed: () => _controller.seekTo(
                                  _currentPosition +
                                      const Duration(seconds: 10),
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Progress Slider
                          Column(
                            children: [
                              Slider(
                                value: _duration.inMilliseconds > 0
                                    ? _currentPosition.inMilliseconds
                                          .toDouble()
                                          .clamp(
                                            0.0,
                                            _duration.inMilliseconds.toDouble(),
                                          )
                                    : 0.0,
                                min: 0,
                                max: _duration.inMilliseconds > 0
                                    ? _duration.inMilliseconds.toDouble()
                                    : 1.0,
                                onChangeStart: (_) => _isSeeking = true,
                                onChanged: (value) {
                                  if (_isSeeking &&
                                      _duration.inMilliseconds > 0) {
                                    setState(() {
                                      _currentPosition = Duration(
                                        milliseconds: value.toInt(),
                                      );
                                    });
                                  }
                                },
                                onChangeEnd: (value) {
                                  if (_duration.inMilliseconds > 0) {
                                    _controller.seekTo(
                                      Duration(milliseconds: value.toInt()),
                                    );
                                  }
                                },
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_formatDuration(_currentPosition)),
                                    Text(_formatDuration(_duration)),
                                  ],
                                ),
                              ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Volume Control
                          Row(
                            children: [
                              Icon(Icons.volume_up, color: Colors.grey[700]),
                              Expanded(
                                child: Slider(
                                  value: _volume,
                                  onChanged: (value) {
                                    setState(() => _volume = value);
                                    _controller.setVolume(value);
                                  },
                                ),
                              ),
                              Text('${(_volume * 100).toInt()}%'),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Speed and Quality
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Speed',
                                      style: TextStyle(color: Colors.grey[600]),
                                    ),
                                    const SizedBox(height: 8),
                                    DropdownButton<double>(
                                      value: _playbackSpeed,
                                      isExpanded: true,
                                      items: [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                                          .map((speed) {
                                            return DropdownMenuItem(
                                              value: speed,
                                              child: Text('${speed}x'),
                                            );
                                          })
                                          .toList(),
                                      onChanged: (value) {
                                        if (value != null) {
                                          setState(
                                            () => _playbackSpeed = value,
                                          );
                                          _controller.setSpeed(value);
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              if (_qualities.isNotEmpty)
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Quality',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      DropdownButton<NativeVideoPlayerQuality>(
                                        value: _currentQuality,
                                        isExpanded: true,
                                        hint: const Text('Auto'),
                                        items: _qualities.map((quality) {
                                          return DropdownMenuItem(
                                            value: quality,
                                            child: Text(quality.label),
                                          );
                                        }).toList(),
                                        onChanged: (value) {
                                          if (value != null) {
                                            setState(
                                              () => _currentQuality = value,
                                            );
                                            _controller.setQuality(value);
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),

                          const SizedBox(height: 16),

                          // Additional Controls
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () =>
                                      _controller.toggleFullScreen(),
                                  icon: const Icon(Icons.fullscreen),
                                  label: const Text('Fullscreen'),
                                ),
                              ),
                              if (_isPipAvailable) ...[
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      if (_isInPipMode) {
                                        _controller.exitPictureInPicture();
                                      } else {
                                        _controller.enterPictureInPicture();
                                      }
                                    },
                                    icon: const Icon(
                                      Icons.picture_in_picture_alt,
                                    ),
                                    label: Text(
                                      _isInPipMode ? 'Exit PiP' : 'PiP',
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),

                    const Divider(height: 1),

                    // Statistics
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Video Statistics',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 16),
                          _buildStatRow(
                            'Duration',
                            _formatDuration(_duration),
                            Icons.access_time,
                          ),
                          const SizedBox(height: 12),
                          _buildStatRow(
                            'Current Position',
                            _formatDuration(_currentPosition),
                            Icons.timer,
                          ),
                          const SizedBox(height: 12),
                          _buildStatRow(
                            'Buffered',
                            _formatDuration(_bufferedPosition),
                            Icons.download_done,
                          ),
                          const SizedBox(height: 12),
                          _buildStatRow(
                            'Available Qualities',
                            '${_qualities.length}',
                            Icons.high_quality,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey[600]),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: TextStyle(fontSize: 15, color: Colors.grey[700]),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}
