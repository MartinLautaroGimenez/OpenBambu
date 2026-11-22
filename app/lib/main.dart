import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'screens/printer_screen.dart';
import 'screens/setup_screen.dart';
import 'services/background.dart';
import 'services/notifications.dart';
import 'services/settings_store.dart';
import 'services/widget_service.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  BackgroundMonitor.init();
  await Notifications.init();
  await PrinterWidget.init();
  final store = await SettingsStore.load();
  final state = AppState(store);
  if (store.configured && store.backgroundMonitor) {
    BackgroundMonitor.start();
  }
  runApp(ChangeNotifierProvider.value(value: state, child: const OpenBambuApp()));
}

class OpenBambuApp extends StatelessWidget {
  const OpenBambuApp({super.key});

  @override
  Widget build(BuildContext context) {
    final configured = context.select<AppState, bool>((s) => s.store.configured);
    final themeMode = context.select<AppState, ThemeMode>((s) => s.themeMode);
    return WithForegroundTask(
      child: MaterialApp(
        title: 'OpenBambu',
        debugShowCheckedModeBanner: false,
        locale: const Locale('es'),
        supportedLocales: const [Locale('es'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: themeMode,
        home: configured ? const PrinterScreen() : const SetupScreen(),
      ),
    );
  }
}
