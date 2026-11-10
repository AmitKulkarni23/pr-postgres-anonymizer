-- Stand-in for a production database: a small shop with customers, addresses,
-- orders and support notes. Every person here is invented, but the values look
-- real so the tests can prove none of them reach a PR environment.
CREATE TABLE customers (
  id bigserial PRIMARY KEY,
  email text NOT NULL UNIQUE,
  first_name text NOT NULL,
  last_name text NOT NULL,
  phone text,
  plan text NOT NULL DEFAULT 'free',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE addresses (
  id bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  street_address text NOT NULL,
  city text NOT NULL,
  zipcode text NOT NULL,
  country text NOT NULL DEFAULT 'US'
);

CREATE TABLE orders (
  id bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  total_cents integer NOT NULL CHECK (total_cents > 0),
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE support_notes (
  id bigserial PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  body text NOT NULL
);

INSERT INTO customers (email, first_name, last_name, phone, plan, created_at)
SELECT
  lower(f.name || '.' || l.name || i) || '@' || (ARRAY['gmail.com', 'outlook.com', 'yahoo.com', 'icloud.com'])[1 + i % 4],
  f.name,
  l.name,
  '+1-415-555-' || lpad((1000 + i)::text, 4, '0'),
  (ARRAY['free', 'pro', 'team'])[1 + i % 3],
  now() - (i || ' hours')::interval
FROM generate_series(1, 500) i
CROSS JOIN LATERAL (SELECT (ARRAY['Maria', 'James', 'Priya', 'Wei', 'Olivia', 'Mateo', 'Aisha', 'Noah'])[1 + i % 8] AS name) f
CROSS JOIN LATERAL (SELECT (ARRAY['Garcia', 'Smith', 'Patel', 'Chen', 'Johnson', 'Rossi', 'Khan', 'Kim', 'Nguyen'])[1 + i % 9] AS name) l;

INSERT INTO addresses (customer_id, street_address, city, zipcode)
SELECT id, (100 + id) || ' ' || (ARRAY['Market St', 'Valencia St', 'Mission St', 'Folsom St'])[1 + id % 4],
       (ARRAY['San Francisco', 'Oakland', 'Berkeley'])[1 + id % 3], (94100 + id % 50)::text
FROM customers;

INSERT INTO orders (customer_id, total_cents, status, created_at)
SELECT 1 + i % 500, 500 + (i * 37) % 20000, (ARRAY['paid', 'refunded', 'shipped'])[1 + i % 3], now() - (i || ' minutes')::interval
FROM generate_series(1, 2000) i;

INSERT INTO support_notes (customer_id, body)
SELECT id, 'Called ' || first_name || ' ' || last_name || ' back at ' || phone || ' about a late delivery.'
FROM customers WHERE id % 5 = 0;
