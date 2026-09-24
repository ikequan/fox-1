import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../config/constants.dart';
import '../providers/providers.dart';
import '../services/agent/agent_bridge.dart';
import '../services/camera/watch_camera_service.dart';
import '../services/call/auto_answer.dart';
import '../services/call/call_agent_duty.dart';
import '../services/bridge/call_bridge_service.dart';
import '../watch_avatar/watch_avatar.dart' show WatchAvatar;
import '../widgets/mascot.dart';
import 'avatar_design_screen.dart';
import '../widgets/ring_settings_card.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late TextEditingController _apiKeyController;
  late TextEditingController _ocHostController;
  late TextEditingController _ocPortController;
  late TextEditingController _ocTokenController;
  late TextEditingController _arHostController;
  late TextEditingController _arPortController;
  late TextEditingController _arTokenController;
  late TextEditingController _nameController;
  late TextEditingController _personaController;
  late TextEditingController _systemPromptController;
  late TextEditingController _userProfileController;
  late TextEditingController _callPromptController;
  late TextEditingController _aaBlockedController;
  late TextEditingController _aaAlwaysController;

  /// Null until checked.
  bool? _answerPermission;

  /// Taps on "FOX-1" at the bottom; seven in a row show the
  /// developer tools.
  int _aboutTaps = 0;
  DateTime? _lastAboutTap;

  /// Reverts the About label when tapping stops.
  Timer? _aboutReset;

  /// Shown in place of "FOX-1" while counting taps. It has to be the
  /// label itself: a SnackBar rises from the bottom and covers the very text
  /// being tapped, so taps 5–7 landed on the SnackBar and never arrived.
  String? _aboutNote;

  /// Boards paired with this device. Loaded once when Settings opens.
  List<PairedDevice> _boards = const [];

  Future<void> _loadBoards() async {
    final found = await CallBridgeService().listPaired();
    if (!mounted) return;
    setState(() => _boards = found);
    // One obvious candidate and nothing chosen: choose it. Making the wearer
    // pick a MAC address out of a list when only one device advertises itself
    // as the call bridge is a step that exists for no reason.
    if (ref.read(callAgentDeviceProvider).isNotEmpty) return;
    final board = found.where((d) => d.looksLikeBoard).toList();
    if (board.length == 1) await _chooseBoard(board.single.address);
  }

  Future<void> _chooseBoard(String address) async {
    ref.read(callAgentDeviceProvider.notifier).state = address;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('call_agent_device', address);
  }

  String _boardLabel(String address) {
    if (address.isEmpty) return 'Not chosen';
    for (final d in _boards) {
      if (d.address == address) return d.name;
    }
    return address;
  }

  void _showDutyError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 5)),
    );
  }

  WatchCameraService? _previewCamera;
  StreamSubscription? _frameSub;
  Uint8List? _latestFrame;
  bool _previewOn = false;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(
      text: ref.read(geminiApiKeyProvider),
    );
    _ocHostController = TextEditingController(
      text: ref.read(openClawHostProvider),
    );
    _ocPortController = TextEditingController(
      text: ref.read(openClawPortProvider).toString(),
    );
    _ocTokenController = TextEditingController(
      text: ref.read(openClawTokenProvider),
    );
    _arHostController = TextEditingController(
      text: ref.read(agentRelayHostProvider),
    );
    final arPort = ref.read(agentRelayPortProvider);
    _arPortController = TextEditingController(
      text: arPort != null ? arPort.toString() : '',
    );
    _arTokenController = TextEditingController(
      text: ref.read(agentRelayTokenProvider),
    );
    _nameController = TextEditingController(text: ref.read(assistantNameProvider));
    _personaController = TextEditingController(
      text: ref.read(aiPersonaProvider),
    );
    _systemPromptController = TextEditingController(
      text: ref.read(userSystemPromptProvider),
    );
    _userProfileController = TextEditingController(
      text: ref.read(userProfileProvider),
    );
    _callPromptController = TextEditingController(
      text: ref.read(callAgentPromptProvider),
    );
    _aaBlockedController = TextEditingController(
      text: ref.read(autoAnswerBlockedProvider),
    );
    _aaAlwaysController = TextEditingController(
      text: ref.read(autoAnswerAlwaysProvider),
    );
    _loadBoards();
    CallAnswerer().hasPermission().then((ok) {
      if (mounted) setState(() => _answerPermission = ok);
    });
  }

  Future<void> _startPreview() async {
    if (_previewCamera != null) return;
    _previewCamera = WatchCameraService();
    try {
      await _previewCamera!.start(config: _currentConfig());
      _frameSub = _previewCamera!.frames.listen((frame) {
        if (mounted) setState(() => _latestFrame = frame);
      });
    } catch (e) {
      debugPrint('[SETTINGS] Camera preview error: $e');
      _previewCamera?.dispose();
      _previewCamera = null;
    }
  }

  Future<void> _stopPreview() async {
    _frameSub?.cancel();
    _frameSub = null;
    _previewCamera?.dispose();
    _previewCamera = null;
    _latestFrame = null;
  }

  CameraConfig _currentConfig() => CameraConfig(
    rotation: ref.read(cameraRotationProvider),
    quality: ref.read(cameraQualityProvider),
    resolution: ref.read(cameraResolutionProvider),
    mirror: ref.read(cameraMirrorProvider),
    aspectRatio: ref.read(cameraAspectRatioProvider),
  );

  @override
  void dispose() {
    _aboutReset?.cancel();
    _stopPreview();
    _apiKeyController.dispose();
    _ocHostController.dispose();
    _ocPortController.dispose();
    _ocTokenController.dispose();
    _arHostController.dispose();
    _arPortController.dispose();
    _arTokenController.dispose();
    _nameController.dispose();
    _personaController.dispose();
    _systemPromptController.dispose();
    _userProfileController.dispose();
    _callPromptController.dispose();
    _aaBlockedController.dispose();
    _aaAlwaysController.dispose();
    super.dispose();
  }

  /// The portal belongs to [PortalService], not to this screen: it stays on
  /// when Settings closes, and turns itself off when unused.
  Future<void> _startServer() async {
    final why = await ref.read(portalServiceProvider).start();
    if (why != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
    }
  }

  Future<void> _stopServer() => ref.read(portalServiceProvider).stop();

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();

    final apiKey = _apiKeyController.text.trim();
    ref.read(geminiApiKeyProvider.notifier).state = apiKey;
    await prefs.setString('gemini_api_key', apiKey);

    final model = ref.read(geminiModelProvider);
    await prefs.setString('gemini_model', model);

    final voice = ref.read(geminiVoiceProvider);
    await prefs.setString('gemini_voice', voice);

    await prefs.setString('mascot', ref.read(mascotProvider).name);

    final ocHost = _ocHostController.text.trim();
    ref.read(openClawHostProvider.notifier).state = ocHost;
    await prefs.setString('openclaw_host', ocHost);

    final ocPort = int.tryParse(_ocPortController.text.trim()) ?? 18789;
    ref.read(openClawPortProvider.notifier).state = ocPort;
    await prefs.setInt('openclaw_port', ocPort);

    final ocToken = _ocTokenController.text.trim();
    ref.read(openClawTokenProvider.notifier).state = ocToken;
    await prefs.setString('openclaw_token', ocToken);

    // Agent provider type
    final providerType = ref.read(agentProviderTypeProvider);
    await prefs.setString('agent_provider_type', providerType.name);

    // Agent Relay settings
    final arHost = _arHostController.text.trim();
    ref.read(agentRelayHostProvider.notifier).state = arHost;
    await prefs.setString('agent_relay_host', arHost);

    final arPortText = _arPortController.text.trim();
    final arPort = arPortText.isEmpty ? null : int.tryParse(arPortText);
    ref.read(agentRelayPortProvider.notifier).state = arPort;
    if (arPort != null) {
      await prefs.setInt('agent_relay_port', arPort);
    } else {
      await prefs.remove('agent_relay_port');
    }

    final arToken = _arTokenController.text.trim();
    ref.read(agentRelayTokenProvider.notifier).state = arToken;
    await prefs.setString('agent_relay_token', arToken);

    // Name + persona + system prompt + profile
    final name = _nameController.text.trim().isEmpty
        ? GeminiConfig.defaultAssistantName
        : _nameController.text.trim();
    ref.read(assistantNameProvider.notifier).state = name;
    await prefs.setString('assistant_name', name);

    final persona = _personaController.text.trim();
    ref.read(aiPersonaProvider.notifier).state = persona;
    await prefs.setString('ai_persona', persona);

    final sysPrompt = _systemPromptController.text.trim();
    ref.read(userSystemPromptProvider.notifier).state = sysPrompt;
    await prefs.setString('user_system_prompt', sysPrompt);

    final profile = _userProfileController.text.trim();
    ref.read(userProfileProvider.notifier).state = profile;
    await prefs.setString('user_profile', profile);

    await prefs.setString(
      'auto_answer_mode',
      ref.read(autoAnswerModeProvider).name,
    );
    await prefs.setInt('auto_answer_delay', ref.read(autoAnswerDelayProvider));
    final aaBlocked = _aaBlockedController.text.trim();
    ref.read(autoAnswerBlockedProvider.notifier).state = aaBlocked;
    await prefs.setString('auto_answer_blocked', aaBlocked);
    final aaAlways = _aaAlwaysController.text.trim();
    ref.read(autoAnswerAlwaysProvider.notifier).state = aaAlways;
    await prefs.setString('auto_answer_always', aaAlways);

    final callPrompt = _callPromptController.text.trim();
    ref.read(callAgentPromptProvider.notifier).state = callPrompt;
    await prefs.setString('call_agent_prompt', callPrompt);

    // Camera settings
    await prefs.setInt('camera_rotation', ref.read(cameraRotationProvider));
    await prefs.setInt('camera_quality', ref.read(cameraQualityProvider));
    await prefs.setString(
      'camera_resolution',
      ref.read(cameraResolutionProvider),
    );
    await prefs.setBool('camera_mirror', ref.read(cameraMirrorProvider));
    await prefs.setString(
      'camera_aspect_ratio',
      ref.read(cameraAspectRatioProvider),
    );

    // Watchface font settings
    final fontFamily = ref.read(watchFontFamilyProvider);
    await prefs.setString('watch_font_family', fontFamily);

    final fontWeight = ref.read(watchFontWeightProvider);
    await prefs.setInt('watch_font_weight', fontWeight);

    final sizeFactor = ref.read(watchFontSizeFactorProvider);
    await prefs.setDouble('watch_font_size_factor', sizeFactor);
    await prefs.setDouble('watch_time_x', ref.read(watchTimeXProvider));
    await prefs.setDouble('watch_time_y', ref.read(watchTimeYProvider));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Settings saved'),
          duration: Duration(seconds: 1),
        ),
      );
      Navigator.of(context).pop();
    }
  }

  static FontWeight _fontWeightFromInt(int weight) {
    return switch (weight) {
      100 => FontWeight.w100,
      300 => FontWeight.w300,
      400 => FontWeight.w400,
      500 => FontWeight.w500,
      600 => FontWeight.w600,
      700 => FontWeight.w700,
      800 => FontWeight.w800,
      _ => FontWeight.w600,
    };
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = ref.watch(geminiModelProvider);
    final selectedVoice = ref.watch(geminiVoiceProvider);
    final selectedProvider = ref.watch(agentProviderTypeProvider);
    final selectedRotation = ref.watch(cameraRotationProvider);
    final selectedQuality = ref.watch(cameraQualityProvider);
    final selectedResolution = ref.watch(cameraResolutionProvider);
    final selectedMirror = ref.watch(cameraMirrorProvider);
    final selectedAspectRatio = ref.watch(cameraAspectRatioProvider);
    final selectedFontFamily = ref.watch(watchFontFamilyProvider);
    final selectedFontWeight = ref.watch(watchFontWeightProvider);
    final selectedSizeFactor = ref.watch(watchFontSizeFactorProvider);
    final serverRunning = ref.watch(webServerRunningProvider);
    final hotspotInfo = ref.watch(webServerHotspotInfoProvider);
    final devMode = ref.watch(developerModeProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Settings', style: TextStyle(fontSize: 16)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text(
              'Save',
              style: TextStyle(color: Color(0xFF00E5CC), fontSize: 13),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Gemini section
          const _SectionHeader('Gemini AI'),
          _buildTextField('API Key', _apiKeyController, obscure: true),
          const SizedBox(height: 8),
          // Model picker
          _buildLabel('Model'),
          _buildDropdownContainer(
            child: DropdownButton<String>(
              value: AppConstants.supportedModel(selectedModel),
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.geminiModels.map((m) {
                return DropdownMenuItem(
                  value: m.value,
                  child: Text(m.label, overflow: TextOverflow.ellipsis),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) ref.read(geminiModelProvider.notifier).state = v;
              },
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Extended Thinking reasons in the background while she talks — '
            'better on multi-step tasks, slower to finish them. Phone calls '
            'always use 3.8 Live.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 8),
          // Voice picker
          _buildDropdownContainer(
            child: DropdownButton<String>(
              value: selectedVoice,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.geminiVoices.map((v) {
                return DropdownMenuItem(
                  value: v.name,
                  child: Text('${v.name} (${v.style})'),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(geminiVoiceProvider.notifier).state = v;
                }
              },
            ),
          ),

          // AI Persona section. Separate from the system prompt because the
          // call agent sees this and not that — it needs a name to introduce
          // itself with, but the device instructions would mislead it on a call.
          const SizedBox(height: 16),
          const _SectionHeader('Name'),
          TextField(
            controller: _nameController,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: GeminiConfig.defaultAssistantName,
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'What your assistant is called. Write {name} in the persona or '
            'instructions and it becomes this.',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),

          const SizedBox(height: 16),
          const _SectionHeader('AI Persona'),
          TextField(
            controller: _personaController,
            maxLines: 3,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'You are {name}, an AI assistant. You are...',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Name and character. Used by the device assistant AND when '
            'answering phone calls',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),

          // System Prompt section
          const SizedBox(height: 16),
          const _SectionHeader('System Prompt'),
          TextField(
            controller: _systemPromptController,
            maxLines: 4,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Add custom instructions for the AI...',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Instructions for the device assistant only — never sent to the '
            'call agent',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),

          // User Profile section
          const SizedBox(height: 16),
          const _SectionHeader('User Profile'),
          TextField(
            controller: _userProfileController,
            maxLines: 4,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Name, preferences, context about yourself...',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Gemini will know this about you in every session',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),

          // Call Agent duty. Above auto-answer because none of those settings
          // do anything while the agent is off.
          const SizedBox(height: 16),
          const _SectionHeader('Call Agent'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeThumbColor: const Color(0xFF00E5CC),
            value: ref.watch(callAgentOnDutyProvider),
            title: const Text(
              'On duty',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
            subtitle: const Text(
              'Connects the board and answers calls. Holds a wake lock.',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
            onChanged: (on) async {
              ref.read(callAgentOnDutyProvider.notifier).state = on;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('call_agent_on_duty', on);
              if (!on) {
                await stopCallAgent();
                return;
              }
              final addr = ref.read(callAgentDeviceProvider);
              if (addr.isEmpty) {
                _showDutyError('Choose the board below first.');
                ref.read(callAgentOnDutyProvider.notifier).state = false;
                await prefs.setBool('call_agent_on_duty', false);
                return;
              }
              final err = await startCallAgent(addr);
              if (err != null) _showDutyError(err);
            },
          ),
          Row(
            children: [
              const Text(
                'Board',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: ref.watch(callAgentDeviceProvider).isEmpty
                      ? null
                      : ref.watch(callAgentDeviceProvider),
                  hint: Text(
                    _boards.isEmpty ? 'No paired devices' : 'Choose the board',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  dropdownColor: const Color(0xFF1A1A1A),
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final d in _boards)
                      DropdownMenuItem(
                        value: d.address,
                        child: Text(
                          d.name + (d.looksLikeBoard ? '  ·  call bridge' : ''),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) _chooseBoard(v);
                  },
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.refresh,
                  size: 18,
                  color: Colors.white54,
                ),
                onPressed: _loadBoards,
              ),
            ],
          ),
          Text(
            ref.watch(callAgentDeviceProvider).isEmpty
                ? 'Pair the ESP32 call bridge in Bluetooth settings, then pick '
                      'it here'
                : 'Using ${_boardLabel(ref.watch(callAgentDeviceProvider))}',
            style: TextStyle(
              color: ref.watch(callAgentDeviceProvider).isEmpty
                  ? const Color(0xFFFFAA00)
                  : Colors.white38,
              fontSize: 10,
            ),
          ),

          // Auto-Answer section.
          const SizedBox(height: 16),
          const _SectionHeader('Auto-Answer'),
          for (final m in AutoAnswerMode.values)
            InkWell(
              onTap: () => ref.read(autoAnswerModeProvider.notifier).state = m,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      ref.watch(autoAnswerModeProvider) == m
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: ref.watch(autoAnswerModeProvider) == m
                          ? const Color(0xFF00E5CC)
                          : Colors.white38,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        switch (m) {
                          AutoAnswerMode.off => 'Never — I answer my own phone',
                          AutoAnswerMode.known =>
                            'Only callers already on file',
                          AutoAnswerMode.everyone => 'Anyone not blocked',
                        },
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                'Ring first',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: Slider(
                  value: ref.watch(autoAnswerDelayProvider).toDouble(),
                  min: 2,
                  max: 20,
                  divisions: 18,
                  activeColor: const Color(0xFF00E5CC),
                  label: '${ref.watch(autoAnswerDelayProvider)}s',
                  onChanged: (v) =>
                      ref.read(autoAnswerDelayProvider.notifier).state = v
                          .round(),
                ),
              ),
              Text(
                '${ref.watch(autoAnswerDelayProvider)}s',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
          const Text(
            'Never zero — you always get the chance to answer it yourself',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),
          const SizedBox(height: 8),
          // Without ANSWER_PHONE_CALLS the device cannot pick up at all, and
          // there is no ADB here to grant it with.
          OutlinedButton.icon(
            icon: const Icon(Icons.phone_callback, size: 16),
            label: Text(
              _answerPermission == true
                  ? 'Answer permission granted'
                  : 'Grant answer permission',
            ),
            onPressed: _answerPermission == true
                ? null
                : () async {
                    await CallAnswerer().requestPermission();
                    // The dialog is asynchronous; re-check on the way back.
                    await Future.delayed(const Duration(seconds: 1));
                    final ok = await CallAnswerer().hasPermission();
                    if (mounted) setState(() => _answerPermission = ok);
                  },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _aaBlockedController,
            maxLines: 2,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Never answer these numbers...',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _aaAlwaysController,
            maxLines: 2,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Always answer these numbers...',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),

          // Call Agent section. The ONLY instruction text a caller's session
          // sees — the System Prompt above never reaches it.
          const SizedBox(height: 16),
          const _SectionHeader('Call Agent'),
          TextField(
            controller: _callPromptController,
            maxLines: 6,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'How to behave when answering the phone...',
              hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
              filled: true,
              fillColor: Colors.white.withValues(alpha: 0.05),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Instructions for answering phone calls. Persona and User Profile '
            'are added automatically',
            style: TextStyle(color: Colors.white38, fontSize: 10),
          ),

          const SizedBox(height: 16),
          const _SectionHeader('Agent'),
          _buildDropdownContainer(
            child: DropdownButton<AgentProviderType>(
              value: selectedProvider,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AgentProviderType.values.map((p) {
                return DropdownMenuItem(value: p, child: Text(p.label));
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(agentProviderTypeProvider.notifier).state = v;
                }
              },
            ),
          ),
          const SizedBox(height: 8),
          if (selectedProvider == AgentProviderType.openClaw) ...[
            _buildTextField(
              'Host',
              _ocHostController,
              hint: 'http://192.168.1.42',
            ),
            const SizedBox(height: 8),
            _buildTextField(
              'Port',
              _ocPortController,
              keyboard: TextInputType.number,
            ),
            const SizedBox(height: 8),
            _buildTextField('Token', _ocTokenController, obscure: true),
          ] else ...[
            _buildTextField(
              'Host',
              _arHostController,
              hint: 'http://192.168.1.42',
            ),
            const SizedBox(height: 8),
            _buildTextField(
              'Port (optional)',
              _arPortController,
              keyboard: TextInputType.number,
              hint: 'Leave empty if none',
            ),
            const SizedBox(height: 8),
            _buildTextField('Token', _arTokenController, obscure: true),
          ],

          // Camera section
          const SizedBox(height: 16),
          const _SectionHeader('Camera'),

          // Preview toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Live Preview',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Switch(
                value: _previewOn,
                activeTrackColor: const Color(0xFF00E5CC),
                onChanged: (on) {
                  setState(() => _previewOn = on);
                  if (on) {
                    _startPreview();
                  } else {
                    _stopPreview();
                    setState(() {});
                  }
                },
              ),
            ],
          ),

          // Live preview (only when toggled on)
          if (_previewOn)
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0F),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              clipBehavior: Clip.antiAlias,
              child: _latestFrame != null
                  ? Image.memory(
                      _latestFrame!,
                      gaplessPlayback: true,
                      fit: BoxFit.contain,
                      width: double.infinity,
                    )
                  : const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF00E5CC),
                        ),
                      ),
                    ),
            ),
          const SizedBox(height: 8),

          // Resolution dropdown
          _buildLabel('Resolution'),
          _buildDropdownContainer(
            child: DropdownButton<String>(
              value: selectedResolution,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.cameraResolutions.map((r) {
                return DropdownMenuItem(value: r.value, child: Text(r.label));
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(cameraResolutionProvider.notifier).state = v;
                  if (_previewOn) _previewCamera?.updateConfig(_currentConfig());
                }
              },
            ),
          ),
          const SizedBox(height: 8),

          // Quality slider
          _buildLabel('JPEG Quality'),
          Row(
            children: [
              const Text(
                '10',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              Expanded(
                child: Slider(
                  value: selectedQuality.toDouble(),
                  min: 10,
                  max: 100,
                  divisions: 18,
                  activeColor: const Color(0xFF00E5CC),
                  inactiveColor: Colors.white12,
                  label: selectedQuality.toString(),
                  onChanged: (v) {
                    ref.read(cameraQualityProvider.notifier).state = v.round();
                    if (_previewOn) _previewCamera?.updateConfig(_currentConfig());
                  },
                ),
              ),
              const Text(
                '100',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Rotation dropdown
          _buildLabel('Rotation'),
          _buildDropdownContainer(
            child: DropdownButton<int>(
              value: selectedRotation,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.cameraRotations.map((r) {
                return DropdownMenuItem(value: r.value, child: Text(r.label));
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(cameraRotationProvider.notifier).state = v;
                  if (_previewOn) _previewCamera?.updateConfig(_currentConfig());
                }
              },
            ),
          ),
          const SizedBox(height: 8),

          // Mirror toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Mirror (Horizontal Flip)',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Switch(
                value: selectedMirror,
                activeTrackColor: const Color(0xFF00E5CC),
                onChanged: (v) {
                  ref.read(cameraMirrorProvider.notifier).state = v;
                  if (_previewOn) _previewCamera?.updateConfig(_currentConfig());
                },
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Aspect ratio dropdown
          _buildLabel('Aspect Ratio'),
          _buildDropdownContainer(
            child: DropdownButton<String>(
              value: selectedAspectRatio,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.cameraAspectRatios.map((a) {
                return DropdownMenuItem(value: a.value, child: Text(a.label));
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(cameraAspectRatioProvider.notifier).state = v;
                  if (_previewOn) _previewCamera?.updateConfig(_currentConfig());
                }
              },
            ),
          ),

          // Mascot — the character on the watch face, the AI screen and the
          // app list. It follows the AI: listening, thinking, speaking.
          const SizedBox(height: 16),
          const _SectionHeader('Mascot'),
          _buildDropdownContainer(
            child: DropdownButton<Mascot>(
              value: ref.watch(mascotProvider),
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: [
                for (final m in Mascot.values)
                  DropdownMenuItem(value: m, child: Text(m.label)),
              ],
              onChanged: (m) {
                if (m != null) ref.read(mascotProvider.notifier).state = m;
              },
            ),
          ),
          const SizedBox(height: 8),
          Center(child: _mascotPreview()),
          Center(
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AvatarDesignScreen()),
              ),
              icon: const Icon(Icons.tune, size: 16, color: Color(0xFF00E5CC)),
              label: const Text(
                'Design',
                style: TextStyle(color: Color(0xFF00E5CC), fontSize: 13),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Shown on the watch face, the AI screen and the app list, and it '
            'follows what the assistant is doing.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),

          // Watchface section
          const SizedBox(height: 16),
          const _SectionHeader('Watchface'),

          // Font family dropdown
          _buildLabel('Font Family'),
          _buildDropdownContainer(
            child: DropdownButton<String>(
              value: selectedFontFamily,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.watchFonts.map((font) {
                return DropdownMenuItem(value: font, child: Text(font));
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(watchFontFamilyProvider.notifier).state = v;
                }
              },
            ),
          ),

          const SizedBox(height: 8),

          // Font weight dropdown
          _buildLabel('Font Weight'),
          _buildDropdownContainer(
            child: DropdownButton<int>(
              value: selectedFontWeight,
              isExpanded: true,
              dropdownColor: const Color(0xFF1A1A1A),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              items: AppConstants.fontWeights.map((w) {
                return DropdownMenuItem(
                  value: w.value,
                  child: Text('${w.label} (${w.value})'),
                );
              }).toList(),
              onChanged: (v) {
                if (v != null) {
                  ref.read(watchFontWeightProvider.notifier).state = v;
                }
              },
            ),
          ),

          const SizedBox(height: 8),

          // Font size slider
          _buildLabel('Font Size'),
          Row(
            children: [
              const Text(
                'A',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              Expanded(
                child: Slider(
                  value: selectedSizeFactor.clamp(0.08, 0.50),
                  min: 0.08,
                  max: 0.50,
                  divisions: 42,
                  activeColor: const Color(0xFF00E5CC),
                  inactiveColor: Colors.white12,
                  label: (selectedSizeFactor * 100).round().toString(),
                  onChanged: (v) {
                    ref.read(watchFontSizeFactorProvider.notifier).state = v;
                  },
                ),
              ),
              const Text(
                'A',
                style: TextStyle(color: Colors.white38, fontSize: 18),
              ),
            ],
          ),

          // Where the time sits on Bloub's or the fox's face.
          const SizedBox(height: 8),
          _buildLabel('Time position'),
          for (final axis in [
            (label: 'Across', provider: watchTimeXProvider),
            (label: 'Down', provider: watchTimeYProvider),
          ])
            Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Text(
                    axis.label,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: ref.watch(axis.provider),
                    divisions: 100,
                    activeColor: const Color(0xFF00E5CC),
                    inactiveColor: Colors.white12,
                    label: '${(ref.watch(axis.provider) * 100).round()}%',
                    onChanged: (v) =>
                        ref.read(axis.provider.notifier).state = v,
                  ),
                ),
              ],
            ),

          const SizedBox(height: 8),

          // Live preview
          Container(
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0F),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white12),
            ),
            alignment: Alignment.center,
            child: Text(
              '12:45',
              style: GoogleFonts.getFont(
                selectedFontFamily,
                fontSize: 36,
                fontWeight: _fontWeightFromInt(selectedFontWeight),
                color: Colors.white,
              ),
            ),
          ),

          // The FOX-1 Hub: notes, health, conversations, memory and these
          // settings, from the wearer's phone.
          const SizedBox(height: 16),
          const _SectionHeader('FOX-1 Hub'),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'FOX-1 Hub',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Switch(
                value: serverRunning,
                activeTrackColor: const Color(0xFF00E5CC),
                onChanged: (on) {
                  if (on) {
                    _startServer();
                  } else {
                    _stopServer();
                  }
                },
              ),
            ],
          ),
          if (serverRunning && hotspotInfo != null) ...[
            const SizedBox(height: 8),
            // Only when the portal had to bring up the device's own hotspot.
            if ((hotspotInfo['ssid'] ?? '').isNotEmpty) ...[
              const Center(
                child: Text(
                  '1. Scan to join the device\'s Wi-Fi',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: QrImageView(
                    data:
                        'WIFI:T:WPA;S:${hotspotInfo['ssid']};P:${hotspotInfo['password']};;',
                    version: QrVersions.auto,
                    size: 140,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            Center(
              child: Text(
                (hotspotInfo['ssid'] ?? '').isNotEmpty
                    ? '2. Scan to open FOX-1 Hub'
                    : 'Scan to open FOX-1 Hub',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                // Carries the PIN, so scanning signs straight in.
                child: QrImageView(
                  data: hotspotInfo['url'] ?? '',
                  version: QrVersions.auto,
                  size: 140,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'PIN ${hotspotInfo['pin'] ?? ''}',
                style: const TextStyle(
                  color: Color(0xFF00E5CC),
                  fontSize: 20,
                  letterSpacing: 3,
                ),
              ),
            ),
            Center(
              child: Text(
                hotspotInfo['address'] ?? '',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
            const SizedBox(height: 4),
            const Center(
              child: Text(
                'Turns itself off after 30 minutes unused',
                style: TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
          ] else if (!serverRunning) ...[
            const Text(
              'Your notes, health, conversations, memory and settings — '
              'on your phone',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
          // Back to first-time setup: the device shows the Hub's code again
          // and the wearer goes through setup on their phone.
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _setUpAgain,
              icon: const Icon(Icons.restart_alt, size: 16, color: Color(0xFF00E5CC)),
              label: const Text('Set up again',
                  style: TextStyle(color: Color(0xFF00E5CC), fontSize: 13)),
            ),
          ),

          // Screen Automation
          const SizedBox(height: 16),
          const _SectionHeader('Screen Automation'),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5CC),
              foregroundColor: const Color(0xFF0A0A0A),
              minimumSize: const Size(double.infinity, 40),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () async {
              const channel = MethodChannel(
                'ai.fox1/screen_automation',
              );
              final enabled =
                  await channel.invokeMethod<bool>('isServiceEnabled') ?? false;
              if (enabled) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Accessibility service is ON'),
                    ),
                  );
                }
              } else {
                final opened =
                    await channel.invokeMethod<bool>(
                      'openAccessibilitySettings',
                    ) ??
                    false;
                if (!opened && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Could not open accessibility settings'),
                    ),
                  );
                }
              }
            },
            child: const Text(
              'Enable Accessibility Service',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Required for AI to control other apps',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),

          // Smart ring — the wearer's view. A ring Android already knows is
          // paired automatically at boot; the card covers the rest.
          const SizedBox(height: 16),
          const _SectionHeader('Smart Ring'),
          const RingSettingsCard(),

          // Playgrounds and bring-up harnesses. Hidden until "FOX-1"
          // below is tapped seven times — a wearer never needs them.
          if (devMode) ...[
            const SizedBox(height: 16),
            const _SectionHeader('Developer'),
            _devButton(
              'Call bridge playground',
              '/bridge-test',
              'ESP32 SPP bring-up stages and stage 7',
            ),
            const SizedBox(height: 10),
            _devButton(
              'Ring test',
              '/ring-test',
              'Ring BLE harness — every command, recordings, health sync',
            ),
            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: () => _setDevMode(false),
                child: const Text(
                  'Hide developer tools',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
            ),
          ],

          const SizedBox(height: 20),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _aboutTapped,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text(
                  _aboutNote ?? 'FOX-1',
                  style: const TextStyle(color: Colors.white24, fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Seven taps within two seconds of each other, as Android's own
  /// developer options do it.
  void _aboutTapped() {
    if (ref.read(developerModeProvider)) {
      _note('already on — see Developer above');
      return;
    }
    final now = DateTime.now();
    if (_lastAboutTap == null ||
        now.difference(_lastAboutTap!) > const Duration(seconds: 2)) {
      _aboutTaps = 0;
    }
    _lastAboutTap = now;
    _aboutTaps++;
    if (_aboutTaps >= 7) {
      _aboutTaps = 0;
      _setDevMode(true);
      _note('developer tools on');
    } else if (_aboutTaps >= 4) {
      _note('${7 - _aboutTaps} more taps');
    }
  }

  /// A word under the thumb, not over it — and it clears itself.
  void _note(String text) {
    setState(() => _aboutNote = text);
    _aboutReset?.cancel();
    _aboutReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _aboutNote = null);
    });
  }

  Future<void> _setDevMode(bool on) async {
    ref.read(developerModeProvider.notifier).state = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('developer_mode', on);
  }

  Widget _devButton(String label, String route, String note) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: const Color(0xFF00E5CC),
          minimumSize: const Size(double.infinity, 40),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () => Navigator.of(context).pushNamed(route),
        child: Text(label, style: const TextStyle(fontSize: 13)),
      ),
      const SizedBox(height: 4),
      Text(note, style: const TextStyle(color: Colors.white38, fontSize: 11)),
    ],
  );

  /// Sends the device back to first-time setup. Nothing is erased: the Hub
  /// setup shows what is already filled in.
  Future<void> _setUpAgain() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        content: const Text(
            'Go through setup again on FOX-1 Hub? Nothing is erased.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white54))),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Set up', style: TextStyle(color: Color(0xFF00E5CC)))),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setup_done', false);
    if (!mounted) return;
    // Settings sits on top of the launcher; close it so setup is what shows.
    // The notifier is taken first: this screen is gone once it has popped.
    final setup = ref.read(setupDoneProvider.notifier);
    Navigator.of(context).popUntil((r) => r.isFirst);
    setup.state = false;
  }

  /// A small copy of the chosen mascot: its own avatar with no controller: Settings is not a launcher page, so page-based pausing
  /// does not apply — it simply stops when Settings closes. Keyed on the
  /// design, so a change shows at once.
  Widget _mascotPreview() {
    final p = ref.watch(liveAvatarParamsProvider);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 96,
        height: 116,
        child: WatchAvatar(key: ValueKey(p), params: p),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
    );
  }

  Widget _buildDropdownContainer({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(child: child),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller, {
    bool obscure = false,
    String? hint,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboard,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.white38, fontSize: 12),
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFF00E5CC),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
