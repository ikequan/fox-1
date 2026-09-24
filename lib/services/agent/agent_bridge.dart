/// Abstract interface for agent providers (OpenClaw, Agent Relay, etc.)
abstract class AgentBridge {
  /// Execute a task and return the result.
  Future<Map<String, dynamic>> execute(String task);

  /// Check if the agent is reachable.
  Future<bool> ping();

  /// Display name for transcript logging.
  String get providerName;

  /// Gemini function_declarations for the setup message.
  List<Map<String, dynamic>> get toolDeclarations;

  /// Route a tool call by name to the appropriate method.
  Future<Map<String, dynamic>> handleToolCall(
      String name, Map<String, dynamic> args);
}

enum AgentProviderType {
  openClaw('OpenClaw'),
  agentRelay('Agent Relay');

  final String label;
  const AgentProviderType(this.label);

  static AgentProviderType fromString(String value) {
    return AgentProviderType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => AgentProviderType.openClaw,
    );
  }
}
