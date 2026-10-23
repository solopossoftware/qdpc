-- Optional: change the company name stored for the Store app (used on printed vouchers / breadcrumb).
-- Safe to run once in the Supabase SQL editor. You can also change it in Store > Settings > Company Name.
update settings set company_name = 'QATAR DETERGENTS', subtitle = 'Primary Chemicals'
where company_name = 'SOLOPOS';
