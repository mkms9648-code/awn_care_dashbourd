-- الخطوة 8: ربط تابات المشغل (تسعيرة/أوامر/عمال) بلوحة تحكم الأدمن الموجودة
-- (admin_feature_catalog في awn-admin) + تصحيح رصيد خالد عشان يتماشى مع نفس
-- الآلية بدل مفاتيح كانت مخترعة بالغلط (reps_enabled/workshop_enabled).
-- idempotent بالكامل

-- الكتالوج القديم كان كله "افتراضي: مفعّل" (المفتاح الغائب = ON). دلوقتي كل
-- عنصر بيحمل "default" — العناصر الاثناعشر القديمة زي ما هي (on)، والتلاتة
-- الجداد بتوع المشغل افتراضيهم OFF (يظهروا بس للشركات اللي تتفعّلهم بالزرار)
CREATE OR REPLACE FUNCTION public.admin_feature_catalog(p_secret text)
 RETURNS json LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions
AS $$
begin
  if not _admin_ok(p_secret) then raise exception 'AWN_FORBIDDEN: سر الأدمن غير صحيح.'; end if;
  return json_build_array(
    json_build_object('key','chat',       'label','الشات',              'default','on'),
    json_build_object('key','pnl',        'label','قائمة الدخل',        'default','on'),
    json_build_object('key','bs',         'label','الميزانية',          'default','on'),
    json_build_object('key','customers',  'label','العملاء',            'default','on'),
    json_build_object('key','suppliers',  'label','الموردين',           'default','on'),
    json_build_object('key','journal',    'label','اليومية',            'default','on'),
    json_build_object('key','tb',         'label','ميزان المراجعة',     'default','on'),
    json_build_object('key','documents',  'label','المستندات',          'default','on'),
    json_build_object('key','inventory',  'label','المخزون',            'default','on'),
    json_build_object('key','reps',       'label','المناديب',           'default','on'),
    json_build_object('key','operations', 'label','العمليات',           'default','on'),
    json_build_object('key','ledger',     'label','دفتر الأستاذ',       'default','on'),
    json_build_object('key','pricing',    'label','تسعيرة الموديلات (مشغل)', 'default','off'),
    json_build_object('key','orders',     'label','أوامر العملاء (مشغل)',   'default','off'),
    json_build_object('key','workers',    'label','العمال (مشغل)',          'default','off')
  );
end;
$$;
GRANT EXECUTE ON FUNCTION public.admin_feature_catalog(text) TO anon, authenticated;

-- تصحيح مؤسسة خالد: من المفاتيح المخترعة (reps_enabled/workshop_enabled)
-- للمفاتيح الصح المتوافقة مع الكتالوج (reps/pricing/orders/workers)
update companies
set feature_flags = (feature_flags - 'reps_enabled' - 'workshop_enabled')
                     || '{"reps": false, "pricing": true, "orders": true, "workers": true}'::jsonb
where id = 'f056f01b-4b62-4ec6-bfde-cb2a3c28c2d5'
  and (feature_flags ? 'reps_enabled' or feature_flags ? 'workshop_enabled');
