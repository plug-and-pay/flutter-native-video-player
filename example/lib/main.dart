import 'package:flutter/material.dart';
import 'package:marionette_flutter/marionette_flutter.dart';

import 'screens/video_list_screen_with_players.dart';
import 'services/error_counter.dart';
import 'services/perf_metrics.dart';

void main() {
  MarionetteBinding.ensureInitialized();
  ErrorCounter.instance.install();
  PerfMetrics.instance.install();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Native Video Player Example',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
      ),
      home: const VideoListScreenWithPlayers(),
    );
  }
}
