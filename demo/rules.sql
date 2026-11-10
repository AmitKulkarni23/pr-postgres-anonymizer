-- Masking rules for demo/production.sql. Paste your own into the masker's
-- MASKING_RULES variable. Function reference:
-- https://postgresql-anonymizer.readthedocs.io/en/stable/masking_functions/

-- Unique and still deliverable nowhere: example.com is reserved (RFC 2606).
SECURITY LABEL FOR anon ON COLUMN public.customers.email
  IS 'MASKED WITH FUNCTION pg_catalog.concat(''customer'', id, ''@example.com'')';
SECURITY LABEL FOR anon ON COLUMN public.customers.first_name
  IS 'MASKED WITH FUNCTION anon.dummy_first_name()';
SECURITY LABEL FOR anon ON COLUMN public.customers.last_name
  IS 'MASKED WITH FUNCTION anon.dummy_last_name()';
SECURITY LABEL FOR anon ON COLUMN public.customers.phone
  IS 'MASKED WITH FUNCTION anon.dummy_phone_number()';

SECURITY LABEL FOR anon ON COLUMN public.addresses.street_address
  IS 'MASKED WITH FUNCTION anon.dummy_street_name()';
SECURITY LABEL FOR anon ON COLUMN public.addresses.zipcode
  IS 'MASKED WITH FUNCTION anon.dummy_zip_code()';

-- Free text: detection cannot see names inside it, so replace it whole.
SECURITY LABEL FOR anon ON COLUMN public.support_notes.body
  IS 'MASKED WITH FUNCTION anon.lorem_ipsum(words := 12)';
