---
id: flutter
kind: framework
maturity: seed
extends: dart
detect-files:
detect-deps: pubspec.yaml:flutter
applies-to: **/*.dart, **/*.arb, l10n.yaml
description: Flutter widget lifecycle, build purity, theming, platform channels and localisation
---

# Flutter

## Checks

### flutter/context-after-async-gap
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=lifecycle,async instance-of=C-USE-AFTER-DISPOSE
**What.** A `BuildContext` is used after an `await` without checking the widget is still mounted: navigation, `showDialog`, `ScaffoldMessenger.of`, `Theme.of` against a deactivated element throw or act on the wrong route. **Signal.** `Navigator.`, `context.`, `showDialog(`, `.of(context)` after an `await` in the same function. **Confirm.** Lint `use_build_context_synchronously` (in `flutter_lints`, not in `package:lints`); the guard is `if (!context.mounted) return;` (Flutter 3.7+) or `if (!mounted) return;` inside a `State`.

### flutter/set-state-after-dispose
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=lifecycle,async instance-of=C-USE-AFTER-DISPOSE
**What.** `setState` runs from a future, timer or stream callback after the `State` is disposed and raises `setState() called after dispose()`. **Signal.** `setState(` after `await`, inside `.then(`, `.listen(`, `Timer(` or `addListener` callbacks. **Confirm.** Show the async path and the missing `mounted` check; a widget test that pops the route mid-request reproduces the error. **Not a finding when.** The source is cancelled in `dispose()` before it can fire.

### flutter/controller-not-disposed
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=lifecycle,leaks
**What.** A `State` creates a `TextEditingController`, `AnimationController`, `ScrollController`, `PageController`, `TabController`, `FocusNode`, `ChangeNotifier`, `Timer` or subscription and never releases it, or creates it inside `build()` so a fresh one replaces it on every rebuild. **Signal.** `= XController(` or `FocusNode(` in fields or `initState` with no matching `.dispose()`/`.cancel()` in `dispose()`; controllers constructed in `build`. **Confirm.** Read `dispose()`. A running `AnimationController` left undisposed asserts `was disposed with an active Ticker`. **Not a finding when.** The controller is passed in by a parent that owns and disposes it.

### flutter/future-created-in-build
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=build,performance
**What.** `build()` must be cheap and free of side effects because the framework calls it at any time. A future or stream created while building restarts on every rebuild, and network, storage or heavy sync work there repeats per frame. **Signal.** `FutureBuilder(future: fetch...(`, `StreamBuilder(stream: repo.watch(`, HTTP or database calls, `jsonDecode` or sorting of large lists inside `build`. **Confirm.** The `FutureBuilder` API docs require the future to be obtained earlier (`initState`, `didUpdateWidget`, `didChangeDependencies`); add a log in the call and trigger a rebuild.

### flutter/missing-keys-in-dynamic-lists
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=state,lists
**What.** Stateful children of a list that inserts, removes or reorders items have no stable key, so element state (text input, animation, expansion) moves to the wrong item. `ValueKey(index)` does not help on reorder, and `UniqueKey()` in `build` recreates the state on every rebuild. **Signal.** `ListView.builder`, `children: items.map(...)`, `AnimatedList` building `StatefulWidget`s without `key: ValueKey(item.id)`. **Confirm.** Remove the first item in a widget test and check the next item's state. `ReorderableListView` asserts that every child has a key.

### flutter/inherited-lookup-in-init-state
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=lifecycle
**What.** `Theme.of`, `MediaQuery.of`, `Localizations.of` and other inherited lookups in `initState` throw `dependOnInheritedWidgetOfExactType ... was called before initState() completed`, and a one-off read there would miss later changes anyway. **Signal.** `.of(context)` inside `initState()`. **Confirm.** Move the read to `didChangeDependencies` or `build`. **Not a finding when.** The lookup does not register a dependency (`Provider.of(context, listen: false)`, Riverpod `ref.read`).

### flutter/single-ticker-multiple-controllers
meta: kind=defect safety=no default=on severity=correctness scope=local pass=correctness tags=animation
**What.** A `State` with `SingleTickerProviderStateMixin` creates more than one `AnimationController` (or recreates one in `didUpdateWidget`) and throws `multiple tickers were created`. **Signal.** Two or more `AnimationController(vsync: this` in a state using `SingleTickerProviderStateMixin`. **Confirm.** Use `TickerProviderStateMixin`; the error text is in the mixin's `createTicker`.

### flutter/platform-channel-errors
meta: kind=defect safety=no default=on severity=correctness scope=cross pass=correctness tags=platform,errors instance-of=C-UNHANDLED-FAILURE-PATH
**What.** `MethodChannel.invokeMethod` throws `PlatformException` for native errors and `MissingPluginException` when no handler is registered (unsupported platform, background isolate, plugin not in the build), and returns a nullable result. Platform channels from a background isolate also need `BackgroundIsolateBinaryMessenger.ensureInitialized` (Flutter 3.7+). **Signal.** `invokeMethod(`, `invokeMapMethod(`, `EventChannel(`, Pigeon-generated host API calls with no `on PlatformException`. **Confirm.** Read the native handler's error paths and the platforms the plugin supports in its `pubspec.yaml` `flutter.plugin.platforms`.

### flutter/hardcoded-user-strings
meta: kind=defect safety=no default=on severity=minor scope=cross pass=conventions tags=i18n
**What.** In a localised app, user-visible text is a string literal instead of a generated localisation getter. **Signal.** `Text('`, `tooltip: '`, `labelText: '`, `hintText: '`, `semanticLabel: '`, `SnackBar(content: Text('` in a repo whose `pubspec.yaml` has `flutter_localizations` or `flutter: generate: true`, or has `l10n.yaml` and `.arb` files. **Confirm.** Show sibling widgets using `AppLocalizations.of(context)` or the repo's extension for it. **Not a finding when.** The text is a log line, debug-only UI, a route name, a key, or a brand name kept untranslated.

### flutter/untranslated-arb-messages
meta: kind=defect safety=no default=on severity=minor scope=cross pass=contracts tags=i18n
**What.** A message is added to the template `.arb` file but not to the other locales; `gen-l10n` falls back to the template language and only prints a warning, so those users see the template text. **Signal.** A diff touching only the `template-arb-file` named in `l10n.yaml`. **Confirm.** `flutter gen-l10n --untranslated-messages-file=/tmp/untranslated.json`, or diff the key sets of the `.arb` files.

### flutter/whole-media-query-dependency
meta: kind=practice safety=no default=on severity=minor scope=local pass=correctness tags=performance,layout
**What.** `MediaQuery.of(context)` subscribes to every `MediaQueryData` change (keyboard insets, padding, text scale), so the widget rebuilds on each one. `MediaQuery.sizeOf`, `paddingOf`, `viewInsetsOf` and similar (Flutter 3.10+) depend on one aspect only. **Signal.** `MediaQuery.of(context).size`, `.padding`, `.viewInsets`. **Confirm.** Check the Flutter version in `pubspec.lock` (`sdks: flutter:`) supports the `*Of` accessors.

### flutter/hardcoded-theme-values
meta: kind=practice safety=no default=off severity=minor scope=cross pass=conventions tags=theming,opinionated instance-of=C-PATTERN-DEPARTURE
**What.** Colours, text styles and spacing are literals while the app defines a `ThemeData`/`ColorScheme`, so dark mode, dynamic colour and text scaling bypass the widget. **Signal.** `Color(0x`, `Colors.` constants, `TextStyle(fontSize:` in feature widgets; fixed pixel breakpoints instead of `LayoutBuilder` constraints. **Confirm.** Show the repo's theme and siblings reading `Theme.of(context).colorScheme` / `textTheme` or a `ThemeExtension`.

## Duplication hotspots

- Formatting with the active locale: `intl` `DateFormat`/`NumberFormat` given `Localizations.localeOf(context)`, and `MaterialLocalizations.of(context)` (`formatShortDate`, `formatTimeOfDay`).
- Design tokens: `Theme.of(context).colorScheme`, `textTheme`, `ThemeExtension`, the repo's spacing constants.
- Foundation helpers: `listEquals`, `mapEquals`, `setEquals`, `ValueNotifier` with `ValueListenableBuilder`, `ChangeNotifier`, `compute`, `kIsWeb`, `defaultTargetPlatform`.
- Layout: `LayoutBuilder`, `MediaQuery.sizeOf`, `SafeArea`, and the repo's own breakpoint helpers.
- Navigation: the repo's router (`go_router`, `auto_route`) instead of raw `Navigator.push(MaterialPageRoute(`.
- Images and caching: `cached_network_image` when present instead of bare `Image.network`.
- State management: the repo's chosen library (Riverpod, Provider, Bloc) instead of new singletons or global `ValueNotifier`s.
- Dialogs, sheets and snackbars: existing wrappers around `showDialog`, `showModalBottomSheet`, `ScaffoldMessenger`.

## Verification

- `flutter analyze`, `flutter test`, `dart run custom_lint` when `custom_lint` is in `analysis_options.yaml` plugins, `flutter gen-l10n`.
- Framework sources: `<flutter-sdk>/packages/flutter/lib/src/` (`flutter --version` shows the path; FVM projects use `.fvm/flutter_sdk`). The `flutter` entry in `.dart_tool/package_config.json` points at the SDK in use.
- Plugin sources: `~/.pub-cache/hosted/pub.dev/<plugin>-<version>/` including `android/`, `ios/`, `macos/`, `windows/`, `linux/` native code.
- Lifecycle bugs reproduce in widget tests: `pumpWidget`, trigger the async call, replace the route, then `pumpAndSettle`; framework errors fail the test.

## Not a finding

- `mounted` guards written as `context.mounted` or via an early return in a helper that is always called first.
- Literal strings in tests, golden fixtures, `debugPrint`, analytics event names and semantic identifiers that are not read aloud.
- Controllers created in `initState` and disposed by a mixin or base `State` class the repo provides.
