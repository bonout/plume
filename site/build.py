#!/usr/bin/env python3
"""Builds plume.bonout.com into a folder: every page in English and French.

    python3 site/build.py _site            # no release yet
    python3 site/build.py _site 0.1.0      # with the latest release

Each page of site/pages/<lang>/ starts with a comment holding its metadata
(JSON: title, description, optional "schema": "app" or "faq", optional
"preload": the picture shown first, fetched early); the layout
(site/layout.html) wraps it with the navigation, the alternate languages,
the structured data, the footer and the styles (inlined: nothing blocks the
first paint). Next to the pages: sitemap.xml, robots.txt (search engines and
AI crawlers welcome), llms.txt and llms-full.txt (llmstxt.org: what an AI
assistant should know about Plume).

The version is optional while there is no release: then the download links
point to building from source, and the parts of a page between
<!--release--> and <!--/release--> are dropped, while those between
<!--source--> and <!--/source--> are kept (and the other way round once
there is a version). The pictures from docs/media and docs/screenshots are
copied by the Pages workflow.
"""
import html
import json
import re
import shutil
import sys
from datetime import date
from html.parser import HTMLParser
from pathlib import Path

SITE = "https://plume.bonout.com"
REPO = "https://github.com/bonout/plume"
LANGS = ("en", "fr")
# The language menu: each language under its own name.
LANG_NAMES = {"en": "English", "fr": "Français"}
OG_LOCALES = {"en": "en_US", "fr": "fr_FR"}

# Page: its file in pages/<lang>/, then its path in each language.
PAGES = [
    ("index", {"en": "/", "fr": "/fr/"}),
    ("nextcloud-iphone", {"en": "/nextcloud-iphone/", "fr": "/fr/client-nextcloud-iphone/"}),
    ("nextcloud-mac", {"en": "/nextcloud-mac/", "fr": "/fr/client-nextcloud-mac/"}),
    ("nextcloud-alternative-client", {"en": "/nextcloud-alternative-client/",
                                      "fr": "/fr/alternative-client-nextcloud/"}),
    ("faq", {"en": "/faq/", "fr": "/fr/faq/"}),
    ("privacy", {"en": "/privacy/", "fr": "/fr/confidentialite/"}),
    ("support", {"en": "/support/", "fr": "/fr/assistance/"}),
]
PATHS = {name: paths for name, paths in PAGES}

WORDS = {
    "en": {
        "mac": "Mac", "iphone": "iPhone &amp; iPad", "compare": "Compare",
        "faq": "FAQ", "language": "Language",
        "footer": "Open source, GPL-3.0-or-later. Not affiliated with Nextcloud GmbH.",
        "privacy": "Privacy", "support": "Support", "vs_official": "Plume vs the official apps",
        # The download button: a release, or building from source.
        "get_release": "Download", "get_source": "Get Plume",
    },
    "fr": {
        "mac": "Mac", "iphone": "iPhone et iPad", "compare": "Comparer",
        "faq": "FAQ", "language": "Langue",
        "footer": "Open source, GPL-3.0 ou ultérieure. Non affilié à Nextcloud GmbH.",
        "privacy": "Confidentialité", "support": "Assistance", "vs_official": "Plume ou les apps officielles",
        "get_release": "Télécharger", "get_source": "Obtenir Plume",
    },
}


def meta_and_body(path):
    text = path.read_text()
    match = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    if not match:
        sys.exit(f"{path}: the page must start with its metadata comment")
    return json.loads(match.group(1)), text[match.end():]


def with_version(text, version):
    """Keeps the <!--release--> parts with a version, the <!--source-->
    parts without one, and fills {{version}}."""
    keep, drop = ("release", "source") if version else ("source", "release")
    text = re.sub(rf"<!--{drop}-->.*?<!--/{drop}-->", "", text, flags=re.S)
    text = re.sub(rf"<!--/?{keep}-->", "", text)
    return text.replace("{{version}}", version)


def download_url(version):
    return f"{REPO}/releases/tag/v{version}" if version else f"{REPO}#build"


def app_schema(lang, version, description):
    schema = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "Plume",
        "description": description,
        "applicationCategory": "UtilitiesApplication",
        "operatingSystem": "iOS 18 or later, iPadOS 18 or later, macOS 15 or later",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "EUR"},
        "license": "https://www.gnu.org/licenses/gpl-3.0.html",
        "url": SITE + PATHS["index"][lang],
        "image": f"{SITE}/img/og-{lang}.png",
        "codeRepository": REPO,
        "inLanguage": lang,
        "publisher": {"@type": "Organization", "name": "Bonout"},
        "sameAs": [REPO],
    }
    if version:
        schema["softwareVersion"] = version
        schema["downloadUrl"] = download_url(version)
    return schema


def faq_schema(body):
    """FAQPage from the <h3> questions and the paragraphs under them."""
    entries = []
    for question, answer in re.findall(r"<h3>(.*?)</h3>(.*?)(?=<h3>|</section>)", body, re.S):
        entries.append({
            "@type": "Question",
            "name": text_of(question),
            "acceptedAnswer": {"@type": "Answer", "text": text_of(answer)},
        })
    if not entries:
        sys.exit("faq: no question found")
    return {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": entries}


class _Text(HTMLParser):
    """Visible text of a fragment, one block per line (for llms-full.txt)."""
    BLOCKS = {"p", "li", "h1", "h2", "h3", "pre", "tr", "div", "section", "br"}
    SKIP = {"script", "style", "svg"}

    def __init__(self):
        super().__init__()
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skip += 1
        elif tag in ("h1", "h2"):
            self.out.append("\n\n## " if tag == "h2" else "\n\n# ")
        elif tag == "h3":
            self.out.append("\n\n### ")
        elif tag == "li":
            self.out.append("\n- ")
        elif tag in ("td", "th"):
            self.out.append(" | ")
        elif tag in self.BLOCKS:
            self.out.append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self.skip -= 1
        elif tag in self.BLOCKS:
            self.out.append("\n")

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)


def text_of(fragment):
    parser = _Text()
    parser.feed(fragment)
    text = "".join(parser.out)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r" *\n *", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def build(out, version):
    root = Path(__file__).resolve().parent
    layout = (root / "layout.html").read_text()
    # Minimal minification: comments and indentation.
    css = re.sub(r"/\*.*?\*/", "", (root / "style.css").read_text(), flags=re.S)
    css = re.sub(r"\s*\n\s*", "\n", css).strip()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    # The IndexNow key (a public file by design: it proves the site is ours).
    for item in ("site.js", "CNAME", ".nojekyll", "img", *(path.name for path in root.glob("*.txt") if path.name != "llms.txt")):
        source = root / item
        if source.is_dir():
            shutil.copytree(source, out / item)
        elif source.exists():
            shutil.copy(source, out / item)

    full_text = []
    for name, paths in PAGES:
        for lang in LANGS:
            meta, body = meta_and_body(root / "pages" / lang / f"{name}.html")
            body = with_version(body, version)
            words = WORDS[lang]
            schema = None
            if meta.get("schema") == "app":
                schema = app_schema(lang, version, meta["description"])
            elif meta.get("schema") == "faq":
                schema = faq_schema(body)
            # Browsers in French landing on an English page get their
            # version, until their reader picks a language in the menu.
            redirect = ""
            if lang == "en":
                others = json.dumps({code: paths[code] for code in LANGS if code != "en"})
                redirect = ("<script>try{const p=((navigator.languages||[navigator.language])[0]||'')"
                            f".toLowerCase().slice(0,2),t={others}[p];"
                            "if(!localStorage.getItem('lang')&&t)location.replace(t+location.hash)}catch{}</script>")
            alternates = "\n".join(f'<link rel="alternate" hreflang="{code}" href="{SITE}{paths[code]}">'
                                   for code in LANGS)
            menu = "".join(f'<a href="{paths[code]}" hreflang="{code}" lang="{code}"'
                           + (' aria-current="page"' if code == lang else "") + f">{LANG_NAMES[code]}</a>"
                           for code in LANGS)
            values = {
                "lang": lang,
                "title": html.escape(meta["title"]),
                "description": html.escape(meta["description"]),
                "canonical": SITE + paths[lang],
                "alternate_en": SITE + paths["en"],
                "alternates": alternates,
                "og_image": f"{SITE}/img/og-{lang}.png",
                "og_locale": OG_LOCALES[lang],
                "schema": (f'<script type="application/ld+json">{json.dumps(schema, ensure_ascii=False)}</script>'
                           if schema else ""),
                "redirect": redirect,
                "css": css,
                "preload": (f'<link rel="preload" as="image" href="{meta["preload"].replace("{lang}", lang)}" fetchpriority="high">'
                            if "preload" in meta else ""),
                "home": PATHS["index"][lang],
                "mac": PATHS["nextcloud-mac"][lang],
                "iphone": PATHS["nextcloud-iphone"][lang],
                "compare": PATHS["nextcloud-alternative-client"][lang],
                "faq": PATHS["faq"][lang],
                "privacy": PATHS["privacy"][lang],
                "support": PATHS["support"][lang],
                "download": download_url(version),
                "w_download": words["get_release" if version else "get_source"],
                "lang_code": lang.upper(),
                "lang_menu": menu,
                "body": body,
                **{f"w_{key}": value for key, value in words.items()},
            }
            page = re.sub(r"\{\{(\w+)\}\}", lambda m: values[m.group(1)] if m.group(1) in values else m.group(0), layout)
            left = re.findall(r"\{\{\w+\}\}|<!--/?(?:release|source)-->", page)
            if left:
                sys.exit(f"{lang}/{name}: unfilled {sorted(set(left))}")
            target = out / paths[lang].lstrip("/") / "index.html"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(page)
            if lang == "en":
                full_text.append(f"Page: {SITE}{paths[lang]}\n\n{text_of(body)}")

    today = date.today().isoformat()
    urls = []
    for _, paths in PAGES:
        for lang in LANGS:
            links = "".join(f'<xhtml:link rel="alternate" hreflang="{other}" href="{SITE}{paths[other]}"/>'
                            for other in LANGS)
            links += f'<xhtml:link rel="alternate" hreflang="x-default" href="{SITE}{paths["en"]}"/>'
            urls.append(f"<url><loc>{SITE}{paths[lang]}</loc><lastmod>{today}</lastmod>{links}</url>")
    (out / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        + "\n".join(urls) + "\n</urlset>\n")

    # Search engines and AI assistants (their search and their answers) are
    # all welcome: the site only describes an open source app.
    agents = ["GPTBot", "OAI-SearchBot", "ChatGPT-User", "ClaudeBot", "Claude-SearchBot", "Claude-User",
              "PerplexityBot", "Perplexity-User", "Google-Extended", "Applebot-Extended", "CCBot", "*"]
    (out / "robots.txt").write_text(
        "".join(f"User-agent: {agent}\nAllow: /\n\n" for agent in agents) + f"Sitemap: {SITE}/sitemap.xml\n")

    llms = with_version((root / "llms.txt").read_text(), version)
    (out / "llms.txt").write_text(llms)
    (out / "llms-full.txt").write_text(llms.rstrip() + "\n\n---\n\n" + "\n\n---\n\n".join(full_text) + "\n")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and not re.fullmatch(r"\d+\.\d+\.\d+", sys.argv[2])):
        sys.exit("usage: build.py <output folder> [version x.y.z]")
    build(Path(sys.argv[1]), sys.argv[2] if len(sys.argv) == 3 else "")
