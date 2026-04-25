<script>
	import { _ } from 'svelte-i18n';
	import { createEventDispatcher } from 'svelte';

	export let suggestions = [];
	export let activeIndex = -1;
	export let visible = false;

	const dispatch = createEventDispatcher();

	function getPosterUrl(path) {
		return path ? `https://image.tmdb.org/t/p/w92${path}` : null;
	}

	function handlePosterError(event) {
		event.target.style.display = 'none';
	}

	function pick(index) {
		dispatch('select', suggestions[index]);
	}
</script>

{#if visible && suggestions.length > 0}
	<ul class="suggestions" role="listbox">
		{#each suggestions as item, i (item.media_type + ':' + item.id)}
			<li
				role="option"
				aria-selected={i === activeIndex}
				class:active={i === activeIndex}
				on:mousedown|preventDefault={() => pick(i)}
				on:mouseenter={() => dispatch('hover', i)}
			>
				<div class="thumb">
					{#if getPosterUrl(item.poster_path)}
						<img
							src={getPosterUrl(item.poster_path)}
							alt=""
							loading="lazy"
							on:error={handlePosterError}
						/>
					{:else}
						<span class="thumb-placeholder">🎬</span>
					{/if}
				</div>
				<div class="meta">
					<span class="title">{item.title}</span>
					<span class="sub">
						{item.media_type === 'tv' ? $_('media.tv') : $_('media.movie')}{#if item.year} · {item.year}{/if}
					</span>
				</div>
			</li>
		{/each}
	</ul>
{/if}

<style>
	.suggestions {
		position: absolute;
		top: calc(100% + 0.25rem);
		left: 0;
		right: 0;
		margin: 0;
		padding: 0.25rem;
		list-style: none;
		background: var(--bg-secondary);
		border: 1px solid var(--border);
		border-radius: 0.75rem;
		box-shadow: 0 8px 24px rgba(0, 0, 0, 0.25);
		max-height: min(60vh, 28rem);
		overflow-y: auto;
		z-index: 20;
	}

	li {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		padding: 0.5rem 0.75rem;
		border-radius: 0.5rem;
		cursor: pointer;
		color: var(--text-primary);
	}

	li.active,
	li:hover {
		background: var(--bg-tertiary);
	}

	.thumb {
		flex: 0 0 auto;
		width: 36px;
		height: 54px;
		border-radius: 0.25rem;
		overflow: hidden;
		background: var(--bg-tertiary);
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.thumb img {
		width: 100%;
		height: 100%;
		object-fit: cover;
		display: block;
	}

	.thumb-placeholder {
		font-size: 1.25rem;
		opacity: 0.6;
	}

	.meta {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}

	.title {
		font-size: 0.95rem;
		font-weight: 500;
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.sub {
		font-size: 0.8rem;
		color: var(--text-secondary);
	}
</style>
