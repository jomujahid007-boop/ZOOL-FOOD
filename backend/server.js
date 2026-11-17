import express from 'express';
import helmet from 'helmet';
import cors from 'cors';
import rateLimit from 'express-rate-limit';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';
import pg from 'pg';
import admin from 'firebase-admin';

const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
const SECRET = process.env.JWT_SECRET;
if (!SECRET) throw new Error('JWT_SECRET is required');
const app = express();
app.use(helmet(), cors(), express.json({ limit: '100kb' }));
app.use(rateLimit({ windowMs: 60_000, limit: Number(process.env.GLOBAL_LIMIT) || 120 }));
const wrap = fn => (req, res) => fn(req, res).catch(e => { console.error(e); res.status(e.status || 500).json({ error: e.status ? e.message : 'server_error' }); });
const fail = (status, message) => Object.assign(new Error(message), { status });
const sha = s => crypto.createHash('sha256').update(s).digest('hex');

// ---- Notifications: saved in DB always, pushed via FCM when GOOGLE_APPLICATION_CREDENTIALS is set ----
const fcm = process.env.GOOGLE_APPLICATION_CREDENTIALS ? (admin.initializeApp(), admin.messaging()) : null;
async function notify(userId, title, body) {
  try {
    await pool.query('INSERT INTO notifications(user_id,title,body) VALUES($1,$2,$3)', [userId, title, body]);
    if (!fcm) return;
    const { rows } = await pool.query('SELECT token FROM device_tokens WHERE user_id=$1', [userId]);
    if (!rows.length) return;
    const r = await fcm.sendEachForMulticast({ tokens: rows.map(x => x.token), notification: { title, body } });
    const bad = [];
    r.responses.forEach((x, i) => { if (!x.success && /not-registered|invalid-argument/.test(x.error?.code || '')) bad.push(rows[i].token); });
    if (bad.length) await pool.query('DELETE FROM device_tokens WHERE token=ANY($1)', [bad]);
  } catch (e) { console.error('notify failed', e.message); }
}
const MSG = {
  accepted: 'المطعم أكّد طلبك', preparing: 'بدأ تجهيز طلبك', ready: 'طلبك جاهز وبانتظار المندوب',
  picked_up: 'المندوب استلم طلبك وهو في الطريق', delivered: 'تم تسليم طلبك. بالهناء والعافية', cancelled: 'تم إلغاء طلبك'
};

// ---- Auth (OTP). Replace sendSms with a real SMS provider. ----
const sendSms = async (phone, code) => console.log(`[SMS to ${phone}] ${code}`);
app.post('/auth/otp', rateLimit({ windowMs: 600_000, limit: Number(process.env.OTP_LIMIT) || 5 }), wrap(async (req, res) => {
  const phone = String(req.body.phone || '').replace(/\s/g, '');
  if (!/^\+?\d{9,15}$/.test(phone)) throw fail(400, 'invalid_phone');
  const code = String(crypto.randomInt(100000, 999999));
  await pool.query('DELETE FROM otp_codes WHERE phone=$1', [phone]);
  await pool.query("INSERT INTO otp_codes(phone,code_hash,expires_at) VALUES($1,$2,now()+interval '5 min')", [phone, sha(code)]);
  await sendSms(phone, code);
  res.json({ ok: true });
}));
app.post('/auth/verify', wrap(async (req, res) => {
  const { phone, code } = req.body;
  const { rows } = await pool.query('SELECT * FROM otp_codes WHERE phone=$1 AND expires_at>now()', [phone]);
  const otp = rows[0];
  if (!otp || otp.attempts >= 5) throw fail(400, 'otp_expired');
  if (otp.code_hash !== sha(String(code))) {
    await pool.query('UPDATE otp_codes SET attempts=attempts+1 WHERE phone=$1', [phone]);
    throw fail(400, 'otp_wrong');
  }
  await pool.query('DELETE FROM otp_codes WHERE phone=$1', [phone]);
  const u = (await pool.query('INSERT INTO users(phone) VALUES($1) ON CONFLICT(phone) DO UPDATE SET phone=EXCLUDED.phone RETURNING id,role,is_active', [phone])).rows[0];
  if (!u.is_active) throw fail(403, 'suspended');
  res.json({ token: jwt.sign({ sub: u.id, role: u.role }, SECRET, { expiresIn: '30d' }), role: u.role });
}));
const auth = (...roles) => (req, res, next) => {
  try {
    req.user = jwt.verify((req.headers.authorization || '').replace('Bearer ', ''), SECRET);
    if (roles.length && !roles.includes(req.user.role)) return res.status(403).json({ error: 'forbidden' });
    next();
  } catch { res.status(401).json({ error: 'unauthorized' }); }
};

// ---- Public catalog ----
app.get('/restaurants', wrap(async (req, res) => {
  const { rows } = await pool.query('SELECT id,name,category,logo_url,rating,prep_minutes,is_open FROM restaurants WHERE is_approved ORDER BY rating DESC');
  res.json(rows);
}));
app.get('/restaurants/:id/menu', wrap(async (req, res) => {
  const { rows } = await pool.query('SELECT id,name,description,price,image_url FROM menu_items WHERE restaurant_id=$1 AND is_available', [req.params.id]);
  res.json(rows);
}));

// ---- Orders: the server computes every price; client prices are ignored ----
app.post('/orders', auth('customer'), wrap(async (req, res) => {
  const { restaurantId, items, address, zoneId = 1, payMethod = 'cash', notes, idemKey, lat, lng } = req.body;
  if (!Array.isArray(items) || !items.length || !address) throw fail(400, 'invalid_order');
  if (!['cash', 'wallet'].includes(payMethod)) throw fail(400, 'invalid_payment');
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    if (idemKey) {
      const dup = await c.query('SELECT id FROM orders WHERE idem_key=$1', [idemKey]);
      if (dup.rows[0]) { await c.query('ROLLBACK'); return res.json({ orderId: dup.rows[0].id, duplicate: true }); }
    }
    const r = (await c.query('SELECT commission_pct,is_open,min_order,owner_id FROM restaurants WHERE id=$1 AND is_approved', [restaurantId])).rows[0];
    if (!r || !r.is_open) throw fail(400, 'restaurant_unavailable');
    let subtotal = 0; const lines = [];
    for (const it of items) {
      const qty = Number(it.qty);
      if (!Number.isInteger(qty) || qty < 1 || qty > 50) throw fail(400, 'invalid_qty');
      const m = (await c.query('SELECT id,name,price FROM menu_items WHERE id=$1 AND restaurant_id=$2 AND is_available', [it.itemId, restaurantId])).rows[0];
      if (!m) throw fail(400, 'item_unavailable');
      subtotal += m.price * qty; lines.push([m, qty]);
    }
    if (subtotal < r.min_order) throw fail(400, 'below_min_order');
    const fee = (await c.query('SELECT base_fee FROM delivery_zones WHERE id=$1 AND is_active', [zoneId])).rows[0]?.base_fee;
    if (fee == null) throw fail(400, 'zone_unavailable');
    const service = 500, total = subtotal + fee + service, commission = Math.round(subtotal * r.commission_pct / 100);
    const o = (await c.query(
      `INSERT INTO orders(customer_id,restaurant_id,address_text,zone_id,subtotal,delivery_fee,service_fee,total,commission,pay_method,notes,idem_key,lat,lng)
       VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14) RETURNING id`,
      [req.user.sub, restaurantId, address, zoneId, subtotal, fee, service, total, commission, payMethod, notes || null, idemKey || null,
       typeof lat === 'number' && Math.abs(lat) <= 90 ? lat : null, typeof lng === 'number' && Math.abs(lng) <= 180 ? lng : null])).rows[0];
    for (const [m, qty] of lines) await c.query('INSERT INTO order_items(order_id,item_id,name,unit_price,qty) VALUES($1,$2,$3,$4,$5)', [o.id, m.id, m.name, m.price, qty]);
    if (payMethod === 'wallet') {
      const w = await c.query('UPDATE wallets SET balance=balance-$1 WHERE user_id=$2 AND balance>=$1 RETURNING balance', [total, req.user.sub]);
      if (!w.rowCount) throw fail(402, 'insufficient_balance');
      await c.query('INSERT INTO wallet_transactions(user_id,amount,kind,ref) VALUES($1,$2,$3,$4)', [req.user.sub, -total, 'order', String(o.id)]);
      await c.query("UPDATE orders SET pay_status='paid' WHERE id=$1", [o.id]);
    }
    await c.query("INSERT INTO order_status_history(order_id,status,actor_id) VALUES($1,'new',$2)", [o.id, req.user.sub]);
    await c.query('COMMIT');
    if (r.owner_id) notify(r.owner_id, 'طلب جديد', `وصلك الطلب #${o.id}`);
    res.status(201).json({ orderId: o.id, total });
  } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
}));

// ---- Status machine with role permissions ----
const NEXT = { new: ['accepted', 'cancelled'], accepted: ['preparing', 'cancelled'], preparing: ['ready'], ready: ['picked_up'], picked_up: ['delivered'] };
const ALLOWED = { restaurant: ['accepted', 'preparing', 'ready', 'cancelled'], courier: ['picked_up', 'delivered'], admin: ['accepted', 'preparing', 'ready', 'picked_up', 'delivered', 'cancelled'] };
app.post('/orders/:id/status', auth('restaurant', 'courier', 'admin'), wrap(async (req, res) => {
  const { status } = req.body;
  if (!ALLOWED[req.user.role].includes(status)) throw fail(403, 'status_not_allowed');
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const o = (await c.query('SELECT * FROM orders WHERE id=$1 FOR UPDATE', [req.params.id])).rows[0];
    if (!o) throw fail(404, 'not_found');
    if (req.user.role === 'restaurant') {
      const own = await c.query('SELECT 1 FROM restaurants WHERE id=$1 AND owner_id=$2 UNION SELECT 1 FROM restaurant_staff WHERE restaurant_id=$1 AND user_id=$2', [o.restaurant_id, req.user.sub]);
      if (!own.rowCount) throw fail(403, 'not_your_restaurant');
    }
    if (req.user.role === 'courier') {
      if (status === 'picked_up' && !o.courier_id) {
        const cr = (await c.query('SELECT is_approved FROM couriers WHERE user_id=$1', [req.user.sub])).rows[0];
        if (!cr?.is_approved) throw fail(403, 'courier_not_approved');
      }
      if (status === 'picked_up' && !o.courier_id) await c.query('UPDATE orders SET courier_id=$1 WHERE id=$2', [req.user.sub, o.id]);
      else if (o.courier_id !== req.user.sub) throw fail(403, 'not_your_order');
    }
    if (!(NEXT[o.status] || []).includes(status)) throw fail(409, 'invalid_transition');
    await c.query('UPDATE orders SET status=$1 WHERE id=$2', [status, o.id]);
    if (status === 'delivered' && o.pay_method === 'cash') await c.query("UPDATE orders SET pay_status='paid' WHERE id=$1", [o.id]);
    await c.query('INSERT INTO order_status_history(order_id,status,actor_id) VALUES($1,$2,$3)', [o.id, status, req.user.sub]);
    if (status === 'cancelled' && o.pay_status === 'paid' && o.pay_method === 'wallet') { // refund wallet-paid orders on cancellation
      await c.query('UPDATE wallets SET balance=balance+$1 WHERE user_id=$2', [o.total, o.customer_id]);
      await c.query('INSERT INTO wallet_transactions(user_id,amount,kind,ref) VALUES($1,$2,$3,$4)', [o.customer_id, o.total, 'refund', String(o.id)]);
      await c.query("UPDATE orders SET pay_status='refunded' WHERE id=$1", [o.id]);
    }
    await c.query('COMMIT');
    if (MSG[status]) notify(o.customer_id, 'زول فود', MSG[status]);
    res.json({ ok: true });
  } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
}));
app.get('/orders/mine', auth('customer'), wrap(async (req, res) => {
  res.json((await pool.query('SELECT id,status,total,created_at FROM orders WHERE customer_id=$1 ORDER BY id DESC LIMIT 50', [req.user.sub])).rows);
}));
app.get('/courier/available', auth('courier'), wrap(async (req, res) => {
  res.json((await pool.query("SELECT o.id,r.name AS restaurant_name,r.address AS restaurant_address,o.address_text,o.delivery_fee FROM orders o JOIN restaurants r ON r.id=o.restaurant_id WHERE o.status='ready' AND o.courier_id IS NULL ORDER BY o.id")).rows);
}));

// ---- Payment gateway webhook: idempotent and signature-verified. A receipt photo is never proof of payment. ----
app.post('/payments/webhook', express.json(), wrap(async (req, res) => {
  const sig = req.headers['x-signature'] || '';
  const mac = crypto.createHmac('sha256', process.env.PAYMENT_WEBHOOK_SECRET || '').update(JSON.stringify(req.body)).digest('hex');
  if (sig.length !== mac.length || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(mac))) throw fail(401, 'bad_signature');
  const { provider, ref, orderId, amount, ok } = req.body;
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    const ins = await c.query('INSERT INTO payments(order_id,provider,provider_ref,amount,status,raw) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING RETURNING id',
      [orderId, provider, ref, amount, ok ? 'paid' : 'failed', req.body]);
    if (ins.rowCount && ok) await c.query("UPDATE orders SET pay_status='paid' WHERE id=$1 AND total=$2", [orderId, amount]);
    await c.query('COMMIT');
    res.json({ ok: true });
  } catch (e) { await c.query('ROLLBACK'); throw e; } finally { c.release(); }
}));

// ---- Admin analytics ----
app.get('/admin/stats', auth('admin'), wrap(async (req, res) => {
  const { rows } = await pool.query(`SELECT count(*)::int orders, coalesce(sum(subtotal) FILTER (WHERE status='delivered'),0)::int sales,
    coalesce(sum(commission+service_fee) FILTER (WHERE status='delivered'),0)::int revenue,
    round(100.0*count(*) FILTER (WHERE status='cancelled')/greatest(count(*),1),1) cancel_rate FROM orders`);
  res.json(rows[0]);
}));


// ---- Extra read endpoints for the web client ----
app.get('/orders/:id', auth('customer'), wrap(async (req, res) => {
  const o = (await pool.query('SELECT o.id,o.status,o.subtotal,o.delivery_fee,o.service_fee,o.total,o.pay_method,o.pay_status,o.address_text,o.restaurant_id,o.lat,o.lng,c.last_lat,c.last_lng,c.last_seen FROM orders o LEFT JOIN couriers c ON c.user_id=o.courier_id WHERE o.id=$1 AND o.customer_id=$2', [req.params.id, req.user.sub])).rows[0];
  if (!o) throw fail(404, 'not_found');
  if (o.status !== 'picked_up') o.last_lat = o.last_lng = o.last_seen = null; // courier location is shared only while delivering
  o.items = (await pool.query('SELECT name,unit_price,qty FROM order_items WHERE order_id=$1', [o.id])).rows;
  res.json(o);
}));
app.get('/restaurant/orders', auth('restaurant'), wrap(async (req, res) => {
  const { rows } = await pool.query(`SELECT o.id,o.status,o.total,o.notes,
    (SELECT json_agg(json_build_object('name',i.name,'qty',i.qty)) FROM order_items i WHERE i.order_id=o.id) items
    FROM orders o JOIN restaurants r ON r.id=o.restaurant_id
    WHERE r.owner_id=$1 OR r.id IN (SELECT restaurant_id FROM restaurant_staff WHERE user_id=$1)
    ORDER BY o.id DESC LIMIT 50`, [req.user.sub]);
  res.json(rows);
}));
app.get('/courier/mine', auth('courier'), wrap(async (req, res) => {
  res.json((await pool.query("SELECT o.id,o.address_text,o.total,o.pay_method,o.pay_status,o.lat,o.lng,o.delivery_fee,r.name AS restaurant_name FROM orders o JOIN restaurants r ON r.id=o.restaurant_id WHERE o.courier_id=$1 AND o.status='picked_up'", [req.user.sub])).rows);
}));
app.post('/courier/online', auth('courier'), wrap(async (req, res) => {
  await pool.query('UPDATE couriers SET is_online=$1 WHERE user_id=$2', [req.body.online === true, req.user.sub]);
  res.json({ ok: true });
}));
app.get('/courier/earnings', auth('courier'), wrap(async (req, res) => {
  const { rows } = await pool.query(`SELECT
    (SELECT count(*)::int FROM orders o JOIN order_status_history h ON h.order_id=o.id AND h.status='delivered' WHERE o.courier_id=$1 AND h.at>=date_trunc('day',now())) deliveries,
    (SELECT coalesce(sum(o.delivery_fee),0)::int FROM orders o JOIN order_status_history h ON h.order_id=o.id AND h.status='delivered' WHERE o.courier_id=$1 AND h.at>=date_trunc('day',now())) earnings,
    (SELECT is_online FROM couriers WHERE user_id=$1) online`, [req.user.sub]);
  res.json(rows[0]);
}));
app.post('/courier/location', auth('courier'), wrap(async (req, res) => {
  const { lat, lng } = req.body;
  if (typeof lat !== 'number' || typeof lng !== 'number' || Math.abs(lat) > 90 || Math.abs(lng) > 180) throw fail(400, 'invalid_location');
  await pool.query('UPDATE couriers SET last_lat=$1,last_lng=$2,last_seen=now() WHERE user_id=$3', [lat, lng, req.user.sub]);
  res.json({ ok: true });
}));
app.post('/devices', auth(), wrap(async (req, res) => {
  const token = String(req.body.token || '');
  if (token.length < 20 || token.length > 4096) throw fail(400, 'invalid_token');
  await pool.query('INSERT INTO device_tokens(token,user_id,platform) VALUES($1,$2,$3) ON CONFLICT(token) DO UPDATE SET user_id=EXCLUDED.user_id,at=now()', [token, req.user.sub, req.body.platform || null]);
  res.json({ ok: true });
}));
// ---- Admin panel API (every write is audit-logged) ----
const A = auth('admin');
const audit = (req, action, entity, id, meta = {}) =>
  pool.query('INSERT INTO admin_audit_logs(admin_id,action,entity,entity_id,meta) VALUES($1,$2,$3,$4,$5)', [req.user.sub, action, entity, String(id), meta]).catch(e => console.error('audit', e.message));
const STATUSES = ['new', 'accepted', 'preparing', 'ready', 'picked_up', 'delivered', 'cancelled'];

app.get('/admin/restaurants', A, wrap(async (req, res) => {
  res.json((await pool.query('SELECT r.id,r.name,r.category,r.commission_pct,r.is_approved,u.phone owner_phone FROM restaurants r LEFT JOIN users u ON u.id=r.owner_id ORDER BY r.id')).rows);
}));
app.patch('/admin/restaurants/:id', A, wrap(async (req, res) => {
  const { is_approved, commission_pct } = req.body;
  if (commission_pct !== undefined && !(Number(commission_pct) >= 0 && Number(commission_pct) <= 50)) throw fail(400, 'invalid_commission');
  const r = await pool.query('UPDATE restaurants SET is_approved=COALESCE($1,is_approved),commission_pct=COALESCE($2,commission_pct) WHERE id=$3 RETURNING id',
    [typeof is_approved === 'boolean' ? is_approved : null, commission_pct === undefined ? null : Number(commission_pct), req.params.id]);
  if (!r.rowCount) throw fail(404, 'not_found');
  audit(req, 'restaurant.update', 'restaurant', req.params.id, { is_approved, commission_pct });
  res.json({ ok: true });
}));
app.get('/admin/couriers', A, wrap(async (req, res) => {
  res.json((await pool.query('SELECT c.user_id id,u.phone,u.name,c.vehicle,c.is_approved,c.is_online FROM couriers c JOIN users u ON u.id=c.user_id ORDER BY u.created_at DESC')).rows);
}));
app.patch('/admin/couriers/:id', A, wrap(async (req, res) => {
  if (typeof req.body.is_approved !== 'boolean') throw fail(400, 'invalid_body');
  const r = await pool.query('UPDATE couriers SET is_approved=$1, is_online=CASE WHEN $1 THEN is_online ELSE false END WHERE user_id=$2 RETURNING user_id', [req.body.is_approved, req.params.id]);
  if (!r.rowCount) throw fail(404, 'not_found');
  audit(req, 'courier.approve', 'courier', req.params.id, { is_approved: req.body.is_approved });
  res.json({ ok: true });
}));
app.get('/admin/orders', A, wrap(async (req, res) => {
  const st = STATUSES.includes(req.query.status) ? req.query.status : null;
  res.json((await pool.query(`SELECT o.id,o.status,o.total,o.pay_method,o.pay_status,o.created_at,r.name restaurant,u.phone customer
    FROM orders o JOIN restaurants r ON r.id=o.restaurant_id JOIN users u ON u.id=o.customer_id
    WHERE ($1::order_status IS NULL OR o.status=$1) ORDER BY o.id DESC LIMIT 100`, [st])).rows);
}));
app.get('/admin/users', A, wrap(async (req, res) => {
  const q = '%' + String(req.query.q || '').replace(/[%_]/g, '') + '%';
  res.json((await pool.query('SELECT id,phone,name,role,is_active FROM users WHERE phone ILIKE $1 OR name ILIKE $1 ORDER BY created_at DESC LIMIT 50', [q])).rows);
}));
app.patch('/admin/users/:id', A, wrap(async (req, res) => {
  if (typeof req.body.is_active !== 'boolean') throw fail(400, 'invalid_body');
  const r = await pool.query("UPDATE users SET is_active=$1 WHERE id=$2 AND role<>'admin' RETURNING id", [req.body.is_active, req.params.id]);
  if (!r.rowCount) throw fail(404, 'not_found');
  audit(req, req.body.is_active ? 'user.activate' : 'user.suspend', 'user', req.params.id);
  res.json({ ok: true });
}));
app.post('/admin/users/:id/role', A, wrap(async (req, res) => {
  const role = req.body.role;
  if (!['customer', 'restaurant', 'courier'].includes(role)) throw fail(400, 'invalid_role');
  const r = await pool.query("UPDATE users SET role=$1 WHERE id=$2 AND role<>'admin' RETURNING id", [role, req.params.id]);
  if (!r.rowCount) throw fail(404, 'not_found');
  if (role === 'courier') await pool.query('INSERT INTO couriers(user_id) VALUES($1) ON CONFLICT DO NOTHING', [req.params.id]);
  audit(req, 'user.role', 'user', req.params.id, { role });
  res.json({ ok: true });
}));
app.get('/admin/coupons', A, wrap(async (req, res) => {
  res.json((await pool.query('SELECT code,pct,amount,max_uses,used,expires_at,first_order_only FROM coupons ORDER BY code')).rows);
}));
app.post('/admin/coupons', A, wrap(async (req, res) => {
  const { code, pct, amount, max_uses, expires_at, first_order_only } = req.body;
  if (!/^[A-Z0-9]{3,20}$/.test(code || '')) throw fail(400, 'invalid_code');
  const hasPct = Number.isInteger(pct) && pct >= 1 && pct <= 100, hasAmt = Number.isInteger(amount) && amount > 0;
  if (hasPct === hasAmt) throw fail(400, 'pct_or_amount');
  await pool.query('INSERT INTO coupons(code,pct,amount,max_uses,expires_at,first_order_only) VALUES($1,$2,$3,$4,$5,$6)',
    [code, hasPct ? pct : null, hasAmt ? amount : null, Number.isInteger(max_uses) ? max_uses : null, expires_at || null, first_order_only === true]);
  audit(req, 'coupon.create', 'coupon', code, { pct, amount });
  res.status(201).json({ ok: true });
}));
app.get('/admin/cities', A, wrap(async (req, res) => {
  res.json((await pool.query(`SELECT c.id,c.state,c.name,c.is_active,
    (SELECT json_agg(json_build_object('id',z.id,'name',z.name,'base_fee',z.base_fee) ORDER BY z.id) FROM delivery_zones z WHERE z.city_id=c.id) zones FROM cities c ORDER BY c.id`)).rows);
}));
app.patch('/admin/cities/:id', A, wrap(async (req, res) => {
  if (typeof req.body.is_active !== 'boolean') throw fail(400, 'invalid_body');
  await pool.query('UPDATE cities SET is_active=$1 WHERE id=$2', [req.body.is_active, req.params.id]);
  audit(req, 'city.toggle', 'city', req.params.id, { is_active: req.body.is_active });
  res.json({ ok: true });
}));
app.patch('/admin/zones/:id', A, wrap(async (req, res) => {
  const fee = Number(req.body.base_fee);
  if (!Number.isInteger(fee) || fee < 0 || fee > 100000) throw fail(400, 'invalid_fee');
  await pool.query('UPDATE delivery_zones SET base_fee=$1 WHERE id=$2', [fee, req.params.id]);
  audit(req, 'zone.fee', 'zone', req.params.id, { fee });
  res.json({ ok: true });
}));
app.get('/admin/audit', A, wrap(async (req, res) => {
  res.json((await pool.query('SELECT a.id,a.action,a.entity,a.entity_id,a.meta,a.at,u.phone admin FROM admin_audit_logs a LEFT JOIN users u ON u.id=a.admin_id ORDER BY a.id DESC LIMIT 100')).rows);
}));

app.use(express.static('public'));

app.listen(process.env.PORT || 3000, () => console.log('ZOL FOOD API up'));
