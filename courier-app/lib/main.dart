import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const baseUrl = String.fromEnvironment('API', defaultValue: 'http://10.0.2.2:3000');
const green = Color(0xFF0F4D3A), gold = Color(0xFFC9A24B), cream = Color(0xFFFAF6EC);

const errors = {
  'invalid_phone': 'رقم الهاتف غير صحيح',
  'otp_wrong': 'الرمز غير صحيح',
  'otp_expired': 'انتهت صلاحية الرمز',
  'courier_not_approved': 'حسابك قيد المراجعة من الإدارة',
  'not_your_order': 'هذا الطلب أخذه مندوب آخر',
  'invalid_transition': 'تغيّرت حالة الطلب، حدّث الصفحة',
  'not_courier': 'هذا الحساب ليس حساب مندوب',
  'unauthorized': 'سجّل الدخول من جديد',
};
String msg(Object e) => errors[e.toString()] ?? 'تعذّر الاتصال، تحقق من الإنترنت وحاول مرة أخرى';
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
  runApp(const CourierApp());
}

class CourierApp extends StatelessWidget {
  const CourierApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'زول فود - المندوب',
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

Future<void> signOut(BuildContext context) async {
  Api.token = null;
  (await SharedPreferences.getInstance()).remove('token');
  if (context.mounted) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginPage()), (r) => false);
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
        if (j['role'] != 'courier') throw 'not_courier';
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
              const Text('تطبيق المندوب', textAlign: TextAlign.center),
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
  bool online = false;
  num deliveries = 0, earnings = 0;
  List available = [], mine = [];
  String? error;
  Timer? poll, loc;

  @override
  void initState() {
    super.initState();
    load();
    poll = Timer.periodic(const Duration(seconds: 6), (_) => load());
    loc = Timer.periodic(const Duration(seconds: 15), (_) => sendLocation());
  }

  @override
  void dispose() { poll?.cancel(); loc?.cancel(); super.dispose(); }

  Future<void> load() async {
    try {
      final e = await Api.call('GET', '/courier/earnings');
      final m = await Api.call('GET', '/courier/mine');
      final a = online || (m as List).isNotEmpty ? await Api.call('GET', '/courier/available') : [];
      if (!mounted) return;
      setState(() {
        online = e['online'] == true;
        deliveries = e['deliveries'] ?? 0;
        earnings = e['earnings'] ?? 0;
        mine = m;
        available = a;
        error = null;
      });
    } catch (e) {
      if (e.toString() == 'unauthorized') { if (mounted) signOut(context); return; }
      if (mounted) setState(() => error = msg(e));
    }
  }

  Future<void> sendLocation() async {
    if (!online) return;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return;
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)));
      await Api.call('POST', '/courier/location', {'lat': pos.latitude, 'lng': pos.longitude});
    } catch (_) {}
  }

  Future<void> toggle(bool v) async {
    try {
      await Api.call('POST', '/courier/online', {'online': v});
      setState(() => online = v);
      if (v) sendLocation();
      load();
    } catch (e) {
      setState(() => error = msg(e));
    }
  }

  Future<void> act(int id, String status) async {
    try {
      await Api.call('POST', '/orders/$id/status', {'status': status});
      if (status == 'picked_up') sendLocation();
      await load();
    } catch (e) {
      setState(() => error = msg(e));
      load();
    }
  }

  Future<void> confirmDelivered(Map o) async {
    final cash = o['pay_method'] == 'cash' && o['pay_status'] != 'paid';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تأكيد التسليم'),
        content: Text(cash ? 'هل سلّمت الطلب واستلمت ${money(o['total'])} نقداً؟' : 'هل سلّمت الطلب للعميل؟'),
        actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تم التسليم'))],
      ),
    );
    if (ok == true) act(o['id'], 'delivered');
  }

  Future<void> navigate(Map o) async {
    final uri = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${o['lat']},${o['lng']}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('المندوب'), actions: [
          Row(children: [Text(online ? 'متصل' : 'غير متصل'), Switch(value: online, activeColor: gold, onChanged: toggle)]),
          IconButton(icon: const Icon(Icons.logout), tooltip: 'خروج', onPressed: () => signOut(context)),
        ]),
        body: RefreshIndicator(
          onRefresh: load,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              Expanded(child: Card(child: ListTile(title: Text('$deliveries', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: green)), subtitle: const Text('توصيلات اليوم')))),
              Expanded(child: Card(child: ListTile(title: Text(money(earnings), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: green)), subtitle: const Text('أرباح اليوم')))),
            ]),
            if (error != null) Padding(padding: const EdgeInsets.all(8), child: Text(error!, style: const TextStyle(color: Colors.red))),
            const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text('قيد التوصيل', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            if (mine.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('لا يوجد طلب قيد التوصيل.')),
            for (final o in mine)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('طلب #${o['id']} من ${o['restaurant_name']}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('إلى: ${o['address_text']}'),
                    Text(o['pay_method'] == 'cash' && o['pay_status'] != 'paid' ? 'حصّل من العميل: ${money(o['total'])}' : 'مدفوع إلكترونياً', style: const TextStyle(color: green, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(children: [
                      if (o['lat'] != null) Expanded(child: OutlinedButton.icon(onPressed: () => navigate(o), icon: const Icon(Icons.navigation), label: const Text('الخريطة'))),
                      if (o['lat'] != null) const SizedBox(width: 8),
                      Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black), onPressed: () => confirmDelivered(o), child: const Text('تم التسليم'))),
                    ]),
                  ]),
                ),
              ),
            const Padding(padding: EdgeInsets.fromLTRB(4, 12, 4, 6), child: Text('طلبات متاحة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            if (!online && mine.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('فعّل "متصل" لاستقبال الطلبات.')),
            if (online && available.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('لا توجد طلبات جاهزة الآن. سنحدّث القائمة تلقائياً.')),
            for (final o in available)
              Card(
                child: ListTile(
                  title: Text('${o['restaurant_name']} ← ${o['address_text']}'),
                  subtitle: Text('عائد التوصيل ${money(o['delivery_fee'])}'),
                  trailing: FilledButton(onPressed: () => act(o['id'], 'picked_up'), child: const Text('استلام')),
                ),
              ),
          ]),
        ),
      );
}
