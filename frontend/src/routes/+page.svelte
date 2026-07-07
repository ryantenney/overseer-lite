<script>
	import { onMount, onDestroy } from 'svelte';
	import { _ } from 'svelte-i18n';
	import {
		authenticated,
		loading,
		addToast,
		setAuthenticated,
		librarySet,
		requestsMap,
		libraryStatus,
		updateLibraryStatus,
		addToRequestsOptimistic
	} from '$lib/stores.js';
	import { verifyPassword, search, getTrending, getUpcoming, addRequest, getLibraryStatus, warmup } from '$lib/api.js';
	import { lazyload } from '$lib/lazyload.js';

	let password = '';
	let userName = '';
	let searchQuery = '';
	let searchResults = [];
	let trendingResults = [];
	let mediaFilter = 'all';
	let discoveryMode = 'trending'; // 'trending' or 'upcoming'
	let searchTimeout = null;
	let trendingLoaded = false;

	// Pagination - target ~20-24 items per page
	let currentPage = 1;
	let gridContainer;
	let columnCount = 5;
	const targetItemsPerPage = 24;
	$: itemsPerPage = targetItemsPerPage;
	$: rowsPerPage = Math.ceil(targetItemsPerPage / columnCount);
	$: totalPages = Math.ceil(displayResults.length / itemsPerPage);
	$: paginatedResults = displayResults.slice(
		(currentPage - 1) * itemsPerPage,
		currentPage * itemsPerPage
	);

	// Infinite scroll for mobile
	let isMobile = false;
	let visibleCount = targetItemsPerPage;
	let loadMoreObserver;
	let loadMoreTrigger;

	$: infiniteResults = displayResults.slice(0, visibleCount);
	$: hasMore = visibleCount < displayResults.length;

	function checkMobile() {
		isMobile = window.innerWidth <= 768;
	}

	function loadMore() {
		if (hasMore) {
			visibleCount = Math.min(visibleCount + targetItemsPerPage, displayResults.length);
		}
	}

	function updateColumnCount() {
		if (!gridContainer) return;
		const containerWidth = gridContainer.offsetWidth;
		const gap = 24; // 1.5rem gap
		const minCardWidth = 180;
		columnCount = Math.max(1, Math.floor((containerWidth + gap) / (minCardWidth + gap)));
	}

	let resizeObserver;

	// Handle PWA returning to foreground - warm up Lambda
	function handleVisibilityChange() {
		if (document.visibilityState === 'visible' && $authenticated) {
			// Warm up Lambda in background (don't await)
			warmup();
		}
	}

	onMount(async () => {
		// Listen for PWA being brought to foreground
		document.addEventListener('visibilitychange', handleVisibilityChange);

		// Check if mobile and listen for resize
		checkMobile();
		window.addEventListener('resize', checkMobile);

		if ($authenticated) {
			// Load trending (uses cached key from localStorage if available)
			await loadTrending();
		}
	});

	// Set up IntersectionObserver for infinite scroll trigger
	$: if (loadMoreTrigger && isMobile && !loadMoreObserver) {
		loadMoreObserver = new IntersectionObserver(
			(entries) => {
				if (entries[0].isIntersecting && hasMore) {
					loadMore();
				}
			},
			{ rootMargin: '200px' }
		);
		loadMoreObserver.observe(loadMoreTrigger);
	}


	// Hydrate a single item with library/request status from stores
	function hydrateItem(item) {
		return {
			...item,
			requested: $requestsMap.has(`${item.media_type}:${item.id}`),
			in_library: $librarySet.has(`${item.media_type}:${item.id}`)
		};
	}

	// Reactive: compute hydrated results when source data or stores change
	// Explicitly reference $requestsMap and $librarySet to trigger re-hydration when they change
	$: hydratedTrending = (($requestsMap, $librarySet), trendingResults.map(hydrateItem));
	$: hydratedSearch = (($requestsMap, $librarySet), searchResults.map(hydrateItem));

	// Set up resize observer when grid container becomes available
	$: if (gridContainer && !resizeObserver) {
		updateColumnCount();
		resizeObserver = new ResizeObserver(() => {
			updateColumnCount();
		});
		resizeObserver.observe(gridContainer);
	}

	onDestroy(() => {
		document.removeEventListener('visibilitychange', handleVisibilityChange);
		window.removeEventListener('resize', checkMobile);
		if (resizeObserver) {
			resizeObserver.disconnect();
		}
		if (loadMoreObserver) {
			loadMoreObserver.disconnect();
		}
		if (searchTimeout) {
			clearTimeout(searchTimeout);
		}
	});

	async function handleLogin() {
		if (!userName.trim()) {
			addToast($_('auth.enterName'), 'error');
			return;
		}
		try {
			$loading = true;
			const response = await verifyPassword(password, userName.trim());
			setAuthenticated(response.token, response.name);
			addToast($_('auth.welcome', { values: { name: response.name } }), 'success');
			// Fetch library status (gets trending key), then load trending
			const statusData = await getLibraryStatus();
			updateLibraryStatus(statusData);
			await loadTrending();
		} catch (error) {
			addToast(error.message || $_('auth.invalidCredentials'), 'error');
		} finally {
			$loading = false;
		}
	}

	async function loadTrending() {
		try {
			const mediaType = mediaFilter === 'all' ? 'all' : mediaFilter;
			const fetchFeed = discoveryMode === 'upcoming' ? getUpcoming : getTrending;
			const data = await fetchFeed(mediaType);
			// Store raw results - hydration happens reactively
			trendingResults = data.results;
			if (data.results.length > 0) {
				trendingLoaded = true;
			}
		} catch (error) {
			console.error(`Failed to load ${discoveryMode}:`, error);
			// If the feed fails (e.g., not warmed yet), show empty
			trendingResults = [];
		}
	}

	function setDiscoveryMode(mode) {
		if (discoveryMode === mode) return;
		discoveryMode = mode;
		loadTrending();
	}

	async function handleSearch() {
		if (!searchQuery.trim()) {
			searchResults = [];
			return;
		}

		try {
			$loading = true;
			const filterType = mediaFilter === 'all' ? null : mediaFilter;
			const data = await search(searchQuery, filterType);
			// Store raw results - hydration happens reactively
			searchResults = data.results;
		} catch (error) {
			addToast($_('requests.failedToLoad'), 'error');
		} finally {
			$loading = false;
		}
	}

	function debounceSearch() {
		if (searchTimeout) {
			clearTimeout(searchTimeout);
		}
		searchTimeout = setTimeout(() => {
			searchTimeout = null;
			handleSearch();
		}, 500);
	}

	async function handleRequest(item) {
		try {
			// Optimistic update - add to store immediately
			addToRequestsOptimistic(item.id, item.media_type, item.title);

			// API call in background
			await addRequest(item.id, item.media_type);
			addToast($_('requests.addedToRequests', { values: { title: item.title } }), 'success');
		} catch (error) {
			// Revert on failure by refreshing from server
			await refreshLibraryStatus();
			addToast($_('requests.failedToAdd'), 'error');
		}
	}

	function getPosterUrl(path) {
		if (!path) return null;
		return `https://image.tmdb.org/t/p/w200${path}`;
	}

	function handlePosterError(event) {
		// Hide broken image, show placeholder
		event.target.style.display = 'none';
	}

	$: displayResults = searchQuery.trim() ? hydratedSearch : hydratedTrending;
	$: sectionTitle = searchQuery.trim()
		? $_('search.results')
		: discoveryMode === 'upcoming'
			? $_('search.upcoming')
			: $_('search.trending');

	// Reset page/scroll when search/filter changes
	$: if (searchQuery || mediaFilter) {
		currentPage = 1;
		visibleCount = targetItemsPerPage;
	}
</script>

{#if !$authenticated}
	<div class="login-container">
		<div class="login-card">
			<h1>🎬 {$_('auth.title')}</h1>
			<p>{$_('auth.subtitle')}</p>
			<form on:submit|preventDefault={handleLogin}>
				<input
					type="text"
					bind:value={userName}
					placeholder={$_('auth.namePlaceholder')}
					autocomplete="name"
				/>
				<input
					type="password"
					bind:value={password}
					placeholder={$_('auth.passwordPlaceholder')}
					autocomplete="current-password"
				/>
				<button type="submit" disabled={$loading || !userName.trim()}>
					{$loading ? $_('auth.checking') : $_('auth.submit')}
				</button>
			</form>
		</div>
	</div>
{:else}
	<div class="search-container">
		<div class="search-box">
			<div class="search-input-wrapper">
				<input
					type="search"
					bind:value={searchQuery}
					on:input={debounceSearch}
					on:keydown={(e) => { if (e.key === 'Enter') e.target.blur(); }}
					enterkeyhint="search"
					placeholder={$_('search.placeholder')}
				/>
				{#if searchQuery}
					<button
						class="clear-btn"
						on:click={() => { searchQuery = ''; searchResults = []; }}
						aria-label={$_('search.clearSearch')}
					>×</button>
				{/if}
			</div>
			<div class="filter-buttons">
				<button
					class:active={mediaFilter === 'all'}
					on:click={() => { mediaFilter = 'all'; handleSearch(); loadTrending(); }}
				>
					{$_('filters.all')}
				</button>
				<button
					class:active={mediaFilter === 'movie'}
					on:click={() => { mediaFilter = 'movie'; handleSearch(); loadTrending(); }}
				>
					{$_('filters.movies')}
				</button>
				<button
					class:active={mediaFilter === 'tv'}
					on:click={() => { mediaFilter = 'tv'; handleSearch(); loadTrending(); }}
				>
					{$_('filters.tvShows')}
				</button>
			</div>
			{#if !searchQuery.trim()}
				<div class="filter-buttons discovery-toggle">
					<button
						class:active={discoveryMode === 'trending'}
						on:click={() => setDiscoveryMode('trending')}
					>
						{$_('search.trending')}
					</button>
					<button
						class:active={discoveryMode === 'upcoming'}
						on:click={() => setDiscoveryMode('upcoming')}
					>
						{$_('search.upcoming')}
					</button>
				</div>
			{/if}
		</div>
	</div>

	<section class="results-section">
		<h2>{sectionTitle}</h2>
		<div class="grid-wrapper" bind:this={gridContainer}>
		{#if $loading}
			<div class="loading">{$_('search.loading')}</div>
		{:else if displayResults.length === 0}
			<p class="no-results">{$_('search.noResults')}</p>
		{:else}
			<div class="media-grid">
				{#each (isMobile ? infiniteResults : paginatedResults) as item (item.id + item.media_type)}
					<div class="media-card">
						<div class="poster">
							<div class="poster-placeholder">
								<span class="placeholder-icon">🎬</span>
							</div>
							{#if getPosterUrl(item.poster_path)}
								<img
									use:lazyload={getPosterUrl(item.poster_path)}
									alt={item.title}
									on:error={handlePosterError}
								/>
							{/if}
							<div class="media-type-badge">{item.media_type === 'tv' ? $_('media.tv') : $_('media.movie')}</div>
							{#if item.vote_average}
								<div class="rating-badge">{item.vote_average.toFixed(1)}</div>
							{/if}
							{#if item.in_library}
								{#if item.media_type === 'movie' && item.imdb_id}
									<a href="https://www.imdb.com/title/{item.imdb_id}" target="_blank" rel="noopener" class="library-badge" title={$_('media.viewInImdb')}>{$_('media.inLibrary')}</a>
								{:else if item.media_type === 'tv' && item.tvdb_id}
									<a href="https://thetvdb.com/series/{item.tvdb_id}" target="_blank" rel="noopener" class="library-badge" title={$_('media.viewInTvdb')}>{$_('media.inLibrary')}</a>
								{:else}
									<div class="library-badge" title={$_('media.alreadyInPlex')}>{$_('media.inLibrary')}</div>
								{/if}
							{:else if item.number_of_seasons}
								{#if item.number_of_seasons > 10}
									<div class="seasons-warning seasons-very-large" title={$_('media.veryLargeSeriesWarning')}>
										{$_('media.seasons', { values: { count: item.number_of_seasons } })}
									</div>
								{:else if item.number_of_seasons > 6}
									<div class="seasons-warning" title={$_('media.largeSeriesWarning')}>
										{$_('media.seasons', { values: { count: item.number_of_seasons } })}
									</div>
								{/if}
							{/if}
						</div>
						<div class="info">
							<h3 title={item.title}>{item.title}</h3>
							<span class="year">{item.year || $_('media.unknown')}</span>
							<p class="overview">{item.overview || $_('media.noDescription')}</p>
							<button
								class="request-btn"
								class:requested={item.requested}
								class:in-library={item.in_library}
								on:click={() => handleRequest(item)}
								disabled={item.requested || item.in_library}
							>
								{#if item.in_library}
									{$_('media.inLibrary')}
								{:else if item.requested}
									✓ {$_('media.requested')}
								{:else}
									+ {$_('media.request')}
								{/if}
							</button>
						</div>
					</div>
				{/each}
			</div>

			{#if isMobile}
				<!-- Infinite scroll trigger -->
				<div bind:this={loadMoreTrigger} class="load-more-trigger">
					{#if hasMore}
						<div class="loading-more">{$_('loading.more')}</div>
					{/if}
				</div>
			{:else if totalPages > 1}
				<div class="pagination">
					<button
						disabled={currentPage === 1}
						on:click={() => currentPage--}
					>
						{$_('pagination.previous')}
					</button>
					<span>{$_('pagination.pageOf', { values: { current: currentPage, total: totalPages } })}</span>
					<button
						disabled={currentPage === totalPages}
						on:click={() => currentPage++}
					>
						{$_('pagination.next')}
					</button>
				</div>
			{/if}
		{/if}
		</div>
	</section>
{/if}

<style>
	.login-container {
		display: flex;
		justify-content: center;
		align-items: center;
		min-height: 60vh;
	}

	.login-card {
		background: var(--bg-secondary);
		padding: 3rem;
		border-radius: 1rem;
		text-align: center;
		max-width: 400px;
		width: 100%;
	}

	.login-card h1 {
		margin-bottom: 0.5rem;
	}

	.login-card p {
		color: var(--text-secondary);
		margin-bottom: 2rem;
	}

	.login-card form {
		display: flex;
		flex-direction: column;
		gap: 1rem;
	}

	.login-card input {
		padding: 1rem;
		border: 1px solid var(--border);
		border-radius: 0.5rem;
		background: var(--bg-tertiary);
		color: var(--text-primary);
		font-size: 1rem;
	}

	.login-card button {
		padding: 1rem;
		background: var(--accent);
		border: none;
		border-radius: 0.5rem;
		color: white;
		font-size: 1rem;
		cursor: pointer;
		transition: background 0.2s;
	}

	.login-card button:hover:not(:disabled),
	.login-card button:active:not(:disabled) {
		background: var(--accent-hover);
	}

	.login-card button:disabled {
		opacity: 0.6;
		cursor: not-allowed;
	}

	.search-container {
		margin-bottom: 2rem;
	}

	.search-box {
		display: flex;
		flex-direction: column;
		gap: 1rem;
	}

	.search-input-wrapper {
		position: relative;
		width: 100%;
	}

	.search-box input {
		padding: 1rem 2.5rem 1rem 1.5rem;
		border: 1px solid var(--border);
		border-radius: 0.75rem;
		background: var(--bg-secondary);
		color: var(--text-primary);
		font-size: 1.1rem;
		width: 100%;
	}

	.search-box input:focus {
		outline: none;
		border-color: var(--accent);
	}

	/* Hide native search clear button (we have our own) */
	.search-box input[type="search"]::-webkit-search-cancel-button {
		-webkit-appearance: none;
		appearance: none;
	}

	.clear-btn {
		position: absolute;
		right: 0.25rem;
		top: 50%;
		transform: translateY(-50%);
		background: transparent;
		border: none;
		color: var(--text-secondary);
		font-size: 1.25rem;
		cursor: pointer;
		min-width: 44px;
		min-height: 44px;
		line-height: 1;
		border-radius: 50%;
		transition: color 0.2s, background 0.2s;
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.clear-btn:hover,
	.clear-btn:active {
		color: var(--text-primary);
		background: var(--bg-tertiary);
	}

	.filter-buttons {
		display: flex;
		gap: 0.5rem;
	}

	.filter-buttons button {
		padding: 0.5rem 1rem;
		border: 1px solid var(--border);
		border-radius: 0.5rem;
		background: transparent;
		color: var(--text-secondary);
		cursor: pointer;
		transition: all 0.2s;
	}

	.filter-buttons button:hover,
	.filter-buttons button:active {
		border-color: var(--accent);
		color: var(--accent);
	}

	.filter-buttons button.active {
		background: var(--accent);
		border-color: var(--accent);
		color: white;
	}

	.results-section h2 {
		margin-bottom: 1.5rem;
		color: var(--text-primary);
	}

	.loading, .no-results {
		text-align: center;
		color: var(--text-secondary);
		padding: 3rem;
	}

	.media-grid {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
		gap: 1.5rem;
	}

	.media-card {
		background: var(--bg-secondary);
		border-radius: 0.75rem;
		overflow: hidden;
		transition: box-shadow 0.2s;
	}

	.media-card:hover {
		box-shadow: 0 0 0 2px var(--accent);
	}

	.poster {
		position: relative;
		aspect-ratio: 2/3;
	}

	.poster-placeholder {
		position: absolute;
		inset: 0;
		background: var(--bg-tertiary);
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.placeholder-icon {
		font-size: 3rem;
		opacity: 0.4;
	}

	.poster img {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.media-type-badge {
		position: absolute;
		top: 0.5rem;
		left: 0.5rem;
		background: var(--accent);
		padding: 0.25rem 0.5rem;
		border-radius: 0.25rem;
		font-size: 0.75rem;
		font-weight: 600;
	}

	.rating-badge {
		position: absolute;
		top: 0.5rem;
		right: 0.5rem;
		background: rgba(0, 0, 0, 0.8);
		padding: 0.25rem 0.5rem;
		border-radius: 0.25rem;
		font-size: 0.75rem;
		font-weight: 600;
		color: #ffd700;
	}

	.library-badge {
		position: absolute;
		bottom: 0.5rem;
		left: 0.5rem;
		background: rgba(76, 175, 80, 0.9);
		padding: 0.25rem 0.5rem;
		border-radius: 0.25rem;
		font-size: 0.7rem;
		font-weight: 600;
		color: white;
		text-decoration: none;
		display: inline-block;
		cursor: pointer;
		transition: background 0.2s;
	}

	.library-badge:hover {
		background: rgba(76, 175, 80, 1);
		text-decoration: underline;
	}

	.seasons-warning {
		position: absolute;
		bottom: 0.5rem;
		left: 0.5rem;
		background: rgba(245, 158, 11, 0.9);
		padding: 0.25rem 0.5rem;
		border-radius: 0.25rem;
		font-size: 0.7rem;
		font-weight: 600;
		color: white;
		cursor: help;
	}

	.seasons-warning.seasons-very-large {
		background: rgba(220, 38, 38, 0.9);
	}

	.info {
		padding: 1rem;
	}

	.info h3 {
		font-size: 0.95rem;
		margin-bottom: 0.25rem;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.year {
		color: var(--text-secondary);
		font-size: 0.85rem;
	}

	.overview {
		font-size: 0.8rem;
		color: var(--text-secondary);
		margin: 0.75rem 0;
		display: -webkit-box;
		-webkit-line-clamp: 3;
		-webkit-box-orient: vertical;
		overflow: hidden;
		line-height: 1.4;
	}

	.request-btn {
		width: 100%;
		padding: 0.6rem;
		border: none;
		border-radius: 0.5rem;
		background: var(--accent);
		color: white;
		font-size: 0.9rem;
		cursor: pointer;
		transition: all 0.2s;
	}

	.request-btn:hover:not(:disabled),
	.request-btn:active:not(:disabled) {
		background: var(--accent-hover);
	}

	.request-btn.requested {
		background: var(--bg-tertiary);
		color: var(--text-secondary);
		cursor: default;
	}

	.request-btn.in-library {
		background: var(--bg-tertiary);
		color: var(--text-secondary);
		cursor: default;
	}

	.request-btn:disabled {
		opacity: 0.8;
	}

	/* Pagination */
	.pagination {
		display: flex;
		justify-content: center;
		align-items: center;
		gap: 1rem;
		margin-top: 2rem;
		padding: 1rem;
	}

	.pagination button {
		padding: 0.5rem 1rem;
		border: 1px solid var(--border);
		border-radius: 0.5rem;
		background: transparent;
		color: var(--text-secondary);
		cursor: pointer;
		transition: all 0.2s;
	}

	.pagination button:hover:not(:disabled),
	.pagination button:active:not(:disabled) {
		border-color: var(--accent);
		color: var(--accent);
	}

	.pagination button:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.pagination span {
		color: var(--text-secondary);
	}

	/* Infinite scroll */
	.load-more-trigger {
		padding: 2rem;
		text-align: center;
	}

	.loading-more {
		color: var(--text-secondary);
	}

	@media (max-width: 768px) {
		.media-grid {
			grid-template-columns: repeat(auto-fill, minmax(140px, 1fr));
			gap: 1rem;
		}

		.pagination {
			display: none;
		}
	}
</style>
