"""App Store product page header for Plume (3840x1646), in the style of the
screenshots: the icon and the promise on the left, the iPhone and the Mac on
the right, rendered by headless Brave or Chrome (BROWSER overrides the path).

  python3 -I scripts/app-store-header.py build/screenshots/raw fastlane/header

<raw-dir>/<locale>/ holds the snapshot captures and the Mac captures.
"""
import base64, html, os, subprocess, sys, tempfile
from pathlib import Path

BRAVE = os.environ.get("BROWSER", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
W, H = 3840, 1646
ICON = Path(__file__).resolve().parent.parent / "App/Assets.xcassets/AppIcon.appiconset/ios.png"

TEXTS = {
    "en-US": ("For your Nextcloud", "All your files,\n*instantly*", "On iPhone, iPad and Mac · open source · nothing collected"),
    "fr-FR": ("Pour votre Nextcloud", "Tous vos fichiers,\n*tout de suite*", "Sur iPhone, iPad et Mac · open source · rien n'est collecté"),
}

PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
*{{margin:0;padding:0;box-sizing:border-box}}
html,body{{width:{W}px;height:{H}px;overflow:hidden}}
body{{background:linear-gradient(120deg,#2B5FD9 0%,#38B6F0 100%);font-family:-apple-system,"SF Pro Display",system-ui,sans-serif;color:#fff;position:relative}}
.glow{{position:absolute;right:-10%;bottom:-40%;width:80%;height:120%;background:radial-gradient(ellipse at center,rgba(255,255,255,.25),transparent 65%)}}
.left{{position:absolute;left:220px;top:50%;transform:translateY(-50%);width:1500px}}
.icon{{width:220px;height:220px;border-radius:50px;box-shadow:0 30px 60px rgba(0,0,0,.25);margin-bottom:56px}}
.kicker{{display:inline-block;font-size:48px;font-weight:600;padding:14px 36px;border-radius:999px;background:rgba(255,255,255,.18);margin-bottom:44px}}
h1{{font-size:170px;line-height:1.02;font-weight:800;letter-spacing:-4px}}
h1 em{{font-style:normal;background:#fff;color:#2B5FD9;padding:0 22px;border-radius:28px;-webkit-box-decoration-break:clone;box-decoration-break:clone}}
.sub{{margin-top:48px;font-size:54px;font-weight:500;opacity:.9}}
.mac{{position:absolute;right:640px;top:250px;width:1560px;border-radius:26px;overflow:hidden;box-shadow:0 60px 120px rgba(0,0,0,.35),0 0 0 4px rgba(255,255,255,.2);background:#fff}}
.mac img{{width:100%;display:block}}
.phone{{position:absolute;right:180px;top:300px;width:560px;height:{ph}px;border-radius:84px;background:#0B0B0F;padding:16px;box-shadow:0 60px 120px rgba(0,0,0,.4),0 0 0 4px rgba(255,255,255,.2)}}
.phone img{{width:100%;height:100%;border-radius:70px;display:block;object-fit:cover;object-position:top}}
</style></head><body><div class="glow"></div>
<div class="mac"><img src="data:image/png;base64,{mac}"></div>
<div class="phone"><img src="data:image/png;base64,{phone}"></div>
<div class="left"><img class="icon" src="data:image/png;base64,{icon}"><br><div class="kicker">{kicker}</div><h1>{headline}</h1><div class="sub">{sub}</div></div>
</body></html>"""


def b64(path):
    return base64.b64encode(Path(path).read_bytes()).decode()


def headline_html(text):
    parts = html.escape(text).split("*")
    return "".join(f"<em>{p}</em>" if i % 2 else p for i, p in enumerate(parts)).replace("\n", "<br>")


def main():
    raw, out = Path(sys.argv[1]), Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    ph = round((560 - 32) * 2868 / 1320) + 32
    with tempfile.TemporaryDirectory() as tmp:
        for locale, (kicker, headline, sub) in TEXTS.items():
            phone = raw / locale / "iPhone 17 Pro Max-05-quick-look.png"
            mac = raw / locale / "Mac-01-browse.png"
            if not phone.exists() or not mac.exists():
                print(f"missing captures for {locale}")
                continue
            page = Path(tmp) / f"{locale}.html"
            page.write_text(PAGE.format(W=W, H=H, ph=ph, mac=b64(mac), phone=b64(phone), icon=b64(ICON),
                                        kicker=html.escape(kicker), headline=headline_html(headline),
                                        sub=html.escape(sub)))
            target = out / f"header-{locale}.png"
            subprocess.run([BRAVE, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                            "--force-device-scale-factor=1", f"--window-size={W},{H}",
                            f"--screenshot={target}", page.as_uri()], check=True, capture_output=True)
            print(target)


main()
