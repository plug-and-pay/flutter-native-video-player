import 'dart:async';
import 'dart:io';

import 'package:better_native_video_player/better_native_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// VideoDownloadController against a local HTTP server (plain `test`, real
/// async — no fake zone, downloads do real I/O into a temp directory).
void main() {
  late HttpServer server;
  late Directory tempDir;
  late String baseUrl;

  /// 256 KB of deterministic bytes, served in chunks.
  final payload = List<int>.generate(256 * 1024, (i) => i % 251);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nvp_dl_test');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/video.mp4' || path == '/nolength.mp4') {
        if (path == '/video.mp4') {
          request.response.contentLength = payload.length;
        }
        for (var i = 0; i < payload.length; i += 64 * 1024) {
          request.response.add(
            payload.sublist(
              i,
              i + 64 * 1024 > payload.length ? payload.length : i + 64 * 1024,
            ),
          );
          await request.response.flush();
        }
        await request.response.close();
      } else if (path == '/slow.mp4') {
        request.response.contentLength = payload.length;
        for (var i = 0; i < payload.length; i += 16 * 1024) {
          request.response.add(payload.sublist(i, i + 16 * 1024));
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  VideoDownloadController newController() =>
      VideoDownloadController(directoryPath: tempDir.path);

  test('downloads with progress and completes', () async {
    final controller = newController();
    final events = await controller
        .download(id: 'vid-1', url: '$baseUrl/video.mp4')
        .toList();

    expect(events.first.status, VideoDownloadStatus.downloading);
    expect(events.last.status, VideoDownloadStatus.completed);
    expect(events.last.receivedBytes, payload.length);
    expect(events.last.fraction, 1.0);

    final path = await controller.localPathFor('vid-1');
    expect(path, isNotNull);
    expect(path, endsWith('.mp4'));
    expect(await File(path!).length(), payload.length);
    expect(await controller.isDownloaded('vid-1'), isTrue);
  });

  test('missing content-length still completes (null fraction)', () async {
    final controller = newController();
    final events = await controller
        .download(id: 'vid-nolen', url: '$baseUrl/nolength.mp4')
        .toList();

    final during = events.where(
      (e) => e.status == VideoDownloadStatus.downloading,
    );
    expect(during.every((e) => e.fraction == null), isTrue);
    expect(events.last.status, VideoDownloadStatus.completed);
    expect(events.last.receivedBytes, payload.length);
  });

  test('index persists across controller instances', () async {
    await newController().download(id: 'vid-2', url: '$baseUrl/video.mp4').last;

    final fresh = newController();
    final downloads = await fresh.listDownloads();
    expect(downloads, hasLength(1));
    expect(downloads.single.id, 'vid-2');
    expect(downloads.single.url, '$baseUrl/video.mp4');
    expect(File(downloads.single.filePath).existsSync(), isTrue);
  });

  test('re-downloading a completed id replays completed immediately', () async {
    final controller = newController();
    await controller.download(id: 'vid-3', url: '$baseUrl/video.mp4').last;

    final events = await controller
        .download(id: 'vid-3', url: '$baseUrl/video.mp4')
        .toList();
    expect(events, hasLength(1));
    expect(events.single.status, VideoDownloadStatus.completed);
  });

  test('remove deletes the file and forgets the id', () async {
    final controller = newController();
    await controller.download(id: 'vid-4', url: '$baseUrl/video.mp4').last;
    final path = (await controller.localPathFor('vid-4'))!;

    await controller.remove('vid-4');
    expect(File(path).existsSync(), isFalse);
    expect(await controller.listDownloads(), isEmpty);
    expect(await controller.isDownloaded('vid-4'), isFalse);
  });

  test('cancel stops the download and leaves nothing behind', () async {
    final controller = newController();
    final events = <VideoDownloadProgress>[];
    final done = Completer<void>();
    controller
        .download(id: 'vid-5', url: '$baseUrl/slow.mp4')
        .listen(events.add, onDone: done.complete);

    // Let a couple of chunks arrive, then cancel mid-flight.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await controller.cancel('vid-5');
    await done.future;

    expect(events.last.status, VideoDownloadStatus.canceled);
    expect(await controller.isDownloaded('vid-5'), isFalse);
    expect(tempDir.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
  });

  test('HTTP errors surface as failed', () async {
    final controller = newController();
    final events = await controller
        .download(id: 'vid-404', url: '$baseUrl/missing.mp4')
        .toList();
    expect(events.last.status, VideoDownloadStatus.failed);
    expect(events.last.error, contains('404'));
    expect(await controller.isDownloaded('vid-404'), isFalse);
  });
}
