-- Demo data (safe to run more than once). Demo logins: customer +249900000001, restaurant +249900000002, courier +249900000003, admin +249900000004
INSERT INTO users(phone,name,role) VALUES
 ('+249900000001','عميل تجريبي','customer'),('+249900000002','صاحب مطعم','restaurant'),
 ('+249900000003','مندوب تجريبي','courier'),('+249900000004','المدير','admin')
ON CONFLICT (phone) DO UPDATE SET role=EXCLUDED.role, is_active=true;

INSERT INTO wallets(user_id,balance) SELECT id,50000 FROM users WHERE phone='+249900000001' ON CONFLICT DO NOTHING;
INSERT INTO couriers(user_id,vehicle,is_approved) SELECT id,'motorcycle',true FROM users WHERE phone='+249900000003'
ON CONFLICT (user_id) DO UPDATE SET is_approved=true;

INSERT INTO restaurants(owner_id,city_id,name,category,prep_minutes,rating,is_approved)
SELECT u.id,(SELECT id FROM cities ORDER BY id LIMIT 1),v.n,v.c,v.p,v.r,true
FROM users u, (VALUES ('مطعم الأصيل','سوداني',35,4.8),('بيتزا الخرطوم','بيتزا',30,4.5),('مشويات النيل','مشويات',40,4.6),('كافيه الجبنة','قهوة',15,4.9)) AS v(n,c,p,r)
WHERE u.phone='+249900000002' AND NOT EXISTS (SELECT 1 FROM restaurants x WHERE x.name=v.n);

INSERT INTO menu_items(restaurant_id,name,price)
SELECT r.id,m.n,m.p FROM restaurants r
JOIN (VALUES
 ('مطعم الأصيل','فتة بالدجاج',9000),('مطعم الأصيل','عصيدة بالملاح',6000),('مطعم الأصيل','كبدة سودانية',8000),
 ('بيتزا الخرطوم','بيتزا مارغريتا',10000),('بيتزا الخرطوم','بيتزا دجاج',12000),('بيتزا الخرطوم','بطاطس',4000),
 ('مشويات النيل','كباب مشكل',14000),('مشويات النيل','دجاج مشوي كامل',16000),
 ('كافيه الجبنة','جبنة سودانية',2500),('كافيه الجبنة','قهوة بالزنجبيل',3000),('كافيه الجبنة','كيك شوكولاتة',5000)
) AS m(rn,n,p) ON r.name=m.rn
WHERE NOT EXISTS (SELECT 1 FROM menu_items i WHERE i.restaurant_id=r.id AND i.name=m.n);
