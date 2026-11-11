//
//  PairingPage.swift
//  PatreonTV
//
//  Pages served by PhonePairingServer to the phone or computer. Self-contained
//  apart from /nacl.js, which the TV itself serves: nothing is loaded from the
//  Internet. The cookie is encrypted in the page before it is sent — see
//  `seal()` below and `open()` in PhonePairingServer, which must stay in sync.
//

enum PairingPage {

    enum CodeState {
        case initial, wrongCode, closed
    }

    /// `http://<tv>:<port>/` — asks for the code shown on the TV.
    static func codeEntry(state: CodeState) -> String {
        let stateName: String
        switch state {
        case .initial: stateName = "initial"
        case .wrongCode: stateName = "wrong"
        case .closed: stateName = "closed"
        }
        return page(
            body: #"""
            <h1 data-t="title"></h1>
            <p class="lead" data-t="codeLead"></p>
            <form class="card" id="codeForm" autocomplete="off">
              <label for="code" data-t="codeLabel"></label>
              <input id="code" class="code" maxlength="9" autocapitalize="characters" autocorrect="off" spellcheck="false" autofocus>
              <button type="submit" data-t="next"></button>
              <div class="msg err" id="msg"></div>
            </form>
            <small data-t="privacy"></small>
            """#,
            script: #"""
            var state = "\#(stateName)";
            var msg = document.getElementById("msg");
            if (state === "wrong") msg.textContent = L.wrongCode;
            if (state === "closed") {
              msg.textContent = L.gone;
              document.getElementById("code").disabled = true;
            }
            document.getElementById("codeForm").onsubmit = function (e) {
              e.preventDefault();
              var c = document.getElementById("code").value.toUpperCase().replace(/[^A-Z0-9]/g, "");
              if (c.length !== 6) { msg.textContent = L.codeLength; return; }
              location.href = "/" + c;
            };
            """#
        )
    }

    /// `http://<tv>:<port>/<CODE>` — the cookie form.
    static func form(publicKey: String) -> String {
        page(
            body: #"""
            <h1 data-t="title"></h1>
            <p class="lead" data-t="lead"></p>
            <div class="card" id="form">
              <label for="cookie" data-t="label"></label>
              <textarea id="cookie" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false"></textarea>
              <button type="button" class="secondary" id="paste" data-t="paste"></button>
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
            <script src="/nacl.js"></script>
            """#,
            script: #"""
            var TV_KEY = "\#(publicKey)";

            function b64(bytes) { var s = ""; for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]); return btoa(s); }
            function unb64(s) {
              s = s.replace(/-/g, "+").replace(/_/g, "/");
              while (s.length % 4) s += "=";
              var bin = atob(s), out = new Uint8Array(bin.length);
              for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
              return out;
            }
            function cat() {
              var n = 0, i, p = 0;
              for (i = 0; i < arguments.length; i++) n += arguments[i].length;
              var o = new Uint8Array(n);
              for (i = 0; i < arguments.length; i++) { o.set(arguments[i], p); p += arguments[i].length; }
              return o;
            }
            function same(a, b) {
              if (a.length !== b.length) return false;
              var d = 0; for (var i = 0; i < a.length; i++) d |= a[i] ^ b[i];
              return d === 0;
            }

            // X25519 with the TV's key, SHA-512 keystream, SHA-512 MAC.
            // Must match PhonePairingServer.open().
            function seal(tvKey, text) {
              var enc = new TextEncoder();
              var eph = nacl.box.keyPair();
              var shared = nacl.scalarMult(eph.secretKey, tvKey);
              var plain = enc.encode(text), ct = new Uint8Array(plain.length);
              for (var i = 0, block = 0; i < plain.length; block++) {
                var ks = nacl.hash(cat(shared, enc.encode("ptv-enc"), new Uint8Array([block])));
                for (var j = 0; j < 64 && i < plain.length; j++, i++) ct[i] = plain[i] ^ ks[j];
              }
              var macKey = nacl.hash(cat(shared, enc.encode("ptv-mac"))).slice(0, 32);
              var tag = nacl.hash(cat(macKey, eph.publicKey, ct)).slice(0, 32);
              return JSON.stringify({ epk: b64(eph.publicKey), ct: b64(ct), tag: b64(tag) });
            }

            function extract(raw) {
              var v = raw.trim(), m = v.match(/session_id=([^;\s]+)/i);
              if (m) v = m[1];
              return v.replace(/^["']|["']$/g, "").trim();
            }

            var box = document.getElementById("cookie"), msg = document.getElementById("msg");
            var send = document.getElementById("send"), paste = document.getElementById("paste");
            function show(text, isError) { msg.textContent = text; msg.className = "msg" + (isError ? " err" : ""); }

            var tvKey = unb64(TV_KEY);
            // Opened from the QR code: the fragment (never sent over the network)
            // carries the TV's real key. A mismatch means another device answered.
            var pinned = location.hash.match(/pk=([A-Za-z0-9_-]+)/);
            if (pinned) {
              history.replaceState(null, "", location.pathname);
              if (!same(unb64(pinned[1]), tvKey)) {
                show(L.mismatch, true);
                send.disabled = true;
              }
            }
            if (typeof nacl === "undefined") { show(L.failed, true); send.disabled = true; }

            if (!navigator.clipboard || !navigator.clipboard.readText) paste.style.display = "none";
            paste.onclick = function () {
              navigator.clipboard.readText().then(function (t) { box.value = t; }).catch(function () { box.focus(); });
            };

            send.onclick = function () {
              var value = extract(box.value);
              if (!value) return show(L.empty, true);
              if (value.length > 2048) return show(L.tooLong, true);
              send.disabled = true;
              show(L.sending, false);
              fetch(location.pathname, {
                method: "POST", headers: { "Content-Type": "application/json" },
                body: seal(tvKey, value), cache: "no-store"
              })
                .then(function (r) {
                  if (r.status === 404 || r.status === 410) throw { gone: true };
                  return r.json();
                })
                .then(function (res) {
                  if (res.ok) {
                    box.value = "";
                    document.getElementById("app").innerHTML = '<div class="card done"><div class="big">✓</div><p></p></div>';
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
            """#
        )
    }

    // MARK: - Shared shell

    private static func page(body: String, script: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="referrer" content="no-referrer">
        <title>PatreonTV</title>
        <style>\(css)</style>
        </head>
        <body>
        <main id="app">
        \(body)
        </main>
        <script>
        \(strings)
        document.querySelectorAll("[data-t]").forEach(function (el) { el.textContent = L[el.getAttribute("data-t")]; });
        \(script)
        </script>
        </body>
        </html>
        """
    }

    private static let css = #"""
    :root { color-scheme: dark; --bg:#0c0c10; --card:#17171d; --line:#2a2a33; --text:#ecebf3; --dim:#9a99a8; --accent:#ff6a5a; --ok:#59d38c; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:16px/1.45 -apple-system, system-ui, sans-serif; padding:28px 18px calc(28px + env(safe-area-inset-bottom)); }
    main { max-width:540px; margin:0 auto; }
    h1 { font-size:26px; margin:6px 0 4px; }
    p.lead { color:var(--dim); margin:0 0 22px; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:18px; padding:18px; margin-bottom:16px; }
    label { display:block; margin-bottom:8px; }
    textarea, input { width:100%; background:#0f0f14; color:var(--text); border:1px solid var(--line); border-radius:12px; padding:12px; }
    textarea { min-height:110px; resize:vertical; font:14px ui-monospace, Menlo, monospace; }
    input.code { font:600 30px ui-monospace, Menlo, monospace; letter-spacing:.3em; text-align:center; text-transform:uppercase; }
    textarea:focus, input:focus { outline:2px solid var(--accent); border-color:transparent; }
    button { width:100%; margin-top:14px; padding:15px; border:0; border-radius:14px; background:var(--accent); color:#fff; font-size:17px; font-weight:600; cursor:pointer; }
    button.secondary { background:#262630; font-weight:500; }
    button:disabled { opacity:.5; cursor:default; }
    ol { margin:8px 0 0; padding-left:20px; color:var(--dim); }
    ol li { margin:6px 0; }
    details summary { cursor:pointer; font-weight:600; }
    .msg { margin-top:12px; font-weight:500; min-height:1em; }
    .err { color:#ff8a80; }
    .done { text-align:center; padding:30px 18px; }
    .done .big { font-size:54px; color:var(--ok); }
    small { color:var(--dim); display:block; margin-top:14px; }
    """#

    private static let strings = #"""
    var T = {
      fr: {
        title: "Connecter l'Apple TV",
        codeLead: "Entre le code affiché sur l'Apple TV, sous le QR code.",
        codeLabel: "Code à 6 caractères",
        next: "Continuer",
        codeLength: "Le code fait 6 caractères.",
        wrongCode: "Ce code ne correspond pas à celui affiché sur la TV.",
        lead: "Colle ton cookie Patreon ici : il est chiffré puis envoyé directement à ton Apple TV, sans passer par Internet.",
        label: "Cookie session_id (ou l'en-tête Cookie complet)",
        paste: "Coller",
        send: "Envoyer à l'Apple TV",
        sending: "Vérification auprès de Patreon…",
        done: "C'est fait ! Ton Apple TV est connectée. Tu peux fermer cette page.",
        howTitle: "Où trouver le cookie ?",
        how1: "Sur un ordinateur, connecte-toi à patreon.com.",
        how2: "Ouvre les outils de développement (F12, ou ⌥⌘I sur Mac).",
        how3: "Onglet Application (Chrome) ou Stockage (Firefox/Safari) → Cookies → https://www.patreon.com.",
        how4: "Copie la valeur de session_id. Sur Android, Firefox avec l'extension Cookie-Editor l'affiche aussi.",
        privacy: "Cette page vient de ton Apple TV, sur ton réseau local. Le cookie est chiffré avant l'envoi (échange de clés X25519) : quelqu'un qui écoute le Wi-Fi ne peut pas le lire. Traite ce cookie comme un mot de passe.",
        empty: "Colle d'abord le cookie.",
        tooLong: "Ce texte est trop long : colle seulement la valeur de session_id.",
        mismatch: "Attention : ce n'est pas ton Apple TV qui a répondu. Rescanne le QR code sur la TV.",
        invalid: "Patreon a refusé ce cookie. Vérifie que tu as copié la bonne valeur, ou reconnecte-toi sur patreon.com.",
        network: "Patreon ne répond pas. Réessaie dans un instant.",
        gone: "Cette connexion est terminée. Rouvre l'écran de connexion sur la TV et recommence.",
        failed: "Échec de l'envoi. Vérifie que cet appareil est sur le même réseau que l'Apple TV."
      },
      en: {
        title: "Connect your Apple TV",
        codeLead: "Enter the code shown on the Apple TV, under the QR code.",
        codeLabel: "6-character code",
        next: "Continue",
        codeLength: "The code is 6 characters long.",
        wrongCode: "This code doesn't match the one on the TV.",
        lead: "Paste your Patreon cookie here: it's encrypted and sent straight to your Apple TV, without going through the Internet.",
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
        privacy: "This page comes from your Apple TV, on your local network. The cookie is encrypted before it's sent (X25519 key exchange): someone listening on the Wi-Fi can't read it. Treat this cookie like a password.",
        empty: "Paste the cookie first.",
        tooLong: "That's too long: paste only the session_id value.",
        mismatch: "Warning: this isn't your Apple TV answering. Scan the QR code on the TV again.",
        invalid: "Patreon rejected this cookie. Check you copied the right value, or sign in again at patreon.com.",
        network: "Patreon isn't responding. Try again in a moment.",
        gone: "This pairing is over. Reopen the sign-in screen on the TV and start again.",
        failed: "Couldn't send. Make sure this device is on the same network as the Apple TV."
      }
    };
    var L = T[(navigator.language || "en").slice(0, 2)] || T.en;
    document.documentElement.lang = L === T.fr ? "fr" : "en";
    """#
}
