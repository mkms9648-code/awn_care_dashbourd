-- ============================================================================
-- Migration 027: هوية العميل — لوجو + تعديل الأسماء (مؤسسة/مساحة عمل)
-- ============================================================================
-- بيضيف عمود logo (data URL / base64 مصغّر) على مساحة العمل، ودوال إدارية
-- لتغيير اسم المؤسسة واسم مساحة العمل ورفع/مسح اللوجو — كلها من اللوحة مباشرة.
-- ============================================================================

alter table public.workspaces add column if not exists logo text;

-- تغيير اسم مساحة العمل
create or replace function public.admin_rename_workspace(p_workspace_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: الاسم مطلوب.'; end if;
  update workspaces set name = btrim(p_name), updated_at = now() where id = p_workspace_id;
  if not found then raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.'; end if;
  return jsonb_build_object('ok', true, 'name', btrim(p_name));
end;
$$;
grant execute on function public.admin_rename_workspace(uuid, text) to authenticated;

-- تغيير اسم المؤسسة
create or replace function public.admin_rename_org(p_org_id uuid, p_name text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'AWN_BAD_INPUT: الاسم مطلوب.'; end if;
  update orgs set name = btrim(p_name), updated_at = now() where id = p_org_id;
  if not found then raise exception 'AWN_NOT_FOUND: المؤسسة مش موجودة.'; end if;
  return jsonb_build_object('ok', true, 'name', btrim(p_name));
end;
$$;
grant execute on function public.admin_rename_org(uuid, text) to authenticated;

-- رفع/مسح لوجو مساحة العمل (p_logo = null أو '' لمسحه)
create or replace function public.admin_set_workspace_logo(p_workspace_id uuid, p_logo text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then raise exception 'AWN_FORBIDDEN: للإداريين فقط.'; end if;
  update workspaces set logo = nullif(p_logo, ''), updated_at = now() where id = p_workspace_id;
  if not found then raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.'; end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.admin_set_workspace_logo(uuid, text) to authenticated;

-- إعادة تعريف admin_workspace_detail (من 025) + إضافة logo في كائن workspace
create or replace function public.admin_workspace_detail(p_workspace_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_ws        workspaces%rowtype;
  v_effective text[];
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  select * into v_ws from workspaces where id = p_workspace_id;
  if not found then
    raise exception 'AWN_NOT_FOUND: مساحة العمل مش موجودة.';
  end if;

  v_effective := app_effective_features(p_workspace_id);

  return jsonb_build_object(
    'workspace', (
      select to_jsonb(x) from (
        select w.id, w.name, w.plan_id, w.feature_overrides, w.org_id, w.logo,
               p.name as plan_name, p.key as plan_key,
               o.name as org_name, o.kind as org_kind,
               (select count(*) from staff s
                  where s.workspace_id = w.id and s.role = 'doctor') as doctors_count
          from workspaces w
          join orgs o on o.id = w.org_id
          left join plans p on p.id = w.plan_id
         where w.id = p_workspace_id
      ) x
    ),
    'features', coalesce((
      select jsonb_agg(to_jsonb(fx) order by fx.key)
      from (
        select f.key, f.label, f.description,
               b.key as bot_key,
               exists (select 1 from plan_features pf
                        where pf.plan_id = v_ws.plan_id and pf.feature_key = f.key) as in_plan,
               (v_ws.feature_overrides ->> f.key)::boolean as override,
               (f.key = any(v_effective)) as effective
          from features f
          left join bots b on b.feature_key = f.key
      ) fx
    ), '[]'::jsonb)
  );
end;
$$;
grant execute on function public.admin_workspace_detail(uuid) to authenticated;
