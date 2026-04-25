---
title: Search Autocomplete
description: How Stellarr provides instant search suggestions without proxying every keystroke to TMDB.
---

Stellarr's search bar offers autocomplete suggestions as the user types
without proxying every keystroke through TMDB. A pre-built popularity-ranked
index is shipped as a static JSON file via CloudFront and matched entirely in
the browser with [Fuse.js](https://www.fusejs.io/).

## Why a Pre-Built Index

Proxying TMDB on every keystroke would burn API quota and add network
latency. The autocomplete index covers the long tail of likely queries
(top ~10K movies + TV shows by popularity, English only at launch). Rare
queries still work — pressing Enter falls through to the existing
`/api/search` endpoint which proxies TMDB live.

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│ EventBridge │────▶│ Autocomplete     │────▶│  S3 Bucket  │
│  (weekly)   │     │ Warmer Lambda    │     │ (trending)  │
└─────────────┘     │   (128 MB)       │     └──────┬──────┘
                    └────────┬─────────┘            │
                             │                      │
                      ┌──────▼──────┐        ┌──────▼──────┐
                      │  TMDB API   │        │ CloudFront  │
                      │  /discover  │        │  (24h TTL)  │
                      └─────────────┘        └──────┬──────┘
                                                    │
                                             ┌──────▼──────┐
                                             │   Browser   │
                                             │  Fuse.js    │
                                             │  in-memory  │
                                             │  + IDB      │
                                             └─────────────┘
```

## Pipeline

### 1. Autocomplete Warmer Lambda

`backend-lambda/autocomplete_warmer.py` runs on a weekly EventBridge
schedule:

1. Reads the TMDB API key from Secrets Manager.
2. Walks `/discover/movie?sort_by=popularity.desc` and
   `/discover/tv?sort_by=popularity.desc` filtered by `vote_count.gte` (drop
   one-hit wonders).
3. Stops when each media type has ~5K items (~10K combined per locale).
4. Writes `autocomplete-en.json` to the trending S3 bucket (reused).

The shared fetch/normalize logic lives in
`backend-lambda/autocomplete_index.py` so the CLI can import it.

### 2. Index Format

Tuple-encoded for compactness (~30% smaller gzipped vs. object form):

```json
{
  "items": [
    [27205, "Inception", 2010, "m", "/poster.jpg"],
    [1399, "Game of Thrones", 2011, "t", "/poster.jpg"]
  ]
}
```

Fields per tuple: `[tmdb_id, title, year, media_type, poster_path]`.
`media_type` is `"m"` or `"t"` to save bytes.

When non-English locales are added, an `original_title` field is appended so
users searching "Inception" while in `es`/`fr`/`de` still match.

### 3. CloudFront Distribution

A dedicated cache behavior on the existing distribution:

- **Path pattern:** `/autocomplete-*.json`
- **Origin:** S3 trending bucket (via Origin Access Control)
- **Cache TTL:** 24 hours
- **Compression:** Gzip/Brotli enabled

### 4. Browser

`frontend/src/lib/autocomplete.js`:

1. On first focus of the search input, fetches
   `/autocomplete-<locale>.json`.
2. Caches the JSON in IndexedDB keyed by locale + ETag for warm reloads.
3. Constructs a `Fuse` instance with `{ keys: ['title'], threshold: 0.3 }`.
4. Each keystroke runs `fuse.search(query, { limit: 8 })` — no debounce
   needed since it's local.
5. Results render in a dropdown beneath the input with keyboard nav.
6. Pressing Enter (with no selection) still triggers the existing
   `/api/search` call so long-tail queries always work.

## Self-Hosted

For Docker users without the Lambda pipeline, `scripts/build-autocomplete-index.py`
runs the same logic locally and writes the JSON into `frontend/static/`,
which Caddy serves directly.

```bash
TMDB_API_KEY=... python scripts/build-autocomplete-index.py \
  --locale en \
  --out frontend/static/autocomplete-en.json
```

## Refresh Cycle

The index is refreshed **weekly** (not daily — popular movies and TV
shows don't churn fast enough to justify daily writes). CloudFront caches
each file for 24 hours.

## Configuration

| Env Variable | Purpose |
|--------------|---------|
| `APP_SECRET_ARN` | Secrets Manager ARN (for TMDB API key) |
| `AWS_REGION_NAME` | AWS region |
| `TRENDING_S3_BUCKET` | Target S3 bucket name (shared with trending cache) |
| `AUTOCOMPLETE_LOCALES` | Comma-separated locale codes (default: `en`) |
| `AUTOCOMPLETE_TARGET_SIZE` | Items per media type (default: `5000`) |

These are set automatically by Terraform.
