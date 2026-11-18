// End-to-end tests for ZOL FOOD API. Needs a REAL but EMPTY test database (name must contain "test").
// Usage:  createdb zolfood_test && psql zolfood_test -f schema.sql && psql zolfood_test -f migration_002.sql
//         DATABASE_URL=postgres://user:pass@localhost:5432/zolfood_test npm test
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import pg from 'pg';

const DB = process.env.DATABASE_URL || '';
if (!/test/i.test(DB.split('/').pop() || '')) throw new Error('Refusing to run: DATABASE_URL must point to a database whose name contains "test" (tests wipe data).');
const PORT = 3999, BASE = `http://localhost:${PORT}`, WH_SECRET = 'test-webhook-secret';
const db = new pg.Pool({ connectionString: DB });
const sha = s => crypto.createHash('sha256').update(s).digest('hex');
const sleep = ms => new Promise(r => setTimeout(r, ms));
let srv, T = {}, ids = {};

async function call(method, path, body, token) {
  const r = await fetch(BASE + path, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) }, body: body ? JSON.stringify(body) : undefined });
  return { status: r.status, body: await r.json().catch(() => ({})) };
}
async function login(phone) {
  await call('POST', '/auth/otp', { phone });
  await db.query('UPDATE otp_codes SET code_hash=$1 WHERE phone=$2', [sha('123456'), phone]);
  const r = await call('POST', '/auth/verify', { phone, code: '123456' });
  assert.equal(r.status, 200, 'login failed for ' + phone);
  return r.body.token;
}
const uid = token => JSON.parse(Buffer.from(token.split('.')[1], 'base64url')).sub;
const order = (token, over = {}) => call('POST', '/orders', { restaurantId: ids.r1, items: [{ itemId: ids.i1, qty: 2 }], address: 'أمدرمان، الموردة', ...over }, token);
const setStatus = (token, id, status) => call('POST', `/orders/${id}/status`, { status }, token);
async function until(fn, ms = 2000) { const t = Date.now(); while (Date.now() - t < ms) { const v = await fn(); if (v) return v; await sleep(100); } return null; }
const row = async (sql, p) => (await db.query(sql, p)).rows[0];

before(async () => {
  await db.query('TRUNCATE users, restaurants, otp_codes, coupons, admin_audit_logs RESTART IDENTITY CASCADE');
  const zone = await row('SELECT id FROM delivery_zones WHERE id=1');
  assert.ok(zone, 'schema.sql seed (zone 1) is missing');
  const mk = async (phone, role) => (await row('INSERT INTO users(phone,role) VALUES($1,$2) RETURNING id', [phone, role])).id;
  const owner1 = await mk('+249911000001', 'restaurant'), owner2 = await mk('+249911000002', 'restaurant');
  const c1 = await mk('+249911000011', 'courier'), c2 = await mk('+249911000012', 'courier'), c3 = await mk('+249911000013', 'courier');
  await mk('+249911000099', 'admin');
  await db.query('INSERT INTO couriers(user_id,is_approved) VALUES($1,true),($2,false),($3,true)', [c1, c2, c3]);
  const rest = async (owner, name, approved, min) => (await row('INSERT INTO restaurants(owner_id,city_id,name,category,is_approved,min_order) VALUES($1,1,$2,$3,$4,$5) RETURNING id', [owner, name, 'سوداني', approved, min])).id;
  ids.r1 = await rest(owner1, 'مطعم أ', true, 5000); ids.r2 = await rest(owner2, 'مطعم ب', true, 0); ids.r3 = await rest(owner1, 'مطعم مخفي', false, 0);
  const item = async (r, n, price, avail = true) => (await row('INSERT INTO menu_items(restaurant_id,name,price,is_available) VALUES($1,$2,$3,$4) RETURNING id', [r, n, price, avail])).id;
  ids.i1 = await item(ids.r1, 'فتة', 9000); ids.i2 = await item(ids.r1, 'بطاطس', 4000); ids.i3 = await item(ids.r1, 'نفدت', 5000, false); ids.i4 = await item(ids.r2, 'برجر', 8000);
  srv = spawn('node', ['server.js'], { env: { ...process.env, PORT, JWT_SECRET: 'test-secret', PAYMENT_WEBHOOK_SECRET: WH_SECRET, OTP_LIMIT: '1000', GLOBAL_LIMIT: '100000', GOOGLE_APPLICATION_CREDENTIALS: '', SEED_DEMO: 'false' }, stdio: 'inherit' });
  assert.ok(await until(async () => { try { return (await call('GET', '/restaurants')).status === 200; } catch { return false; } }, 10000), 'server did not start');
  T.owner1 = await login('+249911000001'); T.owner2 = await login('+249911000002');
  T.c1 = await login('+249911000011'); T.c2 = await login('+249911000012'); T.c3 = await login('+249911000013');
  T.admin = await login('+249911000099'); T.cust = await login('+249911000021'); T.cust2 = await login('+249911000022');
  await db.query('INSERT INTO wallets(user_id,balance) VALUES($1,50000),($2,1000)', [uid(T.cust), uid(T.cust2)]);
});
after(async () => { srv?.kill(); await db.end(); });

test('auth: invalid phone, wrong OTP, lockout after 5 wrong attempts, suspended user', async () => {
  assert.equal((await call('POST', '/auth/otp', { phone: 'abc' })).status, 400);
  const phone = '+249911000031';
  await call('POST', '/auth/otp', { phone });
  await db.query('UPDATE otp_codes SET code_hash=$1 WHERE phone=$2', [sha('123456'), phone]);
  assert.equal((await call('POST', '/auth/verify', { phone, code: '000000' })).body.error, 'otp_wrong');
  for (let i = 0; i < 4; i++) await call('POST', '/auth/verify', { phone, code: '000000' });
  assert.equal((await call('POST', '/auth/verify', { phone, code: '123456' })).body.error, 'otp_expired');
  await login('+249911000032');
  await db.query("UPDATE users SET is_active=false WHERE phone='+249911000032'");
  await call('POST', '/auth/otp', { phone: '+249911000032' });
  await db.query('UPDATE otp_codes SET code_hash=$1 WHERE phone=$2', [sha('123456'), '+249911000032']);
  assert.equal((await call('POST', '/auth/verify', { phone: '+249911000032', code: '123456' })).status, 403);
});

test('access control: no token, wrong role', async () => {
  assert.equal((await call('GET', '/orders/mine')).status, 401);
  assert.equal((await call('GET', '/admin/stats', null, T.cust)).status, 403);
  assert.equal((await call('POST', '/orders/1/status', { status: 'accepted' }, T.cust)).status, 403);
  assert.equal((await call('GET', '/admin/stats', null, T.admin)).status, 200);
});

test('catalog hides unapproved restaurants', async () => {
  const names = (await call('GET', '/restaurants')).body.map(r => r.name);
  assert.ok(names.includes('مطعم أ') && !names.includes('مطعم مخفي'));
});

test('order validation: min order, unavailable/foreign item, qty, zone, closed restaurant', async () => {
  assert.equal((await order(T.cust, { items: [{ itemId: ids.i2, qty: 1 }] })).body.error, 'below_min_order');
  assert.equal((await order(T.cust, { items: [{ itemId: ids.i3, qty: 1 }] })).body.error, 'item_unavailable');
  assert.equal((await order(T.cust, { items: [{ itemId: ids.i4, qty: 1 }] })).body.error, 'item_unavailable');
  assert.equal((await order(T.cust, { items: [{ itemId: ids.i1, qty: 0 }] })).body.error, 'invalid_qty');
  assert.equal((await order(T.cust, { items: [{ itemId: ids.i1, qty: 51 }] })).body.error, 'invalid_qty');
  assert.equal((await order(T.cust, { zoneId: 9999 })).body.error, 'zone_unavailable');
  assert.equal((await order(T.cust, { restaurantId: ids.r3 })).body.error, 'restaurant_unavailable');
  assert.equal((await order(T.cust, { address: '' })).status, 400);
});

test('server computes prices (client tampering ignored) and commission; idempotency key', async () => {
  const r = await order(T.cust, { idemKey: 'k-1', total: 1, subtotal: 1, items: [{ itemId: ids.i1, qty: 2, price: 1 }] });
  assert.equal(r.status, 201);
  assert.equal(r.body.total, 20500); // 18000 + 2000 delivery + 500 service
  ids.A = r.body.orderId;
  const o = await row('SELECT subtotal,commission FROM orders WHERE id=$1', [ids.A]);
  assert.equal(o.subtotal, 18000); assert.equal(o.commission, 2160); // 12%
  const dup = await order(T.cust, { idemKey: 'k-1' });
  assert.equal(dup.body.duplicate, true); assert.equal(dup.body.orderId, ids.A);
  assert.equal((await row("SELECT count(*)::int n FROM orders WHERE idem_key='k-1'")).n, 1);
});

test('data isolation: customers and restaurants only see their own', async () => {
  assert.equal((await call('GET', '/orders/' + ids.A, null, T.cust2)).status, 404);
  assert.equal((await call('GET', '/orders/' + ids.A, null, T.cust)).status, 200);
  const b = await order(T.cust2, { restaurantId: ids.r2, items: [{ itemId: ids.i4, qty: 1 }] });
  const l1 = (await call('GET', '/restaurant/orders', null, T.owner1)).body.map(o => o.id);
  const l2 = (await call('GET', '/restaurant/orders', null, T.owner2)).body.map(o => o.id);
  assert.ok(l1.includes(ids.A) && !l1.includes(b.body.orderId));
  assert.ok(l2.includes(b.body.orderId) && !l2.includes(ids.A));
  assert.equal((await setStatus(T.owner1, b.body.orderId, 'accepted')).body.error, 'not_your_restaurant');
});

test('full lifecycle: accept -> prepare -> ready -> courier pickup -> delivery, with guards', async () => {
  const A = ids.A;
  assert.equal((await setStatus(T.owner1, A, 'ready')).status, 409);       // cannot skip steps
  assert.equal((await setStatus(T.admin, A, 'delivered')).status, 409);    // even admin cannot skip
  assert.equal((await setStatus(T.owner2, A, 'accepted')).body.error, 'not_your_restaurant');
  for (const s of ['accepted', 'preparing', 'ready']) assert.equal((await setStatus(T.owner1, A, s)).status, 200);
  const n = await until(() => row("SELECT 1 FROM notifications WHERE user_id=$1 AND body LIKE '%أكّد%'", [uid(T.cust)]));
  assert.ok(n, 'customer should get an "accepted" notification');
  assert.ok((await call('GET', '/courier/available', null, T.c1)).body.some(o => o.id === A));
  assert.equal((await setStatus(T.c2, A, 'picked_up')).body.error, 'courier_not_approved');
  await call('POST', '/courier/location', { lat: 15.6, lng: 32.5 }, T.c1);
  assert.equal((await call('GET', '/orders/' + A, null, T.cust)).body.last_lat, null); // location hidden before pickup
  assert.equal((await setStatus(T.c1, A, 'picked_up')).status, 200);
  assert.equal((await call('GET', '/orders/' + A, null, T.cust)).body.last_lat, 15.6); // visible while delivering
  assert.equal((await setStatus(T.c3, A, 'picked_up')).body.error, 'not_your_order'); // cannot steal
  assert.equal((await setStatus(T.c3, A, 'delivered')).body.error, 'not_your_order');
  assert.equal((await setStatus(T.c1, A, 'delivered')).status, 200);
  const o = await row('SELECT status,pay_status FROM orders WHERE id=$1', [A]);
  assert.deepEqual(o, { status: 'delivered', pay_status: 'paid' }); // cash settled on delivery
  assert.equal((await row('SELECT count(*)::int n FROM order_status_history WHERE order_id=$1', [A])).n, 6);
  assert.equal((await setStatus(T.admin, A, 'cancelled')).status, 409); // cannot cancel after delivery
  const e = (await call('GET', '/courier/earnings', null, T.c1)).body;
  assert.equal(e.deliveries, 1); assert.equal(e.earnings, 2000);
  assert.equal((await call('GET', '/orders/' + A, null, T.cust)).body.last_lat, null); // hidden again after delivery
});

test('wallet: insufficient balance rolls back; payment deducts; cancellation refunds', async () => {
  const bad = await order(T.cust2, { payMethod: 'wallet' });
  assert.equal(bad.status, 402);
  assert.equal((await row('SELECT count(*)::int n FROM orders WHERE customer_id=$1 AND pay_method=$2', [uid(T.cust2), 'wallet'])).n, 0);
  assert.equal((await row('SELECT balance FROM wallets WHERE user_id=$1', [uid(T.cust2)])).balance, 1000);
  const ok = await order(T.cust, { payMethod: 'wallet' });
  assert.equal(ok.status, 201);
  assert.equal((await row('SELECT balance FROM wallets WHERE user_id=$1', [uid(T.cust)])).balance, 29500);
  assert.equal((await row('SELECT pay_status FROM orders WHERE id=$1', [ok.body.orderId])).pay_status, 'paid');
  assert.equal((await setStatus(T.owner1, ok.body.orderId, 'cancelled')).status, 200);
  assert.equal((await row('SELECT balance FROM wallets WHERE user_id=$1', [uid(T.cust)])).balance, 50000);
  assert.equal((await row('SELECT pay_status FROM orders WHERE id=$1', [ok.body.orderId])).pay_status, 'refunded');
});

test('payment webhook: signature, amount check, replay protection', async () => {
  const o = await order(T.cust, { idemKey: 'k-2' });
  const send = (body, sig) => fetch(BASE + '/payments/webhook', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-signature': sig }, body: JSON.stringify(body) }).then(r => r.status);
  const sign = b => crypto.createHmac('sha256', WH_SECRET).update(JSON.stringify(b)).digest('hex');
  const mk = (ref, amount) => ({ provider: 'test', ref, orderId: o.body.orderId, amount, ok: true });
  assert.equal(await send(mk('r0', 20500), 'bad'), 401);
  assert.equal(await send(mk('r0', 20500), 'a'.repeat(64)), 401);
  const wrong = mk('r1', 100);
  assert.equal(await send(wrong, sign(wrong)), 200);
  assert.equal((await row('SELECT pay_status FROM orders WHERE id=$1', [o.body.orderId])).pay_status, 'pending'); // wrong amount does not mark paid
  const good = mk('r2', 20500);
  assert.equal(await send(good, sign(good)), 200);
  assert.equal((await row('SELECT pay_status FROM orders WHERE id=$1', [o.body.orderId])).pay_status, 'paid');
  const before = (await row('SELECT count(*)::int n FROM payments WHERE order_id=$1', [o.body.orderId])).n;
  assert.equal(await send(good, sign(good)), 200); // replay
  assert.equal((await row('SELECT count(*)::int n FROM payments WHERE order_id=$1', [o.body.orderId])).n, before);
});

test('admin: commission validation, audit log, admin accounts protected', async () => {
  assert.equal((await call('PATCH', '/admin/restaurants/' + ids.r1, { commission_pct: 80 }, T.admin)).body.error, 'invalid_commission');
  assert.equal((await call('PATCH', '/admin/restaurants/' + ids.r1, { commission_pct: 15 }, T.admin)).status, 200);
  const log = await until(async () => (await call('GET', '/admin/audit', null, T.admin)).body.find(a => a.action === 'restaurant.update'));
  assert.ok(log, 'audit log entry missing');
  const adminId = (await row("SELECT id FROM users WHERE role='admin'")).id;
  assert.equal((await call('PATCH', '/admin/users/' + adminId, { is_active: false }, T.admin)).status, 404);
  const next = await order(T.cust); // new orders use the new commission
  assert.equal((await row('SELECT commission FROM orders WHERE id=$1', [next.body.orderId])).commission, 2700); // 15% of 18000
});

test('customer cancel refunds wallet and is owner-only; review after delivery is one-time', async () => {
  const bal = async () => (await row('SELECT balance FROM wallets WHERE user_id=$1', [uid(T.cust)])).balance;
  const before = await bal();
  const w = await order(T.cust, { payMethod: 'wallet' });
  assert.equal(w.status, 201);
  assert.equal((await call('POST', `/orders/${w.body.orderId}/cancel`, null, T.cust2)).status, 404);
  assert.equal((await call('POST', `/orders/${w.body.orderId}/cancel`, null, T.cust)).status, 200);
  assert.equal(await bal(), before);
  assert.equal((await call('POST', `/orders/${w.body.orderId}/cancel`, null, T.cust)).status, 409);
  assert.equal((await call('POST', `/orders/${ids.A}/review`, { stars: 9 }, T.cust)).status, 400);
  assert.equal((await call('POST', `/orders/${ids.A}/review`, { stars: 5 }, T.cust2)).status, 404);
  assert.equal((await call('POST', `/orders/${ids.A}/review`, { stars: 5 }, T.cust)).body.duplicate, false);
  assert.equal((await call('POST', `/orders/${ids.A}/review`, { stars: 1 }, T.cust)).body.duplicate, true);
});
