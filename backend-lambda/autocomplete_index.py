"""
Build the search-autocomplete index from TMDB.

Walks /discover/{movie,tv}?sort_by=popularity.desc, drops one-hit wonders by
vote_count threshold, and returns a compact tuple-encoded payload ready to be
written to S3 (or to disk for self-hosted deployments).

Imported by both backend-lambda/autocomplete_warmer.py (Lambda) and
scripts/build-autocomplete-index.py (CLI).
"""
from __future__ import annotations

import time

import httpx

TMDB_BASE_URL = "https://api.themoviedb.org/3"
RESULTS_PER_PAGE = 20
TMDB_MAX_PAGE = 500
DEFAULT_VOTE_COUNT_GTE = 50
DEFAULT_TARGET_SIZE = 5000


def _discover_page(
    client: httpx.Client,
    media_type: str,
    page: int,
    api_key: str,
    locale: str,
    vote_count_gte: int,
) -> list[dict]:
    """Fetch a single discover page from TMDB."""
    response = client.get(
        f"{TMDB_BASE_URL}/discover/{media_type}",
        params={
            "api_key": api_key,
            "language": locale,
            "sort_by": "popularity.desc",
            "include_adult": "false",
            "vote_count.gte": vote_count_gte,
            "page": page,
        },
    )
    response.raise_for_status()
    return response.json().get("results", [])


def _normalize(item: dict, media_type: str) -> list | None:
    """
    Convert a TMDB discover item into the compact tuple form:
        [tmdb_id, title, year, media_type_code, poster_path]

    media_type_code is "m" for movie, "t" for tv. Returns None if the item is
    missing a usable title or id.
    """
    tmdb_id = item.get("id")
    if not tmdb_id:
        return None

    if media_type == "tv":
        title = item.get("name") or item.get("original_name")
        date_str = item.get("first_air_date") or ""
        code = "t"
    else:
        title = item.get("title") or item.get("original_title")
        date_str = item.get("release_date") or ""
        code = "m"

    if not title:
        return None

    year = int(date_str[:4]) if len(date_str) >= 4 and date_str[:4].isdigit() else None
    poster_path = item.get("poster_path")

    return [tmdb_id, title, year, code, poster_path]


def _collect(
    client: httpx.Client,
    media_type: str,
    api_key: str,
    locale: str,
    target_size: int,
    vote_count_gte: int,
) -> list[list]:
    """Fetch enough discover pages to reach target_size items for one media type."""
    items: list[list] = []
    seen: set[int] = set()
    pages_needed = min(TMDB_MAX_PAGE, (target_size // RESULTS_PER_PAGE) + 5)

    for page in range(1, pages_needed + 1):
        try:
            results = _discover_page(
                client, media_type, page, api_key, locale, vote_count_gte
            )
        except httpx.HTTPStatusError as e:
            # TMDB returns 422 when paging past available results; stop cleanly.
            if e.response.status_code == 422:
                break
            raise

        if not results:
            break

        for raw in results:
            tmdb_id = raw.get("id")
            if not tmdb_id or tmdb_id in seen:
                continue
            normalized = _normalize(raw, media_type)
            if normalized is None:
                continue
            seen.add(tmdb_id)
            items.append(normalized)
            if len(items) >= target_size:
                return items

        # Light politeness delay - TMDB is generous but no need to hammer it.
        time.sleep(0.05)

    return items


def build_index(
    api_key: str,
    locale: str = "en",
    target_size: int = DEFAULT_TARGET_SIZE,
    vote_count_gte: int = DEFAULT_VOTE_COUNT_GTE,
) -> dict:
    """
    Build the autocomplete index for one locale.

    Returns a dict shaped like:
        {"items": [[tmdb_id, title, year, media_type, poster_path], ...]}

    Movies and TV are interleaved by popularity rank so the most popular items
    of either type appear first in the array.
    """
    with httpx.Client(timeout=30.0) as client:
        movies = _collect(
            client, "movie", api_key, locale, target_size, vote_count_gte
        )
        tv = _collect(
            client, "tv", api_key, locale, target_size, vote_count_gte
        )

    # Interleave so position in the array roughly tracks popularity rank
    # across both media types - useful as a tiebreaker for the client.
    interleaved: list[list] = []
    for i in range(max(len(movies), len(tv))):
        if i < len(movies):
            interleaved.append(movies[i])
        if i < len(tv):
            interleaved.append(tv[i])

    return {"items": interleaved}
