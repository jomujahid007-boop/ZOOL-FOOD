-- Demo data. Log in with these phones (OTP is printed in the server console).
INSERT INTO users(phone,name,role) VALUES
('+249900000001','عميل تجريبي','customer'),('+249900000002','صاحب مطعم','restaurant'),
('+249900000003','مندوب تجريبي','courier'),('+249900000004','المدير','admin') ON CONFLICT DO NOTHING;
INSERT INTO wallets(user_id,balance) SELECT id,50000 FROM users WHERE phone='+249900000001' ON CONFLICT DO NOTHING;
INSERT INTO couriers(user_id,vehicle,is_approved) SELECT id,'motorcycle',true FROM users WHERE phone='+249900000003' ON CONFLICT DO NOTHING;
INSERT INTO restaurants(owner_id,city_id,name,category,prep_minutes,rating,is_approved)
SELECT id,1,'مطعم الأصيل','سوداني',35,4.8,true FROM users WHERE phone='+249900000002';
INSERT INTO restaurants(owner_id,city_id,name,category,prep_minutes,rating,is_approved)
SELECT id,1,'بيتزا الخرطوم','بيتزا',30,4.5,true FROM users WHERE phone='+249900000002';
INSERT INTO menu_items(restaurant_id,name,price) VALUES
(1,'فتة بالدجاج',9000),(1,'عصيدة بالملاح',6000),(1,'كبدة سودانية',8000),
(2,'بيتزا مارغريتا',10000),(2,'بيتزا دجاج',12000),(2,'بطاطس',4000);
