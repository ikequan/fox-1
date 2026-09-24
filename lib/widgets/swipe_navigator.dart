import 'package:flutter/material.dart';

enum SwipeScreen { notifications, home, aiAgent, apps, controls }

/// PageView-based swipe navigator modeled after Universal Launcher's
/// nested ViewPager approach. A vertical PageView holds 3 rows:
///   [Controls]  (top, swipe down to reveal)
///   [horizontal row: Apps | Home | Notifications]  (center)
///   [AI Agent]  (bottom, swipe up to reveal)
class SwipeNavigator extends StatefulWidget {
  final Widget home;
  final Widget aiAgent;
  final Widget apps;
  final Widget notifications;
  final Widget controls;
  final ValueChanged<SwipeScreen>? onScreenChanged;

  const SwipeNavigator({
    super.key,
    required this.home,
    required this.aiAgent,
    required this.apps,
    required this.notifications,
    required this.controls,
    this.onScreenChanged,
  });

  @override
  State<SwipeNavigator> createState() => SwipeNavigatorState();
}

class SwipeNavigatorState extends State<SwipeNavigator> {
  late PageController _verticalController;
  late PageController _horizontalController;

  static const int _vHome = 1;
  static const int _hHome = 1;

  SwipeScreen _current = SwipeScreen.home;

  @override
  void initState() {
    super.initState();
    _verticalController = PageController(initialPage: _vHome);
    _horizontalController = PageController(initialPage: _hHome);
  }

  @override
  void dispose() {
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

  SwipeScreen get currentScreen => _current;

  /// Current page of [c], or null when nothing is attached to read.
  ///
  /// `PageController.page` goes through `ScrollController.position`, which is
  /// `positions.single` — it throws `Bad state: No element` the moment no
  /// PageView is attached. The inner horizontal PageView is a lazily-built
  /// child of the outer one, so there are real frames where it is not.
  int? _pageOf(PageController c) {
    if (c.positions.length != 1) return null;
    return c.page?.round();
  }

  /// Animate [c] home, unless it has nothing attached to animate.
  ///
  /// A detached controller is not an error here: its PageView will be built at
  /// [PageController.initialPage], and both initialPages are already home.
  void _animateHome(PageController c, int page) {
    if (c.positions.length != 1) return;
    c.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void goHome() {
    _animateHome(_verticalController, _vHome);
    _animateHome(_horizontalController, _hHome);
    _updateScreen(SwipeScreen.home);
  }

  void _onVerticalPageChanged(int page) {
    if (page == 0) {
      _updateScreen(SwipeScreen.controls);
    } else if (page == 2) {
      _updateScreen(SwipeScreen.aiAgent);
    } else {
      // Fires mid-animation, while the horizontal PageView may still be
      // attaching. Unreadable means it is about to open on its initialPage.
      final hPage = _pageOf(_horizontalController) ?? _hHome;
      if (hPage == 0) {
        _updateScreen(SwipeScreen.apps);
      } else if (hPage == 2) {
        _updateScreen(SwipeScreen.notifications);
      } else {
        _updateScreen(SwipeScreen.home);
      }
    }
  }

  void _onHorizontalPageChanged(int page) {
    if (page == 0) {
      _updateScreen(SwipeScreen.apps);
    } else if (page == 2) {
      _updateScreen(SwipeScreen.notifications);
    } else {
      _updateScreen(SwipeScreen.home);
    }
  }

  void _updateScreen(SwipeScreen screen) {
    if (_current != screen) {
      _current = screen;
      widget.onScreenChanged?.call(screen);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    // Vertical: always scrollable
    // Horizontal: only scrollable when on the home row (vertical page 1)
    final bool onHomeRow = _current == SwipeScreen.home ||
        _current == SwipeScreen.apps ||
        _current == SwipeScreen.notifications;

    return PageView(
      controller: _verticalController,
      scrollDirection: Axis.vertical,
      onPageChanged: _onVerticalPageChanged,
      children: [
        widget.controls,
        // Horizontal row: only scrollable when the vertical is on this page
        PageView(
          controller: _horizontalController,
          scrollDirection: Axis.horizontal,
          onPageChanged: _onHorizontalPageChanged,
          physics: onHomeRow
              ? const ClampingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          children: [
            widget.apps,
            widget.home,
            widget.notifications,
          ],
        ),
        widget.aiAgent,
      ],
    );
  }
}
