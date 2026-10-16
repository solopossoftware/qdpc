-- Run this ONCE in Supabase > SQL Editor (needs solopos_production_app.sql already run before).
-- Adds Production orders + Consumption to the Production app. Safe to run again.

-- ================================================================
--  PRODUCTION ORDERS  &  CONSUMPTION   (moved here from the Store app)
--  All objects are prod_* only — nothing references the Store.
-- ================================================================
create table if not exists prod_orders (
  id              uuid          primary key default gen_random_uuid(),
  order_no        text          not null unique,
  client_token    text          unique,
  order_date      date          not null default current_date,
  tank_id         uuid          not null references prod_tanks(id) on delete restrict,   -- the location is a TANK
  item_id         uuid          not null references prod_items(id) on delete restrict,
  product_name    text,
  batch_no        text,
  output_qty      numeric(14,3) not null check (output_qty > 0),
  unit            text,
  hours_taken     numeric(8,2)  not null default 0 check (hours_taken >= 0),               -- typed by hand; no start/end time, no timer
  remarks         text,
  status          text          not null default 'Pending Approval' check (status in ('Draft','Pending Approval','Approved','Rejected')),
  submitted_by    text, approved_by text, approved_at timestamptz, reject_reason text,
  created_by      text,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);
create index if not exists idx_prod_orders_status on prod_orders(status);
create index if not exists idx_prod_orders_date   on prod_orders(order_date desc);
create index if not exists idx_prod_orders_tank   on prod_orders(tank_id);

-- raw-material usage is its own module: planned (e.g. 3 MT) versus actual (e.g. 3.8 MT)
create table if not exists prod_consumptions (
  id              uuid          primary key default gen_random_uuid(),
  cons_no         text          not null unique,
  client_token    text          unique,
  cons_date       date          not null default current_date,
  order_id        uuid          references prod_orders(id) on delete restrict,           -- optional link to a production order
  for_item_id     uuid          references prod_items(id) on delete restrict,            -- the product this raw material was used for (e.g. LABSA 3 MT)
  for_product     text,
  item_id         uuid          not null references prod_items(id) on delete restrict,
  product_name    text,
  source_tank_id  uuid          references prod_tanks(id) on delete restrict,            -- optional: deduct the actual quantity from this tank
  planned_qty     numeric(14,3) not null default 0 check (planned_qty >= 0),
  actual_qty      numeric(14,3) not null check (actual_qty > 0),
  unit            text,
  remarks         text,
  status          text          not null default 'Pending Approval' check (status in ('Draft','Pending Approval','Approved','Rejected')),
  submitted_by    text, approved_by text, approved_at timestamptz, reject_reason text,
  created_by      text,
  created_at      timestamptz   not null default now(),
  updated_at      timestamptz   not null default now()
);
alter table prod_consumptions add column if not exists for_item_id uuid references prod_items(id) on delete restrict;
alter table prod_consumptions add column if not exists for_product text;
create index if not exists idx_prod_cons_status on prod_consumptions(status);
create index if not exists idx_prod_cons_date   on prod_consumptions(cons_date desc);

do $$ declare t text; begin
  foreach t in array array['prod_orders','prod_consumptions'] loop
    execute format('drop trigger if exists trg_%s_touch on %I', t, t);
    execute format('create trigger trg_%s_touch before update on %I for each row execute function _p_touch()', t, t);
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists allow_anon_all on %I', t);
    execute format('create policy allow_anon_all on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

create or replace function prod_order_create(p jsonb) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype; tok text := nullif(p->>'client_token',''); tk prod_tanks%rowtype; it prod_items%rowtype;
        q numeric := (p->>'output_qty')::numeric; h numeric := coalesce((p->>'hours_taken')::numeric, 0);
        st text := coalesce(nullif(p->>'status',''),'Pending Approval'); u text := p->>'user'; num text;
begin
  if tok is not null then select * into r from prod_orders where client_token = tok; if found then return to_jsonb(r); end if; end if;
  if st not in ('Draft','Pending Approval') then raise exception 'A new production order can only be Draft or Pending Approval'; end if;
  select * into tk from prod_tanks where id = (p->>'tank_id')::uuid; if not found then raise exception 'Select a tank'; end if;
  select * into it from prod_items where id = (p->>'item_id')::uuid; if not found then raise exception 'Select the product produced'; end if;
  if q is null or q <= 0 then raise exception 'Enter the quantity produced'; end if;
  if h < 0 or h > 9999 then raise exception 'Hours taken is not valid'; end if;
  if st = 'Pending Approval' and h <= 0 then raise exception 'Enter the Hours taken'; end if;
  num := prod_next_no('order', coalesce(nullif(p->>'prefix',''),'PRO'));
  insert into prod_orders(order_no, client_token, order_date, tank_id, item_id, product_name, batch_no, output_qty, unit, hours_taken, remarks, status, submitted_by, created_by)
  values (num, tok, coalesce(nullif(p->>'order_date','')::date, current_date), tk.id, it.id, it.name, nullif(p->>'batch_no',''), q, coalesce(it.unit, tk.unit), h, p->>'remarks', st,
          case when st = 'Pending Approval' then u end, u)
  on conflict (client_token) do nothing returning * into r;
  if not found then select * into r from prod_orders where client_token = tok; return to_jsonb(r); end if;
  perform _p_audit('order', r.id, r.order_no, 'Created', null, r.status, u, jsonb_build_object('tank', tk.name, 'qty', q, 'hours', h));
  return to_jsonb(r);
end $$;

create or replace function prod_order_submit(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype;
begin
  select * into r from prod_orders where id = p_id for update; if not found then raise exception 'Production order not found'; end if;
  if r.status = 'Pending Approval' then return to_jsonb(r); end if;
  if r.status not in ('Draft','Rejected') then raise exception 'Order % is % and cannot be submitted', r.order_no, r.status; end if;
  if r.hours_taken <= 0 then raise exception 'Enter the Hours taken before submitting'; end if;
  update prod_orders set status = 'Pending Approval', submitted_by = p_user, reject_reason = null where id = p_id returning * into r;
  perform _p_audit('order', r.id, r.order_no, 'Submitted', 'Draft', 'Pending Approval', p_user);
  return to_jsonb(r);
end $$;

-- approval adds the produced quantity to the tank (row-locked, capacity + same-product checks, ledger + audit)
create or replace function prod_order_approve(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype; bal numeric;
begin
  select * into r from prod_orders where id = p_id for update; if not found then raise exception 'Production order not found'; end if;
  if r.status = 'Approved' then raise exception 'Order % is already approved — stock was not added again', r.order_no; end if;
  if r.status <> 'Pending Approval' then raise exception 'Order % is % and cannot be approved', r.order_no, r.status; end if;
  bal := _p_tank_in(r.tank_id, r.item_id, r.output_qty);
  perform _p_ledger('ORDER_OUTPUT', 'ORDER', r.id, r.order_no, 'tank', r.tank_id, r.item_id, 'IN', r.output_qty, bal, p_user, 'Production order output');
  update prod_tanks set status = 'Completed' where id = r.tank_id and status = 'Available';
  update prod_orders set status = 'Approved', approved_by = p_user, approved_at = now() where id = p_id returning * into r;
  perform _p_audit('order', r.id, r.order_no, 'Approved — stock added', 'Pending Approval', 'Approved', p_user, jsonb_build_object('qty', r.output_qty, 'hours', r.hours_taken));
  return to_jsonb(r);
end $$;

create or replace function prod_order_reject(p_id uuid, p_user text, p_reason text default null) returns jsonb language plpgsql as $$
declare r prod_orders%rowtype; old text;
begin
  select * into r from prod_orders where id = p_id for update; if not found then raise exception 'Production order not found'; end if;
  old := r.status;
  if old = 'Rejected' then return to_jsonb(r); end if;
  if old <> 'Pending Approval' then raise exception 'Order % is % and cannot be rejected', r.order_no, old; end if;
  update prod_orders set status = 'Rejected', approved_by = p_user, approved_at = now(), reject_reason = p_reason where id = p_id returning * into r;
  perform _p_audit('order', r.id, r.order_no, 'Rejected', old, 'Rejected', p_user, case when p_reason is null then null else jsonb_build_object('reason', p_reason) end);
  return to_jsonb(r);
end $$;

create or replace function prod_cons_create(p jsonb) returns jsonb language plpgsql as $$
declare r prod_consumptions%rowtype; tok text := nullif(p->>'client_token',''); it prod_items%rowtype; tk prod_tanks%rowtype; fi prod_items%rowtype; fid uuid := nullif(p->>'for_item_id','')::uuid;
        pl numeric := coalesce((p->>'planned_qty')::numeric, 0); ac numeric := (p->>'actual_qty')::numeric;
        st text := coalesce(nullif(p->>'status',''),'Pending Approval'); u text := p->>'user'; num text; tid uuid := nullif(p->>'source_tank_id','')::uuid; oid uuid := nullif(p->>'order_id','')::uuid;
begin
  if tok is not null then select * into r from prod_consumptions where client_token = tok; if found then return to_jsonb(r); end if; end if;
  if st not in ('Draft','Pending Approval') then raise exception 'A new consumption can only be Draft or Pending Approval'; end if;
  select * into it from prod_items where id = (p->>'item_id')::uuid; if not found then raise exception 'Select the raw material'; end if;
  if ac is null or ac <= 0 then raise exception 'Enter the actual quantity used'; end if;
  if pl < 0 then raise exception 'Planned quantity cannot be negative'; end if;
  if tid is not null then select * into tk from prod_tanks where id = tid; if not found then raise exception 'Tank not found'; end if; end if;
  if oid is not null and not exists (select 1 from prod_orders where id = oid) then raise exception 'Production order not found'; end if;
  if fid is not null then select * into fi from prod_items where id = fid; if not found then raise exception 'Product not found'; end if; end if;
  num := prod_next_no('cons', coalesce(nullif(p->>'prefix',''),'CON'));
  insert into prod_consumptions(cons_no, client_token, cons_date, order_id, for_item_id, for_product, item_id, product_name, source_tank_id, planned_qty, actual_qty, unit, remarks, status, submitted_by, created_by)
  values (num, tok, coalesce(nullif(p->>'cons_date','')::date, current_date), oid, fid, fi.name, it.id, it.name, tid, pl, ac, it.unit, p->>'remarks', st, case when st = 'Pending Approval' then u end, u)
  on conflict (client_token) do nothing returning * into r;
  if not found then select * into r from prod_consumptions where client_token = tok; return to_jsonb(r); end if;
  perform _p_audit('consumption', r.id, r.cons_no, 'Created', null, r.status, u, jsonb_build_object('planned', pl, 'actual', ac));
  return to_jsonb(r);
end $$;

create or replace function prod_cons_approve(p_id uuid, p_user text) returns jsonb language plpgsql as $$
declare r prod_consumptions%rowtype; bal numeric;
begin
  select * into r from prod_consumptions where id = p_id for update; if not found then raise exception 'Consumption not found'; end if;
  if r.status = 'Approved' then raise exception 'Consumption % is already approved — stock was not deducted again', r.cons_no; end if;
  if r.status <> 'Pending Approval' then raise exception 'Consumption % is % and cannot be approved', r.cons_no, r.status; end if;
  if r.source_tank_id is not null then
    bal := _p_tank_out(r.source_tank_id, r.item_id, r.actual_qty);
    perform _p_ledger('CONSUMPTION', 'CONS', r.id, r.cons_no, 'tank', r.source_tank_id, r.item_id, 'OUT', r.actual_qty, bal, p_user, 'Raw material consumed');
  end if;
  update prod_consumptions set status = 'Approved', approved_by = p_user, approved_at = now() where id = p_id returning * into r;
  perform _p_audit('consumption', r.id, r.cons_no, case when r.source_tank_id is null then 'Approved' else 'Approved — stock deducted' end, 'Pending Approval', 'Approved', p_user, jsonb_build_object('planned', r.planned_qty, 'actual', r.actual_qty));
  return to_jsonb(r);
end $$;

create or replace function prod_cons_reject(p_id uuid, p_user text, p_reason text default null) returns jsonb language plpgsql as $$
declare r prod_consumptions%rowtype; old text;
begin
  select * into r from prod_consumptions where id = p_id for update; if not found then raise exception 'Consumption not found'; end if;
  old := r.status;
  if old = 'Rejected' then return to_jsonb(r); end if;
  if old <> 'Pending Approval' then raise exception 'Consumption % is % and cannot be rejected', r.cons_no, old; end if;
  update prod_consumptions set status = 'Rejected', approved_by = p_user, approved_at = now(), reject_reason = p_reason where id = p_id returning * into r;
  perform _p_audit('consumption', r.id, r.cons_no, 'Rejected', old, 'Rejected', p_user, case when p_reason is null then null else jsonb_build_object('reason', p_reason) end);
  return to_jsonb(r);
end $$;

-- existing Production accounts get the two new pages (new installs get them from the starter data below)
update prod_users set pages = pages || ',orders,consumption'
 where pages <> 'all' and role <> 'Operator' and pages not like '%orders%';
update prod_users set pages = pages || ',orders'
 where pages <> 'all' and role = 'Operator' and pages not like '%orders%';

notify pgrst, 'reload schema';
