// Shared by every page (site/build.py); the home page gives the search
// demo's files and queries in <script type="application/json" id="search-demo-data">.

// The language menu remembers the reader's choice (the English page's
// <head> sends French browsers to their version until they pick one).
for (const link of document.querySelectorAll("a[hreflang]")) {
  link.addEventListener("click", () => {
    try { localStorage.setItem("lang", link.hreflang); } catch {}
  });
}

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Search as you type, the way Plume does it: every file of the account,
// ignoring case and accents ("resume" finds "Résumé").
const demo = document.getElementById("search-demo");
const data = document.getElementById("search-demo-data");
if (demo && data) {
  const { files, queries } = JSON.parse(data.textContent);
  const query = demo.querySelector(".query");
  const list = demo.querySelector("ul");
  const fold = (text) => [...text].map((char) => char.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase());
  const escape = (text) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const render = (typed) => {
    const needle = fold(typed).join("");
    list.innerHTML = files
      .map((file) => {
        // Folding keeps one character per character here, so the match's
        // position in the folded name is its position in the name.
        const chars = [...file.name];
        const at = needle ? fold(file.name).join("").indexOf(needle) : 0;
        if (at < 0) return "";
        const name = needle
          ? escape(chars.slice(0, at).join("")) + "<mark>" + escape(chars.slice(at, at + needle.length).join(""))
            + "</mark>" + escape(chars.slice(at + needle.length).join(""))
          : escape(file.name);
        return `<li><span class="kind" aria-hidden="true">${file.kind}</span><span><span class="name">${name}</span><br><span class="where">${escape(file.where)}</span></span></li>`;
      })
      .filter(Boolean)
      .slice(0, 4)
      .join("");
    query.textContent = typed;
  };
  if (reduced) {
    render(queries[0]);
  } else {
    let q = 0;
    const type = (n) => {
      const word = queries[q];
      render(word.slice(0, n));
      if (n < word.length) setTimeout(() => type(n + 1), 140);
      else setTimeout(() => { q = (q + 1) % queries.length; type(0); }, 2200);
    };
    type(0);
  }
}

// Sections rise into view.
const observer = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add("in");
    observer.unobserve(entry.target);
  }
}, { threshold: 0.2 });
document.querySelectorAll(".reveal").forEach((el) => observer.observe(el));

const tilt = document.querySelector(".stage .tilt");
if (tilt && !reduced) {
  const update = () => tilt.style.setProperty("--tilt", Math.max(0, 1 - scrollY / 420).toFixed(3));
  addEventListener("scroll", update, { passive: true });
  update();
}

for (const video of document.querySelectorAll("video[data-play]")) {
  if (reduced) continue;
  new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) video.play().catch(() => {});
    else video.pause();
  }, { threshold: 0.3 }).observe(video);
}
