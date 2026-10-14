// PR preview overlay. Copied next to index.html by the deploy-web action for previews only.
// Reads ./_preview.json (written by CI, refreshed on PR title/body edits without a rebuild)
// and shows a corner badge; click it or press ` to open the details panel.
(function () {
  "use strict";
  var KEY = "`";

  function el(tag, props, text) {
    var n = document.createElement(tag);
    if (props) for (var k in props) n.style[k] = props[k];
    if (text != null) n.textContent = text; // textContent only: PR text is untrusted.
    return n;
  }

  function fmtTime(iso) {
    var d = new Date(iso);
    return isNaN(d) ? "" : d.toLocaleString();
  }

  function build(meta) {
    var short = (meta.sha || "").slice(0, 7);
    var title = "PR #" + meta.number + " – " + meta.title;
    document.title = title;

    var root = el("div", {
      position: "fixed", top: "8px", left: "8px", zIndex: "2147483647",
      font: "12px/1.4 system-ui, sans-serif", color: "#fff",
    });

    var badge = el("button", {
      all: "initial", cursor: "pointer", display: "block", font: "inherit",
      background: "rgba(20,20,24,.78)", color: "#fff", padding: "4px 8px",
      borderRadius: "6px", border: "1px solid rgba(255,255,255,.25)",
      maxWidth: "70vw", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap",
    }, "PR #" + meta.number + " · " + meta.branch + " · " + short);
    badge.title = "Click or press ` for PR details";

    var panel = el("div", {
      display: "none", marginTop: "6px", width: "min(420px, 90vw)", maxHeight: "70vh",
      overflow: "auto", background: "rgba(20,20,24,.94)", padding: "12px",
      borderRadius: "8px", border: "1px solid rgba(255,255,255,.25)",
    });
    panel.appendChild(el("div", { fontWeight: "600", fontSize: "14px", marginBottom: "6px" }, meta.title));
    panel.appendChild(el("div", { opacity: ".75", marginBottom: "8px" },
      meta.branch + " @ " + short + (meta.built_at ? " · built " + fmtTime(meta.built_at) : "")));
    if (meta.body) {
      panel.appendChild(el("div", { whiteSpace: "pre-wrap", marginBottom: "10px" }, meta.body));
    }
    var link = el("a", {
      color: "#8ab4ff", textDecoration: "underline",
    }, "Open PR on GitHub");
    link.href = meta.url;
    link.target = "_blank";
    link.rel = "noopener noreferrer";
    panel.appendChild(link);

    function toggle() {
      panel.style.display = panel.style.display === "none" ? "block" : "none";
    }
    badge.addEventListener("click", toggle);
    // Capture phase so the Godot canvas can't swallow the key.
    window.addEventListener("keydown", function (e) {
      if (e.key === KEY && !e.ctrlKey && !e.metaKey && !e.altKey) {
        e.preventDefault();
        e.stopPropagation();
        toggle();
      }
    }, true);

    root.appendChild(badge);
    root.appendChild(panel);
    document.body.appendChild(root);
  }

  function start() {
    fetch("_preview.json", { cache: "no-store" })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (meta) { if (meta) build(meta); })
      .catch(function () { /* no metadata: stay invisible */ });
  }

  if (document.body) start();
  else document.addEventListener("DOMContentLoaded", start);
})();
