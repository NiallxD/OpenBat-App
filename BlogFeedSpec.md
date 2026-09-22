# Blog feed — what the app consumes

The contract between the website build and the app's field guide tab. The website
emits one file; the app fetches, caches and renders it. Nothing else about the
blog is app-visible.

This mirrors how the app already takes `SpeciesGuideData.json` and
`SpeciesPresenceData.json` from the field guide repo: same envelope fields, same
cache-then-refresh behaviour, same rule that a fetch failure leaves the last good
copy in place.

---

## Where it lives

    https://openbat.app/app/blog.json

A build output of the Eleventy site, deployed with it. The app treats a 404 as
"no posts" and shows nothing rather than an error — so the button can ship before
the feed does, and the feed can be withdrawn without breaking an installed app.

Served with an `ETag` or `Last-Modified`; the app sends a conditional request and
expects `304` when nothing changed.

---

## Which posts are in it

A post is included when its frontmatter says so, and only then:

```yaml
inApp: true
```

Same shape as the existing `featured` flag, and independent of it — a post can be
featured on the website without appearing in the app, and vice versa. A post with
`publish: false` is never included whatever `inApp` says.

Optional, for ordering:

```yaml
appPriority: 1     # lower runs first; posts without one follow, newest first
```

---

## The envelope

```json
{
  "schemaVersion": 1,
  "dataVersion": 7,
  "updatedAt": "2026-09-21T16:40:00Z",
  "categories": [
    { "id": "locations",    "label": "Locations" },
    { "id": "stories",      "label": "Stories" },
    { "id": "research",     "label": "Research" },
    { "id": "conservation", "label": "Conservation" },
    { "id": "history",      "label": "History" }
  ],
  "posts": [ ... ]
}
```

### `categories`

**In the order they should appear on the dial**, which is the order they are
written here — the app does not sort them. Species is not listed: it is the
app's own first position and is always present.

This exists so that adding a category is a website change. The app builds the
dial's detents from this array, so a sixth category appears on the dial of every
installed app on the next fetch, with no release. Hard-coding the list app-side
would mean the opposite.

| field | notes |
|---|---|
| `id` | Matches a post's `type` exactly. Lowercase, stable. |
| `label` | What the dial's readout shows. Title case, short — it is read on one line over a map. |

A category with no posts is still offered if it is listed here; the app shows
the position empty rather than silently dropping a detent, because a dial whose
positions come and go with content is a dial you cannot learn. Drop the entry
here when you want the position gone.

If `categories` is absent the app falls back to the distinct `type` values it
finds across the posts, alphabetically — workable, but the order is then not
yours.

`dataVersion` is informational. **The app does not use it to decide whether to
adopt a feed** — the server's copy always wins, and the app simply compares what
it fetched against what it cached. It was version-gated at first, and that broke
the moment the feed was republished with `dataVersion` reset from 2 to 1: every
app that had already fetched kept showing the old posts and refused the new ones,
with nothing a reader could do about it. A version going backwards is a normal
thing to happen while a site is being built, so nothing load-bearing hangs on it.

Bump it anyway if it is useful to you — it is carried through and shown in
diagnostics — but nothing breaks if it stalls, repeats or goes backwards.

---

## A post

```json
{
  "id": "the-models-openbat-uses",
  "title": "The Models OpenBat Uses",
  "excerpt": "OpenBat ships two published classifiers rather than one of its own...",
  "date": "2026-09-05",
  "updated": "2026-09-20",
  "author": "Niall Bell",
  "tags": ["auto-id", "classifier", "machine-learning"],
  "coverImage": "https://openbat.app/static/images/orange-sunset.webp",
  "url": "https://openbat.app/blog/the-models-openbat-uses/",
  "searchText": "OpenBat doesn\'t have \"an AI\". It does however include two...",
  "readingMinutes": 6,
  "html": "<p>OpenBat doesn\'t have ...</p>"
}
```

| field | required | notes |
|---|---|---|
| `id` | yes | The website slug. Stable — it is the app's cache key and its deep-link target. Renaming a post without keeping the slug reads as a delete plus an add. |
| `title` | yes | |
| `excerpt` | yes | Falls back to `description` if a post sets no excerpt. Two sentences; this is the card text. |
| `date` | yes | `YYYY-MM-DD`. Publication date. |
| `updated` | no | Omit if never edited. |
| `author` | no | Defaults to Niall Bell app-side if absent. |
| `tags` | yes | Possibly empty. Lowercase, as written. |
| `coverImage` | no | **Absolute URL.** Omit rather than pointing at a missing file. |
| `url` | yes | The canonical website page, for "open in Safari" and for sharing. |
| `searchText` | yes | Title, excerpt and body as plain text, HTML stripped, entities decoded, whitespace collapsed. See below. |
| `readingMinutes` | no | Whole minutes. Nice to have, not load-bearing. |
| `type` | yes | The category this post belongs to — one of the `id`s above. A post whose `type` matches no listed category is still readable from the Blog button, but appears on no dial position. |
| `location` | no | `{ "latitude": 42.65, "longitude": -73.75, "name": "Albany, New York" }`. Where the post's story happened, for its pin on the globe. Omit for a post that is not about a place — see below. |
| `html` | yes | The rendered body. See below. |

### Posts without a location

A post with no `location` is not pinned, and that is expected rather than a gap
to fill: a post about how a classifier works does not happen anywhere, and
inventing a coordinate for it would put a false claim on a map. Those posts stay
reachable from the Blog button and through search; they simply do not appear on
the globe.

What this does mean is that a category where most posts are placeless will look
thin on the dial. If a whole category is placeless, it probably wants to be
reached from the blog list rather than given a position.

---

## `html` — what the app will render

A **fragment**, not a document: no `<html>`, `<head>`, `<body>`, and none of the
site's header, nav, footer or post chrome. Start at the first paragraph of the
post body.

It is rendered in a web view with the app\'s own stylesheet — app fonts, app
colours, app dark mode. So:

- **No `<script>`, no inline event handlers, no `<style>`.** The app refuses to
  load remote resources other than images, and a stylesheet in the fragment would
  fight the app\'s own.
- **No `class` attributes the app does not know about.** The ones the app will
  style are listed below; anything else is ignored and renders as plain prose,
  which is a degradation rather than a break.
- **Images: absolute URLs, always.** Relative paths have no base in the app.
  Include `width` and `height` so the layout does not jump while they load.
- **Headings start at `<h2>`.** The app draws the title itself as `<h1>`.

### Classes the app styles

| element | produced by |
|---|---|
| `<blockquote class="callout callout-note">` and `-tip`, `-warning` | Obsidian callouts. Keep the `[!note]` title line as a `<strong>` first child, or omit it and the app labels it from the class. |
| `<details><summary>` | The sources block. Rendered collapsed. |
| `<figure class="chart">` | Data figures — see the decision below. |
| `<table>` | Plain tables, including chart fallbacks. |
| `<pre>`, `<code>` | Rare, but present. |

### Links

Three kinds, and the app needs to tell them apart from the href alone:

- **A wikilink to another post that is also `inApp: true`** →
  `<a href="openbat://post/{id}">`. The app pushes that post; no network, no
  Safari.
- **A wikilink to a post that is not in the feed, or to any other page on the
  site** → the absolute `https://openbat.app/...` URL. The app opens it in
  Safari after a confirmation.
- **Any external link** → absolute URL, opened in Safari.

This is the piece that cannot be worked out app-side: only the build knows which
posts are in the feed.

---

## `searchText`

The field guide\'s search box searches posts as well as species, so this needs to
be plain text with no markup at all — tags stripped, entities decoded (`&amp;` →
`&`), whitespace collapsed to single spaces.

Include the title and excerpt at the front, then the body. Exclude the contents
of the sources block: a post should not match because of a URL in its citations.

---

## Two decisions I would like your call on

**1. Charts.** They currently emit a Chart.js `<canvas>` plus a `<noscript>`
table. The app will not run JavaScript, so the simplest thing is for the app feed
to emit **the table alone, visibly** — same numbers, no canvas, no bundled
charting library, works offline. The alternative is bundling Chart.js in the app
so figures are drawn; that is real work and a permanent dependency for seven
figures. My recommendation is the table.

**2. Body images.** Cover images are small and worth caching. Body images vary.
Cheapest first version is to cache cover images and load body images on demand,
which means a post read offline has its text and its cover but gaps where the
photographs were. The alternative is caching everything a post references the
first time it is opened.

---

## What the app does with it

Fetches on first open of the blog tab and at most once a day after that, honours
Low Data Mode, and falls back to the cached copy on any failure. A post already
cached stays readable with no network. Search covers cached posts only.
