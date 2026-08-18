// ============================================================================
// الهيكل: السايدبار = مبدّل المنتجين (فوق) + تنقّل المنتج النشط (تحت) + الفوتر.
// كل صفحات المنتجات جوّه فولدرات (awncare/ , fathi/)، فالـ base دايمًا "../".
// ============================================================================
import { signOut, escapeHtml, productConfig } from "./core.js";

const NAV = {
  awncare: [
    { key: "overview",      file: "overview.html",      label: "نظرة عامة",        icon: "ti-layout-dashboard" },
    { key: "subscriptions", file: "subscriptions.html", label: "الاشتراكات والتحكم", icon: "ti-toggle-right-filled" },
    { key: "plans",         file: "plans.html",         label: "الباقات",           icon: "ti-package" },
    { key: "doctors",       file: "doctors.html",       label: "الأطباء والدخول",   icon: "ti-user-cog" },
    { key: "nurses",        file: "nurses.html",        label: "الممرضين والدخول", icon: "ti-vaccine" },
    { key: "units",         file: "units.html",         label: "الأقسام",           icon: "ti-building-hospital" },
    { key: "viewas",        file: "view-as.html",       label: "تجربة الدكتور",     icon: "ti-eye" },
    { key: "announcements", file: "announcements.html", label: "الإعلانات",         icon: "ti-speakerphone" },
    { key: "conversations", file: "conversations.html", label: "المحادثات",         icon: "ti-message-circle" },
    { key: "assistant",     file: "assistant.html",     label: "مساعد المبيعات",    icon: "ti-sparkles" },
    { key: "bots",          file: "bots.html",          label: "البرومبتات والأدوات", icon: "ti-robot" },
    { key: "ai-tester",     file: "ai-tester.html",     label: "اختبار الذكاء الاصطناعي", icon: "ti-test-pipe" },
    { key: "qa-runs",       file: "qa-runs.html",       label: "سجل اختبارات QA",   icon: "ti-clipboard-list" },
  ],
  fathi: [
    { key: "overview",      file: "overview.html",      label: "نظرة عامة",        icon: "ti-layout-dashboard" },
    { key: "subscriptions", file: "subscriptions.html", label: "الاشتراكات والتحكم", icon: "ti-toggle-right-filled" },
    { key: "clients",       file: "clients.html",       label: "العملاء والدخول",   icon: "ti-user-cog" },
    { key: "invoices",      file: "invoices.html",      label: "شكل الفواتير",      icon: "ti-file-invoice" },
    { key: "receipts",      file: "receipts.html",      label: "شكل إيصال الاستلام", icon: "ti-receipt" },
    { key: "conversations", file: "conversations.html", label: "المحادثات",         icon: "ti-message-circle" },
    { key: "assistant",     file: "assistant.html",     label: "مساعد المبيعات",    icon: "ti-sparkles" },
  ],
};

// renderShell(session, { product, active, base })
export function renderShell(session, { product, active, base = "../" }) {
  const el = document.getElementById("app-nav");
  if (!el) return;
  el.classList.add("sidebar");

  const cfg = window.APP_CONFIG.PRODUCTS;
  const products = Object.keys(cfg);

  const switchHtml = products.map((key) => {
    const p = cfg[key];
    const enabled = p.enabled !== false;
    const isActive = key === product;
    const cls = "ps-btn" + (isActive ? " active" : "") + (enabled ? "" : " disabled");
    const inner = `
      <span class="ps-icon" style="background:${p.accent}"><i class="ti ${p.icon}"></i></span>
      <span class="ps-meta">
        <span class="ps-name">${escapeHtml(p.label)}</span>
        <span class="ps-sub">${escapeHtml(p.sub || "")}</span>
      </span>
      ${enabled ? "" : '<span class="ps-soon">قريبًا</span>'}`;
    return enabled
      ? `<a class="${cls}" href="${base}${key}/overview.html">${inner}</a>`
      : `<div class="${cls}" title="لسه تحت التطوير">${inner}</div>`;
  }).join("");

  const links = (NAV[product] || []).map((l) => `
    <a href="${base}${product}/${l.file}" class="sidebar-link ${l.key === active ? "active" : ""}">
      <i class="ti ${l.icon}"></i><span>${l.label}</span>
    </a>`).join("");

  el.innerHTML = `
    <div class="product-switch">
      <div class="ps-title">المنتجات</div>
      ${switchHtml}
    </div>
    <nav class="sidebar-nav">
      <div class="nav-group">${escapeHtml(productConfig(product).label)}</div>
      ${links}
    </nav>
    <div class="sidebar-footer">
      <div class="user-email">${escapeHtml(session.user.email || "")}</div>
      <button id="signout-btn" class="btn btn-ghost" style="width:100%;">
        <i class="ti ti-logout"></i> <span>تسجيل خروج</span>
      </button>
    </div>`;

  document.getElementById("signout-btn").addEventListener("click", signOut);
}
