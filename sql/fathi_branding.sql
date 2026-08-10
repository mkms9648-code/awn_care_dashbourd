-- ============================================================================
--  فتحي — هوية العميل: لوجو + تعديل اسم الشركة (من لوحة التحكم)
--  شغّله على مشروع فتحي بعد fathi_admin_dashboard.sql
-- ============================================================================

alter table companies add column if not exists logo text;

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

-- إعادة تعريف admin_list_companies + إضافة logo
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
             exists(select 1 from company_access ca where ca.company_id = c.id) as has_code
        from companies c
    ) t
  ), '[]'::json);
end;
$$;
grant execute on function admin_list_companies(text) to anon, authenticated;
