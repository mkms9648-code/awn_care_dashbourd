import { signOut, escapeHtml } from "./supabase.js";

const LINKS = [
  { key: "overview", href: "index.html", label: "نظرة عامة" },
  { key: "doctors", href: "doctors.html", label: "الأطباء والحالات" },
  { key: "conversations", href: "conversations.html", label: "مراجعة المحادثات" },
];

export function renderNav(session, activeKey) {
  const el = document.getElementById("app-nav");
  if (!el) return;

  el.innerHTML = `
    <nav class="topnav">
      <div class="topnav-brand">داشبورد المدير</div>
      <div class="topnav-links">
        ${LINKS.map(
          (l) =>
            `<a href="${l.href}" class="${l.key === activeKey ? "active" : ""}">${l.label}</a>`
        ).join("")}
      </div>
      <div class="topnav-user">
        <span class="muted">${escapeHtml(session.user.email || "")}</span>
        <button id="signout-btn" class="btn btn-ghost">تسجيل خروج</button>
      </div>
    </nav>
  `;

  document.getElementById("signout-btn").addEventListener("click", signOut);
}
