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
    },
    fathi: {
      label: "فتحي ميزانية",
      sub: "المحاسب الذكي — Fathi",
      icon: "ti-calculator",
      accent: "#0D3D2B",
      SUPABASE_URL: "https://jiniprotcrmsverqetmw.supabase.co",
      SUPABASE_ANON_KEY: "sb_publishable__50LG05sqjbG4ofbGaCC1g_O05FxmzL",
      N8N_BASE_URL: "https://n8n-c1bz.srv1841520.hstgr.cloud",
      // فتحي لسه ماعندهوش طبقة أدمن (المرحلة الجاية) — الصفحات بتعرض "قريبًا"
      enabled: false,
    },
  },
};
