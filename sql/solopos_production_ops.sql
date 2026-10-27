-- ================================================================
--  SOLOPOS Production app - QDPCC operations modules (run once, safe to re-run)
--  Stores the Production app's records: master items & stock, daily production,
--  consumption, filling, dispatch, GRV, NSF transfers, utility, HDPE drums,
--  LABSA transfers and the stock ledger.  Touches prod_* tables ONLY.
-- ================================================================
create table if not exists prod_ops_records (
  coll        text        not null,
  id          text        not null,
  data        jsonb       not null,
  updated_by  text,
  updated_at  timestamptz not null default now(),
  primary key (coll, id)
);
create index if not exists idx_prod_ops_coll on prod_ops_records(coll);

alter table prod_ops_records enable row level security;
drop policy if exists allow_anon_all on prod_ops_records;
create policy allow_anon_all on prod_ops_records for all to anon using (true) with check (true);

-- one atomic batch of changes: {"user":"..","upserts":[{"coll":"..","id":"..","data":{..}}],"deletes":[{"coll":"..","id":".."}]}
create or replace function prod_ops_apply(p jsonb) returns jsonb language plpgsql as $$
declare u jsonb; d jsonb; n_up int := 0; n_del int := 0;
begin
  for u in select * from jsonb_array_elements(coalesce(p->'upserts','[]'::jsonb)) loop
    insert into prod_ops_records(coll, id, data, updated_by, updated_at)
    values (u->>'coll', u->>'id', u->'data', p->>'user', now())
    on conflict (coll, id) do update set data = excluded.data, updated_by = excluded.updated_by, updated_at = now();
    n_up := n_up + 1;
  end loop;
  for d in select * from jsonb_array_elements(coalesce(p->'deletes','[]'::jsonb)) loop
    delete from prod_ops_records where coll = d->>'coll' and id = d->>'id';
    n_del := n_del + 1;
  end loop;
  return jsonb_build_object('upserted', n_up, 'deleted', n_del);
end $$;

grant all on prod_ops_records to anon;
grant execute on function prod_ops_apply(jsonb) to anon;
notify pgrst, 'reload schema';
