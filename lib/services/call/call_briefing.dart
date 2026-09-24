/// Composes what the call agent is told before it picks up.
///
/// This exists because the agent had no idea who it was or who it worked for.
/// Asked on a live call, it invented an owner called "Todd" — twice, unprompted
/// — and it introduced itself as nothing at all. Both are the same defect: the
/// call prompt was a fixed string with no identity in it, while the wearer's
/// name and the assistant's name were sitting in Settings the whole time.
///
/// The identity comes from the **AI Persona** setting, never from the system
/// prompt. That distinction is the point of the setting: the system prompt is
/// pages of on-device instructions — drive the screen, use the camera, poll jobs,
/// call `stand_down` — all of which is wrong on a phone call and some of which
/// is dangerous there. An earlier version took the prompt's opening paragraph
/// on the assumption the name lived at the top; that guessed at a structure the
/// wearer never agreed to, and leaked whatever else was in that paragraph.
library;

import '../../config/constants.dart';

/// The full system prompt handed to the call agent at connect time.
///
/// Deliberately assembled before the phone rings, because the Gemini setup
/// message is sent once per session. Anything caller-specific — history, who is
/// on the line — arrives later as an injected context message instead.
String composeCallPrompt({
  required String persona,
  required String userProfile,
  required String callInstructions,
  String name = GeminiConfig.defaultAssistantName,
}) {
  final identity = GeminiConfig.withName(persona.trim(), name);
  final profile = userProfile.trim();
  final b = StringBuffer();

  b.writeln('[Who you are]');
  b.writeln(nameLine(name));
  if (identity.isNotEmpty) b.writeln(identity);
  b.writeln();
  if (profile.isNotEmpty) {
    b.writeln('[Who you answer the phone for]');
    b.writeln(profile);
    b.writeln();
  }

  // Falling back rather than sending nothing: an empty field would leave the
  // agent with a name, an owner and no idea it was on a phone.
  final rules = callInstructions.trim();
  b.write(GeminiConfig.withName(rules.isEmpty ? GeminiConfig.defaultCallPrompt.trim() : rules, name));
  return b.toString();
}

/// Told to both agents first, so the name the wearer chose is the one used,
/// whatever the persona text says.
String nameLine(String name) {
  final n = name.trim().isEmpty ? GeminiConfig.defaultAssistantName : name.trim();
  return 'Your name is $n. Use it when you introduce yourself.';
}
