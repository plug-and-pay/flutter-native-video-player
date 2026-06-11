import 'dart:convert';
import 'dart:typed_data';

/// One CASTV2 message: a tiny fixed protobuf
/// (`extensions.api.cast_channel.CastMessage`) framed with a 4-byte
/// big-endian length. The schema is small and frozen, so the plugin
/// hand-rolls the five fields instead of depending on protobuf codegen:
///
/// ```proto
/// required int32  protocol_version = 1; // 0 = CASTV2_1_0
/// required string source_id        = 2;
/// required string destination_id   = 3;
/// required string namespace        = 4;
/// required PayloadType payload_type = 5; // 0 = STRING
/// optional string payload_utf8     = 6;
/// ```
class CastChannelMessage {
  const CastChannelMessage({
    required this.sourceId,
    required this.destinationId,
    required this.namespace,
    required this.payload,
  });

  final String sourceId;
  final String destinationId;
  final String namespace;

  /// JSON payload (CASTV2 control messages are all JSON strings).
  final String payload;

  Map<String, dynamic> get payloadJson =>
      jsonDecode(payload) as Map<String, dynamic>;

  @override
  String toString() => 'CastChannelMessage($namespace $payload)';
}

/// Encoder/decoder for framed [CastChannelMessage]s.
class CastProtocolCodec {
  CastProtocolCodec._();

  static void _writeVarint(BytesBuilder out, int value) {
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7f) | 0x80);
      v >>= 7;
    }
    out.addByte(v);
  }

  static void _writeString(BytesBuilder out, int fieldNumber, String value) {
    out.addByte((fieldNumber << 3) | 2); // length-delimited
    final bytes = utf8.encode(value);
    _writeVarint(out, bytes.length);
    out.add(bytes);
  }

  static void _writeVarintField(BytesBuilder out, int fieldNumber, int value) {
    out.addByte(fieldNumber << 3); // wire type 0
    _writeVarint(out, value);
  }

  /// Encodes [message] as a length-framed CastMessage ready for the socket.
  static Uint8List encodeFrame(CastChannelMessage message) {
    final body = BytesBuilder();
    _writeVarintField(body, 1, 0); // protocol_version CASTV2_1_0
    _writeString(body, 2, message.sourceId);
    _writeString(body, 3, message.destinationId);
    _writeString(body, 4, message.namespace);
    _writeVarintField(body, 5, 0); // payload_type STRING
    _writeString(body, 6, message.payload);

    final bytes = body.toBytes();
    final framed = BytesBuilder();
    framed.add([
      (bytes.length >> 24) & 0xff,
      (bytes.length >> 16) & 0xff,
      (bytes.length >> 8) & 0xff,
      bytes.length & 0xff,
    ]);
    framed.add(bytes);
    return framed.toBytes();
  }

  static int _readVarint(Uint8List data, _Cursor cursor) {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = data[cursor.offset++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
    }
  }

  /// Decodes ONE unframed CastMessage body.
  static CastChannelMessage decodeBody(Uint8List body) {
    final cursor = _Cursor();
    String sourceId = '';
    String destinationId = '';
    String namespace = '';
    String payload = '';

    while (cursor.offset < body.length) {
      final tag = _readVarint(body, cursor);
      final fieldNumber = tag >> 3;
      final wireType = tag & 0x7;
      switch (wireType) {
        case 0:
          final value = _readVarint(body, cursor);
          // protocol_version / payload_type — values are fixed, ignore.
          assert(fieldNumber != 5 || value == 0, 'binary payloads unused');
        case 2:
          final length = _readVarint(body, cursor);
          final bytes = body.sublist(cursor.offset, cursor.offset + length);
          cursor.offset += length;
          final text = utf8.decode(bytes, allowMalformed: true);
          switch (fieldNumber) {
            case 2:
              sourceId = text;
            case 3:
              destinationId = text;
            case 4:
              namespace = text;
            case 6:
              payload = text;
          }
        default:
          throw FormatException('Unsupported wire type $wireType');
      }
    }
    return CastChannelMessage(
      sourceId: sourceId,
      destinationId: destinationId,
      namespace: namespace,
      payload: payload,
    );
  }
}

class _Cursor {
  int offset = 0;
}

/// Accumulates socket bytes and yields complete message bodies (handles
/// partial frames and multiple frames per packet).
class CastFrameBuffer {
  final BytesBuilder _buffer = BytesBuilder();

  List<CastChannelMessage> addChunk(List<int> chunk) {
    _buffer.add(chunk);
    final messages = <CastChannelMessage>[];
    var bytes = _buffer.toBytes();
    while (bytes.length >= 4) {
      final length =
          (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
      if (bytes.length < 4 + length) break;
      messages.add(
        CastProtocolCodec.decodeBody(
          Uint8List.sublistView(bytes, 4, 4 + length),
        ),
      );
      bytes = Uint8List.sublistView(bytes, 4 + length);
    }
    _buffer.clear();
    _buffer.add(bytes);
    return messages;
  }
}
