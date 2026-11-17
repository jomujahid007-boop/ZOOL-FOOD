# ZOL FOOD - customer app (Flutter)
1. `flutter create . --platforms=android,ios` (inside this folder; keeps lib/ and pubspec.yaml)
2. `flutter pub get`
3. Android: add `<uses-permission android:name="android.permission.INTERNET"/>` to android/app/src/main/AndroidManifest.xml
   and, for local http testing only, `android:usesCleartextTraffic="true"` on <application>.
4. Run against your API: `flutter run --dart-define=API=http://10.0.2.2:3000` (emulator) or your server URL.
Production must use HTTPS.

## Map and push notifications
- Location: add `ACCESS_FINE_LOCATION` to AndroidManifest.xml (iOS: `NSLocationWhenInUseUsageDescription` in Info.plist).
- Map tiles use OpenStreetMap (fine for testing; for production traffic use a paid tile provider or your own tiles).
- Push: create a Firebase project, run `flutterfire configure`, and give the backend a service-account JSON via GOOGLE_APPLICATION_CREDENTIALS. Without Firebase the app still works, only push is off.
- Backend: run `psql $DATABASE_URL -f migration_002.sql` and `npm i` again (new firebase-admin dependency).
- Test courier tracking before the courier app exists:
  `curl -X POST $API/courier/location -H "Authorization: Bearer <courier token>" -H "Content-Type: application/json" -d '{"lat":15.64,"lng":32.48}'`
