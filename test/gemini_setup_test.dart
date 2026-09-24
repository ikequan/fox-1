import 'package:flutter_test/flutter_test.dart';
import 'package:fox1/config/constants.dart';
import 'package:fox1/services/gemini/gemini_live_client.dart';

/// What each Gemini 3.8 Live model needs in its setup message.
void main() {
  const tools = [
    {'name': 'set_timer', 'description': 'Start a timer.'},
  ];

  Map<String, dynamic> setupFor(String model) => GeminiLiveClient(
        config: GeminiConfig(apiKey: 'k', model: model, toolDeclarations: tools),
      ).buildSetupMessage()['setup'] as Map<String, dynamic>;

  List<Map> declarations(Map<String, dynamic> setup) =>
      ((setup['tools'] as List).single['functionDeclarations'] as List).cast<Map>();

  test('3.8 Live: tools block, no thinking setting, both transcripts on', () {
    final s = setupFor(AppConstants.geminiModel);
    expect(s['model'], 'models/gemini-3.8-live');
    expect((s['generationConfig'] as Map).containsKey('thinkingConfig'), isFalse);
    expect(declarations(s).single, {
      'name': 'set_timer',
      'description': 'Start a timer.',
      'behavior': 'BLOCKING',
    });
    expect(s['inputAudioTranscription'], isEmpty);
    expect(s['outputAudioTranscription'], isEmpty);
    expect(s.containsKey('proactivity'), isFalse);
    expect(s['generationConfig'].containsKey('enableAffectiveDialog'), isFalse);
  });

  test('extended thinking: a thinking level, and non-blocking tools only', () {
    final s = setupFor(AppConstants.geminiThinkingModel);
    expect(s['model'], 'models/gemini-3.8-live-extended-thinking');
    expect((s['generationConfig'] as Map)['thinkingConfig'], {'thinkingLevel': 'MEDIUM'});
    expect(declarations(s).single['behavior'], 'NON_BLOCKING');
    expect(tools.single.containsKey('behavior'), isFalse, reason: 'the declarations are not mutated');
  });

  test('only the two current models are kept', () {
    expect(AppConstants.geminiModels.map((m) => m.value),
        ['models/gemini-3.8-live', 'models/gemini-3.8-live-extended-thinking']);
    expect(AppConstants.supportedModel(AppConstants.geminiThinkingModel),
        AppConstants.geminiThinkingModel);
    expect(AppConstants.supportedModel('models/gemini-3.1-flash-live-preview'),
        AppConstants.geminiModel);
    expect(AppConstants.supportedModel('other'), AppConstants.geminiModel);
    expect(AppConstants.supportedModel(null), AppConstants.geminiModel);
  });

  test('interactionStatus: busy until IDLE; silent when not sent', () {
    expect(
        GeminiLiveClient.interactionBusy({
          'serverContent': {'turnComplete': true, 'interactionStatus': 'IN_PROGRESS'},
        }),
        isTrue);
    expect(
        GeminiLiveClient.interactionBusy({
          'serverContent': {'interactionStatus': 'IDLE'},
        }),
        isFalse);
    expect(
        GeminiLiveClient.interactionBusy({
          'serverContent': {'turnComplete': true},
        }),
        isNull);
  });
}
