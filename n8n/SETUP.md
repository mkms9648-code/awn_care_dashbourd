# مساعد المبيعات — إعداد n8n

المساعد بيشتغل عن طريق **n8n** (المفتاح بيفضل هناك بأمان). اللوحة بتبعت السؤال
لـ webhook، والـ webhook بيقرا "المعرفة" من Supabase، يسأل Gemini، ويرجّع الرد.

## عقد الاتصال (Contract)

**الطلب** (POST JSON من اللوحة للـ webhook):
```json
{ "product": "awncare | fathi", "message": "سؤال الموظف", "session_id": "…", "history": [ {"role":"user|assistant","content":"…"} ] }
```

**الرد** المتوقع من n8n:
```json
{ "reply": "رد المساعد" }
```
> اللوحة بتقبل كمان `output` / `text` / `answer` بدل `reply` لو أسهل ليك.

## الخطوات

1. **استورد القالب**: n8n → Import from File → `sales-assistant.json`.
2. **الموديل**: افتح نود **Google Gemini Chat Model** واختار الـ credential بتاع
   Gemini بتاعك (نفس اللي مستخدمه في فلوز فتحي/عون كير). تقدر تغيّر الموديل
   (مثلاً `models/gemini-2.0-flash` أو `1.5-pro`).
3. **المعرفة (Get KB)**: النود بيقرا من دالة `sales_kb_get` على مشروع عون كير.
   المفتاح (anon) متحطوط أصلاً. **لازم تكون شغّلت** `sql/026_sales_assistant.sql`
   على مشروع عون كير الأول.
4. **فعّل الـ workflow** وخُد الـ **Production URL** بتاع نود Webhook.
5. **حطّه في اللوحة**: في `admin-dashboard/config.js` حط الرابط في:
   - `PRODUCTS.awncare.SALES_ENDPOINT`
   - `PRODUCTS.fathi.SALES_ENDPOINT`
   (تقدر تستخدم نفس الـ webhook للاتنين — الـ `product` بيتبعت في الطلب فبيفرّق
   المعرفة تلقائيًا؛ أو اعمل workflow لكل منتج لو حابب.)
6. **املأ المعرفة**: من اللوحة → مساعد المبيعات → **تعديل المعرفة** → اكتب الشخصية
   (نبرة الرد) + الأسعار/الباقات/الدفع/اللينكات/التقني، واحفظ. المساعد بيقراها لحظيًا.

## اختياري: ذاكرة محادثة (multi-turn)
عايز المساعد يفتكر سياق المحادثة؟ ضيف نود **Postgres Chat Memory** موصول بـ
**Sales Agent** (input: ai_memory)، و`sessionKey = {{ $('Webhook').item.json.body.session_id }}`
باستخدام نفس Postgres credential بتاعك. من غيرها المساعد بيرد على كل سؤال لوحده
(كافي لأغلب استعلامات الأسعار/الدعم).

## أمان
- ممكن تحمي الـ webhook بـ Header Auth في n8n وتزوّد نفس الهيدر في اللوحة لو حبيت
  تمنع أي حد يستدعيه — مش ضروري للاستخدام الداخلي.
- `sales_kb_get` بترجّع بس معلومات المبيعات (مش سرية — دي اللي المساعد بيقولها للناس).
