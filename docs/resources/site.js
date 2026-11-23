/* StoneVPN Manager — landing behaviour + mock UI.
   Every address/name in the mockups is made up: RFC 5737 documentation ranges
   (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24) and RFC 2606 example.* hosts. */
(function () {
  "use strict";
  var doc = document, root = doc.documentElement;
  var L = (root.lang || "en").slice(0, 2) === "uk" ? "uk" : "en";
  var reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ── storage (may be blocked) ─────────────────────────────────────── */
  function getPref(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function setPref(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* private mode */ } }

  /* ── theme ────────────────────────────────────────────────────────── */
  var saved = getPref("theme");
  if (saved === "light" || saved === "dark") root.setAttribute("data-theme", saved);
  doc.addEventListener("click", function (e) {
    var b = e.target.closest("[data-theme-toggle]");
    if (!b) return;
    var cur = root.getAttribute("data-theme") ||
      (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark");
    var next = cur === "light" ? "dark" : "light";
    root.setAttribute("data-theme", next);
    setPref("theme", next);
  });

  /* ── copy buttons ─────────────────────────────────────────────────── */
  doc.addEventListener("click", function (e) {
    var b = e.target.closest("[data-copy]");
    if (!b) return;
    var txt = b.getAttribute("data-copy");
    var done = function () {
      var old = b.textContent;
      b.textContent = b.getAttribute("data-done") || "✓";
      b.classList.add("done");
      setTimeout(function () { b.textContent = old; b.classList.remove("done"); }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(done, function () {});
    else { var t = doc.createElement("textarea"); t.value = txt; doc.body.appendChild(t); t.select(); try { doc.execCommand("copy"); done(); } catch (x) {} t.remove(); }
  });

  /* ── reveal + spotlight ───────────────────────────────────────────── */
  function onVisible(el, fn, opts) {
    if (!("IntersectionObserver" in window)) { fn(); return; }
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (x) { if (x.isIntersecting) { fn(); io.disconnect(); } });
    }, opts || { threshold: 0.25 });
    io.observe(el);
  }
  doc.querySelectorAll(".reveal").forEach(function (el) {
    onVisible(el, function () { el.classList.add("in"); }, { threshold: 0.12 });
  });
  doc.querySelectorAll(".feat").forEach(function (el) {
    el.addEventListener("pointermove", function (e) {
      var r = el.getBoundingClientRect();
      el.style.setProperty("--mx", (e.clientX - r.left) + "px");
      el.style.setProperty("--my", (e.clientY - r.top) + "px");
    });
  });

  /* ── strings ──────────────────────────────────────────────────────── */
  var S = {
    en: {
      idle: "No active tunnels", conn: "Connecting…", one: "1 tunnel up", many: function (n) { return n + " tunnels up"; },
      dnsProblem: "DNS problem", net: "Network", online: "online", ok: "responding", dead: "not responding",
      providers: "Providers", edit: "Edit", last: "last", connecting: "connecting…",
      banner: function (r) { return "Resolver " + r + " isn't answering — ping hangs. Fix checks orphaned DNS and bounces the service."; },
      disconnectAll: "Disconnect all", profiles: "Profiles…", quit: "Quit",
      resolver: "Resolver", owner: "Owner", primary: "Primary", deadSum: "dead",
      log1: function (r) { return "primary: en0 · resolver: " + r + " ✗"; },
      log2: "1 orphaned resolver of a dead tunnel — removed",
      log3: "Wi-Fi: DNS bounced (empty → DHCP), cache flushed",
      log4: "Resolver answers again ✓",
      healthy: "All healthy: the resolver answers, no orphaned entries.",
      setDNS: "Set DNS on a service", addRule: "+ Rule",
      routesDefault: "Default route", routeFix: "Route-fix (to VPN servers, around the tunnel)",
      winProfiles: "Profiles", search: "Search", connect: "Connect", disconnect: "Disconnect",
      endpoint: "Endpoint", address: "Address", allowed: "AllowedIPs", alias: "Alias", fav: "Favourite", rf: "Route-fix",
      rfOpts: ["Ask", "LAN", "Fixed", "Never"], finder: "Show in Finder", del: "Delete…", conf: "Config",
      winConnect: "Connect", user: "Username", pass: "Password", code: "Code", cancel: "Cancel",
      gwFor: "Route-fix gateway for ovpn.example.net (203.0.113.40)", curGw: "Current LAN gateway", otherIp: "Other IP", never: "Never",
      remember: "Remember for this profile and don't ask again",
      tabs: ["General", "Backends", "OpenVPN", "DNS", "Network", "Notifications", "Helper", "Advanced"],
      sGuard: "DNS restore after WireGuard", sGuardT: "Watch DNS after a WireGuard tunnel goes down",
      sGuardH: "Baseline per service, learned while no WG is up and the resolver answers.",
      baseline: "Baseline", dhcp: "DHCP", resetBase: "Reset baseline",
      sDoctor: "Doctor", sProbe: "Probe the resolver", sProbeH: "dig apple.com with a 2 s timeout every 30 s and on DNS change; on failure the icon turns red.",
      sAuto: "Automation", sAutoT: "Fix DNS automatically", sAutoH: "Only when DNS is dead, no sessions and no foreign tunnels are up. Helper only, 2-minute cooldown.",
      sSplit: "Split DNS (/etc/resolver)"
    },
    uk: {
      idle: "Немає активних тунелів", conn: "Підключення…", one: "1 тунель активний", many: function (n) { return n + " тунелі активні"; },
      dnsProblem: "Проблема з DNS", net: "Мережа", online: "online", ok: "відповідає", dead: "не відповідає",
      providers: "Провайдери", edit: "Змінити", last: "останній", connecting: "підключається…",
      banner: function (r) { return "Резолвер " + r + " не відповідає — ping «висить». Fix перевірить осиротілі DNS і переб'є сервіс."; },
      disconnectAll: "Відключити все", profiles: "Профілі…", quit: "Quit",
      resolver: "Resolver", owner: "Власник", primary: "Основний", deadSum: "мертвий",
      log1: function (r) { return "первинний: en0 · резолвер: " + r + " ✗"; },
      log2: "1 осиротілий резолвер мертвого тунелю — прибрано",
      log3: "Wi-Fi: DNS переключено (empty → DHCP), кеш скинуто",
      log4: "Резолвер знову відповідає ✓",
      healthy: "Все здорове: резолвер відповідає, осиротілих записів немає.",
      setDNS: "Встановити DNS на сервіс", addRule: "+ Правило",
      routesDefault: "Default route", routeFix: "Route-fix (до VPN-серверів повз тунель)",
      winProfiles: "Профілі", search: "Пошук", connect: "Підключити", disconnect: "Відключити",
      endpoint: "Endpoint", address: "Адреса", allowed: "AllowedIPs", alias: "Псевдонім", fav: "Обране", rf: "Route-fix",
      rfOpts: ["Питати", "LAN-шлюз", "Фіксований", "Ніколи"], finder: "Показати у Finder", del: "Видалити…", conf: "Конфіг",
      winConnect: "Підключення", user: "Логін", pass: "Пароль", code: "Код", cancel: "Скасувати",
      gwFor: "Route-fix шлюз для ovpn.example.net (203.0.113.40)", curGw: "Поточний LAN-шлюз", otherIp: "Інший IP", never: "Ніколи",
      remember: "Запам'ятати для профілю й більше не питати",
      tabs: ["Загальні", "Бекенди", "OpenVPN", "DNS", "Мережа", "Сповіщення", "Helper", "Додатково"],
      sGuard: "Повернення DNS після WireGuard", sGuardT: "Стежити за DNS після відключення WireGuard",
      sGuardH: "Еталон для кожного сервісу — знімається, поки WG немає і резолвер відповідає.",
      baseline: "Еталон", dhcp: "DHCP", resetBase: "Скинути еталон",
      sDoctor: "Doctor", sProbe: "Перевіряти резолвер", sProbeH: "dig apple.com з таймаутом 2 с раз на 30 с і при зміні DNS; при відмові іконка стає червоною.",
      sAuto: "Автоматика", sAutoT: "Auto DNS fix", sAutoH: "Лише коли DNS мертвий, сесій і сторонніх тунелів немає. Тільки через helper, пауза 2 хв.",
      sSplit: "Split DNS (/etc/resolver)"
    }
  }[L];

  /* ── icons ────────────────────────────────────────────────────────── */
  var I = {
    chev: '<svg viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 1.5 7 5 3.5 8.5"/></svg>',
    refresh: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M13.5 8a5.5 5.5 0 1 1-1.7-4"/><path d="M13.2 1.8v3.1h-3.1"/></svg>',
    gear: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="2.3"/><path d="M8 1.2v2M8 12.8v2M1.2 8h2M12.8 8h2M3.2 3.2l1.4 1.4M11.4 11.4l1.4 1.4M3.2 12.8l1.4-1.4M11.4 4.6l1.4-1.4"/></svg>',
    star: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8 1.3l2 4.2 4.6.6-3.4 3.2.9 4.6L8 11.6l-4.1 2.3.9-4.6L1.4 6.1 6 5.5z"/></svg>',
    wifi: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M1.5 6a9.5 9.5 0 0 1 13 0M3.8 8.6a6.2 6.2 0 0 1 8.4 0M6 11.1a3 3 0 0 1 4 0"/><circle cx="8" cy="13.3" r=".9" fill="currentColor" stroke="none"/></svg>',
    batt: '<svg viewBox="0 0 22 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="1" y="4" width="17" height="8" rx="2.4"/><rect x="2.8" y="5.8" width="11" height="4.4" rx="1.2" fill="currentColor" stroke="none"/><path d="M19.6 6.6v2.8"/></svg>',
    search: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><circle cx="7" cy="7" r="4.6"/><path d="m10.5 10.5 3.6 3.6"/></svg>',
    tabs: [
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="10" cy="10" r="2.8"/><path d="M10 2v2.5M10 15.5V18M2 10h2.5M15.5 10H18M4.3 4.3l1.8 1.8M13.9 13.9l1.8 1.8M4.3 15.7l1.8-1.8M13.9 6.1l1.8-1.8"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M10 3 17 6.5 10 10 3 6.5z"/><path d="m3 10 7 3.5 7-3.5M3 13.5 10 17l7-3.5"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M10 2.5 16.5 5v5c0 4-2.8 6.5-6.5 7.5C6.3 16.5 3.5 14 3.5 10V5z"/><rect x="7.2" y="8.6" width="5.6" height="4.4" rx="1"/><path d="M8.4 8.6V7.4a1.6 1.6 0 0 1 3.2 0v1.2"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="10" cy="10" r="7.5"/><path d="M2.5 10h15M10 2.5c2.2 2.2 3.2 4.7 3.2 7.5S12.2 15.3 10 17.5C7.8 15.3 6.8 12.8 6.8 10S7.8 4.7 10 2.5z"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M2.5 7.5a10.6 10.6 0 0 1 15 0M5 10.4a7 7 0 0 1 10 0M7.5 13.2a3.5 3.5 0 0 1 5 0"/><circle cx="10" cy="15.8" r="1" fill="currentColor" stroke="none"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M5 13.5V9a5 5 0 0 1 10 0v4.5l1.5 1.5h-13z"/><path d="M8.2 17a1.9 1.9 0 0 0 3.6 0"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M10 2.5 16.5 5v5c0 4-2.8 6.5-6.5 7.5C6.3 16.5 3.5 14 3.5 10V5z"/><path d="m7 10 2.1 2.1L13.2 8" stroke-linecap="round"/></svg>',
      '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M3 5.5h8M14.5 5.5H17M3 10h2.5M9 10h8M3 14.5h6M12.5 14.5H17"/><circle cx="12.7" cy="5.5" r="1.8"/><circle cx="7.2" cy="10" r="1.8"/><circle cx="10.8" cy="14.5" r="1.8"/></svg>'
    ]
  };

  /* menubar shield = MenuIcon.swift (24-unit path): outline idle, filled + cut-out mark otherwise */
  var SHIELD = "M12 2.5 19.5 5.5V11.7C19.5 16.4 16.3 19.7 12 21.5 7.7 19.7 4.5 16.4 4.5 11.7V5.5Z";
  var TONE_COLOR = { idle: "#ffffff", ok: "#30d158", busy: "#ff9f0a", problem: "#ff453a", foreign: "#bf5af2" };
  var maskSeq = 0;
  function shield(tone) {
    var c = TONE_COLOR[tone] || "#fff", id = "sm" + (++maskSeq);
    if (tone === "idle") return '<svg viewBox="0 0 24 24"><path d="' + SHIELD + '" fill="none" stroke="' + c + '" stroke-width="2" stroke-linejoin="round"/></svg>';
    var mark = tone === "problem"
      ? '<rect x="11" y="7.5" width="2" height="6" rx="1"/><circle cx="12" cy="16.3" r="1.1"/>'
      : tone === "foreign" ? '<circle cx="12" cy="11.5" r="2.4"/>' : "";
    return '<svg viewBox="0 0 24 24"><defs><mask id="' + id + '"><rect width="24" height="24" fill="#fff"/><g fill="#000">' + mark +
      '</g></mask></defs><path d="' + SHIELD + '" fill="' + c + '" stroke="' + c + '" stroke-width="2" stroke-linejoin="round" mask="url(#' + id + ')"/></svg>';
  }

  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function h(html) { var t = doc.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; }
  function badge(b, lg) { return '<span class="badge b-' + b + (lg ? " lg" : "") + '">' + { wg: "WG", ov: "OV", dg: "DG", cs: "CS", ne: "NE" }[b] + "</span>"; }

  /* ── made-up data ─────────────────────────────────────────────────── */
  var D = {
    router: "192.0.2.1", lanDNS: "192.0.2.53", dgDNS: "198.51.100.53", wgDNS: "198.51.100.1",
    rows: [
      { b: "wg", title: "WireGuard", name: "homelab", end: "203.0.113.10:51820", iface: "utun4", addr: "198.51.100.7", total: 3,
        subs: [{ name: "office", end: "vpn.example.com:51820" }] },
      { b: "ov", title: "OpenVPN", name: "Staging", end: "ovpn.example.net:1194", extra: "OTP", total: 2 },
      { b: "dg", title: "Defguard", name: "Engineering", end: "dg.example.com:51820", extra: "MFA", iface: "utun6", addr: "198.51.100.130", total: 2 },
      { b: "cs", title: "Cisco", name: "vpn.example.com:8443", end: "", total: 1 }
    ]
  };
  function offSub(r, isMain) {
    var bits = [];
    if (isMain && r.b === "wg") bits.push(S.last);
    if (r.end) bits.push(r.end);
    if (r.extra) bits.push(r.extra);
    return bits.join(" · ");
  }
  function clock(sec) {
    var p = function (n) { return (n < 10 ? "0" : "") + n; };
    return p(Math.floor(sec / 3600)) + ":" + p(Math.floor(sec / 60) % 60) + ":" + p(sec % 60);
  }

  /* ── popover ──────────────────────────────────────────────────────── */
  function popoverHTML(opts) {
    opts = opts || {};
    var rows = D.rows.map(function (r) {
      var subs = (r.subs || []).map(function (s) {
        return '<div class="subrow" data-sub="' + r.b + '"><span class="sw sm"></span><span class="n">' + esc(s.name) +
          '</span><span class="s">' + esc(s.end) + '</span><span class="star">' + I.star + "</span></div>";
      }).join("");
      return '<div data-row="' + r.b + '"><div class="prov"><span class="sw" data-sw></span><div class="pinfo"><div class="ptitle">' + badge(r.b) +
        "<b>" + r.title + '</b><span class="dim">·</span><span class="name">' + esc(r.name) + '</span></div><div class="psub" data-sub>' +
        esc(offSub(r, true)) + '</div></div><span class="cnt" data-cnt>0/' + r.total + I.chev + "</span></div>" + subs + "</div>";
    }).join("");
    return '<div class="mk"><div class="pop">' +
      '<div><div class="ph-row"><span class="tone" data-tone></span><span class="headline" data-head>' + S.idle + '</span><span class="ib">' + I.refresh + '</span><span class="ib">' + I.gear + "</span></div>" +
      '<div class="pgrid"><span class="k">' + S.net + '</span><span class="v">Wi-Fi · en0 · via ' + D.router + '</span><span class="tag c-g">' + S.online + "</span>" +
      '<span class="k">DNS</span><span class="v mono" data-dns>' + D.lanDNS + '</span><span class="tag c-g" data-dnsst>' + S.ok + "</span></div></div>" +
      '<div class="banner hide" data-banner><span data-btext></span><span class="pbtn" data-fix>Fix DNS</span></div>' +
      '<div class="slabel"><b>' + S.providers + '</b><a>' + S.edit + "</a></div>" +
      '<div class="card">' + rows + "</div>" +
      '<div class="card">' +
      '<div class="trow" data-tool="dns"><span class="chev">' + I.chev + '</span><b>DNS</b><span class="sum" data-dnssum>' + D.lanDNS + " · split 2</span></div>" +
      '<div class="tpanel hide" data-panel="dns"></div>' +
      '<div class="trow" data-tool="routes"><span class="chev">' + I.chev + '</span><b>Routes</b><span class="sum" data-rsum>default → en0 · 0 utun</span></div>' +
      '<div class="tpanel hide" data-panel="routes"></div>' +
      '<div class="trow"><span class="chev">' + I.chev + '</span><b>Network</b><span class="sum">Wi-Fi (en0)</span></div>' +
      "</div>" +
      '<div class="pfoot"><span class="red dis" data-disc>' + S.disconnectAll + '</span><span class="sp"></span><span>' + S.profiles + '</span><span class="q">' + S.quit + "</span></div>" +
      "</div></div>";
  }

  function Pop(el) {
    this.el = el;
    this.$ = function (sel) { return el.querySelector(sel); };
  }
  Pop.prototype.row = function (b) { return this.el.querySelector('[data-row="' + b + '"]'); };
  Pop.prototype.setRow = function (b, status, sub) {
    var row = this.row(b), sw = row.querySelector("[data-sw]"), ps = row.querySelector("[data-sub]");
    var r = D.rows.filter(function (x) { return x.b === b; })[0];
    sw.className = "sw" + (status === "up" ? " on up" : status === "busy" ? " on busy" : "");
    ps.className = "psub" + (status === "up" ? " c-g" : status === "busy" ? " c-o" : "");
    ps.textContent = sub != null ? sub : offSub(r, true);
    var c = row.querySelector("[data-cnt]");
    c.className = "cnt" + (status === "up" ? " up" : "");
    c.firstChild.nodeValue = (status === "up" ? 1 : 0) + "/" + r.total;
  };
  Pop.prototype.head = function (tone, text) {
    this.$("[data-tone]").className = "tone " + tone;
    this.$("[data-head]").textContent = text;
  };
  Pop.prototype.dns = function (servers, alive, split) {
    this.$("[data-dns]").textContent = servers;
    var st = this.$("[data-dnsst]");
    st.className = "tag " + (alive ? "c-g" : "c-r");
    st.textContent = alive ? S.ok : S.dead;
    var sum = this.$("[data-dnssum]");
    sum.textContent = servers.split(/\s+/).join(", ") + (alive ? "" : " · " + S.deadSum) + " · split " + (split == null ? 2 : split);
    sum.className = "sum" + (alive ? "" : " c-r");
  };
  Pop.prototype.banner = function (text) {
    var b = this.$("[data-banner]");
    if (text) { this.$("[data-btext]").textContent = text; b.classList.remove("hide"); }
    else b.classList.add("hide");
  };
  Pop.prototype.tool = function (id, html) {
    var self = this;
    ["dns", "routes"].forEach(function (t) {
      var on = t === id;
      self.$('[data-tool="' + t + '"]').classList.toggle("open", on);
      var p = self.$('[data-panel="' + t + '"]');
      p.classList.toggle("hide", !on);
      if (on && html != null) p.innerHTML = html;
    });
  };

  function dnsPanelHTML(o) {
    o = o || {};
    var res = (o.res || [[D.dgDNS, true], [D.lanDNS, true]]).map(function (x) {
      return '<span class="mono ' + (x[1] === true ? "c-g" : x[1] === false ? "c-r" : "") + '">' + x[0] + (x[1] === true ? " ✓" : x[1] === false ? " ✗" : "") + "</span>";
    }).join(" &nbsp;");
    return '<div class="tgrid"><span class="k">' + S.resolver + "</span><span>" + res + '</span><span class="k">' + S.owner + "</span><span>" + (o.owner || "Defguard Engineering") + "</span>" +
      '<span class="k">' + S.primary + '</span><span>' + (o.primary || "Defguard Engineering") + ' <span class="c-s">⌄</span></span></div>' +
      '<div class="btnrow"><span class="pbtn blue">Fix DNS</span><span class="pbtn plain">Flush</span></div>' +
      '<div class="log" data-log>' + (o.log || []).map(function (l) { return "<div>" + esc(l) + "</div>"; }).join("") + "</div>" +
      (o.compact ? "" :
      '<div class="split"><b style="font-size:11.5px">Split DNS</b>' +
      '<div class="rule"><span class="mono">corp.example</span><span class="arrow">→</span><span class="mono">' + D.dgDNS + "</span></div>" +
      '<div class="rule"><span class="mono">lab.example.net</span><span class="arrow">→</span><span class="mono">' + D.wgDNS + "</span></div>" +
      '<div class="rule c-s">' + S.addRule + "</div></div>" +
      '<div class="c-s">› ' + S.setDNS + "</div>");
  }

  function routesPanelHTML() {
    var g = function (iface, owner, rs) {
      return '<div><b style="font-size:11.5px">' + iface + '</b> <span class="c-s">· ' + owner + "</span>" +
        rs.map(function (r) { return '<div class="rule"><span class="mono">' + r + "</span></div>"; }).join("") + "</div>";
    };
    return '<div class="tgrid"><span class="k">' + S.routesDefault + '</span><span class="mono">en0 via ' + D.router + "</span></div>" +
      '<div class="split">' + g("utun4", "WireGuard homelab", ["198.51.100.0/25", "203.0.113.128/26"]) +
      g("utun6", "Defguard Engineering", ["198.51.100.128/25", "default (scoped)"]) + "</div>" +
      '<div class="split"><b style="font-size:11.5px">' + S.routeFix + "</b>" +
      '<div class="rule"><span class="mono">203.0.113.40</span><span class="arrow">via</span><span class="mono">' + D.router + ' (en0)</span></div></div>';
  }

  /* ── windows ──────────────────────────────────────────────────────── */
  function winBar(title) { return '<div class="win-bar"><span class="lights"><i></i><i></i><i></i></span><span class="win-title">' + title + "</span></div>"; }

  function profilesHTML() {
    var side = [["wg", "WireGuard", "1/3", true], ["ov", "OpenVPN", "0/2"], ["dg", "Defguard", "1/2"], ["cs", "Cisco", "0/1"]].map(function (x) {
      return '<div class="sb-i' + (x[3] ? " sel" : "") + '">' + badge(x[0], true) + "<span>" + x[1] + '</span><span class="c' + (x[2][0] !== "0" ? " up" : "") + '">' + x[2] + "</span></div>";
    }).join("");
    var list = [["homelab", "203.0.113.10:51820", true, true, true], ["office", "vpn.example.com:51820", false, true], ["backup", "203.0.113.24:51820"]].map(function (x) {
      return '<div class="li' + (x[2] ? " sel" : "") + '"><span class="dot' + (x[2] ? " up" : "") + '"></span><div><div><b>' + x[0] + "</b>" +
        (x[3] ? ' <span class="star" style="display:inline-block;width:9px;height:9px">' + I.star + "</span>" : "") +
        (x[4] ? '<span class="pill">' + S.last + "</span>" : "") + '</div><div class="m mono">' + x[1] + "</div></div></div>";
    }).join("");
    var seg = S.rfOpts.map(function (o, i) { return "<span" + (i === 3 ? ' class="on"' : "") + ">" + o + "</span>"; }).join("");
    return '<div class="mk"><div class="win" style="width:860px">' + winBar(S.winProfiles) +
      '<div class="split3"><div class="sidebar"><div class="sb-h">' + S.providers + "</div>" + side + "</div>" +
      '<div class="list"><div class="field" style="margin:2px 0 8px"><span class="ph" style="display:flex;gap:6px;align-items:center"><span style="width:12px;height:12px;display:inline-block">' + I.search + "</span>" + S.search + "</span></div>" + list + "</div>" +
      '<div class="detail"><div class="dh">' + badge("wg", true) + '<div><h4>homelab</h4><div class="m">utun4 · 198.51.100.7 · 01:12:44</div></div></div>' +
      '<div class="form"><div><span class="k">' + S.endpoint + '</span><span class="v mono">203.0.113.10:51820</span></div>' +
      '<div><span class="k">' + S.address + '</span><span class="v mono">198.51.100.7/32</span></div>' +
      '<div><span class="k">DNS</span><span class="v mono">' + D.wgDNS + "</span></div>" +
      '<div><span class="k">' + S.allowed + '</span><span class="v mono">198.51.100.0/25, 203.0.113.128/26</span></div>' +
      '<div><span class="k">' + S.conf + '</span><span class="v mono">/opt/homebrew/etc/wireguard/homelab.conf</span></div></div>' +
      '<div class="form"><div><span class="k">' + S.alias + '</span><span class="field"><span class="ph">homelab</span></span></div>' +
      '<div><span class="k">' + S.fav + '</span><span class="v" style="display:flex;justify-content:flex-end"><span class="mini-sw off"></span></span></div>' +
      '<div><span class="k">' + S.rf + '</span><span class="v"><span class="seg">' + seg + "</span></span></div></div>" +
      '<div class="wbtns"><span class="wbtn">' + S.finder + '</span><span class="wbtn" style="color:var(--r)">' + S.del + '</span><span class="wbtn pri">' + S.disconnect + "</span></div>" +
      "</div></div></div></div>";
  }

  function connectHTML() {
    return '<div class="mk"><div class="win connect">' + winBar(S.winConnect) + '<div class="body">' +
      '<div class="hd">' + badge("ov", true) + '<div><b>OpenVPN · Staging</b><div class="m mono">ovpn.example.net:1194</div></div></div>' +
      '<div class="frow"><span class="k">' + S.user + '</span><span class="field">alex</span></div>' +
      '<div class="frow"><span class="k">' + S.pass + '</span><span class="field">••••••••••</span></div>' +
      '<div class="frow"><span class="k">' + S.code + ' (OTP)</span><span class="field focus">48 21 07<span class="caret" style="height:12px;width:1.5px;margin-left:1px"></span></span></div>' +
      '<div class="form" style="padding:10px 0"><div style="border:0;min-height:0;padding-bottom:6px" class="note">' + S.gwFor + "</div>" +
      '<div style="border:0;min-height:26px"><span class="radio"><i class="on"></i>' + S.curGw + ' <span class="mono c-s">' + D.router + "</span></span></div>" +
      '<div style="border:0;min-height:26px"><span class="radio"><i></i>' + S.otherIp + '</span><span class="field" style="max-width:130px"><span class="ph">192.0.2.254</span></span></div>' +
      '<div style="border:0;min-height:26px"><span class="radio"><i></i>' + S.never + "</span></div></div>" +
      '<div class="srow"><span class="mini-sw off"></span><span class="grow" style="font-size:12.5px">' + S.remember + "</span></div>" +
      '<div class="wbtns"><span class="wbtn">' + S.cancel + '</span><span class="wbtn pri">' + S.connect + "</span></div>" +
      "</div></div></div>";
  }

  function settingsHTML() {
    var tabs = S.tabs.map(function (t, i) { return "<span" + (i === 3 ? ' class="on"' : "") + ">" + I.tabs[i] + t + "</span>"; }).join("");
    var row = function (title, hint, on) {
      return '<div><div class="srow"><span class="grow">' + title + (hint ? '<span class="hint">' + hint + "</span>" : "") + '</span><span class="mini-sw' + (on ? "" : " off") + '"></span></div></div>';
    };
    return '<div class="mk"><div class="win settings">' + winBar("DNS") + '<div class="tabs">' + tabs + "</div>" + '<div class="sbody">' +
      '<div class="sgroup"><h5>' + S.sGuard + '</h5><div class="form">' + row(S.sGuardT, S.sGuardH, true) +
      '<div><span class="k">' + S.baseline + '</span><span class="v mono">Wi-Fi → ' + S.dhcp + " · USB LAN → " + D.lanDNS + "</span></div>" +
      '<div><span class="grow"></span><span class="wbtn">' + S.resetBase + "</span></div></div></div>" +
      '<div class="sgroup"><h5>' + S.sDoctor + '</h5><div class="form">' + row(S.sProbe, S.sProbeH, true) + "</div></div>" +
      '<div class="sgroup"><h5>' + S.sAuto + '</h5><div class="form">' + row(S.sAutoT, S.sAutoH, false) + "</div></div>" +
      '<div class="sgroup"><h5>' + S.sSplit + '</h5><div class="form"><div><span class="mono grow">corp.example</span><span class="mono c-s">' + D.dgDNS +
      '</span></div><div><span class="mono grow">lab.example.net</span><span class="mono c-s">' + D.wgDNS + "</span></div></div></div>" +
      "</div></div></div>";
  }

  /* ── fit fixed-size mockups into fluid containers ─────────────────── */
  function fit(box, inner, natural) {
    if (box._apply) { box._apply(); return box._apply; }
    var apply = box._apply = function () {
      var w = box.clientWidth || natural, s = Math.min(1, w / natural);
      inner.style.transform = s < 1 ? "scale(" + s + ")" : "";
      inner.style.transformOrigin = "top left";
      box.style.height = inner.offsetHeight * s + "px";
      inner.style.marginLeft = s < 1 ? "0" : Math.max(0, (w - natural) / 2) + "px";
      box._scale = s;
    };
    apply();
    if ("ResizeObserver" in window) {
      var ro = new ResizeObserver(function () { requestAnimationFrame(apply); });
      ro.observe(box); ro.observe(inner);
    } else window.addEventListener("resize", apply);
    return apply;
  }

  /* ── hero scene ───────────────────────────────────────────────────── */
  function sleep(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
  function waitVisible() {
    return new Promise(function (r) {
      if (!doc.hidden) return r();
      var f = function () { if (!doc.hidden) { doc.removeEventListener("visibilitychange", f); r(); } };
      doc.addEventListener("visibilitychange", f);
    });
  }

  var heroFit = doc.querySelector("[data-hero-stage]");
  if (heroFit) {
    var stage = heroFit.querySelector(".stage");
    var desk = stage.querySelector(".desk");
    desk.insertAdjacentHTML("beforeend", popoverHTML());
    var popEl = desk.querySelector(".pop");
    var pop = new Pop(popEl);
    var mb = stage.querySelector("[data-mb-icon]"), mbc = stage.querySelector("[data-mb-count]");
    var cursor = h('<svg class="cursor" viewBox="0 0 22 22"><path d="M4 2.5v15.2l3.9-3.6 2.6 5.9 2.6-1.1-2.5-5.8 5.4-.3z" fill="#fff" stroke="#111" stroke-width="1.1" stroke-linejoin="round"/></svg>');
    desk.appendChild(cursor);
    var relayout = fit(heroFit, stage, 470);

    var setIcon = function (tone, n) { mb.innerHTML = shield(tone); mbc.textContent = n > 0 ? String(n) : ""; };
    var moveTo = function (el, dx, dy) {
      var s = heroFit._scale || 1, d = desk.getBoundingClientRect(), r = el.getBoundingClientRect();
      var x = (r.left - d.left + r.width * (dx == null ? 0.5 : dx)) / s, y = (r.top - d.top + r.height * (dy == null ? 0.55 : dy)) / s;
      cursor.style.transform = "translate(" + x + "px," + y + "px)";
      return sleep(reduce ? 0 : 900);
    };
    var click = function () { cursor.classList.remove("click"); void cursor.offsetWidth; cursor.classList.add("click"); return sleep(260); };

    var timers = {};
    var tick = function (b, r) {
      var t0 = Date.now();
      clearInterval(timers[b]);
      var upd = function () { pop.setRow(b, "up", r.iface + " · " + r.addr + " · " + clock(Math.floor((Date.now() - t0) / 1000) + (b === "wg" ? 4380 : 0))); };
      upd();
      timers[b] = setInterval(upd, 1000);
    };
    var stopTicks = function () { Object.keys(timers).forEach(function (k) { clearInterval(timers[k]); }); timers = {}; };
    var wg = D.rows[0], dg = D.rows[2];

    var idle = function () {
      stopTicks();
      D.rows.forEach(function (r) { pop.setRow(r.b, "off"); });
      pop.head("idle", S.idle); pop.dns(D.lanDNS, true); pop.banner(null); pop.tool(null);
      pop.$("[data-rsum]").textContent = "default → en0 · 0 utun";
      pop.$("[data-disc]").classList.add("dis");
      setIcon("idle", 0);
    };

    var staticShot = function () {
      idle();
      tick("wg", wg); tick("dg", dg); stopTicks();
      pop.head("ok", S.many(2)); pop.dns(D.dgDNS, true);
      pop.$("[data-rsum]").textContent = "default → en0 · 2 utun";
      pop.$("[data-disc]").classList.remove("dis");
      setIcon("ok", 2);
    };

    var run = async function () {
      for (;;) {
        await waitVisible();
        idle(); relayout();
        cursor.style.transition = "none";
        cursor.style.transform = "translate(330px, 600px)";
        void cursor.offsetWidth;
        cursor.style.transition = "";
        await sleep(1400);
        var sw = pop.row("wg").querySelector("[data-sw]");
        await moveTo(sw); await click();
        pop.setRow("wg", "busy", S.connecting); pop.head("busy", S.conn); setIcon("busy", 0);
        await sleep(1500);
        tick("wg", wg); pop.head("ok", S.one); setIcon("ok", 1); pop.dns(D.wgDNS, true);
        pop.$("[data-rsum]").textContent = "default → en0 · 1 utun";
        pop.$("[data-disc]").classList.remove("dis");
        await sleep(1700);
        await moveTo(pop.row("dg").querySelector("[data-sw]")); await click();
        pop.setRow("dg", "busy", S.connecting); pop.head("busy", S.one + " · 1 " + (L === "uk" ? "підключається" : "connecting")); setIcon("busy", 1);
        await sleep(1600);
        tick("dg", dg); pop.head("ok", S.many(2)); setIcon("ok", 2); pop.dns(D.dgDNS, true);
        pop.$("[data-rsum]").textContent = "default → en0 · 2 utun";
        await sleep(2200);
        // the resolver dies (e.g. gateway dropped the session)
        pop.dns(D.dgDNS, false); pop.head("problem", S.dnsProblem); setIcon("problem", 2);
        pop.banner(S.banner(D.dgDNS));
        await sleep(1900);
        await moveTo(pop.$("[data-fix]")); await click();
        pop.banner(null);
        pop.tool("dns", dnsPanelHTML({ res: [[D.dgDNS, false]], log: [], compact: true }));
        relayout();
        var log = pop.$("[data-log]");
        var lines = [S.log1(D.dgDNS), S.log2, S.log3, S.log4];
        for (var i = 0; i < lines.length; i++) {
          await sleep(750);
          log.insertAdjacentHTML("beforeend", "<div>" + esc(lines[i]) + "</div>");
          if (i === 3) {
            pop.$('[data-panel="dns"] .tgrid > span:nth-child(2)').innerHTML = '<span class="mono c-g">' + D.dgDNS + ' ✓</span> &nbsp;<span class="mono c-g">' + D.lanDNS + " ✓</span>";
            pop.dns(D.dgDNS, true); pop.head("ok", S.many(2)); setIcon("ok", 2);
          }
        }
        await sleep(2600);
        pop.tool(null); relayout();
        await sleep(500);
        await moveTo(pop.$("[data-disc]"), 0.4); await click();
        D.rows.forEach(function (r) { if (r.iface) pop.setRow(r.b, "busy", S.connecting); });
        stopTicks(); setIcon("busy", 2);
        await sleep(900);
        idle();
        await sleep(1600);
      }
    };
    if (reduce) staticShot(); else run();
  }

  /* ── gallery ──────────────────────────────────────────────────────── */
  var gal = doc.querySelector("[data-gallery]");
  if (gal) {
    var build = {
      dns: function () {
        var w = h(popoverHTML());
        var p = new Pop(w);
        p.setRow("wg", "up", "utun4 · 198.51.100.7 · 01:12:44");
        p.setRow("dg", "up", "utun6 · 198.51.100.130 · 00:18:09");
        p.head("ok", S.many(2)); p.dns(D.dgDNS + "  " + D.lanDNS, true);
        p.$("[data-rsum]").textContent = "default → en0 · 2 utun";
        p.$("[data-disc]").classList.remove("dis");
        p.tool("dns", dnsPanelHTML({ log: [S.healthy] }));
        return [w, 380];
      },
      routes: function () {
        var w = h(popoverHTML());
        var p = new Pop(w);
        p.setRow("wg", "up", "utun4 · 198.51.100.7 · 01:12:44");
        p.setRow("dg", "up", "utun6 · 198.51.100.130 · 00:18:09");
        p.head("ok", S.many(2)); p.dns(D.dgDNS, true);
        p.$("[data-rsum]").textContent = "default → en0 · 2 utun";
        p.$("[data-disc]").classList.remove("dis");
        p.tool("routes", routesPanelHTML());
        return [w, 380];
      },
      profiles: function () { return [h(profilesHTML()), 860]; },
      connect: function () { return [h(connectHTML()), 440]; },
      settings: function () { return [h(settingsHTML()), 640]; }
    };
    gal.querySelectorAll(".g-pane").forEach(function (pane) {
      var r = build[pane.getAttribute("data-pane")]();
      var box = pane.querySelector(".g-fit");
      box.appendChild(r[0]);
      pane._fit = function () { fit(box, r[0], r[1]); };
      pane._fit();
    });
    var tabs = gal.querySelectorAll(".g-tab");
    var show = function (id) {
      tabs.forEach(function (t) { t.setAttribute("aria-selected", String(t.getAttribute("data-for") === id)); });
      gal.querySelectorAll(".g-pane").forEach(function (p) {
        var on = p.getAttribute("data-pane") === id;
        p.classList.toggle("on", on);
        if (on && p._fit) { p._fit(); }
      });
    };
    tabs.forEach(function (t) { t.addEventListener("click", function () { show(t.getAttribute("data-for")); auto = false; }); });
    show(tabs[0].getAttribute("data-for"));
    var auto = !reduce, idx = 0;
    onVisible(gal, function () {
      setInterval(function () {
        if (!auto || doc.hidden) return;
        idx = (idx + 1) % tabs.length;
        show(tabs[idx].getAttribute("data-for"));
      }, 6500);
    });
  }

  /* ── terminals (typed when visible) ───────────────────────────────── */
  doc.querySelectorAll("[data-term]").forEach(function (pre) {
    var script = JSON.parse(pre.querySelector("script").textContent);
    pre.textContent = "";
    var put = function (cls, text) { var s = doc.createElement("span"); if (cls) s.className = cls; s.textContent = text; pre.appendChild(s); return s; };
    var caret = doc.createElement("span"); caret.className = "caret";
    var play = async function () {
      for (;;) {
        pre.textContent = "";
        for (var i = 0; i < script.length; i++) {
          var l = script[i];
          if (l.c) {
            put("pr", "$ ");
            var span = put("", "");
            pre.appendChild(caret);
            for (var k = 0; k < l.c.length; k++) { span.textContent += l.c[k]; await sleep(reduce ? 0 : 28 + Math.random() * 40); }
            await sleep(reduce ? 0 : 380);
            caret.remove();
            put("", "\n");
          } else {
            put(l.k || "", l.o + "\n");
            await sleep(reduce ? 0 : (l.w || 260));
          }
        }
        put("pr", "$ "); pre.appendChild(caret);
        if (reduce) return;
        await sleep(6000);
        await waitVisible();
      }
    };
    onVisible(pre, play);
  });

  /* ── architecture diagram ─────────────────────────────────────────── */
  var arch = doc.querySelector("[data-arch]");
  if (arch) {
    var A = JSON.parse(arch.querySelector("script").textContent);
    var node = function (x, y, w, hh, cls, t, s) {
      return '<g class="node ' + cls + '"><rect x="' + x + '" y="' + y + '" width="' + w + '" height="' + hh + '" rx="14"/>' +
        '<text x="' + (x + 16) + '" y="' + (y + (s ? 26 : 30)) + '">' + esc(t) + "</text>" + (s ? '<text class="s" x="' + (x + 16) + '" y="' + (y + 45) + '">' + esc(s) + "</text>" : "") + "</g>";
    };
    var svg = '<svg class="arch-svg" viewBox="0 0 640 440" role="img" aria-label="' + esc(A.aria) + '">' +
      '<path class="flow" d="M200 92 H 310"/>' +
      '<path class="flow lamp" d="M460 92 H 475 M475 58 V 264 M475 58 H 490 M475 128 H 490 M475 196 H 490 M475 264 H 490"/>' +
      '<path class="flow" d="M110 124 V 329 H 160 M110 237 H 160"/><path class="flow" d="M50 124 V 372"/><path class="flow" d="M250 398 H 300"/>' +
      node(20, 60, 180, 64, "app", A.app, A.appS) +
      '<text class="s" x="212" y="82">' + esc(A.xpc) + "</text>" +
      node(310, 60, 150, 64, "root", A.helper, A.helperS) +
      node(490, 36, 130, 44, "", "wg-quick") + node(490, 106, 130, 44, "", "openvpn") +
      node(490, 174, 130, 44, "", A.dns) + node(490, 242, 130, 44, "", A.routes) +
      node(160, 212, 220, 50, "", "defguard-client", A.noRoot) +
      node(160, 304, 220, 50, "", "Cisco vpn CLI", A.noRoot) +
      node(20, 372, 230, 52, "", "config.env · state.env", A.shared) +
      node(300, 376, 320, 44, "", "main-vpn-manager.sh  (CLI)") +
      "</svg>";
    arch.insertAdjacentHTML("beforeend", svg);
  }
})();
