import 'dart:convert';

import 'package:better_native_video_player/src/services/cast/cast_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CastProtocolCodec', () {
    test('encode/decode round-trips all fields', () {
      const message = CastChannelMessage(
        sourceId: 'sender-0',
        destinationId: 'receiver-0',
        namespace: 'urn:x-cast:com.google.cast.tp.heartbeat',
        payload: '{"type":"PING"}',
      );

      final frame = CastProtocolCodec.encodeFrame(message);
      // 4-byte big-endian length prefix.
      final length =
          (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
      expect(length, frame.length - 4);

      final decoded = CastProtocolCodec.decodeBody(frame.sublist(4));
      expect(decoded.sourceId, message.sourceId);
      expect(decoded.destinationId, message.destinationId);
      expect(decoded.namespace, message.namespace);
      expect(decoded.payload, message.payload);
      expect(decoded.payloadJson['type'], 'PING');
    });

    test('handles payloads larger than one varint byte (>127 bytes)', () {
      final payload = jsonEncode({
        'type': 'LOAD',
        'media': {'contentId': 'https://example.com/${'v' * 300}.mp4'},
      });
      final message = CastChannelMessage(
        sourceId: 'sender-0',
        destinationId: 'app-1',
        namespace: 'urn:x-cast:com.google.cast.media',
        payload: payload,
      );
      final frame = CastProtocolCodec.encodeFrame(message);
      final decoded = CastProtocolCodec.decodeBody(frame.sublist(4));
      expect(decoded.payload, payload);
    });

    test('round-trips non-ASCII payloads', () {
      const message = CastChannelMessage(
        sourceId: 'sender-0',
        destinationId: 'receiver-0',
        namespace: 'urn:x-cast:com.google.cast.media',
        payload: '{"title":"Café Ümläut — 你好"}',
      );
      final frame = CastProtocolCodec.encodeFrame(message);
      expect(
        CastProtocolCodec.decodeBody(frame.sublist(4)).payload,
        message.payload,
      );
    });
  });

  group('CastFrameBuffer', () {
    CastChannelMessage msg(String payload) => CastChannelMessage(
      sourceId: 's',
      destinationId: 'd',
      namespace: 'ns',
      payload: payload,
    );

    test('reassembles a frame split across chunks', () {
      final buffer = CastFrameBuffer();
      final frame = CastProtocolCodec.encodeFrame(msg('{"type":"PONG"}'));

      expect(buffer.addChunk(frame.sublist(0, 3)), isEmpty);
      expect(buffer.addChunk(frame.sublist(3, 10)), isEmpty);
      final messages = buffer.addChunk(frame.sublist(10));
      expect(messages, hasLength(1));
      expect(messages.single.payloadJson['type'], 'PONG');
    });

    test('yields multiple frames from one chunk', () {
      final buffer = CastFrameBuffer();
      final a = CastProtocolCodec.encodeFrame(msg('{"n":1}'));
      final b = CastProtocolCodec.encodeFrame(msg('{"n":2}'));
      final messages = buffer.addChunk([...a, ...b]);
      expect(messages, hasLength(2));
      expect(messages[0].payloadJson['n'], 1);
      expect(messages[1].payloadJson['n'], 2);
    });
  });
}
