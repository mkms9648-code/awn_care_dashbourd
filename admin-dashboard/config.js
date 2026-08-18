// ============================================================================
// إعدادات لوحة تحكم عون إيجنت الموحّدة — عدّل القيم دي بعد الرفع، ومفيش أي حاجة
// تانية محتاجة تتعدّل في باقي الملفات.
// ============================================================================
// اللوحة دي بتدير منتجين، كل واحد على مشروع Supabase منفصل:
//   • عون كير (Doctor Assistant) — دي اللي بيتسجّل بيها الدخول (فيها app_admins).
//   • فتحي ميزانية (Fathi)        — بتتوصل قراءةً/تحكمًا حسب المرحلة.
// مفاتيح الـ anon عمومًا public وده طبيعي — كل الحماية جوّه دوال SECURITY DEFINER
// اللي بتفحص صلاحية المدير الأول.
// ============================================================================
window.APP_CONFIG = {
  // المشروع اللي بيتسجّل عليه دخول المدير (لازم يبقى فيه app_admins + app_is_admin)
  AUTH_PRODUCT: "awncare",

  PRODUCTS: {
    awncare: {
      label: "عون كير",
      sub: "مساعد النائب — Doctor Assistant",
      icon: "ti-stethoscope",
      accent: "#ff3c00",
      SUPABASE_URL: "https://kaqoozpuvdvernvlmqbk.supabase.co",
      SUPABASE_ANON_KEY: "sb_publishable_eDVjcLea7223PDB1seW-kQ_s0K5P-fP",
      // رابط n8n (من غير / في الآخر) — عشان لينك تنفيذ كل رد يشتغل
      N8N_BASE_URL: "https://n8n-c1bz.srv1841520.hstgr.cloud",
      // ويب-هوك مساعد المبيعات (n8n): بياخد {product,message,session_id,history}
      // ويرجّع {reply}. نفس الرابط للمنتجين — بيفرّق بينهم بـ product في الطلب.
      SALES_ENDPOINT: "https://n8n-c1bz.srv1841520.hstgr.cloud/webhook/sales-assistant",
      // ويب-هوك اختبار الذكاء الاصطناعي (n8n): بياخد {system_prompt,message,history}
      // ويرجّع {reply} — دكتور مختبِر AI بيكلم بوتات ed/round/clinic الحقيقية.
      AI_TESTER_ENDPOINT: "https://n8n-c1bz.srv1841520.hstgr.cloud/webhook/ai-tester",
      // ويب-هوك محلل السبب الجذري (n8n): بياخد تفاصيل ملاحظة + دليل معروف،
      // ويرجّع تصنيف السبب + الدليل + أول نقطة انحراف — لتقرير Claude Code.
      ROOT_CAUSE_ENDPOINT: "https://n8n-c1bz.srv1841520.hstgr.cloud/webhook/root-cause-analyzer",
      // ويب-هوك تفاصيل تنفيذ n8n (proxy): بياخد {execution_id}، وبينادي على
      // n8n API نفسه (المفتاح مخزّن جوّه n8n بس) ويرجّع تفاصيل الـ nodes/الأدوات.
      EXECUTION_DETAIL_ENDPOINT: "https://n8n-c1bz.srv1841520.hstgr.cloud/webhook/execution-detail-proxy",
      // ويب-هوك إرسال إشعار push (n8n): بياخد {push_tokens[],title,body}
      // وبيبعت لكل توكن عبر FCM HTTP v1 — بتستخدمه صفحة الإعلانات.
      NOTIFICATION_PUSH_ENDPOINT: "https://n8n-c1bz.srv1841520.hstgr.cloud/webhook/send-notification-push",
    },
    fathi: {
      label: "فتحي ميزانية",
      sub: "المحاسب الذكي — Fathi",
      icon: "ti-calculator",
      accent: "#0D3D2B",
      SUPABASE_URL: "https://jiniprotcrmsverqetmw.supabase.co",
      SUPABASE_ANON_KEY: "sb_publishable__50LG05sqjbG4ofbGaCC1g_O05FxmzL",
      N8N_BASE_URL: "https://n8n-c1bz.srv1841520.hstgr.cloud",
      // ويب-هوك مساعد مبيعات فتحي (n8n) — نفس رابط عون كير، بيفرّق بـ product.
      SALES_ENDPOINT: "https://n8n-c1bz.srv1841520.hstgr.cloud/webhook/sales-assistant",
      // فتحي متفعّل — محتاج تشغّل fathi_admin_dashboard.sql على مشروع فتحي +
      // تعيّن سر الأدمن: select set_admin_secret('...')
      enabled: true,
    },
  },
};
