"""App Store screenshots for Plume, in the same style as Verrou's: one message per
screen, the app's real UI in a device frame, rendered by headless Brave or Chrome
(BROWSER overrides the path).

  fastlane snapshot
  python3 -I scripts/app-store-screenshots.py build/screenshots/raw fastlane/screenshots

<raw-dir>/<locale>/ holds the fastlane snapshot captures ("<device>-<NN-name>.png").
Writes <out-dir>/<locale>/ with, per slide: the 6.9" iPhone (1320x2868), the 6.3"
iPhone (1206x2622, resampled from the 6.9"), the 13" iPad (2064x2752) and, from
scripts/mac-store-captures.sh, the Mac (2880x1800).
"""
import base64, html, os, subprocess, sys, tempfile
from pathlib import Path

BRAVE = os.environ.get("BROWSER", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")

DEVICES = {
    "iPhone 17 Pro Max": {"size": (1320, 2868), "frame": 1060, "top": 830, "radius": 118, "inner": 98,
                          "pad": 22, "resample": {"iPhone 6.3": (1206, 2622)}},
    "iPad Pro 13-inch (M5)": {"size": (2064, 2752), "frame": 1640, "top": 760, "radius": 72, "inner": 50,
                              "pad": 26, "resample": {}},
    "Mac": {"size": (2880, 1800), "frame": 2200, "top": 640, "radius": 22, "inner": 22, "pad": 0,
            "window": True, "resample": {}},
}

SLIDES = [
    ("01-browse", ("#2B5FD9", "#38B6F0"), {
        "en-US": ("For your Nextcloud", "All your files,\n*instantly*", "Open source · nothing collected"),
        "fr-FR": ("Pour votre Nextcloud", "Tous vos fichiers,\n*tout de suite*", "Open source · rien n'est collecté"),
    }),
    ("02-search", ("#0E8F7E", "#1BB39A"), {
        "en-US": ("Instant search", "Find any file\nas you *type*", "The whole account, accents and case ignored"),
        "fr-FR": ("Recherche instantanée", "Tout retrouver\nen *tapant*", "Tout le compte, accents et majuscules compris"),
    }),
    ("03-files-app", ("#14161F", "#2A2F45"), {
        "en-US": ("Files and Finder", "Right in the\n*Files* app", "Next to iCloud Drive, with thumbnails"),
        "fr-FR": ("Fichiers et Finder", "Directement\ndans *Fichiers*", "À côté d'iCloud Drive, avec les vignettes"),
    }),
    ("04-offline", ("#1F9D55", "#33D17A"), {
        "en-US": ("Offline", "Keep folders\n*on hand*", "Always up to date, open without a connection"),
        "fr-FR": ("Hors ligne", "Vos dossiers\n*sous la main*", "Toujours à jour, ouverts sans connexion"),
    }),
    ("05-quick-look", ("#525CF2", "#7C83F7"), {
        "en-US": ("Quick Look", "Open anything,\n*fast*", "PDFs, photos, videos and Office documents"),
        "fr-FR": ("Coup d'œil", "Tout s'ouvre,\n*vite*", "PDF, photos, vidéos et documents Office"),
    }),
    ("06-save-from-any-app", ("#E8613C", "#F28A4B"), {
        "en-US": ("Share sheet", "Save from\n*any app*", "Uploads resume when the connection drops"),
        "fr-FR": ("Partage", "Enregistrez depuis\n*toutes vos apps*", "Les envois reprennent si la connexion coupe"),
    }),
    ("07-privacy", ("#2B3A55", "#41557A"), {
        "en-US": ("Private by design", "Your server,\n*nothing else*", "No account with us, no ads, no tracking"),
        "fr-FR": ("Confidentiel par nature", "Votre serveur,\n*rien d'autre*", "Aucun compte chez nous, aucune pub, aucun pistage"),
    }),
]

PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{width:{W}px;height:{H}px;overflow:hidden}}
body{{background:linear-gradient(160deg,{c1} 0%,{c2} 100%);font-family:-apple-system,"SF Pro Display",system-ui,sans-serif;color:#fff;position:relative}}
.glow{{position:absolute;inset:auto -20% -10% -20%;height:55%;background:radial-gradient(ellipse at center,rgba(255,255,255,.22),transparent 65%)}}
.top{{position:absolute;top:140px;left:0;right:0;text-align:center;padding:0 90px}}
.kicker{{display:inline-block;font-size:42px;font-weight:600;letter-spacing:.5px;padding:12px 32px;border-radius:999px;background:rgba(255,255,255,.16);margin-bottom:40px}}
.sub{{margin-top:40px;font-size:50px;line-height:1.25;font-weight:500;opacity:.88}}
h1{{font-size:{size}px;line-height:1.04;font-weight:800;letter-spacing:-3px}}
h1 em{{font-style:normal;background:#fff;color:{c1};padding:0 18px;border-radius:22px;-webkit-box-decoration-break:clone;box-decoration-break:clone}}
.device{{position:absolute;left:50%;top:{top}px;width:{fw}px;height:{fh}px;transform:translateX(-50%);border-radius:{radius}px;background:#0B0B0F;padding:{pad}px;box-shadow:0 60px 120px rgba(0,0,0,.35),0 0 0 4px rgba(255,255,255,.18)}}
.device img{{width:100%;height:100%;border-radius:{inner}px;display:block;object-fit:cover;object-position:top}}
</style></head><body><div class="glow"></div>
<div class="top"><div class="kicker">{kicker}</div><h1>{headline}</h1><div class="sub">{footer}</div></div>
<div class="device"><img src="data:image/png;base64,{img}"></div>
</body></html>"""


def headline_html(text):
    parts = html.escape(text).split("*")
    out = "".join(f"<em>{p}</em>" if i % 2 else p for i, p in enumerate(parts))
    return out.replace("\n", "<br>")


def render(page, target, width, height):
    subprocess.run([BRAVE, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=1", f"--window-size={width},{height}",
                    f"--screenshot={target}", page.as_uri()], check=True, capture_output=True)


def main():
    raw, out = Path(sys.argv[1]), Path(sys.argv[2])
    written = 0
    with tempfile.TemporaryDirectory() as tmp:
        for locale_dir in sorted(p for p in raw.iterdir() if p.is_dir()):
            locale = locale_dir.name
            target_dir = out / locale
            target_dir.mkdir(parents=True, exist_ok=True)
            for device, spec in DEVICES.items():
                W, H = spec["size"]
                fw = spec["frame"]
                fh = round((fw - 2 * spec["pad"]) * H / W) + 2 * spec["pad"]
                if spec.get("window"):
                    first = next(iter(locale_dir.glob(f"{device}-*.png")), None)
                    if first is None:
                        continue
                    cw, ch = map(int, subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(first)],
                                                     capture_output=True, text=True).stdout.split()[-3::2])
                    fh = round(fw * ch / cw)
                for n, (shot, (c1, c2), texts) in enumerate(SLIDES, 1):
                    capture = locale_dir / f"{device}-{shot}.png"
                    if not capture.exists() or locale not in texts:
                        print(f"missing {locale}/{capture.name}")
                        continue
                    kicker, headline, footer = texts[locale]
                    longest = max(len(line) for line in headline.replace("*", "").split("\n"))
                    size = 150 if longest <= 14 else 128 if longest <= 17 else 112
                    if spec.get("window"):
                        headline = headline.replace("\n", " ")
                        size = 120
                    page = Path(tmp) / f"{locale}-{n}.html"
                    page.write_text(PAGE.format(W=W, H=H, c1=c1, c2=c2, kicker=html.escape(kicker),
                                                headline=headline_html(headline), footer=html.escape(footer),
                                                img=base64.b64encode(capture.read_bytes()).decode(),
                                                fw=fw, fh=fh, top=spec["top"], radius=spec["radius"],
                                                inner=spec["inner"], pad=spec["pad"], size=size))
                    device_dir = out.parent / f"{out.name}-mac" / locale if spec.get("window") else target_dir
                    device_dir.mkdir(parents=True, exist_ok=True)
                    target = device_dir / f"{device}-{shot}.png"
                    render(page, target, W, H)
                    written += 1
                    for name, (w, h) in spec["resample"].items():
                        subprocess.run(["sips", "-z", str(h), str(w), str(target),
                                        "--out", str(target_dir / f"{name}-{shot}.png")],
                                       check=True, capture_output=True)
                        written += 1
    print(f"{written} screenshots in {out}")


main()
