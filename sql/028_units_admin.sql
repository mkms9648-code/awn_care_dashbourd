-- ============================================================================
-- Migration 028: إدارة أقسام المستشفى (units) من لوحة التحكم
-- ============================================================================
-- كل مساحة عمل ليها أقسامها اللي بتظهر في الراوند (units.name). المستشفيات
-- بتختلف مسمياتها، فالمدير محتاج يضيف/يعدّل/يمسح الأقسام لكل مساحة عمل.
-- key = مُعرّف ثابت داخلي (مش بيتعرض)، name = الاسم الظاهر (اللي بيتعدّل).
-- ============================================================================

create or replace function public.admin_list_units(p_workspace_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_org uuid;
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  select org_id into v_org from workspaces where id = p_workspace_id;
  if v_org is null then raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.'; end if;

  return coalesce((
    select jsonb_agg(to_jsonb(t) order by t.name)
    from (
      select u.id, u.key, u.name,
             (select count(*) from encounters e where e.current_unit_id = u.id) as in_use
        from units u
       where u.workspace_id = p_workspace_id
          or (u.workspace_id is null and u.org_id = v_org)
    ) t
  ), '[]'::jsonb);
end;
$$;
grant execute on function public.admin_list_units(uuid) to authenticated;

-- إضافة قسم (key بيتولّد تلقائيًا؛ مايتكررش الاسم في نفس مساحة العمل)
create or replace function public.admin_create_unit(p_workspace_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_org uuid; v_key text; v_id uuid;
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: اسم القسم مطلوب.'; end if;
  select org_id into v_org from workspaces where id = p_workspace_id;
  if v_org is null then raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.'; end if;
  if exists (select 1 from units u where u.workspace_id = p_workspace_id and u.name = btrim(p_name)) then
    raise exception 'AWN_BAD_INPUT: فيه قسم بنفس الاسم بالفعل.';
  end if;

  v_key := 'u_' || substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  insert into units (org_id, workspace_id, key, name)
  values (v_org, p_workspace_id, v_key, btrim(p_name))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;
grant execute on function public.admin_create_unit(uuid, text) to authenticated;

-- تغيير اسم قسم
create or replace function public.admin_rename_unit(p_unit_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
declare v_ws uuid;
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: الاسم مطلوب.'; end if;
  select workspace_id into v_ws from units where id = p_unit_id;
  if not found then raise exception 'AWN_NOT_FOUND: القسم مش موجود.'; end if;
  if exists (select 1 from units u where u.workspace_id is not distinct from v_ws and u.name = btrim(p_name) and u.id <> p_unit_id) then
    raise exception 'AWN_BAD_INPUT: فيه قسم بنفس الاسم بالفعل.';
  end if;
  update units set name = btrim(p_name) where id = p_unit_id;
  return jsonb_build_object('ok', true, 'name', btrim(p_name));
end;
$$;
grant execute on function public.admin_rename_unit(uuid, text) to authenticated;

-- حذف قسم — بس لو مش مستخدم في أي حالة (عشان مايكسرش مراجع)
create or replace function public.admin_delete_unit(p_unit_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  if exists (select 1 from encounters e where e.current_unit_id = p_unit_id) then
    raise exception 'AWN_IN_USE: القسم مستخدم في حالات حالية — غيّر اسمه بدل ما تمسحه، أو انقل الحالات الأول.';
  end if;
  delete from units where id = p_unit_id;
  if not found then raise exception 'AWN_NOT_FOUND: القسم مش موجود.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_delete_unit(uuid) to authenticated;
