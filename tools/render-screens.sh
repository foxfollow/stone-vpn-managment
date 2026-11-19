#!/bin/bash
# Renders the landing-page mockups (docs/resources/site.js, made-up data only)
# into PNGs for the READMEs + the Open Graph card, with headless Google Chrome.
#
#   tools/render-screens.sh            → docs/resources/screens/{en,uk}/*.png, docs/resources/og-image.png
#
# Re-run after changing the mock UI in site.js / site.css.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$ROOT/docs"
OUT="$DOCS/resources/screens"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[[ -x "$CHROME" ]] || { echo "Google Chrome not found (set CHROME=…)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# One page per mockup: the gallery markup site.js expects, with a single pane.
pane_page() { # lang pane width
  cat > "$TMP/$1-$2.html" <<EOF
<!DOCTYPE html><html lang="$1" data-theme="dark"><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
<link rel="stylesheet" href="file://$DOCS/resources/site.css">
<style>body{margin:0;background:#061820}.g-stage{min-height:100vh;border-radius:0;border:0;padding:36px}.g-tabs{display:none}</style>
</head><body><div data-gallery><div class="g-tabs"><button class="g-tab" data-for="$2"></button></div>
<div class="g-stage"><div class="g-pane" data-pane="$2"><div class="g-fit"></div></div></div></div>
<script src="file://$DOCS/resources/site.js"></script></body></html>
EOF
}

shoot() { # html png width height
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-prefers-reduced-motion --user-data-dir="$TMP/profile" --force-device-scale-factor=2 \
    --window-size="$3,$4" --virtual-time-budget=2500 --screenshot="$2" "file://$1" >/dev/null 2>&1
  echo "  $2"
}

for lang in en uk; do
  mkdir -p "$OUT/$lang"
  pane_page "$lang" dns;      shoot "$TMP/$lang-dns.html"      "$OUT/$lang/dns.png"      460 1010
  pane_page "$lang" routes;   shoot "$TMP/$lang-routes.html"   "$OUT/$lang/routes.png"   460 880
  pane_page "$lang" profiles; shoot "$TMP/$lang-profiles.html" "$OUT/$lang/profiles.png" 940 560
  pane_page "$lang" connect;  shoot "$TMP/$lang-connect.html"  "$OUT/$lang/connect.png"  520 560
  pane_page "$lang" settings; shoot "$TMP/$lang-settings.html" "$OUT/$lang/settings.png" 720 700
done

# Open Graph card 1200×630
cat > "$TMP/og.html" <<EOF
<!DOCTYPE html><html lang="en" data-theme="dark"><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@500;700;800&display=swap" rel="stylesheet">
<link rel="stylesheet" href="file://$DOCS/resources/site.css">
<style>
body{margin:0;width:1200px;height:630px;overflow:hidden;display:grid;grid-template-columns:330px 1fr;align-items:center;gap:56px;padding:0 90px;
background:radial-gradient(700px 420px at 85% 10%,rgba(63,182,201,.35),transparent 70%),radial-gradient(600px 380px at 10% 100%,rgba(243,205,116,.22),transparent 70%),linear-gradient(160deg,#0d3a4a,#061820 70%)}
img{width:330px;height:330px;filter:drop-shadow(0 30px 50px rgba(0,0,0,.5))}
h1{margin:0 0 18px;font:800 76px/1 var(--font);letter-spacing:-.035em;color:#e6f0f4}
h1 span{background:linear-gradient(100deg,#ffe7a8,#f3cd74 45%,#3fb6c9);-webkit-background-clip:text;background-clip:text;color:transparent}
p{margin:0 0 28px;font:500 26px/1.35 var(--font);color:#9fb8c3}
.r{display:flex;gap:22px;font:700 22px var(--font);color:#e6f0f4}.r span{display:flex;gap:10px;align-items:center}
.r .badge{width:34px;height:34px;border-radius:9px;font-size:13px}
</style></head><body>
<img src="file://$DOCS/resources/icon-512.png" alt="">
<div><h1>StoneVPN<br><span>Manager</span></h1><p>One menu bar for every VPN on macOS —<br>plus the DNS &amp; routing fixes they never do.</p>
<div class="r"><span><b class="badge b-wg">WG</b>WireGuard</span><span><b class="badge b-ov">OV</b>OpenVPN</span><span><b class="badge b-dg">DG</b>Defguard</span><span><b class="badge b-cs">CS</b>Cisco</span></div></div>
</body></html>
EOF
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files --user-data-dir="$TMP/profile" \
  --window-size=1200,630 --virtual-time-budget=2000 --screenshot="$DOCS/resources/og-image.png" "file://$TMP/og.html" >/dev/null 2>&1
echo "  $DOCS/resources/og-image.png"
