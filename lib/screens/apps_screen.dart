import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/app_info.dart';
import '../providers/providers.dart';
import '../widgets/live_mascot.dart';

/// Installed apps screen — mascot centered, horizontal scrollable row
/// of app icons at the bottom. Apps are cached via provider (no re-fetch on swipe).
class AppsScreen extends ConsumerWidget {
  const AppsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final size = MediaQuery.of(context).size;
    final appsAsync = ref.watch(installedAppsProvider);

    return Container(
      color: const Color(0xFF0A0A0F),
      child: Stack(
        children: [
          // The mascot goes edge to edge, with the app row over it: boxed in
          // above the row, its own background showed as a band against the
          // screen's.
          const Positioned.fill(child: LiveMascot(screen: ActiveScreen.apps)),

          // App icon row — horizontal scroll at bottom
          Positioned(
            left: 0,
            right: 0,
            bottom: size.height * 0.04,
            height: size.height * 0.16,
            child: appsAsync.when(
              loading: () => const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00E5CC),
                  ),
                ),
              ),
              error: (_, _) => const Center(
                child: Text(
                  'Error loading apps',
                  style: TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ),
              data: (apps) => ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: size.width * 0.06),
                itemCount: apps.length,
                itemBuilder: (context, index) => _AppIcon(
                  app: apps[index],
                  onTap: () => ref
                      .read(installedAppsServiceProvider)
                      .launchApp(apps[index].packageName),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppIcon extends StatelessWidget {
  final AppInfo app;
  final VoidCallback onTap;

  const _AppIcon({required this.app, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: SizedBox(
          width: 60,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                ),
                clipBehavior: Clip.antiAlias,
                child: app.icon != null
                    ? Image.memory(app.icon!, fit: BoxFit.cover)
                    : Container(
                        color: Colors.white10,
                        child: const Icon(
                          Icons.apps,
                          color: Colors.white38,
                          size: 28,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
