// Chord suite header: logo menu (open/close) and the active tab. Shared by the desk, Crescent and Cadence.
(function () {
  var btn = document.getElementById("suiteBtn"), menu = document.getElementById("suiteMenu");
  if (btn && menu) {
    var set = function (open) { menu.hidden = !open; btn.setAttribute("aria-expanded", open ? "true" : "false"); };
    btn.addEventListener("click", function (e) { e.stopPropagation(); set(menu.hidden); });
    document.addEventListener("click", function (e) { if (!menu.hidden && !menu.contains(e.target)) set(false); });
    document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !menu.hidden) { set(false); btn.focus(); } });
    menu.addEventListener("click", function (e) { if (e.target.closest("a")) set(false); });
  }
  var p = location.pathname, here = /\/crescent\//.test(p) ? "crescent" : /\/cadence\//.test(p) ? "cadence" : /\/partners\//.test(p) ? "partners" : /\/how-it-works\//.test(p) ? "" : "desk";
  document.querySelectorAll("[data-suite]").forEach(function (a) {
    var on = a.getAttribute("data-suite") === here;
    a.classList.toggle("on", on);
    if (on) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  });
})();
