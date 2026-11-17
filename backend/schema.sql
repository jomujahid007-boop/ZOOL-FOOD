-- ZOL FOOD | PostgreSQL schema (money stored as integer SDG, no decimals)
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TYPE user_role AS ENUM ('customer','restaurant','courier','admin');
CREATE TYPE order_status AS ENUM ('new','accepted','preparing','ready','picked_up','delivered','cancelled');
CREATE TYPE pay_method AS ENUM ('cash','wallet','gateway');
CREATE TYPE pay_status AS ENUM ('pending','paid','failed','refunded');

CREATE TABLE users(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 phone text UNIQUE NOT NULL, name text, role user_role NOT NULL DEFAULT 'customer',
 is_active boolean NOT NULL DEFAULT true, created_at timestamptz DEFAULT now());
CREATE TABLE otp_codes(
 phone text NOT NULL, code_hash text NOT NULL, expires_at timestamptz NOT NULL,
 attempts int NOT NULL DEFAULT 0, created_at timestamptz DEFAULT now());
CREATE TABLE cities(id serial PRIMARY KEY, state text NOT NULL, name text NOT NULL, is_active boolean DEFAULT false);
CREATE TABLE delivery_zones(
 id serial PRIMARY KEY, city_id int REFERENCES cities ON DELETE CASCADE, name text NOT NULL,
 base_fee int NOT NULL DEFAULT 2000, is_active boolean DEFAULT true);
CREATE TABLE restaurants(
 id serial PRIMARY KEY, owner_id uuid REFERENCES users, city_id int REFERENCES cities,
 name text NOT NULL, category text, logo_url text, cover_url text, address text,
 lat double precision, lng double precision, prep_minutes int DEFAULT 30, min_order int DEFAULT 0,
 commission_pct numeric(5,2) NOT NULL DEFAULT 12, is_approved boolean DEFAULT false,
 is_open boolean DEFAULT true, rating numeric(2,1) DEFAULT 0);
CREATE TABLE restaurant_staff(
 restaurant_id int REFERENCES restaurants ON DELETE CASCADE, user_id uuid REFERENCES users,
 staff_role text NOT NULL CHECK (staff_role IN ('manager','orders','menu','accountant')),
 PRIMARY KEY(restaurant_id,user_id));
CREATE TABLE categories(id serial PRIMARY KEY, name text NOT NULL, sort int DEFAULT 0);
CREATE TABLE menu_items(
 id serial PRIMARY KEY, restaurant_id int NOT NULL REFERENCES restaurants ON DELETE CASCADE,
 category_id int REFERENCES categories, name text NOT NULL, description text,
 price int NOT NULL CHECK (price>=0), image_url text, is_available boolean DEFAULT true, stock int);
CREATE TABLE menu_options(
 id serial PRIMARY KEY, item_id int NOT NULL REFERENCES menu_items ON DELETE CASCADE,
 name text NOT NULL, extra_price int NOT NULL DEFAULT 0);
CREATE TABLE addresses(
 id serial PRIMARY KEY, user_id uuid NOT NULL REFERENCES users ON DELETE CASCADE, label text,
 details text NOT NULL, lat double precision, lng double precision, zone_id int REFERENCES delivery_zones);
CREATE TABLE couriers(
 user_id uuid PRIMARY KEY REFERENCES users, vehicle text, is_approved boolean DEFAULT false,
 is_online boolean DEFAULT false, last_lat double precision, last_lng double precision, last_seen timestamptz);
CREATE TABLE coupons(
 code text PRIMARY KEY, pct int, amount int, max_uses int, used int DEFAULT 0,
 expires_at timestamptz, first_order_only boolean DEFAULT false);
CREATE TABLE orders(
 id bigserial PRIMARY KEY, customer_id uuid NOT NULL REFERENCES users,
 restaurant_id int NOT NULL REFERENCES restaurants, courier_id uuid REFERENCES couriers,
 address_text text NOT NULL, lat double precision, lng double precision, zone_id int REFERENCES delivery_zones,
 subtotal int NOT NULL, delivery_fee int NOT NULL, service_fee int NOT NULL DEFAULT 0,
 discount int NOT NULL DEFAULT 0, total int NOT NULL, commission int NOT NULL DEFAULT 0,
 coupon_code text REFERENCES coupons, pay_method pay_method NOT NULL, pay_status pay_status NOT NULL DEFAULT 'pending',
 status order_status NOT NULL DEFAULT 'new', notes text, idem_key text UNIQUE,
 created_at timestamptz DEFAULT now());
CREATE INDEX ON orders(restaurant_id,status); CREATE INDEX ON orders(customer_id,created_at DESC); CREATE INDEX ON orders(courier_id,status);
CREATE TABLE order_items(
 id bigserial PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders ON DELETE CASCADE,
 item_id int REFERENCES menu_items, name text NOT NULL, unit_price int NOT NULL, qty int NOT NULL CHECK(qty>0), options jsonb DEFAULT '[]');
CREATE TABLE order_status_history(
 id bigserial PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders ON DELETE CASCADE,
 status order_status NOT NULL, actor_id uuid, at timestamptz DEFAULT now());
CREATE TABLE payments(
 id bigserial PRIMARY KEY, order_id bigint NOT NULL REFERENCES orders, provider text, provider_ref text,
 amount int NOT NULL, status pay_status NOT NULL DEFAULT 'pending', raw jsonb, created_at timestamptz DEFAULT now(),
 UNIQUE(provider,provider_ref));
CREATE TABLE refunds(id bigserial PRIMARY KEY, payment_id bigint REFERENCES payments, amount int NOT NULL, reason text, created_at timestamptz DEFAULT now());
CREATE TABLE wallets(user_id uuid PRIMARY KEY REFERENCES users, balance int NOT NULL DEFAULT 0 CHECK(balance>=0));
CREATE TABLE wallet_transactions(id bigserial PRIMARY KEY, user_id uuid REFERENCES users, amount int NOT NULL, kind text NOT NULL, ref text, at timestamptz DEFAULT now());
CREATE TABLE reviews(id bigserial PRIMARY KEY, order_id bigint UNIQUE REFERENCES orders, restaurant_id int REFERENCES restaurants, stars int CHECK(stars BETWEEN 1 AND 5), comment text, at timestamptz DEFAULT now());
CREATE TABLE support_tickets(id bigserial PRIMARY KEY, user_id uuid REFERENCES users, order_id bigint REFERENCES orders, kind text, body text, status text DEFAULT 'open', at timestamptz DEFAULT now());
CREATE TABLE notifications(id bigserial PRIMARY KEY, user_id uuid REFERENCES users, title text, body text, read boolean DEFAULT false, at timestamptz DEFAULT now());
CREATE TABLE restaurant_settlements(id bigserial PRIMARY KEY, restaurant_id int REFERENCES restaurants, period daterange, gross int, commission int, net int, paid_at timestamptz);
CREATE TABLE courier_settlements(id bigserial PRIMARY KEY, courier_id uuid REFERENCES couriers, period daterange, earnings int, cash_collected int, net int, paid_at timestamptz);
CREATE TABLE admin_audit_logs(id bigserial PRIMARY KEY, admin_id uuid, action text, entity text, entity_id text, meta jsonb, at timestamptz DEFAULT now());

-- Seed: Khartoum zone + sample restaurant
INSERT INTO cities(state,name,is_active) VALUES('الخرطوم','أمدرمان',true);
INSERT INTO delivery_zones(city_id,name,base_fee) VALUES(1,'وسط أمدرمان',2000);
