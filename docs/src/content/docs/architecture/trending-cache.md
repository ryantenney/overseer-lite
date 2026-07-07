---
title: Trending Cache
description: How Stellarr serves trending data through S3 and CloudFront with privacy-preserving client-side hydration.
---

Stellarr serves trending media data through a cache architecture that separates public data from private user status, keeping costs low and performance high.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│ EventBridge │────▶│ Cache Warmer│────▶│  S3 Bucket  │
│  (daily)    │     │   Lambda    │     │ (trending)  │
└─────────────┘     │  (128 MB)   │     └──────┬──────┘
                    └──────┬──────┘            │
                           │                   │
                    ┌──────▼──────┐     ┌──────▼──────┐
                    │  TMDB API   │     │ CloudFront  │
                    └─────────────┘     │  (1hr TTL)  │
                                        └──────┬──────┘
                                               │
                                        ┌──────▼──────┐
                                        │   Browser   │
                                        │  (hydrate   │
                                        │  with user  │
                                        │   status)   │
                                        └─────────────┘
```

## How It Works

### 1. Cache Warmer Lambda

A separate lightweight Lambda function (`cache_warmer.py`, 128 MB) runs on a daily schedule via EventBridge:

1. Reads the TMDB API key from Secrets Manager
2. Fetches trending movies and TV shows from TMDB's trending endpoints
3. Fetches upcoming releases from TMDB's `/movie/upcoming` and `/tv/on_the_air` endpoints (these are vote-agnostic, so soon-to-release titles surface even though they haven't accumulated popularity yet)
4. Fetches both feeds for multiple locales (en, es, fr, de, etc.)
5. Writes results as JSON files to the trending S3 bucket
6. Sets `Cache-Control: max-age=3600` (1 hour) on each file

### 2. S3 Storage

Discovery data is stored as static JSON files, one per feed / media type / locale:

```
s3://stellarr-trending-bucket/
├── trending-all-en.json
├── trending-movie-en.json
├── trending-tv-en.json
├── upcoming-all-en.json
├── upcoming-movie-en.json
├── upcoming-tv-en.json
├── trending-all-es.json
├── upcoming-all-es.json
└── ...
```

Each file contains an array of media objects with TMDB metadata (title, year, overview, poster path, IDs, etc.) but **no user-specific data**. Upcoming feeds are sorted soonest-first and require a real poster to filter out placeholder entries.

### 3. CloudFront Distribution

CloudFront serves discovery files from the S3 origin with dedicated cache behaviors:

- **Path patterns:** `/trending-*.json` and `/upcoming-*.json`
- **Origin:** S3 trending bucket (via Origin Access Control)
- **Cache TTL:** 1 hour (matches the `Cache-Control` header)
- **Compression:** Gzip/Brotli enabled

### 4. Client-Side Hydration

The frontend handles the privacy separation:

1. On login, fetches `/api/library-status` to get the user's request and library data
2. Caches this status in `localStorage`
3. When displaying trending results, merges the public trending data with the private user status
4. Shows "Requested", "In Library", or "Added" badges based on the merged data

## Privacy Separation

This architecture ensures a clean separation between public and private data:

| Data | Storage | Access |
|------|---------|--------|
| Trending media (title, poster, etc.) | S3 → CloudFront | Public, no auth required |
| User's requests | DynamoDB → Lambda | Authenticated API call |
| Library status | DynamoDB → Lambda | Authenticated API call |
| Merged view | Browser localStorage | Client-side only |

No Lambda invocation is needed to display trending data. User-specific status is fetched separately and merged in the browser.

## Cost Benefits

| Approach | Cost per 1,000 views |
|----------|---------------------|
| Lambda proxy to TMDB | ~$0.0002 (Lambda) + TMDB rate limits |
| S3 + CloudFront (current) | ~$0.000001 (S3 GET) |

The cache architecture reduces trending costs by roughly 200x compared to proxying every request through Lambda.

## Refresh Cycle

1. **EventBridge** triggers the cache warmer every 24 hours
2. **Cache warmer** fetches fresh data from TMDB and writes to S3
3. **CloudFront** cache expires every 1 hour, fetching the latest from S3
4. **Users** see data that's at most 1 hour stale (trending changes slowly)

After deployment, the cache warmer is invoked immediately to populate initial data:

```bash
aws lambda invoke \
  --function-name stellarr-prod-cache-warmer \
  /tmp/cache-warmer-output.json
```

## Configuration

The cache warmer Lambda has minimal configuration:

| Env Variable | Purpose |
|-------------|---------|
| `APP_SECRET_ARN` | Secrets Manager ARN (for TMDB API key) |
| `AWS_REGION_NAME` | AWS region |
| `TRENDING_S3_BUCKET` | Target S3 bucket name |

These are set automatically by Terraform.
