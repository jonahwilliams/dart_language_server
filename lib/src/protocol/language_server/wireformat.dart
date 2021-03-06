import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';
import 'package:async/async.dart';

class StdIOStreamChannel extends StreamChannelMixin<String> {
  final StreamSink<String> sink;
  final Stream<String> stream;

  factory StdIOStreamChannel() {
    var parser = new _Parser();
    var outSink = new StreamSinkTransformer.fromHandlers(
        handleData: _serialize,
        handleDone: (sink) {
          sink.close();
          parser.close();
        }).bind(stdout);
    return new StdIOStreamChannel._(parser.stream, outSink);
  }

  StdIOStreamChannel._(this.stream, this.sink);
}

void _serialize(String data, EventSink<List<int>> sink) {
  var message = UTF8.encode(data);
  var header = 'Content-Length: ${message.length}\r\n\r\n';
  sink.add(ASCII.encode(header));
  for (var chunk in _chunks(message, 1024)) {
    sink.add(chunk);
  }
}

class _Parser {
  final _streamCtl = new StreamController<String>();
  Stream<String> get stream => _streamCtl.stream;

  final _buffer = <int>[];
  bool _headerMode = true;
  int _contentLength = -1;

  StreamSubscription _subscription;

  _Parser() {
    _subscription =
        stdin.expand((bytes) => bytes).listen(_handleByte, onDone: () {
      _streamCtl.close();
    });
  }

  Future<Null> close() => _subscription.cancel();

  void _handleByte(int byte) {
    _buffer.add(byte);
    if (_headerMode && _headerComplete) {
      _contentLength = _parseContentLength();
      _buffer.clear();
      _headerMode = false;
    } else if (!_headerMode && _messageComplete) {
      _streamCtl.add(UTF8.decode(_buffer));
      _buffer.clear();
      _headerMode = true;
    }
  }

  /// Whether the entire message is in [_buffer].
  bool get _messageComplete => _buffer.length >= _contentLength;

  /// Decodes [_buffer] into a String and looks for the 'Content-Length' header.
  int _parseContentLength() {
    var asString = ASCII.decode(_buffer);
    var headers = asString.split('\r\n');
    var lengthHeader =
        headers.firstWhere((h) => h.startsWith('Content-Length'));
    var length = lengthHeader.split(':').last.trim();
    return int.parse(length);
  }

  /// Whether [_buffer] ends in '\r\n\r\n'.
  bool get _headerComplete {
    var l = _buffer.length;
    return l > 4 &&
        _buffer[l - 1] == 10 &&
        _buffer[l - 2] == 13 &&
        _buffer[l - 3] == 10 &&
        _buffer[l - 4] == 13;
  }
}

Iterable<List<T>> _chunks<T>(List<T> data, int chunkSize) sync* {
  if (data.length <= chunkSize) {
    yield data;
    return;
  }
  int low = 0;
  while (low < data.length) {
    if (data.length > low + chunkSize) {
      yield data.sublist(low, low + chunkSize);
    } else {
      yield data.sublist(low);
    }
    low += chunkSize;
  }
}
