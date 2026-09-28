import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../config/constants.dart';
import '../agent/agent_bridge.dart';

/// Bridge to OpenClaw gateway for executing tool calls from Gemini.
class OpenClawBridge implements AgentBridge {
  final String host;
  final int port;
  final String gatewayToken;
  final String? agentId;

  OpenClawBridge({
    required this.host,
    this.port = 18789,
    required this.gatewayToken,
    this.agentId,
  });

  String get _baseUrl => '$host:$port';

  @override
  String get providerName => 'OpenClaw';

  @override
  List<Map<String, dynamic>> get toolDeclarations => [
        {
          'name': 'execute',
          'description':
              'Execute a task for the user via OpenClaw — ONLY when the wearer '
                  'explicitly asks for OpenClaw or the relay agent, or for work '
                  'nothing on the device can do. Anything done with an app on the '
                  'device is done with your own tools, even when it gets difficult: '
                  'OpenClaw runs on another computer. OpenClaw has 56+ '
                  'skills including: web search, sending messages (WhatsApp, '
                  'Telegram, iMessage), managing lists and reminders, '
                  'controlling smart home devices, taking notes, and more. '
                  'Describe the task in natural language.',
          'parameters': {
            'type': 'object',
            'properties': {
              'task': {
                'type': 'string',
                'description':
                    'Natural language description of the task to execute '
                        '(e.g., "Add eggs to my shopping list", '
                        '"Send John a message saying I\'ll be late", '
                        '"Search for coffee shops nearby")',
              },
            },
            'required': ['task'],
          }
        }
      ];

  @override
  Future<Map<String, dynamic>> handleToolCall(
      String name, Map<String, dynamic> args) async {
    final task = args['task'] as String? ?? args.toString();
    return execute(task);
  }

  @override
  Future<Map<String, dynamic>> execute(String task) async {
    try {
      final headers = {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $gatewayToken',
        if (agentId != null) 'x-openclaw-agent-id': agentId!, // ignore: use_null_aware_elements
      };

      final body = {
        'model': 'openclaw',
        'messages': [
          {'role': 'user', 'content': task},
        ],
      };

      final response = await http
          .post(
            Uri.parse('$_baseUrl/v1/chat/completions'),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(AppConstants.agentRequestTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final choices = data['choices'] as List?;
        if (choices != null && choices.isNotEmpty) {
          final message = choices[0]['message'] as Map<String, dynamic>?;
          final content = message?['content'] as String? ?? '';
          return {'success': true, 'result': content};
        }
        return {'success': true, 'result': 'Task submitted to OpenClaw.'};
      } else if (response.statusCode == 401) {
        return {
          'success': false,
          'error': 'OpenClaw auth failed — check your gateway token.',
        };
      } else {
        return {
          'success': false,
          'error': 'OpenClaw HTTP ${response.statusCode}: ${response.body}',
        };
      }
    } catch (e) {
      return {'success': false, 'error': 'OpenClaw unreachable: $e'};
    }
  }

  @override
  Future<bool> ping() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/health'))
          .timeout(AppConstants.agentPingTimeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
