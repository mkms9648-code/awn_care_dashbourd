-- ============================================================================
--  فتحي — إدارة المناديب لكل شركة من لوحة التحكم (عرض + إضافة + كود دخول)
--  شغّله على مشروع فتحي بعد fathi_admin_dashboard.sql و feature_rep_portal.sql
-- ============================================================================
--  كل مندوب له كود دخول لبورتال المناديب (rep.html) — مخزّن hash للتحقق + نص
--  للنسخ (نفس فكرة كود العميل). للأدمن فقط عبر سر الأدمن.
-- ============================================================================

-- تأكيد وجود جدول أكواد المناديب + عمود النص للنسخ
create table if not exists rep_access (
  rep_id     uuid primary key references reps(id) on delete cascade,
  code_hash  text not null,
  updated_at timestamptz not null default now()
);
alter table rep_access add column if not exists code_plain text;

-- قائمة مناديب شركة
create or replace function admin_list_reps(p_secret text, p_company_id uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  return coalesce((
    select json_agg(t order by t.name)
    from (
      select r.id, r.name, r.commission_percent, r.is_active, r.created_at,
             exists(select 1 from rep_access ra where ra.rep_id = r.id) as has_code,
             (select ra.code_plain from rep_access ra where ra.rep_id = r.id) as code
        from reps r
       where r.company_id = p_company_id
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function admin_list_reps(text, uuid) to anon, authenticated;

-- إضافة مندوب (+ كود اختياري)
create or replace function admin_create_rep(
  p_secret text, p_company_id uuid, p_name text,
  p_commission numeric default 50, p_code text default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: اسم المندوب مطلوب.'; end if;
  if not exists(select 1 from companies where id = p_company_id) then
    raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.';
  end if;
  if exists(select 1 from reps where company_id = p_company_id and name = btrim(p_name)) then
    raise exception 'AWN_BAD_INPUT: فيه مندوب بنفس الاسم في الشركة دي.';
  end if;

  insert into reps(company_id, name, commission_percent)
  values (p_company_id, btrim(p_name), coalesce(p_commission, 50))
  returning id into v_id;

  if p_code is not null and btrim(p_code) <> '' then
    insert into rep_access(rep_id, code_hash, code_plain)
    values (v_id, crypt(btrim(p_code), gen_salt('bf')), btrim(p_code));
  end if;

  return json_build_object('ok', true, 'rep_id', v_id);
end;
$$;
grant execute on function admin_create_rep(text, uuid, text, numeric, text) to anon, authenticated;

-- تعيين/تغيير كود دخول المندوب (hash + نص للنسخ)
create or replace function admin_set_rep_code(p_secret text, p_rep_id uuid, p_code text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  if coalesce(btrim(p_code), '') = '' then raise exception 'AWN_BAD_INPUT: الكود مطلوب.'; end if;
  if not exists(select 1 from reps where id = p_rep_id) then
    raise exception 'AWN_NOT_FOUND: المندوب مش موجود.';
  end if;

  insert into rep_access(rep_id, code_hash, code_plain)
  values (p_rep_id, crypt(btrim(p_code), gen_salt('bf')), btrim(p_code))
  on conflict (rep_id) do update
    set code_hash = crypt(btrim(p_code), gen_salt('bf')),
        code_plain = btrim(p_code),
        updated_at = now();

  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_set_rep_code(text, uuid, text) to anon, authenticated;

-- إلغاء كود دخول المندوب
create or replace function admin_clear_rep_code(p_secret text, p_rep_id uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  delete from rep_access where rep_id = p_rep_id;
  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_clear_rep_code(text, uuid) to anon, authenticated;

-- تفعيل/إيقاف مندوب
create or replace function admin_set_rep_active(p_secret text, p_rep_id uuid, p_active boolean)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  update reps set is_active = p_active where id = p_rep_id;
  if not found then raise exception 'AWN_NOT_FOUND: المندوب مش موجود.'; end if;
  return json_build_object('ok', true, 'is_active', p_active);
end;
$$;
grant execute on function admin_set_rep_active(text, uuid, boolean) to anon, authenticated;

-- تغيير اسم المندوب
create or replace function admin_rename_rep(p_secret text, p_rep_id uuid, p_name text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_company uuid;
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: الاسم مطلوب.'; end if;
  select company_id into v_company from reps where id = p_rep_id;
  if v_company is null then raise exception 'AWN_NOT_FOUND: المندوب مش موجود.'; end if;
  if exists(select 1 from reps where company_id = v_company and name = btrim(p_name) and id <> p_rep_id) then
    raise exception 'AWN_BAD_INPUT: فيه مندوب بنفس الاسم.';
  end if;
  update reps set name = btrim(p_name) where id = p_rep_id;
  return json_build_object('ok', true, 'name', btrim(p_name));
end;
$$;
grant execute on function admin_rename_rep(text, uuid, text) to anon, authenticated;

-- ============================================================================
--  إتاحة لوجو الشركة لبورتال المناديب — إعادة تعريف rep_portal_data + logo
--  (نفس الدالة من feature_rep_portal.sql مع إضافة logo في كائن company)
-- ============================================================================
create or replace function rep_portal_data(p_rep_code text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_rep reps%rowtype; v_company companies%rowtype;
begin
  select r.* into v_rep from rep_access ra join reps r on r.id = ra.rep_id
  where ra.code_hash = crypt(p_rep_code, ra.code_hash);
  if not found then return json_build_object('ok', false, 'error', 'كود الدخول غير صحيح'); end if;
  if not v_rep.is_active then return json_build_object('ok', false, 'error', 'حسابك موقوف — كلّم الإدارة'); end if;

  select * into v_company from companies where id = v_rep.company_id;

  return json_build_object('ok', true,
    'rep', json_build_object('rep_id', v_rep.id, 'name', v_rep.name),
    'company', json_build_object('name', v_company.name, 'currency', v_company.currency, 'logo', v_company.logo),
    'custody',
      (select coalesce(json_agg(json_build_object(
          'name', i.name, 'unit', i.unit, 'qty_on_hand', rc.qty_on_hand, 'price', i.base_price
        ) order by i.name), '[]'::json)
       from rep_custody rc join items i on i.id = rc.item_id
       where rc.rep_id = v_rep.id and rc.qty_on_hand <> 0),
    'catalog',
      (select coalesce(json_agg(json_build_object(
          'name', i.name, 'unit', i.unit, 'price', i.base_price
        ) order by i.name), '[]'::json)
       from items i where i.company_id = v_company.id and i.is_active));
end;
$$;
grant execute on function rep_portal_data(text) to anon, authenticated;
