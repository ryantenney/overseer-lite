// Search autocomplete: lazily fetches the prebuilt popularity-ranked index,
// caches it in IndexedDB, and runs fuzzy matching with Fuse.js entirely in
// the browser. The index covers the long tail of likely queries; pressing
// Enter falls through to the existing /api/search endpoint for anything not
// in the index.

import Fuse from 'fuse.js';
import { getAutocompleteIndex } from './api.js';

const DB_NAME = 'stellarr-autocomplete';
const STORE_NAME = 'index';
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days; matches the warmer cadence
const FUSE_OPTIONS = {
	keys: ['title'],
	threshold: 0.3,
	ignoreLocation: true,
	includeScore: true,
	minMatchCharLength: 2
};

// In-memory cache of the loaded Fuse instance, keyed by locale.
const memoryCache = new Map();
const inflight = new Map();

function openDb() {
	return new Promise((resolve, reject) => {
		const req = indexedDB.open(DB_NAME, 1);
		req.onupgradeneeded = () => {
			const db = req.result;
			if (!db.objectStoreNames.contains(STORE_NAME)) {
				db.createObjectStore(STORE_NAME);
			}
		};
		req.onsuccess = () => resolve(req.result);
		req.onerror = () => reject(req.error);
	});
}

async function readCache(locale) {
	try {
		const db = await openDb();
		return await new Promise((resolve, reject) => {
			const tx = db.transaction(STORE_NAME, 'readonly');
			const req = tx.objectStore(STORE_NAME).get(locale);
			req.onsuccess = () => resolve(req.result || null);
			req.onerror = () => reject(req.error);
		});
	} catch {
		return null;
	}
}

async function writeCache(locale, items) {
	try {
		const db = await openDb();
		await new Promise((resolve, reject) => {
			const tx = db.transaction(STORE_NAME, 'readwrite');
			tx.objectStore(STORE_NAME).put({ items, fetchedAt: Date.now() }, locale);
			tx.oncomplete = () => resolve();
			tx.onerror = () => reject(tx.error);
		});
	} catch {
		// Best-effort cache; ignore failures (private mode, quota, etc.).
	}
}

// Convert tuple-encoded items from the JSON payload into objects Fuse can index.
// Tuple shape: [tmdb_id, title, year, media_type_code, poster_path]
function hydrate(rawItems) {
	const out = new Array(rawItems.length);
	for (let i = 0; i < rawItems.length; i++) {
		const [id, title, year, code, posterPath] = rawItems[i];
		out[i] = {
			id,
			title,
			year,
			media_type: code === 't' ? 'tv' : 'movie',
			poster_path: posterPath,
			rank: i
		};
	}
	return out;
}

function buildFuse(items) {
	return new Fuse(items, FUSE_OPTIONS);
}

async function loadFromNetwork(locale) {
	const payload = await getAutocompleteIndex(locale);
	const items = hydrate(payload.items || []);
	writeCache(locale, payload.items || []); // store the raw tuples to keep IDB small
	return items;
}

// Load the index for a given locale and return a ready-to-search Fuse instance.
// Uses memory cache first, then IndexedDB (if fresh), then network. Concurrent
// callers share a single inflight fetch.
export async function loadIndex(locale = 'en') {
	if (memoryCache.has(locale)) return memoryCache.get(locale);
	if (inflight.has(locale)) return inflight.get(locale);

	const promise = (async () => {
		const cached = await readCache(locale);
		if (cached && Date.now() - cached.fetchedAt < CACHE_TTL_MS) {
			const items = hydrate(cached.items);
			const fuse = buildFuse(items);
			memoryCache.set(locale, fuse);
			return fuse;
		}

		try {
			const items = await loadFromNetwork(locale);
			const fuse = buildFuse(items);
			memoryCache.set(locale, fuse);
			return fuse;
		} catch (err) {
			// Network failed but we have a stale cache - use it rather than nothing.
			if (cached) {
				const items = hydrate(cached.items);
				const fuse = buildFuse(items);
				memoryCache.set(locale, fuse);
				return fuse;
			}
			throw err;
		}
	})();

	inflight.set(locale, promise);
	try {
		return await promise;
	} finally {
		inflight.delete(locale);
	}
}

// Run a fuzzy search against the in-memory index. Returns up to `limit`
// hydrated items, ordered by Fuse score (lower is better) with popularity
// rank as a tiebreaker.
export function searchIndex(fuse, query, { limit = 8, mediaType = null } = {}) {
	if (!fuse || !query || query.trim().length < 2) return [];

	const matches = fuse.search(query.trim(), { limit: limit * 3 });
	const filtered = mediaType
		? matches.filter((m) => m.item.media_type === mediaType)
		: matches;

	filtered.sort((a, b) => {
		if (a.score !== b.score) return a.score - b.score;
		return a.item.rank - b.item.rank;
	});

	return filtered.slice(0, limit).map((m) => m.item);
}
