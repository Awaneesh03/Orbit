// Orbit for YouTube: reports this tab's main YouTube player (title, channel,
// thumbnail, position, duration, state) to the extension's background, and
// applies play/pause/seek it relays from Orbit. Event-driven: it listens to
// the player's media events (no polling, no DOM observers) and reads the page
// only when one fires. Nothing else on the page, and no history, is read.
// Diagnostics go to this tab's console ("[Orbit] …"), never with titles.
(() => {
  'use strict';

  // Injected again into open tabs when the extension is installed or
  // reloaded: the previous copy steps aside first.
  if (typeof globalThis.__orbitYouTubeStop === 'function') globalThis.__orbitYouTubeStop();

  const site = location.hostname === 'music.youtube.com' ? 'music' : 'youtube';
  const PLAYER = '#movie_player, #shorts-player, ytmusic-player';
  // Events that move the position (sent even when nothing else changed).
  const TIMING = new Set(['play', 'playing', 'pause', 'seeked', 'ratechange', 'waiting', 'ended']);
  const EVENTS = [...TIMING, 'durationchange', 'loadedmetadata', 'emptied', 'volumechange'];

  let port = null;
  let video = null; // the main player's <video>, found from its own events
  let lastKey = '';
  let metadataTimer = 0;
  let reconnectTimer = 0;
  let reconnectDelay = 1000;
  let stopped = false;

  function mainVideo(element) {
    return element instanceof HTMLVideoElement && element.closest(PLAYER) ? element : null;
  }

  // The extension was reloaded or removed: this copy can't reach it any more.
  function orphaned() {
    return !(globalThis.chrome && chrome.runtime && chrome.runtime.id);
  }

  function connect() {
    if (port || stopped) return port;
    if (orphaned()) return stop();
    try {
      port = chrome.runtime.connect({ name: 'orbit-youtube' });
    } catch {
      return stop();
    }
    const current = port;
    current.onDisconnect.addListener(() => {
      if (port !== current) return;
      port = null;
      lastKey = '';
      if (orphaned()) return stop();
      // The background went idle and was restarted by Brave: tell it again
      // what's playing rather than waiting for the next media event.
      clearTimeout(reconnectTimer);
      reconnectTimer = setTimeout(() => report(true), reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 60000);
    });
    current.onMessage.addListener(command);
    return current;
  }

  function post(message) {
    for (let attempt = 0; attempt < 2; attempt++) {
      const target = connect();
      if (!target) return;
      try {
        target.postMessage(message);
        return;
      } catch {
        port = null; // the background restarted: reconnect once
        lastKey = '';
      }
    }
  }

  function text(selector) {
    const element = document.querySelector(selector);
    return element ? element.textContent.trim() : '';
  }

  function currentVideoID() {
    const url = new URL(location.href);
    const id = url.searchParams.get('v');
    if (id) return id;
    const shorts = url.pathname.match(/^\/shorts\/([\w-]+)/);
    return shorts ? shorts[1] : null;
  }

  // The page's own Media Session metadata first; the visible title and
  // channel when YouTube hasn't set it.
  function metadata(id) {
    const meta = navigator.mediaSession ? navigator.mediaSession.metadata : null;
    let artwork = null;
    if (meta && meta.artwork && meta.artwork.length) {
      const size = (entry) => parseInt((entry.sizes || '0').split('x')[0], 10) || 0;
      artwork = [...meta.artwork].sort((a, b) => size(b) - size(a))[0].src;
    }
    const title = (meta && meta.title) ||
      (site === 'music' ? text('ytmusic-player-bar .title') : text('ytd-watch-metadata h1')) ||
      document.title.replace(/ - YouTube( Music)?$/, '');
    const channel = (meta && meta.artist) ||
      (site === 'music' ? text('ytmusic-player-bar .byline a') : text('ytd-watch-metadata #owner #channel-name a'));
    return {
      title: title || null,
      channel: channel || null,
      album: (meta && meta.album) || null,
      artwork: artwork || (id ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : null),
    };
  }

  function snapshot() {
    if (!video || (!video.currentSrc && video.readyState === 0)) return null;
    const id = currentVideoID();
    const ended = video.ended;
    const playing = !video.paused && !ended;
    const stalled = playing && video.readyState < 3;
    const player = video.closest('.html5-video-player');
    const duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : null;
    return {
      type: 'update',
      site,
      state: ended ? 'ended' : playing ? 'playing' : 'paused',
      muted: video.muted || video.volume === 0,
      ad: Boolean(player && player.classList.contains('ad-showing')),
      videoID: id,
      ...metadata(id),
      position: Number.isFinite(video.currentTime) ? Math.max(0, video.currentTime) : 0,
      duration,
      rate: playing && !stalled ? video.playbackRate : 0,
      at: Date.now(),
    };
  }

  function report(timing) {
    const state = snapshot();
    if (!state) return;
    const key = JSON.stringify({ ...state, position: 0, at: 0 });
    if (!timing && key === lastKey) return;
    lastKey = key;
    post(state);
  }

  // YouTube sets the Media Session a moment after a new video starts: read
  // the metadata once more shortly after.
  function refreshMetadataSoon() {
    clearTimeout(metadataTimer);
    metadataTimer = setTimeout(() => report(false), 1500);
  }

  function onMediaEvent(event) {
    const element = mainVideo(event.target);
    if (!element) return; // previews and other videos on the page
    if (video !== element) console.debug('[Orbit] found the YouTube player');
    video = element;
    reconnectDelay = 1000;
    report(TIMING.has(event.type));
    if (event.type === 'playing' || event.type === 'loadedmetadata') refreshMetadataSoon();
  }

  // Single-page navigation: a new video, or a page without one.
  function onNavigate() {
    if (!video) video = mainVideo(document.querySelector('#movie_player video'));
    if (video && !video.paused) return refreshMetadataSoon();
    if (!currentVideoID()) {
      lastKey = '';
      post({ type: 'gone' }); // left the video while it was paused
    } else {
      refreshMetadataSoon();
    }
  }

  // Back from the back/forward cache: the old connection was closed.
  function onPageShow(event) {
    if (event.persisted) report(true);
  }

  // Media events don't bubble, but capturing listeners on the document see them,
  // including on a <video> YouTube replaces.
  for (const type of EVENTS) document.addEventListener(type, onMediaEvent, true);
  document.addEventListener('yt-navigate-finish', onNavigate);
  window.addEventListener('pageshow', onPageShow);

  function stop() {
    if (stopped) return null;
    stopped = true;
    for (const type of EVENTS) document.removeEventListener(type, onMediaEvent, true);
    document.removeEventListener('yt-navigate-finish', onNavigate);
    window.removeEventListener('pageshow', onPageShow);
    clearTimeout(metadataTimer);
    clearTimeout(reconnectTimer);
    if (port) {
      try { port.disconnect(); } catch {}
      port = null;
    }
    if (globalThis.__orbitYouTubeStop === stop) delete globalThis.__orbitYouTubeStop;
    return null;
  }
  globalThis.__orbitYouTubeStop = stop;

  function command(message) {
    if (!message || !video || typeof message.action !== 'string') return;
    if (message.videoID && message.videoID !== currentVideoID()) return; // this tab moved on
    switch (message.action) {
      case 'play':
        video.play().catch(() => {});
        break;
      case 'pause':
        video.pause();
        break;
      case 'seek':
        if (Number.isFinite(message.position)) {
          const end = Number.isFinite(video.duration) ? video.duration : message.position;
          video.currentTime = Math.min(Math.max(message.position, 0), end);
        }
        break;
    }
  }

  // Already playing when the script loads (autoplay, or a tab that was open
  // before the extension): report it once.
  video = mainVideo(document.querySelector('#movie_player video, ytmusic-player video'));
  console.info(`[Orbit] watching this tab's YouTube player (${video ? 'player found' : 'no player yet'})`);
  if (video) report(true);
})();
