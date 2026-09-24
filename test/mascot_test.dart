import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/widgets/mascot.dart';

void main() {
  test('Bloub and the fox are the mascots', () {
    expect(Mascot.values, [Mascot.bloub, Mascot.fox]);
    expect(Mascot.bloub.label, 'Bloub');
    expect(Mascot.fox.label, 'Fox');
  });

  test('nothing saved, something unknown or a removed mascot means the fox', () {
    expect(Mascot.byName(null), Mascot.fox);
    expect(Mascot.byName(''), Mascot.fox);
    expect(Mascot.byName('whatever'), Mascot.fox);
    // OpenClaw's GIFs are gone; a device that had it chosen shows the fox.
    expect(Mascot.byName('openclaw'), Mascot.fox);
    expect(Mascot.byName('bloub'), Mascot.bloub);
    expect(Mascot.fallback, Mascot.fox);
  });
}
