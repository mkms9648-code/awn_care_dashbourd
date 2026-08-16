-- ============================================================================
-- Migration 045: إضافة "مساحة عمل جديدة" من لوحة التحكم
-- ============================================================================
-- لغاية دلوقتي subscriptions.html بيعدّل مساحات عمل موجودة بس (باقة/مميزات/
-- اسم/لوجو/أقسام) — مفيش طريقة تنشئ عميل جديد من غير الدخول على Supabase.
--
-- مساحة العمل لازم تتبع مؤسسة (orgs.id FK) — فالإنشاء له مسارين:
--   1) مؤسسة موجودة بالفعل (فرع/مساحة عمل تانية لنفس العميل) → p_org_id.
--   2) مؤسسة جديدة كاملة (عميل جديد) → p_org_name + p_org_kind، وبننشئها
--      جوّه نفس الفنكشن قبل مساحة العمل.
-- ============================================================================

-- ---- 1) قائمة المؤسسات — لقايمة الاختيار في نافذة "مساحة عمل جديدة" ----
create or replace function public.admin_list_orgs()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'name', o.name, 'kind', o.kind,
             'workspaces_count', (select count(*) from workspaces w where w.org_id = o.id)
           ) order by o.name)
    from orgs o
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.admin_list_orgs() to authenticated;

-- ---- 2) إنشاء مساحة عمل جديدة (+ مؤسسة جديدة اختياريًا) ----
create or replace function public.admin_create_workspace(
  p_workspace_name text,
  p_org_id         uuid default null,  -- مؤسسة موجودة
  p_org_name       text default null,  -- أو: اسم مؤسسة جديدة
  p_org_kind       text default null,  -- ونوعها (solo/group/hospital)
  p_plan_id        uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_org_id uuid;
  v_ws_id  uuid;
begin
  if not app_is_admin() then
    raise exception 'AWN_FORBIDDEN: للإداريين فقط.';
  end if;

  if coalesce(btrim(p_workspace_name), '') = '' then
    raise exception 'AWN_BAD_INPUT: اسم مساحة العمل مطلوب.';
  end if;

  if p_org_id is not null then
    select id into v_org_id from orgs where id = p_org_id;
    if v_org_id is null then
      raise exception 'AWN_NOT_FOUND: المؤسسة مش موجودة.';
    end if;
  else
    if coalesce(btrim(p_org_name), '') = '' then
      raise exception 'AWN_BAD_INPUT: اسم المؤسسة مطلوب.';
    end if;
    if p_org_kind is null or p_org_kind not in ('solo','group','hospital') then
      raise exception 'AWN_BAD_INPUT: نوع المؤسسة لازم يكون solo/group/hospital.';
    end if;
    insert into orgs (name, kind) values (btrim(p_org_name), p_org_kind)
    returning id into v_org_id;
  end if;

  if p_plan_id is not null and not exists (select 1 from plans where id = p_plan_id) then
    raise exception 'AWN_BAD_INPUT: باقة مش موجودة.';
  end if;

  insert into workspaces (org_id, name, plan_id)
  values (v_org_id, btrim(p_workspace_name), p_plan_id)
  returning id into v_ws_id;

  return jsonb_build_object('workspace_id', v_ws_id, 'org_id', v_org_id);
end;
$$;

grant execute on function public.admin_create_workspace(text, uuid, text, text, uuid) to authenticated;
