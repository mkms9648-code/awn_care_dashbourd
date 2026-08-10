-- ============================================================================
--  فتحي — هوية العميل (لوجو + اسم) + إتاحة نسخ كود الدخول الحالي
--  شغّله على مشروع فتحي بعد fathi_admin_dashboard.sql (آمن تعيد تشغيله)
-- ============================================================================
--  ملاحظة أمان: كود الدخول كان متخزّن مشفّر (bcrypt) بس، فمكانش ينفع يترجّع
--  لعرضه/نسخه. هنا بنضيف عمود code_plain يخزّن الكود كنص جنب المشفّر، عشان
--  المدير يقدر ينسخه ويبعته للعميل تاني. المقايضة: لو قاعدة البيانات تسرّبت،
--  الأكواد هتبقى مكشوفة — مقبول لأداة إدارية داخلية. التسجيل نفسه لسه بيتحقق
--  بالـ hash. الأكواد القديمة (المعمولة قبل ده) هتفضل غير قابلة للنسخ لحد ما
--  تعمل لها "كود جديد" مرة واحدة.
-- ============================================================================

alter table companies      add column if not exists logo       text;
alter table company_access add column if not exists code_plain text;

-- تغيير اسم الشركة
create or replace function admin_rename_company(p_secret text, p_company_id uuid, p_name text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: الاسم مطلوب.'; end if;
  update companies set name = btrim(p_name) where id = p_company_id;
  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return json_build_object('ok', true, 'name', btrim(p_name));
end;
$$;
grant execute on function admin_rename_company(text, uuid, text) to anon, authenticated;

-- رفع/مسح لوجو الشركة (p_logo فاضي = مسح)
create or replace function admin_set_company_logo(p_secret text, p_company_id uuid, p_logo text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  update companies set logo = nullif(p_logo, '') where id = p_company_id;
  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_set_company_logo(text, uuid, text) to anon, authenticated;

-- تعيين/تغيير كود دخول شركة — بيخزّن hash (للتسجيل) + نص (للنسخ)
create or replace function admin_set_company_code(p_secret text, p_company_id uuid, p_code text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  if coalesce(btrim(p_code), '') = '' then raise exception 'AWN_BAD_INPUT: الكود مطلوب.'; end if;
  if not exists(select 1 from companies where id = p_company_id) then
    raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.';
  end if;

  insert into company_access(company_id, code_hash, code_plain)
  values (p_company_id, crypt(btrim(p_code), gen_salt('bf')), btrim(p_code))
  on conflict (company_id) do update
    set code_hash = crypt(btrim(p_code), gen_salt('bf')),
        code_plain = btrim(p_code),
        updated_at = now();

  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_set_company_code(text, uuid, text) to anon, authenticated;

-- إنشاء شركة (+ كود اختياري يتخزّن hash + نص)
create or replace function admin_create_company(
  p_secret text, p_name text, p_currency text default 'EGP', p_code text default null
)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_id uuid;
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: اسم الشركة مطلوب.'; end if;

  insert into companies(name, currency)
  values (btrim(p_name), coalesce(nullif(btrim(p_currency), ''), 'EGP'))
  returning id into v_id;

  if p_code is not null and btrim(p_code) <> '' then
    insert into company_access(company_id, code_hash, code_plain)
    values (v_id, crypt(btrim(p_code), gen_salt('bf')), btrim(p_code));
  end if;

  return json_build_object('ok', true, 'company_id', v_id);
end;
$$;
grant execute on function admin_create_company(text, text, text, text) to anon, authenticated;

-- قائمة الشركات + logo + code (الكود النصي لو متاح، وإلا null)
create or replace function admin_list_companies(p_secret text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then
    raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.';
  end if;

  return coalesce((
    select json_agg(t order by t.name)
    from (
      select c.id, c.name, c.currency, c.industry, c.logo,
             c.chat_enabled, c.is_active, c.feature_flags,
             c.telegram_chat_id, c.created_at,
             exists(select 1 from company_access ca where ca.company_id = c.id) as has_code,
             (select ca.code_plain from company_access ca where ca.company_id = c.id) as code
        from companies c
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function admin_list_companies(text) to anon, authenticated;

-- إتاحة اللوجو لتطبيق العميل (يقرأه بكود الدخول) — عشان يظهر في الهيدر/الفواتير.
-- بيعيد تعريف dashboard_flags (من fathi_admin_dashboard.sql) + إضافة logo.
create or replace function dashboard_flags(p_code text)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v_company companies%rowtype;
begin
  select c.* into v_company
  from company_access ca join companies c on c.id = ca.company_id
  where ca.code_hash = crypt(p_code, ca.code_hash);
  if not found then return json_build_object('ok', false); end if;
  return json_build_object('ok', true,
    'chat_enabled', v_company.chat_enabled,
    'is_active', v_company.is_active,
    'feature_flags', v_company.feature_flags,
    'logo', v_company.logo);
end;
$$;
grant execute on function dashboard_flags(text) to anon, authenticated;
