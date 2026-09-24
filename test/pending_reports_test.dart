import 'package:flutter_test/flutter_test.dart';

import 'package:fox1/services/call/call_report.dart';
import 'package:fox1/services/call/pending_reports.dart';

/// Messages waiting for the wearer. The failure this guards against is an
/// assistant that announces something to an empty room and calls it delivered.
void main() {
  CallReport report({
    String number = '0200000001',
    String summary = 'Asked when the printing will be ready.',
    List<String> commitments = const [],
    List<String> asserted = const [],
    bool callback = false,
  }) =>
      CallReport(
        number: number,
        durationS: 62,
        summary: summary,
        commitments: commitments,
        callerAsserted: asserted,
        callbackRequested: callback,
      );

  test('nothing queued means nothing to say', () async {
    final p = PendingReports();
    expect(p.isEmpty, isTrue);
    expect(p.briefing(wearer: 'Alex'), '');
  });

  test('the briefing leads with who called and names the wearer', () async {
    final p = PendingReports();
    await p.add(report());
    final b = p.briefing(wearer: 'Alex');
    expect(b, contains('Alex'));
    expect(b, contains('0200000001 called'));
    expect(b, contains('printing'));
  });

  test('claims stay marked when passed to the wearer', () async {
    final p = PendingReports();
    await p.add(report(asserted: ['he already paid the deposit']));
    final b = p.briefing(wearer: 'Alex');
    expect(b, contains('CLAIMED'));
    expect(b, contains('unverified'));
  });

  test('commitments and callbacks are carried, not just the summary', () async {
    final p = PendingReports();
    await p.add(report(commitments: ['ring them back Friday'], callback: true));
    final b = p.briefing(wearer: 'Alex');
    expect(b, contains('you promised them: ring them back Friday'));
    expect(b, contains('asked to be called back'));
  });

  test('several calls are one message, not several', () async {
    final p = PendingReports();
    await p.add(report(number: '0200000001'));
    await p.add(report(number: '0209999999', summary: 'Wrong number.'));
    expect(p.length, 2);
    final b = p.briefing(wearer: 'Alex');
    expect(b, contains('Tell Alex about these now'));
  });

  test('clearing is what marks them delivered', () async {
    final p = PendingReports();
    await p.add(report());
    await p.clear();
    expect(p.isEmpty, isTrue);
    expect(p.briefing(wearer: 'Alex'), '');
  });

  test('a blank profile does not produce a nameless instruction', () async {
    final p = PendingReports();
    await p.add(report());
    expect(p.briefing(wearer: '   '), contains('your owner'));
  });
}
