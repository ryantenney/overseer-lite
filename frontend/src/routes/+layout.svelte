<script>
	import { onMount } from 'svelte';
	import { _, isLoading as i18nLoading, locale } from 'svelte-i18n';
	import { authenticated, logout, toasts, addToast, updateLibraryStatus, pushSubscribed, pushSupported, pushPermission, checkPushPermission, iosBrowserNeedsPwa } from '$lib/stores.js';
	import { preloadAuthParams, getFeedInfo, getLibraryStatus, getVapidPublicKey, subscribePush, unsubscribePush } from '$lib/api.js';
	import { initI18n, supportedLocales, setLocale } from '$lib/i18n.js';

	initI18n();

	const appName = import.meta.env.VITE_APP_NAME || 'Stellarr';
	let showLangDropdown = false;

	let showFeedModal = false;
	let showPwaModal = false;
	let showPushModal = false;
	let feedInfo = null;
	let loadingFeeds = false;
	let pushLoading = false;

	onMount(() => {
		if ($authenticated) {
			// If authenticated, fetch library status (also warms up Lambda)
			refreshLibraryStatus();
			registerServiceWorker();
			checkPushState();
		} else {
			// Preload auth params to warm up Lambda for login
			preloadAuthParams();
		}
	});

	// Register service worker for push notifications
	async function registerServiceWorker() {
		if (!$pushSupported) return;

		try {
			const registration = await navigator.serviceWorker.register('/sw.js');
			console.log('Service worker registered:', registration.scope);
		} catch (error) {
			console.error('Service worker registration failed:', error);
		}
	}

	// Check if this device has an active push subscription
	async function checkPushState() {
		if (!$pushSupported) return;

		try {
			// Check the browser's PushManager directly to see if THIS device is subscribed
			const registration = await navigator.serviceWorker.ready;
			const subscription = await registration.pushManager.getSubscription();
			pushSubscribed.set(subscription !== null);
		} catch (error) {
			console.error('Failed to check push status:', error);
			pushSubscribed.set(false);
		}
	}

	// Show push confirmation modal
	function openPushModal() {
		if (pushLoading) return;
		showPushModal = true;
	}

	// Confirm push action from modal
	async function confirmPushAction() {
		showPushModal = false;
		pushLoading = true;

		try {
			if ($pushSubscribed) {
				// Unsubscribe
				await unsubscribePush();
				pushSubscribed.set(false);
				addToast($_('pushModal.disabled'), 'info');
			} else {
				// Subscribe
				await enablePush();
			}
		} catch (error) {
			console.error('Push toggle failed:', error);
			addToast($_('pushModal.failed'), 'error');
		} finally {
			pushLoading = false;
		}
	}

	// Enable push notifications
	async function enablePush() {
		// Request permission if needed
		if (Notification.permission === 'default') {
			const permission = await Notification.requestPermission();
			checkPushPermission();
			if (permission !== 'granted') {
				addToast($_('pushModal.permissionDenied'), 'error');
				return;
			}
		} else if (Notification.permission === 'denied') {
			addToast($_('pushModal.blocked'), 'error');
			return;
		}

		// Get service worker registration
		const registration = await navigator.serviceWorker.ready;

		// Get VAPID public key from server
		const { public_key } = await getVapidPublicKey();

		// Convert base64 to Uint8Array
		const vapidKey = urlBase64ToUint8Array(public_key);

		// Subscribe to push
		const subscription = await registration.pushManager.subscribe({
			userVisibleOnly: true,
			applicationServerKey: vapidKey
		});

		// Get keys from subscription
		const keys = {
			p256dh: arrayBufferToBase64(subscription.getKey('p256dh')),
			auth: arrayBufferToBase64(subscription.getKey('auth'))
		};

		// Send to server
		await subscribePush({
			endpoint: subscription.endpoint,
			keys: keys
		});

		pushSubscribed.set(true);
		addToast($_('pushModal.enabled'), 'success');
	}

	// Helper: Convert URL-safe base64 to Uint8Array
	function urlBase64ToUint8Array(base64String) {
		const padding = '='.repeat((4 - base64String.length % 4) % 4);
		const base64 = (base64String + padding)
			.replace(/-/g, '+')
			.replace(/_/g, '/');
		const rawData = window.atob(base64);
		const outputArray = new Uint8Array(rawData.length);
		for (let i = 0; i < rawData.length; ++i) {
			outputArray[i] = rawData.charCodeAt(i);
		}
		return outputArray;
	}

	// Helper: Convert ArrayBuffer to base64
	function arrayBufferToBase64(buffer) {
		const bytes = new Uint8Array(buffer);
		let binary = '';
		for (let i = 0; i < bytes.byteLength; i++) {
			binary += String.fromCharCode(bytes[i]);
		}
		return window.btoa(binary)
			.replace(/\+/g, '-')
			.replace(/\//g, '_')
			.replace(/=+$/, '');
	}

	// Fetch library status and update store
	async function refreshLibraryStatus() {
		try {
			const data = await getLibraryStatus();
			updateLibraryStatus(data);
		} catch (error) {
			console.error('Failed to fetch library status:', error);
		}
	}

	async function openFeedModal() {
		showFeedModal = true;
		if (!feedInfo) {
			loadingFeeds = true;
			try {
				feedInfo = await getFeedInfo();
			} catch (error) {
				console.error('Failed to load feed info:', error);
			} finally {
				loadingFeeds = false;
			}
		}
	}

	function copyUrl(url) {
		navigator.clipboard.writeText(url);
		addToast($_('feedModal.copied'), 'success');
	}

	function handleLangSelect(code) {
		setLocale(code);
		showLangDropdown = false;
	}

	function closeLangDropdown(event) {
		if (!event.target.closest('.lang-dropdown-container')) {
			showLangDropdown = false;
		}
	}
</script>

<svelte:window on:click={closeLangDropdown} />

<svelte:head>
	<style>
		:root {
			--bg-primary: #0f0f0f;
			--bg-secondary: #1a1a1a;
			--bg-tertiary: #252525;
			--text-primary: #ffffff;
			--text-secondary: #a0a0a0;
			--accent: #7b2cbf;
			--accent-hover: #9d4edd;
			--success: #10b981;
			--error: #ef4444;
			--warning: #f59e0b;
			--border: #333;
		}

		* {
			box-sizing: border-box;
			margin: 0;
			padding: 0;
		}

		html {
			overscroll-behavior: none;
		}

		body {
			font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
			background-color: var(--bg-primary);
			color: var(--text-primary);
			min-height: 100vh;
			overscroll-behavior: none;
			/* Disable text selection on UI elements */
			-webkit-user-select: none;
			user-select: none;
			/* Disable tap highlight on mobile */
			-webkit-tap-highlight-color: transparent;
			/* Smooth scrolling */
			-webkit-overflow-scrolling: touch;
			/* Prevent pull-to-refresh */
			overflow-y: auto;
		}

		/* Allow text selection in content areas */
		p, h1, h2, h3, h4, h5, h6, .selectable {
			-webkit-user-select: text;
			user-select: text;
		}

		/* Disable callout on long-press (iOS) */
		a, button, img {
			-webkit-touch-callout: none;
		}

		/* Prevent image dragging */
		img {
			-webkit-user-drag: none;
			user-drag: none;
		}

		/* Fix for iOS input zoom - ensure inputs are 16px+ */
		input, textarea, select {
			font-size: 16px;
		}
	</style>
</svelte:head>

{#if $i18nLoading}
	<div class="app loading-i18n"></div>
{:else}
<div class="app">
	<header>
		<div class="header-content">
			<a href="/" class="logo">
				<svg class="logo-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
					<rect x="2" y="2" width="20" height="20" rx="2" />
					<path d="M7 2v20M17 2v20M2 12h20M2 7h5M2 17h5M17 7h5M17 17h5" />
				</svg>
				<span class="logo-text">{appName}</span>
			</a>
			{#if $authenticated}
				<nav>
					<a href="/" class="nav-link" title={$_('nav.search')}>
						<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
							<circle cx="11" cy="11" r="8" />
							<path d="M21 21l-4.35-4.35" />
						</svg>
						<span class="nav-text">{$_('nav.search')}</span>
					</a>
					<a href="/requests" class="nav-link" title={$_('nav.requests')}>
						<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
							<path d="M9 5H7a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2h-2" />
							<rect x="9" y="3" width="6" height="4" rx="1" />
							<path d="M9 12h6M9 16h6" />
						</svg>
						<span class="nav-text">{$_('nav.requests')}</span>
					</a>
					<button class="nav-btn feeds-btn" on:click={openFeedModal} title={$_('nav.feedUrls')}>
						<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
							<path d="M4 11a9 9 0 0 1 9 9" />
							<path d="M4 4a16 16 0 0 1 16 16" />
							<circle cx="5" cy="19" r="1" fill="currentColor" />
						</svg>
					</button>
					{#if $pushSupported}
						<button
							class="nav-btn"
							class:subscribed={$pushSubscribed}
							class:loading={pushLoading}
							on:click={openPushModal}
							title={$pushSubscribed ? $_('nav.disableNotifications') : $_('nav.enableNotifications')}
						>
							<svg class="nav-icon bell-icon" viewBox="0 0 24 24" fill={$pushSubscribed && !pushLoading ? 'currentColor' : 'none'} stroke="currentColor" stroke-width="2">
								<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
								<path d="M13.73 21a2 2 0 0 1-3.46 0" />
							</svg>
						</button>
					{:else if $iosBrowserNeedsPwa}
						<button
							class="nav-btn"
							on:click={() => showPwaModal = true}
							title={$_('nav.enableNotifications')}
						>
							<svg class="nav-icon bell-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
								<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
								<path d="M13.73 21a2 2 0 0 1-3.46 0" />
							</svg>
						</button>
					{/if}
					<!-- Language switcher -->
					<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
					<div class="lang-dropdown-container">
						<button
							class="nav-btn lang-btn"
							on:click={() => showLangDropdown = !showLangDropdown}
							title="Language"
						>
							<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
								<circle cx="12" cy="12" r="10" />
								<path d="M2 12h20M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
							</svg>
						</button>
						{#if showLangDropdown}
							<div class="lang-dropdown">
								{#each supportedLocales as lang}
									<button
										class="lang-option"
										class:active={$locale === lang.code}
										on:click={() => handleLangSelect(lang.code)}
									>
										{lang.name}
									</button>
								{/each}
							</div>
						{/if}
					</div>
					<button class="nav-btn logout-btn" on:click={logout} title={$_('nav.logout')}>
						<svg class="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
							<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
							<polyline points="16,17 21,12 16,7" />
							<line x1="21" y1="12" x2="9" y2="12" />
						</svg>
					</button>
				</nav>
			{/if}
		</div>
	</header>

	<main>
		<slot />
	</main>

	<!-- Toast notifications -->
	<div class="toast-container">
		{#each $toasts as toast (toast.id)}
			<div class="toast toast-{toast.type}">
				{toast.message}
			</div>
		{/each}
	</div>

	<!-- Feed URLs Modal -->
	{#if showFeedModal}
		<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
		<div class="modal-overlay" on:click={() => showFeedModal = false}>
			<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
			<div class="modal" on:click|stopPropagation>
				<div class="modal-header">
					<h2>{$_('feedModal.title')}</h2>
					<button class="close-btn" on:click={() => showFeedModal = false}>&times;</button>
				</div>
				<div class="modal-content">
					{#if loadingFeeds}
						<div class="loading">{$_('feedModal.loading')}</div>
					{:else if feedInfo}
						{#if feedInfo.token_required}
							<p class="token-notice">{$_('feedModal.tokenRequired')}</p>
						{/if}

						<div class="feed-section">
							<h3>{$_('feedModal.radarr')}</h3>
							<div class="feed-item">
								<div class="feed-info">
									<strong>{feedInfo.feeds.radarr.name}</strong>
									<p>{feedInfo.feeds.radarr.description}</p>
									<code>{feedInfo.feeds.radarr.setup}</code>
								</div>
								<button on:click={() => copyUrl(feedInfo.feeds.radarr.url)}>{$_('feedModal.copyUrl')}</button>
							</div>
						</div>

						<div class="feed-section">
							<h3>{$_('feedModal.sonarr')}</h3>
							<div class="feed-item">
								<div class="feed-info">
									<strong>{feedInfo.feeds.sonarr.name}</strong>
									<p>{feedInfo.feeds.sonarr.description}</p>
									<code>{feedInfo.feeds.sonarr.setup}</code>
								</div>
								<button on:click={() => copyUrl(feedInfo.feeds.sonarr.url)}>{$_('feedModal.copyUrl')}</button>
							</div>
						</div>
					{:else}
						<div class="error">{$_('feedModal.failed')}</div>
					{/if}
				</div>
			</div>
		</div>
	{/if}

	<!-- iOS PWA Install Modal -->
	{#if showPwaModal}
		<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
		<div class="modal-overlay" on:click={() => showPwaModal = false}>
			<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
			<div class="modal pwa-modal" on:click|stopPropagation>
				<div class="modal-header">
					<h2>{$_('pwaModal.title')}</h2>
					<button class="close-btn" on:click={() => showPwaModal = false}>&times;</button>
				</div>
				<div class="modal-content">
					<p>{$_('pwaModal.description')}</p>
					<div class="pwa-steps">
						<div class="pwa-step">
							<span class="step-number">1</span>
							<span>{$_('pwaModal.step1', { values: { share: '' }})}<strong>{$_('pwaModal.share')}</strong></span>
							<svg class="share-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
								<path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8" />
								<polyline points="16,6 12,2 8,6" />
								<line x1="12" y1="2" x2="12" y2="15" />
							</svg>
						</div>
						<div class="pwa-step">
							<span class="step-number">2</span>
							<span>{$_('pwaModal.step2', { values: { addToHomeScreen: '' }})}<strong>{$_('pwaModal.addToHomeScreen')}</strong></span>
						</div>
						<div class="pwa-step">
							<span class="step-number">3</span>
							<span>{$_('pwaModal.step3')}</span>
						</div>
						<div class="pwa-step">
							<span class="step-number">4</span>
							<span>{$_('pwaModal.step4')}</span>
						</div>
					</div>
				</div>
			</div>
		</div>
	{/if}

	<!-- Push Notification Confirmation Modal -->
	{#if showPushModal}
		<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
		<div class="modal-overlay" on:click={() => showPushModal = false}>
			<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
			<div class="modal push-modal" on:click|stopPropagation>
				<div class="modal-header">
					<h2>{$pushSubscribed ? $_('pushModal.disableTitle') : $_('pushModal.enableTitle')}</h2>
					<button class="close-btn" on:click={() => showPushModal = false}>&times;</button>
				</div>
				<div class="modal-content">
					{#if $pushSubscribed}
						<p>{$_('pushModal.disableDescription')}</p>
					{:else}
						<p>{$_('pushModal.enableDescription')}</p>
					{/if}
					<div class="modal-actions">
						<button class="btn-secondary" on:click={() => showPushModal = false}>{$_('pushModal.cancel')}</button>
						<button class="btn-primary" on:click={confirmPushAction}>
							{$pushSubscribed ? $_('pushModal.disable') : $_('pushModal.enable')}
						</button>
					</div>
				</div>
			</div>
		</div>
	{/if}
</div>
{/if}

<style>
	.app {
		min-height: 100vh;
		display: flex;
		flex-direction: column;
	}

	header {
		background: var(--bg-secondary);
		border-bottom: 1px solid var(--border);
		padding: calc(1rem + env(safe-area-inset-top, 0px)) calc(2rem + env(safe-area-inset-right, 0px)) 1rem calc(2rem + env(safe-area-inset-left, 0px));
		position: sticky;
		top: 0;
		z-index: 100;
	}

	.header-content {
		max-width: 1400px;
		margin: 0 auto;
		display: flex;
		justify-content: space-between;
		align-items: center;
	}

	.logo {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		text-decoration: none;
		color: var(--text-primary);
	}

	.logo-icon {
		width: 1.5rem;
		height: 1.5rem;
	}

	.logo-text {
		font-size: 1.25rem;
		font-weight: 600;
	}

	nav {
		display: flex;
		gap: 1rem;
		align-items: center;
	}

	.nav-link {
		display: flex;
		align-items: center;
		gap: 0.5rem;
		color: var(--text-secondary);
		text-decoration: none;
		transition: color 0.2s;
	}

	.nav-link:hover,
	.nav-link:active {
		color: var(--text-primary);
	}

	.nav-icon {
		width: 1.25rem;
		height: 1.25rem;
		flex-shrink: 0;
	}

	.nav-text {
		display: inline;
	}

	.nav-btn {
		display: flex;
		align-items: center;
		justify-content: center;
		background: transparent;
		border: none;
		color: var(--text-secondary);
		cursor: pointer;
		padding: 0.5rem;
		border-radius: 0.5rem;
		transition: color 0.2s, background 0.2s;
	}

	.nav-btn:hover,
	.nav-btn:active {
		color: var(--text-primary);
		background: var(--bg-tertiary);
	}

	.nav-btn:focus {
		outline: none;
	}

	.nav-btn:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 2px;
	}

	.nav-btn.subscribed .bell-icon {
		color: var(--accent);
	}

	.nav-btn.loading {
		opacity: 0.5;
		pointer-events: none;
	}

	.logout-btn:hover,
	.logout-btn:active {
		color: var(--error);
		background: rgba(239, 68, 68, 0.1);
	}

	main {
		flex: 1;
		max-width: 1400px;
		margin: 0 auto;
		padding: 2rem;
		width: 100%;
	}

	.toast-container {
		position: fixed;
		bottom: 1rem;
		right: 1rem;
		display: flex;
		flex-direction: column;
		gap: 0.5rem;
		z-index: 1000;
	}

	.toast {
		padding: 1rem 1.5rem;
		border-radius: 0.5rem;
		background: var(--bg-tertiary);
		box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
		animation: slideIn 0.3s ease;
	}

	.toast-success {
		border-left: 4px solid var(--success);
	}

	.toast-error {
		border-left: 4px solid var(--error);
	}

	.toast-info {
		border-left: 4px solid var(--accent);
	}

	@keyframes slideIn {
		from {
			transform: translateX(100%);
			opacity: 0;
		}
		to {
			transform: translateX(0);
			opacity: 1;
		}
	}

	@media (max-width: 768px) {
		header {
			padding: calc(0.75rem + env(safe-area-inset-top, 0px)) calc(1rem + env(safe-area-inset-right, 0px)) 0.75rem calc(1rem + env(safe-area-inset-left, 0px));
		}

		nav {
			gap: 0.5rem;
		}

		.nav-text {
			display: none;
		}

		.nav-link {
			padding: 0.5rem;
			border-radius: 0.5rem;
		}

		.nav-link:hover,
		.nav-link:active {
			background: var(--bg-tertiary);
		}

		.feeds-btn {
			display: none;
		}

		main {
			padding: 1rem;
		}
	}

	/* Modal styles */
	.modal-overlay {
		position: fixed;
		top: 0;
		left: 0;
		right: 0;
		bottom: 0;
		background: rgba(0, 0, 0, 0.8);
		display: flex;
		align-items: center;
		justify-content: center;
		z-index: 1000;
		padding: 1rem;
	}

	.modal {
		background: var(--bg-secondary);
		border-radius: 1rem;
		max-width: 600px;
		width: 100%;
		max-height: min(90vh, 100dvh);
		overflow-y: auto;
	}

	.modal-header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 1.5rem;
		border-bottom: 1px solid var(--border);
	}

	.modal-header h2 {
		margin: 0;
		font-size: 1.25rem;
	}

	.close-btn {
		background: none;
		border: none;
		font-size: 1.5rem;
		color: var(--text-secondary);
		cursor: pointer;
		min-width: 44px;
		min-height: 44px;
		display: flex;
		align-items: center;
		justify-content: center;
		border-radius: 50%;
		transition: color 0.2s, background 0.2s;
	}

	.close-btn:hover,
	.close-btn:active {
		color: var(--text-primary);
		background: var(--bg-tertiary);
	}

	.modal-content {
		padding: 1.5rem;
	}

	.loading, .error {
		text-align: center;
		color: var(--text-secondary);
		padding: 2rem;
	}

	.token-notice {
		background: var(--bg-tertiary);
		padding: 0.75rem 1rem;
		border-radius: 0.5rem;
		margin-bottom: 1.5rem;
		color: var(--warning);
		font-size: 0.9rem;
	}

	.feed-section {
		margin-bottom: 1.5rem;
	}

	.feed-section h3 {
		font-size: 1rem;
		margin-bottom: 0.75rem;
		color: var(--text-secondary);
	}

	.feed-item {
		display: flex;
		justify-content: space-between;
		align-items: flex-start;
		padding: 1rem;
		background: var(--bg-tertiary);
		border-radius: 0.5rem;
		margin-bottom: 0.5rem;
		gap: 1rem;
	}

	.feed-item.recommended {
		border: 1px solid var(--accent);
	}

	.feed-info {
		flex: 1;
	}

	.feed-info strong {
		display: block;
		margin-bottom: 0.25rem;
	}

	.feed-info p {
		font-size: 0.85rem;
		color: var(--text-secondary);
		margin: 0.25rem 0;
	}

	.feed-info code {
		font-size: 0.75rem;
		color: var(--text-secondary);
		background: var(--bg-secondary);
		padding: 0.25rem 0.5rem;
		border-radius: 0.25rem;
	}

	.badge {
		display: inline-block;
		background: var(--accent);
		color: white;
		font-size: 0.7rem;
		padding: 0.2rem 0.5rem;
		border-radius: 0.25rem;
		margin-left: 0.5rem;
		vertical-align: middle;
	}

	.feed-item button {
		padding: 0.5rem 1rem;
		background: var(--accent);
		border: none;
		border-radius: 0.5rem;
		color: white;
		font-size: 0.85rem;
		cursor: pointer;
		white-space: nowrap;
	}

	.feed-item button:hover,
	.feed-item button:active {
		background: var(--accent-hover);
	}

	@media (max-width: 768px) {
		.feed-item {
			flex-direction: column;
		}

		.feed-item button {
			width: 100%;
		}
	}

	/* PWA Install Modal */
	.pwa-modal {
		max-width: 400px;
	}

	.pwa-modal .modal-content p {
		margin: 0 0 1.5rem 0;
		color: var(--text-secondary);
		line-height: 1.5;
	}

	.pwa-steps {
		display: flex;
		flex-direction: column;
		gap: 1rem;
	}

	.pwa-step {
		display: flex;
		align-items: center;
		gap: 0.75rem;
		padding: 0.75rem;
		background: var(--bg-tertiary);
		border-radius: 0.5rem;
	}

	.step-number {
		width: 1.75rem;
		height: 1.75rem;
		background: var(--accent);
		color: white;
		border-radius: 50%;
		display: flex;
		align-items: center;
		justify-content: center;
		font-weight: 600;
		font-size: 0.875rem;
		flex-shrink: 0;
	}

	.share-icon {
		width: 1.25rem;
		height: 1.25rem;
		color: var(--accent);
		flex-shrink: 0;
	}

	/* Push Notification Modal */
	.push-modal {
		max-width: 400px;
	}

	.push-modal .modal-content p {
		margin: 0 0 1.5rem 0;
		color: var(--text-secondary);
		line-height: 1.5;
	}

	.modal-actions {
		display: flex;
		gap: 0.75rem;
		justify-content: flex-end;
	}

	.btn-primary,
	.btn-secondary {
		padding: 0.625rem 1.25rem;
		border-radius: 0.5rem;
		font-size: 0.9rem;
		font-weight: 500;
		cursor: pointer;
		border: none;
		transition: background 0.2s;
	}

	.btn-primary {
		background: var(--accent);
		color: white;
	}

	.btn-primary:hover,
	.btn-primary:active {
		background: var(--accent-hover);
	}

	.btn-secondary {
		background: var(--bg-tertiary);
		color: var(--text-primary);
	}

	.btn-secondary:hover,
	.btn-secondary:active {
		background: var(--border);
	}

	/* Language dropdown */
	.lang-dropdown-container {
		position: relative;
	}

	.lang-dropdown {
		position: absolute;
		top: 100%;
		right: 0;
		margin-top: 0.5rem;
		background: var(--bg-secondary);
		border: 1px solid var(--border);
		border-radius: 0.5rem;
		overflow: hidden;
		z-index: 1000;
		min-width: 120px;
		box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
	}

	.lang-option {
		display: block;
		width: 100%;
		padding: 0.75rem 1rem;
		background: none;
		border: none;
		color: var(--text-secondary);
		text-align: left;
		cursor: pointer;
		transition: background 0.2s, color 0.2s;
		font-size: 0.9rem;
	}

	.lang-option:hover,
	.lang-option:active {
		background: var(--bg-tertiary);
		color: var(--text-primary);
	}

	.lang-option.active {
		background: var(--accent);
		color: white;
	}
</style>
