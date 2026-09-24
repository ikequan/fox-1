import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../config/constants.dart';
import 'agent_bridge.dart';

/// Bridge to Agent Relay for executing tool calls from Gemini.
/// Exposes two tools: execute (submit async job) and check_job (poll status).
class AgentRelayBridge implements AgentBridge {
  final String host;
  final int? port;
  final String token;

  /// How much of each job's streamed output has already been handed to the
  /// model, so check_job can return only what is new. Returning the whole
  /// accumulated transcript on every call made the agent re-read the entire
  /// job each time it checked.
  final Map<String, int> _sentSentences = {};
  final Map<String, int> _sentChars = {};

  AgentRelayBridge({required this.host, this.port, required this.token});

  String get _baseUrl => port != null ? '$host:$port' : host;

  @override
  String get providerName => 'Agent Relay';

  @override
  List<Map<String, dynamic>> get toolDeclarations => [
    {
      'name': 'execute',
      'description':
          'Execute a task for the user via Agent Relay. '
          'The agent can perform web searches, send messages, manage '
          'lists and reminders, control smart home devices, and more. '
          'Describe the task in natural language. Returns a job_id — then poll '
          'check_job every few seconds until it reports done, relaying only the '
          'new output each time.',
      'parameters': {
        'type': 'object',
        'properties': {
          'task': {
            'type': 'string',
            'description':
                'Natural language description of the task to execute',
          },
        },
        'required': ['task'],
      },
    },
    {
      'name': 'check_job',
      'description':
          'Check on a background job started with execute. Returns ONLY the '
          'output that has arrived since your previous check, never the whole '
          'transcript. Call it every few seconds while a job runs. If '
          'has_new_output is false there is nothing to say — stay silent and '
          'check again. When done is true you get the final result.',
      'parameters': {
        'type': 'object',
        'properties': {
          'job_id': {
            'type': 'string',
            'description': 'The job_id returned by execute()',
          },
        },
        'required': ['job_id'],
      },
    },
  ];

  @override
  Future<Map<String, dynamic>> handleToolCall(
    String name,
    Map<String, dynamic> args,
  ) async {
    switch (name) {
      case 'execute':
        return execute(args['task'] as String? ?? args.toString());
      case 'check_job':
        return checkJob(
          args['job_id'] as String? ?? '',
          // The automatic poller needs the streamed output to compute deltas.
          // A model-initiated call must NOT get it: handing back the whole
          // accumulated transcript is what made the agent re-read the entire
          // job every time it checked.
          includeStream: args['_stream'] == true,
        );
      default:
        return {'success': false, 'error': 'Unknown tool: $name'};
    }
  }

  @override
  Future<Map<String, dynamic>> execute(String task) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_baseUrl/agent'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'prompt': task,
              'async': true,
              'resume': false,
              'stream': true,
              // true => stream_response is a growing string[] of COMPLETE
              // sentences, markdown-stripped for speech. false returns one
              // ever-growing raw markdown blob, which forced us to resend the
              // whole text on every poll — the model then restarted it from the
              // beginning each time. Sentences are the right unit for TTS.
              'chunk_response': true,
            }),
          )
          .timeout(AppConstants.agentRequestTimeout);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final jobId = data['job_id'] as String?;
        return {
          'success': true,
          'job_id': jobId ?? '',
          'result':
              'Job submitted. Use check_job with job_id "$jobId" to get results.',
        };
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'Agent Relay auth failed — check your token.',
        };
      } else {
        return {
          'success': false,
          'error': 'Agent Relay HTTP ${response.statusCode}: ${response.body}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Agent Relay unreachable: $e'};
    }
  }

  Future<Map<String, dynamic>> checkJob(
    String jobId, {
    bool includeStream = false,
  }) async {
    if (jobId.isEmpty) {
      return {'success': false, 'error': 'Missing job_id'};
    }
    try {
      final response = await http
          .get(
            Uri.parse('$_baseUrl/job/$jobId'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(AppConstants.agentJobCheckTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (includeStream) return {'success': true, ...data};

        final status = (data['status'] as String? ?? '').toLowerCase();
        final finished = status == 'completed' ||
            status == 'failed' ||
            status == 'error' ||
            status == 'cancelled';

        if (finished) {
          _sentSentences.remove(jobId);
          _sentChars.remove(jobId);
          return {
            'success': true,
            'status': data['status'],
            'done': true,
            if (data['error'] != null) 'error': data['error'],
            if (data['full_response'] != null || data['response'] != null)
              'result': data['full_response'] ?? data['response'],
          };
        }

        // Only the part that has arrived since the last check.
        final stream = data['stream_response'];
        var newOutput = '';
        if (stream is List) {
          final already = _sentSentences[jobId] ?? 0;
          if (stream.length > already) {
            newOutput = stream.sublist(already).map((e) => '$e').join(' ');
            _sentSentences[jobId] = stream.length;
          }
        } else if (stream is String) {
          final already = _sentChars[jobId] ?? 0;
          if (stream.length > already) {
            newOutput = stream.substring(already);
            _sentChars[jobId] = stream.length;
          }
        }

        return {
          'success': true,
          'status': data['status'],
          'done': false,
          'has_new_output': newOutput.trim().isNotEmpty,
          'new_output': newOutput,
          'note': newOutput.trim().isEmpty
              ? 'Still working, nothing new since your last check. Say nothing '
                  'and check again shortly.'
              : 'This is ONLY what is new since your last check. You have '
                  'already relayed everything before it — do not repeat it.',
        };
      } else {
        return {
          'success': false,
          'error': 'Agent Relay HTTP ${response.statusCode}: ${response.body}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'Agent Relay unreachable: $e'};
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/agent'))
          .timeout(AppConstants.agentPingTimeout);
      return response.statusCode < 500;
    } catch (_) {
      return false;
    }
  }
}
