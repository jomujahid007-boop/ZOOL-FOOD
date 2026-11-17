# ZOL FOOD - courier app (Flutter)
1. `flutter create . --platforms=android,ios` then `flutter pub get`
2. AndroidManifest.xml: add INTERNET and ACCESS_FINE_LOCATION permissions (and `usesCleartextTraffic` for local http testing only).
   Android 11+ also needs `<queries>` for url_launcher (see its docs) to open Google Maps.
3. `flutter run --dart-define=API=http://10.0.2.2:3000`
4. Log in with a courier account (demo: +249900000003). The admin must approve couriers (couriers.is_approved) before they can accept orders.

Known limit: location is sent while the app is open. Reliable background tracking needs an Android foreground service / iOS background mode (next step).
