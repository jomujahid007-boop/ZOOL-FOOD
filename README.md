# ZOL FOOD | زول فود
منصة طلب وتوصيل طعام للسودان.

- `backend/` : API (Node + Express + PostgreSQL) + واجهة العميل `public/index.html` + لوحة الإدارة `public/admin.html` + الاختبارات
- `customer-app/` : تطبيق العملاء (Flutter)
- `courier-app/` : تطبيق المندوب (Flutter)

## تشغيل الـ Backend محلياً
```
cd backend && npm i && cp .env.example .env
npm run db && psql $DATABASE_URL -f migration_002.sql && psql $DATABASE_URL -f seed.sql
npm start
```
ثم افتح http://localhost:3000 (العميل) و http://localhost:3000/admin.html (الإدارة).

## النشر على Render
`render.yaml` جاهز: Blueprint جديد من المستودع ينشئ الخدمة وقاعدة PostgreSQL. بعد أول نشر شغّل `schema.sql` و`migration_002.sql` و`seed.sql` على القاعدة. راجع الخطط المجانية، فقاعدة Render المجانية تنتهي بعد فترة محدودة.

## الاختبارات
قاعدة اختبار فارغة اسمها يحتوي `test`، ثم `cd backend && DATABASE_URL=... npm test`.
