import { signOut, escapeHtml } from "./supabase.js";

const LINKS = [
  { key: "overview", href: "index.html", label: "نظرة عامة", icon: "ti-layout-dashboard" },
  { key: "doctors", href: "doctors.html", label: "الأطباء والحالات", icon: "ti-stethoscope" },
  { key: "conversations", href: "conversations.html", label: "مراجعة المحادثات", icon: "ti-message-circle" },
];

export function renderNav(session, activeKey) {
  const el = document.getElementById("app-nav");
  if (!el) return;

  el.innerHTML = `
    <div class="sidebar-brand">
      <div class="brand-name">داشبورد <span>المدير</span></div>
      <div class="brand-sub">Awn Agents</div>
    </div>
    <nav class="sidebar-nav">
      ${LINKS.map(
        (l) => `
        <a href="${l.href}" class="sidebar-link ${l.key === activeKey ? "active" : ""}">
          <i class="ti ${l.icon}"></i>
          <span>${l.label}</span>
        </a>`
      ).join("")}
    </nav>
    <div class="sidebar-footer">
      <div class="user-email">${escapeHtml(session.user.email || "")}</div>
      <button id="signout-btn" class="btn btn-ghost" style="width:100%; justify-content:center;">
        <i class="ti ti-logout"></i> تسجيل خروج
      </button>
    </div>
  `;

  document.getElementById("signout-btn").addEventListener("click", signOut);
}
