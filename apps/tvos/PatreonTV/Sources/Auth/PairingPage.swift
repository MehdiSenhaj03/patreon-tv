//
//  PairingPage.swift
//  PatreonTV
//
//  The page the phone opens after scanning the QR code on the TV. Served by
//  PhonePairingServer; self-contained (no external resources), so nothing
//  leaves the local network. The cookie is XORed with the one-time pad from the
//  URL fragment before it is sent — see PhonePairingServer.
//

enum PairingPage {
    static let html = #"""
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<title>PatreonTV</title>
<style>
  :root { color-scheme: dark; --bg:#0c0c10; --card:#17171d; --line:#2a2a33; --text:#ecebf3; --dim:#9a99a8; --accent:#ff6a5a; --ok:#59d38c; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:16px/1.45 -apple-system, system-ui, sans-serif; padding:24px 18px calc(24px + env(safe-area-inset-bottom)); }
  main { max-width:520px; margin:0 auto; }
  h1 { font-size:26px; margin:6px 0 4px; }
  p.lead { color:var(--dim); margin:0 0 22px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:18px; margin-bottom:16px; }
  textarea { width:100%; min-height:110px; resize:vertical; background:#0f0f14; color:var(--text); border:1px solid var(--line); border-radius:12px; padding:12px; font:14px ui-monospace, Menlo, monospace; }
  textarea:focus { outline:2px solid var(--accent); border-color:transparent; }
  button { width:100%; margin-top:14px; padding:15px; border:0; border-radius:14px; background:var(--accent); color:#fff; font-size:17px; font-weight:600; }
  button:disabled { opacity:.5; }
  .row { display:flex; gap:10px; }
  .row button { background:#262630; font-weight:500; }
  ol { margin:8px 0 0; padding-left:20px; color:var(--dim); }
  ol li { margin:6px 0; }
  details summary { cursor:pointer; font-weight:600; }
  .msg { margin-top:12px; font-weight:500; }
  .err { color:#ff8a80; }
  .done { text-align:center; padding:30px 18px; }
  .done .big { font-size:54px; color:var(--ok); }
  small { color:var(--dim); display:block; margin-top:14px; }
  code { background:#24242c; padding:1px 6px; border-radius:6px; }
</style>
</head>
<body>
<main id="app">
  <h1 data-t="title"></h1>
  <p class="lead" data-t="lead"></p>

  <div class="card" id="form">
    <label for="cookie" data-t="label"></label>
    <textarea id="cookie" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea>
    <div class="row">
      <button type="button" id="paste" data-t="paste"></button>
    </div>
    <button type="button" id="send" data-t="send"></button>
    <div class="msg" id="msg"></div>
  </div>

  <div class="card">
    <details>
      <summary data-t="howTitle"></summary>
      <ol>
        <li data-t="how1"></li>
        <li data-t="how2"></li>
        <li data-t="how3"></li>
        <li data-t="how4"></li>
      </ol>
    </details>
  </div>

  <small data-t="privacy"></small>
</main>
<script>
(function () {
  var T = {
    fr: {
      title: "Connecter l'Apple TV",
      lead: "Colle ton cookie Patreon ici : il est envoyé directement à ton Apple TV, chiffré, sans passer par Internet.",
      label: "Cookie session_id (ou l'en-tête Cookie complet)",
      paste: "Coller",
      send: "Envoyer à l'Apple TV",
      sending: "Vérification auprès de Patreon…",
      done: "C'est fait ! Ton Apple TV est connectée. Tu peux fermer cette page.",
      howTitle: "Où trouver le cookie ?",
      how1: "Sur un ordinateur, connecte-toi à patreon.com.",
      how2: "Ouvre les outils de développement (F12, ou ⌥⌘I sur Mac).",
      how3: "Onglet Application (Chrome) ou Stockage (Firefox/Safari) → Cookies → https://www.patreon.com.",
      how4: "Copie la valeur de session_id. Sur Android, Firefox + l'extension Cookie-Editor l'affiche aussi.",
      privacy: "La page vient de ton Apple TV, sur ton réseau local. Le cookie est chiffré avec une clé à usage unique contenue dans le QR code, qui ne circule jamais sur le réseau. Traite ce cookie comme un mot de passe.",
      empty: "Colle d'abord le cookie.",
      tooLong: "Ce texte est trop long : colle seulement la valeur de session_id.",
      noKey: "Lien incomplet : scanne à nouveau le QR code affiché sur la TV.",
      invalid: "Patreon a refusé ce cookie. Vérifie que tu as copié la bonne valeur, ou reconnecte-toi sur patreon.com.",
      network: "Patreon ne répond pas. Réessaie dans un instant.",
      gone: "Ce QR code a expiré. Rouvre l'écran de connexion sur la TV et scanne le nouveau.",
      failed: "Échec de l'envoi. Vérifie que ton téléphone est sur le même Wi-Fi que l'Apple TV."
    },
    en: {
      title: "Connect your Apple TV",
      lead: "Paste your Patreon cookie here: it goes straight to your Apple TV, encrypted, without going through the Internet.",
      label: "session_id cookie (or the full Cookie header)",
      paste: "Paste",
      send: "Send to Apple TV",
      sending: "Checking with Patreon…",
      done: "Done! Your Apple TV is connected. You can close this page.",
      howTitle: "Where do I find the cookie?",
      how1: "On a computer, sign in at patreon.com.",
      how2: "Open the developer tools (F12, or ⌥⌘I on Mac).",
      how3: "Application tab (Chrome) or Storage (Firefox/Safari) → Cookies → https://www.patreon.com.",
      how4: "Copy the session_id value. On Android, Firefox with the Cookie-Editor add-on shows it too.",
      privacy: "This page comes from your Apple TV, on your local network. The cookie is encrypted with a one-time key from the QR code, which never travels over the network. Treat this cookie like a password.",
      empty: "Paste the cookie first.",
      tooLong: "That's too long: paste only the session_id value.",
      noKey: "Incomplete link: scan the QR code on the TV again.",
      invalid: "Patreon rejected this cookie. Check you copied the right value, or sign in again at patreon.com.",
      network: "Patreon isn't responding. Try again in a moment.",
      gone: "This QR code has expired. Reopen the sign-in screen on the TV and scan the new one.",
      failed: "Couldn't send. Make sure your phone is on the same Wi-Fi as the Apple TV."
    }
  };
  var L = T[(navigator.language || "en").slice(0, 2)] || T.en;
  document.documentElement.lang = L === T.fr ? "fr" : "en";
  document.querySelectorAll("[data-t]").forEach(function (el) { el.textContent = L[el.getAttribute("data-t")]; });

  function fromB64u(s) {
    s = s.replace(/-/g, "+").replace(/_/g, "/");
    while (s.length % 4) s += "=";
    var bin = atob(s), out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }
  function extract(raw) {
    var v = raw.trim(), m = v.match(/session_id=([^;\s]+)/i);
    if (m) v = m[1];
    return v.replace(/^["']|["']$/g, "").trim();
  }

  var match = location.hash.match(/k=([A-Za-z0-9_-]+)/);
  var key = match ? fromB64u(match[1]) : null;
  // Drop the key from the address bar and history.
  if (match) history.replaceState(null, "", location.pathname);

  var box = document.getElementById("cookie"), msg = document.getElementById("msg");
  var send = document.getElementById("send"), paste = document.getElementById("paste");
  function show(text, isError) { msg.textContent = text; msg.className = "msg" + (isError ? " err" : ""); }

  if (!navigator.clipboard || !navigator.clipboard.readText) paste.style.display = "none";
  paste.onclick = function () {
    navigator.clipboard.readText().then(function (t) { box.value = t; }).catch(function () { box.focus(); });
  };

  send.onclick = function () {
    if (!key) return show(L.noKey, true);
    var value = extract(box.value);
    if (!value) return show(L.empty, true);
    var bytes = new TextEncoder().encode(value);
    if (bytes.length > key.length) return show(L.tooLong, true);
    var hex = "";
    for (var i = 0; i < bytes.length; i++) hex += ("0" + (bytes[i] ^ key[i]).toString(16)).slice(-2);

    send.disabled = true;
    show(L.sending, false);
    fetch(location.pathname, { method: "POST", headers: { "Content-Type": "text/plain" }, body: hex, cache: "no-store" })
      .then(function (r) {
        if (r.status === 404) throw { gone: true };
        return r.json();
      })
      .then(function (res) {
        if (res.ok) {
          box.value = "";
          document.getElementById("app").innerHTML =
            '<div class="card done"><div class="big">✓</div><p></p></div>';
          document.querySelector(".done p").textContent = L.done;
          return;
        }
        var m = res.message;
        show(m === "invalid" ? L.invalid : m === "network" ? L.network
           : m === "too_many_attempts" ? L.gone : L.failed, true);
        send.disabled = false;
      })
      .catch(function (e) {
        show(e && e.gone ? L.gone : L.failed, true);
        send.disabled = false;
      });
  };
})();
</script>
</body>
</html>
"""#
}
