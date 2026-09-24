import 'package:intl/intl.dart';

import 'note_store.dart';

/// The assistant's view of the wearer's voice notes: list, search, read one.
///
/// "What did I note today?" is `list_notes` for today — there is no separate
/// journal to keep in step. New notes are mentioned through [announcement]
/// the next time the wearer talks to her.
class NoteTools {
  NoteTools(this.store, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final NoteStore store;
  final DateTime Function() _now;

  static const names = {'list_notes', 'search_notes', 'read_note'};

  Future<Map<String, dynamic>> handle(String name, Map<String, dynamic> args) async {
    try {
      return switch (name) {
        'list_notes' => await _list(args),
        'search_notes' => await _search(args),
        'read_note' => await _read(args),
        _ => {'success': false, 'error': 'Unknown notes tool: $name'},
      };
    } catch (e) {
      return {'success': false, 'error': 'Could not read the notes: $e'};
    }
  }

  Future<Map<String, dynamic>> _list(Map<String, dynamic> args) async {
    final day = _day(args['day']);
    final limit = ((args['limit'] as num?)?.toInt() ?? 10).clamp(1, 30);
    final notes = day != null ? await store.on(day) : (await store.all()).take(limit).toList();
    if (notes.isEmpty) {
      return {
        'success': true,
        'result': day != null
            ? 'No voice notes on ${_dayName(day)}.'
            : 'No voice notes yet. Quadruple-tap the ring to start recording one, '
                'and quadruple-tap again to stop.',
      };
    }
    final waiting = notes.where((n) => n.status == NoteStatus.pending).length;
    return {
      'success': true,
      'result': {
        if (day != null) 'day': _dayName(day),
        'notes': [for (final n in notes) _brief(n)],
        if (waiting > 0) 'still_transcribing': waiting,
      },
    };
  }

  Future<Map<String, dynamic>> _search(Map<String, dynamic> args) async {
    final q = '${args['query'] ?? ''}'.trim();
    if (q.isEmpty) return {'success': false, 'error': 'Nothing to search for.'};
    final found = (await store.search(q)).take(10).toList();
    if (found.isEmpty) {
      return {'success': true, 'result': 'No voice note mentions "$q".'};
    }
    return {
      'success': true,
      'result': {
        'notes': [
          for (final n in found) {..._brief(n), 'snippet': ?_snippet(n, q)},
        ],
      },
    };
  }

  Future<Map<String, dynamic>> _read(Map<String, dynamic> args) async {
    final id = '${args['id'] ?? 'latest'}'.trim();
    final n = id == 'latest' || id.isEmpty
        ? (await store.all()).firstOrNull
        : await store.get(id);
    if (n == null) {
      return {'success': false, 'error': 'No such note. Use list_notes or search_notes for its id.'};
    }
    if (n.status == NoteStatus.pending) {
      return {
        'success': true,
        'result': {
          ..._brief(n),
          'state': 'still being transcribed — it will be ready shortly',
        },
      };
    }
    if (n.status == NoteStatus.failed) {
      return {
        'success': true,
        'result': {
          ..._brief(n),
          'state': 'could not be transcribed (${n.error ?? 'unknown reason'}); '
              'the recording itself is kept on the device',
        },
      };
    }
    return {
      'success': true,
      'result': {
        'id': n.id,
        'recorded': _when(n.recordedAt),
        'length': _length(n.duration),
        'title': n.title,
        'summary': n.summary,
        'transcript': (n.transcript ?? '').isEmpty ? '(no speech)' : n.transcript,
        'language': ?n.language,
        if (n.actionItems.isNotEmpty) 'action_items': n.actionItems,
        if (n.people.isNotEmpty) 'people': n.people,
        if (n.dates.isNotEmpty) 'dates': n.dates,
      },
    };
  }

  Map<String, Object?> _brief(Note n) => {
        'id': n.id,
        'recorded': _when(n.recordedAt),
        'length': _length(n.duration),
        'title': switch (n.status) {
          NoteStatus.done => n.title,
          NoteStatus.pending => 'not transcribed yet',
          NoteStatus.failed => 'could not be transcribed',
        },
        if (n.transcribed && (n.summary ?? '').isNotEmpty) 'summary': n.summary,
        if (n.actionItems.isNotEmpty) 'action_items': n.actionItems,
      };

  /// A few words either side of the first match in the transcript.
  String? _snippet(Note n, String q) {
    final t = n.transcript ?? '';
    final word = q.toLowerCase().split(RegExp(r'\s+')).first;
    final at = t.toLowerCase().indexOf(word);
    if (at < 0) return null;
    final from = (at - 60).clamp(0, t.length);
    final to = (at + word.length + 60).clamp(0, t.length);
    return '${from > 0 ? '…' : ''}${t.substring(from, to)}${to < t.length ? '…' : ''}';
  }

  DateTime? _day(Object? v) {
    final s = '${v ?? ''}'.trim().toLowerCase();
    if (s.isEmpty) return null;
    final today = DateTime(_now().year, _now().month, _now().day);
    if (s == 'today') return today;
    if (s == 'yesterday') return DateTime(today.year, today.month, today.day - 1);
    return DateTime.tryParse(s);
  }

  String _dayName(DateTime d) {
    final today = DateTime(_now().year, _now().month, _now().day);
    final diff = today.difference(DateTime(d.year, d.month, d.day)).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'yesterday';
    return DateFormat('EEEE d MMMM').format(d);
  }

  String _when(DateTime t) {
    final day = _dayName(t);
    final clock = DateFormat('HH:mm').format(t);
    return day == 'today' || day == 'yesterday' ? '$day at $clock' : '$day, $clock';
  }

  static String _length(Duration d) {
    final s = d.inSeconds;
    return s < 60 ? '$s s' : '${s ~/ 60} min ${s % 60} s';
  }

  /// Handed to the assistant when the wearer next talks to it. An instruction,
  /// not a script: she decides how to fit it in.
  static String announcement(List<Note> fresh) {
    final list = [
      for (final n in fresh.take(5))
        '"${n.title}" (${DateFormat('EEE HH:mm').format(n.recordedAt)})',
    ].join(', ');
    final more = fresh.length > 5 ? ' and ${fresh.length - 5} more' : '';
    return '[New voice notes the wearer recorded on the ring since you last '
        'spoke: $list$more. After you have dealt with whatever they are asking, '
        'mention them in one short sentence — titles only — and offer to read '
        'one. Do not read them out unless asked.]';
  }

  static const List<Map<String, dynamic>> declarations = [
    {
      'name': 'list_notes',
      'description':
          'Voice notes the wearer recorded on their ring (quadruple-tap to start '
              'and stop), newest first, with titles and summaries — transcribed '
              'automatically. Use for "what did I record today", "what did I note '
              'this morning", "my notes from yesterday" (pass day). To read one '
              'in full, use read_note.',
      'parameters': {
        'type': 'object',
        'properties': {
          'day': {
            'type': 'string',
            'description': '"today", "yesterday" or YYYY-MM-DD. Omit for the most recent notes.',
          },
          'limit': {
            'type': 'integer',
            'description': 'How many, when no day is given. Default 10.',
          },
        },
      },
    },
    {
      'name': 'search_notes',
      'description':
          'Find voice notes by what was said in them, a person or a topic. Use '
              'for "the note where I talked about the grant", "what did I say '
              'about Emmanuel".',
      'parameters': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Words to look for.'},
        },
        'required': ['query'],
      },
    },
    {
      'name': 'read_note',
      'description':
          'One voice note in full: the transcript in the language it was spoken, '
              'summary, action items, people and dates. Pass an id from list_notes '
              'or search_notes, or "latest". Give the summary unless the wearer '
              'asks to hear it word for word.',
      'parameters': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'The note id, or "latest".'},
        },
        'required': ['id'],
      },
    },
  ];
}
