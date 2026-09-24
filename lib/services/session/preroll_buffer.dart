import 'dart:typed_data';

/// Speech captured before the socket was ready.
///
/// Holding the ring starts the mic at once, but connecting to Gemini takes a
/// second or two — and the wearer is already talking by then, because that is
/// what holding a button means. Without this their opening words, usually the
/// whole request, were recorded into nothing.
///
/// Bounded on purpose: if the connection never comes, minutes of stale audio
/// must not arrive at once and be answered as if it had just been said.
class PrerollBuffer {
  PrerollBuffer({this.limitBytes = 16000 * 2 * 8});

  /// Eight seconds of PCM16 at 16 kHz by default.
  final int limitBytes;

  final _chunks = <Uint8List>[];
  int _bytes = 0;

  int get bytes => _bytes;
  bool get isEmpty => _chunks.isEmpty;
  int get chunks => _chunks.length;

  /// Roughly how much speech is held, at 16 kHz PCM16.
  Duration get duration => Duration(milliseconds: _bytes ~/ 32);

  void add(Uint8List pcm) {
    _chunks.add(pcm);
    _bytes += pcm.length;
    while (_bytes > limitBytes && _chunks.isNotEmpty) {
      _bytes -= _chunks.removeAt(0).length;
    }
  }

  /// Hands over everything held and empties the buffer.
  List<Uint8List> takeAll() {
    final out = List<Uint8List>.from(_chunks);
    clear();
    return out;
  }

  void clear() {
    _chunks.clear();
    _bytes = 0;
  }
}
