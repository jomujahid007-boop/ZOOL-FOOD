import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

const baseUrl = String.fromEnvironment('API', defaultValue: 'http://10.0.2.2:3000');
const green = Color(0xFF0F4D3A), gold = Color(0xFFC9A24B), cream = Color(0xFFFAF6EC);

const errors = {
  'invalid_phone': 'رقم الهاتف غير صحيح',
  'otp_wrong': 'الرمز غير صحيح',
  'otp_expired': 'انتهت صلاحية الرمز',
  'insufficient_balance': 'رصيد المحفظة لا يكفي',
  'restaurant_unavailable': 'المطعم غير متاح الآن',
  'unauthorized': 'سجّل الدخول من جديد',
};
String msg(Object e) => errors[e.toString()] ?? 'تعذّر الاتصال، تحقق من الإنترنت وحاول مرة أخرى';
final messengerKey = GlobalKey<ScaffoldMessengerState>();
bool _pushReady = false;

/// Push is optional: if Firebase isn't configured the app keeps working without it.
Future<void> initPush() async {
  try {
    if (!_pushReady) {
      await Firebase.initializeApp();
      _pushReady = true;
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n != null) messengerKey.currentState?.showSnackBar(SnackBar(content: Text('${n.title ?? ''}: ${n.body ?? ''}')));
      });
      FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        if (Api.token != null) Api.call('POST', '/devices', {'token': t}).catchError((_) {});
      });
    }
    await FirebaseMessaging.instance.requestPermission();
    final t = await FirebaseMessaging.instance.getToken();
    if (t != null && Api.token != null) await Api.call('POST', '/devices', {'token': t});
  } catch (_) {}
}

Future<Position?> locate() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)));
  } catch (_) {
    return null;
  }
}

LatLng? pt(dynamic a, dynamic b) => (a is num && b is num) ? LatLng(a.toDouble(), b.toDouble()) : null;

class TrackMap extends StatefulWidget {
  final LatLng? dest, courier;
  const TrackMap({super.key, this.dest, this.courier});
  @override
  State<TrackMap> createState() => _TrackMapState();
}

class _TrackMapState extends State<TrackMap> {
  final ctl = MapController();
  LatLng get center => widget.courier ?? widget.dest!;
  @override
  void didUpdateWidget(TrackMap old) {
    super.didUpdateWidget(old);
    if (old.courier != widget.courier) {
      try { ctl.move(center, 15); } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) => FlutterMap(
        mapController: ctl,
        options: MapOptions(initialCenter: center, initialZoom: 15),
        children: [
          TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.zolfood.app'),
          MarkerLayer(markers: [
            if (widget.dest != null) Marker(point: widget.dest!, width: 40, height: 40, child: const Icon(Icons.home, color: green, size: 36)),
            if (widget.courier != null) Marker(point: widget.courier!, width: 40, height: 40, child: const Icon(Icons.delivery_dining, color: Colors.deepOrange, size: 36)),
          ]),
          const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
        ],
      );
}

String money(num n) => '${n.toInt()} ج';

class Api {
  static String? token;
  static Future<dynamic> call(String method, String path, [Map<String, dynamic>? body]) async {
    final req = http.Request(method, Uri.parse(baseUrl + path));
    req.headers['Content-Type'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 15)));
    final j = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) throw (j is Map ? j['error'] : null) ?? 'error';
    return j;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Api.token = (await SharedPreferences.getInstance()).getString('token');
  runApp(const ZolFood());
}

class ZolFood extends StatelessWidget {
  const ZolFood({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'زول فود',
        scaffoldMessengerKey: messengerKey,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: green, secondary: gold),
          scaffoldBackgroundColor: cream,
          appBarTheme: const AppBarTheme(backgroundColor: green, foregroundColor: Colors.white),
          useMaterial3: true,
        ),
        builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: Api.token == null ? const LoginPage() : const HomePage(),
      );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  final phone = TextEditingController(), code = TextEditingController();
  bool sent = false, busy = false;
  String? error;

  Future<void> run(Future<void> Function() fn) async {
    setState(() { busy = true; error = null; });
    try { await fn(); } catch (e) { error = msg(e); }
    if (mounted) setState(() => busy = false);
  }

  Future<void> sendOtp() => run(() async {
        await Api.call('POST', '/auth/otp', {'phone': phone.text.trim()});
        sent = true;
      });

  Future<void> verify() => run(() async {
        final j = await Api.call('POST', '/auth/verify', {'phone': phone.text.trim(), 'code': code.text.trim()});
        Api.token = j['token'];
        (await SharedPreferences.getInstance()).setString('token', Api.token!);
        if (!mounted) return;
        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const HomePage()));
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('زول فود', textAlign: TextAlign.center, style: TextStyle(fontSize: 38, fontWeight: FontWeight.w800, color: green)),
              const Text('من مطعمك لبابك… بكل سهولة', textAlign: TextAlign.center),
              const SizedBox(height: 32),
              TextField(controller: phone, enabled: !sent, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'رقم الهاتف', hintText: '+249...', border: OutlineInputBorder())),
              if (sent) ...[
                const SizedBox(height: 12),
                TextField(controller: code, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'رمز التحقق', border: OutlineInputBorder())),
              ],
              if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Colors.red))),
              const SizedBox(height: 16),
              FilledButton(onPressed: busy ? null : (sent ? verify : sendOtp), child: Text(sent ? 'دخول' : 'إرسال الرمز')),
            ]),
          ),
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    initPush();
  }

  late Future<dynamic> future = Api.call('GET', '/restaurants');

  Future<void> logout() async {
    Api.token = null;
    (await SharedPreferences.getInstance()).remove('token');
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('المطاعم'), actions: [
          IconButton(icon: const Icon(Icons.receipt_long), tooltip: 'طلباتي', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrdersPage()))),
          IconButton(icon: const Icon(Icons.logout), tooltip: 'خروج', onPressed: logout),
        ]),
        body: FutureBuilder(
          future: future,
          builder: (c, s) {
            if (s.hasError) return Center(child: TextButton(onPressed: () => setState(() => future = Api.call('GET', '/restaurants')), child: Text('${msg(s.error!)}\nاضغط للمحاولة مجدداً', textAlign: TextAlign.center)));
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final list = s.data as List;
            if (list.isEmpty) return const Center(child: Text('لا توجد مطاعم متاحة حالياً'));
            return ListView(padding: const EdgeInsets.all(12), children: [
              for (final r in list)
                Card(
                  child: ListTile(
                    leading: const CircleAvatar(backgroundColor: green, child: Icon(Icons.restaurant, color: Colors.white)),
                    title: Text(r['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${r['category'] ?? ''} · ★ ${r['rating']} · ${r['prep_minutes']} دقيقة'),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MenuPage(r))),
                  ),
                ),
            ]);
          },
        ),
      );
}

class MenuPage extends StatefulWidget {
  final Map r;
  const MenuPage(this.r, {super.key});
  @override
  State<MenuPage> createState() => _MenuState();
}

class _MenuState extends State<MenuPage> {
  late final Future<dynamic> future = Api.call('GET', '/restaurants/${widget.r['id']}/menu');
  List items = [];
  final cart = <int, int>{};
  num get total => items.fold(0, (a, m) => a + (m['price'] as num) * (cart[m['id']] ?? 0));
  void add(int id, int d) => setState(() {
        final n = (cart[id] ?? 0) + d;
        n <= 0 ? cart.remove(id) : cart[id] = n;
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.r['name'])),
        bottomNavigationBar: total > 0
            ? SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: FilledButton(style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CartPage(widget.r['id'], items, cart))), child: Text('عرض السلة · ${money(total)}'))))
            : null,
        body: FutureBuilder(
          future: future,
          builder: (c, s) {
            if (s.hasError) return Center(child: Text(msg(s.error!)));
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            items = s.data as List;
            return ListView(padding: const EdgeInsets.all(12), children: [
              for (final m in items)
                Card(
                  child: ListTile(
                    title: Text(m['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(money(m['price'])),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if ((cart[m['id']] ?? 0) > 0) ...[
                        IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => add(m['id'], -1)),
                        Text('${cart[m['id']]}'),
                      ],
                      IconButton(icon: const Icon(Icons.add_circle, color: green), onPressed: () => add(m['id'], 1)),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      );
}

class CartPage extends StatefulWidget {
  final int rid;
  final List items;
  final Map<int, int> cart;
  const CartPage(this.rid, this.items, this.cart, {super.key});
  @override
  State<CartPage> createState() => _CartState();
}

class _CartState extends State<CartPage> {
  final address = TextEditingController();
  final idem = List.generate(16, (_) => Random.secure().nextInt(36).toRadixString(36)).join();
  String pay = 'cash';
  double? lat, lng;
  bool busy = false;
  String? error;
  num get sub => widget.items.fold(0, (a, m) => a + (m['price'] as num) * (widget.cart[m['id']] ?? 0));

  Future<void> useLocation() async {
    final p = await locate();
    if (!mounted) return;
    setState(() {
      if (p != null) { lat = p.latitude; lng = p.longitude; error = null; } else { error = 'تعذّر تحديد موقعك. فعّل الموقع أو اكتب العنوان يدوياً'; }
    });
  }

  Future<void> place() async {
    if (address.text.trim().isEmpty) { setState(() => error = 'اكتب عنوان التوصيل'); return; }
    setState(() { busy = true; error = null; });
    try {
      final j = await Api.call('POST', '/orders', {
        'restaurantId': widget.rid,
        'items': [for (final e in widget.cart.entries) {'itemId': e.key, 'qty': e.value}],
        'address': address.text.trim(),
        'payMethod': pay,
        'idemKey': idem,
        'lat': lat,
        'lng': lng,
      });
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => TrackPage(j['orderId'])), (r) => r.isFirst);
    } catch (e) {
      error = msg(e);
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('تأكيد الطلب')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          for (final m in widget.items.where((m) => widget.cart.containsKey(m['id'])))
            ListTile(title: Text('${widget.cart[m['id']]}× ${m['name']}'), trailing: Text(money(m['price'] * widget.cart[m['id']]))),
          const Divider(),
          ListTile(title: const Text('المنتجات'), trailing: Text(money(sub))),
          const ListTile(title: Text('رسوم التوصيل والخدمة'), subtitle: Text('تُحسب من الخادم وتظهر في صفحة الطلب')),
          TextField(controller: address, decoration: const InputDecoration(labelText: 'عنوان التوصيل', border: OutlineInputBorder())),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: useLocation, icon: Icon(lat == null ? Icons.my_location : Icons.check_circle, color: green), label: Text(lat == null ? 'استخدم موقعي الحالي' : 'تم تحديد موقعك')),
          RadioListTile(value: 'cash', groupValue: pay, onChanged: (v) => setState(() => pay = v!), title: const Text('الدفع عند الاستلام')),
          RadioListTile(value: 'wallet', groupValue: pay, onChanged: (v) => setState(() => pay = v!), title: const Text('المحفظة')),
          if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 8),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black, padding: const EdgeInsets.all(14)), onPressed: busy ? null : place, child: const Text('تأكيد الطلب')),
        ]),
      );
}

const steps = {
  'new': 'تم استلام الطلب',
  'accepted': 'المطعم أكّد الطلب',
  'preparing': 'جاري التجهيز',
  'ready': 'الطعام جاهز',
  'picked_up': 'المندوب في الطريق',
  'delivered': 'تم التسليم',
};

class TrackPage extends StatefulWidget {
  final int id;
  const TrackPage(this.id, {super.key});
  @override
  State<TrackPage> createState() => _TrackState();
}

class _TrackState extends State<TrackPage> {
  Map? order;
  Timer? timer;
  String? error;

  Future<void> load() async {
    try {
      final j = await Api.call('GET', '/orders/${widget.id}');
      if (mounted) setState(() { order = j; error = null; });
    } catch (e) {
      if (mounted) setState(() => error = msg(e));
    }
  }

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() { timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final keys = steps.keys.toList();
    final cur = order == null ? -1 : keys.indexOf(order!['status']);
    return Scaffold(
      appBar: AppBar(title: Text('طلب #${widget.id}')),
      body: order == null
          ? Center(child: error != null ? Text(error!) : const CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (pt(order!['lat'], order!['lng']) != null || pt(order!['last_lat'], order!['last_lng']) != null)
                SizedBox(height: 220, child: ClipRRect(borderRadius: BorderRadius.circular(12), child: TrackMap(dest: pt(order!['lat'], order!['lng']), courier: pt(order!['last_lat'], order!['last_lng'])))),
              if (order!['status'] == 'picked_up' && pt(order!['last_lat'], order!['last_lng']) == null) const Padding(padding: EdgeInsets.all(8), child: Text('بانتظار موقع المندوب...')),
              if (order!['status'] == 'cancelled') const Card(child: ListTile(leading: Icon(Icons.cancel, color: Colors.red), title: Text('تم إلغاء الطلب'))),
              for (var i = 0; i < keys.length; i++)
                ListTile(
                  leading: Icon(i < cur || order!['status'] == 'delivered' ? Icons.check_circle : i == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked, color: i <= cur ? green : Colors.grey),
                  title: Text(steps[keys[i]]!, style: TextStyle(fontWeight: i == cur ? FontWeight.bold : FontWeight.normal)),
                ),
              const Divider(),
              for (final it in order!['items']) ListTile(dense: true, title: Text('${it['qty']}× ${it['name']}'), trailing: Text(money(it['unit_price'] * it['qty']))),
              ListTile(title: const Text('التوصيل'), trailing: Text(money(order!['delivery_fee']))),
              ListTile(title: const Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.bold)), trailing: Text(money(order!['total']), style: const TextStyle(fontWeight: FontWeight.bold))),
            ]),
    );
  }
}

class OrdersPage extends StatelessWidget {
  const OrdersPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('طلباتي')),
        body: FutureBuilder(
          future: Api.call('GET', '/orders/mine'),
          builder: (c, s) {
            if (s.hasError) return Center(child: Text(msg(s.error!)));
            if (!s.hasData) return const Center(child: CircularProgressIndicator());
            final l = s.data as List;
            if (l.isEmpty) return const Center(child: Text('لا توجد طلبات بعد. اختر مطعماً وابدأ.'));
            return ListView(children: [
              for (final o in l)
                ListTile(
                  title: Text('طلب #${o['id']}'),
                  subtitle: Text(steps[o['status']] ?? 'ملغي'),
                  trailing: Text(money(o['total'])),
                  onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TrackPage(o['id']))),
                ),
            ]);
          },
        ),
      );
}
