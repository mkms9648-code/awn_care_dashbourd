-- ============================================================================
--  فتحي — شكل الفاتورة لكل شركة (invoice_config) + إتاحته لبورتال المناديب
--  شغّله على مشروع فتحي بعد fathi_reps_admin.sql (آمن تعيد تشغيله)
-- ============================================================================
--  invoice_config (jsonb) بيتحكم في شكل الفاتورة: اللوجو (حجم/مكان/إظهار)،
--  اللون، العنوان، سطور فوق (عنوان/تليفون/ضريبة)، إظهار/إخفاء حقول، الفوتر.
--  القيمة الفاضية {} = الشكل الافتراضي. للأدمن يعدّلها من اللوحة، والمندوب
--  يقراها في rep_portal_data فالفاتورة تطلع بالشكل ده.
-- ============================================================================

alter table companies add column if not exists invoice_config jsonb not null default '{}'::jsonb;

-- قراءة الإعداد (أدمن)
create or replace function admin_get_invoice_config(p_secret text, p_company_id uuid)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
declare v jsonb;
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  select invoice_config into v from companies where id = p_company_id;
  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return coalesce(v, '{}'::jsonb)::json;
end;
$$;
grant execute on function admin_get_invoice_config(text, uuid) to anon, authenticated;

-- حفظ الإعداد (أدمن)
create or replace function admin_set_invoice_config(p_secret text, p_company_id uuid, p_config jsonb)
returns json
language plpgsql security definer set search_path = public, extensions
as $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  update companies set invoice_config = coalesce(p_config, '{}'::jsonb) where id = p_company_id;
  if not found then raise exception 'AWN_NOT_FOUND: الشركة مش موجودة.'; end if;
  return json_build_object('ok', true);
end;
$$;
grant execute on function admin_set_invoice_config(text, uuid, jsonb) to anon, authenticated;

-- إعادة تعريف rep_portal_data — نفس أحدث نسخة (logo + customers + صور/كراتين)
-- مع إضافة invoice_config في كائن company.
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
    'company', json_build_object('name', v_company.name, 'currency', v_company.currency,
                                 'logo', v_company.logo, 'invoice_config', v_company.invoice_config),
    'custody',
      (select coalesce(json_agg(json_build_object(
          'name', i.name, 'unit', i.unit, 'qty_on_hand', rc.qty_on_hand, 'price', i.base_price,
          'image_url', i.image_url, 'pieces_per_carton', i.pieces_per_carton, 'carton_price', i.carton_price
        ) order by i.name), '[]'::json)
       from rep_custody rc join items i on i.id = rc.item_id
       where rc.rep_id = v_rep.id and rc.qty_on_hand <> 0),
    'catalog',
      (select coalesce(json_agg(json_build_object(
          'name', i.name, 'unit', i.unit, 'price', i.base_price,
          'image_url', i.image_url, 'pieces_per_carton', i.pieces_per_carton, 'carton_price', i.carton_price
        ) order by i.name), '[]'::json)
       from items i where i.company_id = v_company.id and i.is_active),
    'customers',
      (select coalesce(json_agg(json_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::json)
       from parties p where p.company_id = v_company.id and p.type in ('customer','both')));
end;
$$;
grant execute on function rep_portal_data(text) to anon, authenticated;
