import 'package:flutter/material.dart';

import 'controller.dart';
import 'param_specs.dart';
import 'params.dart';

/// A ready-made settings list, built entirely from [kParamSpecs]: every
/// setting, grouped, with the right control for each. Changes apply live.
///
/// Use it as-is, restyle it, or read it as a reference for building your own
/// pages. Settings that don't apply to the current character are hidden.
/// Persist `controller.params.toJson()` however the app stores settings.
class AvatarSettingsList extends StatelessWidget {
  const AvatarSettingsList({super.key, required this.controller, this.groups = kParamGroups});

  final AvatarController controller;

  /// Which groups to show, e.g. just `['Colour']` for a colour page.
  final List<String> groups;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final p = controller.params;
        final tiles = <Widget>[];
        for (final g in groups) {
          final specs =
              kParamSpecs.where((s) => s.group == g && s.appliesTo(p.character)).toList();
          if (specs.isEmpty) continue;
          tiles.add(_Header(g));
          if (g == 'Colour') tiles.add(_Palettes(controller: controller));
          for (final s in specs) {
            tiles.add(_ParamTile(controller: controller, spec: s));
          }
        }
        return ListView(children: tiles);
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _Palettes extends StatelessWidget {
  const _Palettes({required this.controller});
  final AvatarController controller;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final pal in kPalettes)
              ActionChip(
                label: Text(pal.name),
                avatar: CircleAvatar(backgroundColor: pal.body),
                onPressed: () => controller.params = pal.applyTo(controller.params),
              ),
          ],
        ),
      );
}

class _ParamTile extends StatelessWidget {
  const _ParamTile({required this.controller, required this.spec});
  final AvatarController controller;
  final ParamSpec spec;

  AvatarParams get _p => controller.params;

  void _set(Object value) {
    if (spec.key == 'character') {
      controller.params = _p.switchCharacter(value as Character);
    } else {
      controller.params = _p.withValue(spec.key, value);
    }
  }

  String _fmt(double v) {
    final s = spec.step >= 1 ? v.round().toString() : v.toStringAsFixed(spec.step >= 0.1 ? 1 : 2);
    return '$s${spec.unit}';
  }

  @override
  Widget build(BuildContext context) {
    final value = _p.valueOf(spec.key);
    switch (spec.kind) {
      case ParamKind.toggle:
        return SwitchListTile(
          dense: true,
          title: Text(spec.label),
          value: value as bool,
          onChanged: (v) => _set(v),
        );
      case ParamKind.number:
        final v = (value as double).clamp(spec.min, spec.max).toDouble();
        final divisions = ((spec.max - spec.min) / spec.step).round();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: <Widget>[
                Expanded(child: Text(spec.label)),
                Text(_fmt(v)),
              ]),
              Slider(
                value: v,
                min: spec.min,
                max: spec.max,
                divisions: divisions > 0 ? divisions : null,
                onChanged: (x) {
                  // snap to the step, as the web tool does
                  final snapped = spec.min + ((x - spec.min) / spec.step).round() * spec.step;
                  _set(double.parse(snapped.toStringAsFixed(4)));
                },
              ),
            ],
          ),
        );
      case ParamKind.choice:
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(spec.label),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final c in spec.choices)
                    ChoiceChip(
                      label: Text(c.label),
                      selected: c.value == value,
                      onSelected: (_) => _set(c.value),
                    ),
                ],
              ),
            ],
          ),
        );
      case ParamKind.color:
        final current = value as Color;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(spec.label),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final c in kSwatches)
                    GestureDetector(
                      onTap: () => _set(c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: c.toARGB32() == current.toARGB32()
                                ? Theme.of(context).colorScheme.primary
                                : const Color(0x55888888),
                            width: c.toARGB32() == current.toARGB32() ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
    }
  }
}
