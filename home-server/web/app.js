/* Household desk page. Capture stays on the phone.
 *
 * Three panes: the house (spaces and containers), a list, and the item you
 * opened. Opening an item never throws the list away — it opens beside it —
 * so checking several results or filing the drop zone is one click each.
 */
'use strict';

const DROP_ZONE_ID = 'drop-zone';
const QTY_MIN = 0;
const QTY_MAX = 9999;
const RECENT_SHOWN = 12;
const APP_NAME = 'Home inventory';
const TYPE_NAMES = {
  box: 'Box',
  drawer: 'Drawer',
  shelf: 'Shelf',
  cabinet: 'Cabinet',
  bin: 'Bin',
  bag: 'Bag',
  crate: 'Crate',
  other: 'Container',
};
const DATE_FORMAT = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric',
  month: 'long',
  year: 'numeric',
});
const RELATIVE_FORMAT = new Intl.RelativeTimeFormat('en-GB', { numeric: 'auto' });

/** At this width the item panel sits beside the list instead of covering it. */
const docked = window.matchMedia('(min-width: 900px)');

const $ = (id) => document.getElementById(id);
const el = {
  gate: $('gate'),
  app: $('app'),
  login: $('login'),
  password: $('password'),
  loginError: $('login-error'),
  loginSubmit: $('login-submit'),
  q: $('q'),
  searchForm: $('search-form'),
  rail: $('rail'),
  railToggle: $('rail-toggle'),
  railScrim: $('rail-scrim'),
  main: $('main'),
  panel: $('panel'),
  lock: $('lock'),
  liveState: $('live-state'),
  moveDialog: $('move-dialog'),
  moveTitle: $('move-title'),
  moveQ: $('move-q'),
  moveList: $('move-list'),
  moveError: $('move-error'),
  photoDialog: $('photo-dialog'),
  photoFull: $('photo-full'),
  toasts: $('toasts'),
  announce: $('announce'),
};

/* ---------- State ---------- */

/** The house: every space and container, plus what is waiting in the drop zone. */
const tree = { spaces: [], containers: [], unsorted: [], householdName: 'Home' };
/** Last data painted for each list URL, so going back is instant. */
const viewCache = new Map();
const scrollMemory = new Map();
/** Every item seen in any list, so the panel can paint before its fetch returns. */
const itemIndex = new Map();
/** Unsaved edit forms, kept when you open something else, restored when you return. */
const drafts = new Map();
/** Quantity writes in flight, per item. See flushQty. */
const qtyWrites = new Map();

let mainUrl = null;
let mainRoute = null;
let mainTitle = APP_NAME;
let mainGen = 0;
let mainLoad = Promise.resolve();
let panelItem = null;
let panelMode = 'read';
let panelGen = 0;
let recentExpanded = false;
let focusHeadingNext = false;
let locked = true;
let events = null;
let knownRevision = null;
let liveTimer = 0;
let refreshTimer = 0;
let searchTimer = 0;
let qtyRepeat = null;
let moveContext = null;

/* ---------- Small helpers ---------- */

function esc(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function plural(n, one, many = `${one}s`) {
  return `${n} ${n === 1 ? one : many}`;
}

function sentenceList(parts) {
  if (parts.length <= 1) return parts.join('');
  return `${parts.slice(0, -1).join(', ')} and ${parts[parts.length - 1]}`;
}

function icon(name, cls = '') {
  return `<svg class="icon${cls ? ` ${cls}` : ''}" aria-hidden="true"><use href="#i-${name}"/></svg>`;
}

function typeIcon(type) {
  return icon(type in TYPE_NAMES ? type : 'other');
}

function tape(code, size = '') {
  return `<span class="tape${size ? ` tape-${size}` : ''}">${esc(code)}</span>`;
}

function safeColor(color) {
  return /^#[0-9a-f]{3,8}$/i.test(color || '') ? color : '#8a948d';
}

function pip(color) {
  return `<span class="pip" style="--room:${safeColor(color)}" aria-hidden="true"></span>`;
}

function roomEmoji(space, size = '') {
  return `<span class="room-emoji${size ? ` room-emoji-${size}` : ''}" style="--room:${safeColor(
    space.color,
  )}" aria-hidden="true">${esc(space.icon || '🏠')}</span>`;
}

function isNamed(item) {
  return Boolean(item.name && item.name.trim());
}

function titleOf(item) {
  return isNamed(item) ? item.name : 'Needs a name';
}

function typeName(type) {
  return TYPE_NAMES[type] || TYPE_NAMES.other;
}

function containerLabel(container) {
  return container.name || container.shortCode;
}

function photoUrl(item, thumb) {
  if (!item.photoId) return '';
  return `/v1/photos/${encodeURIComponent(item.photoId)}${thumb ? '?thumb=1' : ''}`;
}

function highlight(text, terms) {
  const usable = (terms || []).filter((term) => term && term.length > 1);
  if (!usable.length) return esc(text);
  const pattern = new RegExp(
    `(${usable.map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|')})`,
    'gi',
  );
  return String(text)
    .split(pattern)
    .map((part, index) => (index % 2 ? `<mark>${esc(part)}</mark>` : esc(part)))
    .join('');
}

function ago(ms) {
  const diff = ms - Date.now();
  const size = Math.abs(diff);
  const units = [
    ['year', 365 * 864e5],
    ['month', 30 * 864e5],
    ['week', 7 * 864e5],
    ['day', 864e5],
    ['hour', 36e5],
    ['minute', 6e4],
  ];
  for (const [unit, span] of units) {
    if (size >= span) return RELATIVE_FORMAT.format(Math.round(diff / span), unit);
  }
  return 'just now';
}

function compact(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[-_/.']/g, '');
}

function byLabel(a, b) {
  return containerLabel(a).localeCompare(containerLabel(b), 'en', { sensitivity: 'base' });
}

function spaceById(id) {
  return tree.spaces.find((space) => space.id === id) || null;
}

function containerById(id) {
  return tree.containers.find((container) => container.id === id) || null;
}

function isField(target) {
  return Boolean(target?.closest?.('input, textarea, select, [contenteditable="true"]'));
}

function isPlainClick(event) {
  return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey;
}

function announce(message) {
  el.announce.textContent = '';
  window.setTimeout(() => {
    el.announce.textContent = message;
  }, 30);
}

function indexItems(list) {
  for (const item of list || []) itemIndex.set(item.id, item);
}

/* ---------- Server ---------- */

class ApiError extends Error {
  constructor(status, body = {}) {
    super(body.error || `request failed (${status})`);
    this.status = status;
    this.body = body;
  }
}

async function api(path, init = {}) {
  let response;
  try {
    response = await fetch(path, { credentials: 'same-origin', ...init });
  } catch {
    throw new ApiError(0);
  }
  if (response.status === 401) {
    lockOut();
    throw new ApiError(401);
  }
  if (!response.ok) {
    throw new ApiError(response.status, await response.json().catch(() => ({})));
  }
  if (response.status === 204) return {};
  return response.json();
}

function getItem(id) {
  return api(`/v1/items/${encodeURIComponent(id)}`);
}

function patchItem(id, body) {
  return api(`/v1/items/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
}

/* ---------- Gate ---------- */

function clearSession() {
  stopEvents();
  setLive(true);
  knownRevision = null;
  mainGen += 1;
  panelGen += 1;
  closeDialogs();
  viewCache.clear();
  scrollMemory.clear();
  itemIndex.clear();
  drafts.clear();
  qtyWrites.clear();
  mainUrl = null;
  mainRoute = null;
  panelItem = null;
  panelMode = 'read';
  el.main.innerHTML = '';
  el.rail.innerHTML = '';
  el.panel.innerHTML = '';
  el.panel.hidden = true;
  el.app.classList.remove('has-panel', 'rail-open');
  document.body.classList.remove('panel-overlay');
  el.toasts.innerHTML = '';
}

function showGate(message = '') {
  clearSession();
  el.app.hidden = true;
  el.gate.hidden = false;
  el.loginError.textContent = message;
  document.title = APP_NAME;
  el.password.focus();
}

function lockOut() {
  if (locked) return;
  locked = true;
  showGate('Your session ended. Enter the password to carry on where you were.');
}

async function enter() {
  locked = false;
  el.gate.hidden = true;
  el.app.hidden = false;
  startEvents();
  try {
    await loadTree();
  } catch {
    /* each view reports its own failure */
  }
  await render();
  const route = parseUrl(currentUrl());
  if ((route.name === 'home' || route.name === 'search') && docked.matches) el.q.focus();
}

el.login.addEventListener('submit', async (event) => {
  event.preventDefault();
  const password = el.password.value;
  if (!password) {
    el.loginError.textContent = 'Enter the household password.';
    el.password.focus();
    return;
  }
  el.loginError.textContent = '';
  el.loginSubmit.disabled = true;
  el.loginSubmit.textContent = 'Unlocking…';
  try {
    const response = await fetch('/v1/web/login', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password }),
    });
    if (response.status === 401) {
      el.loginError.textContent = 'That password did not work. Check it and try again.';
      el.password.select();
      return;
    }
    if (!response.ok) {
      el.loginError.textContent = 'The household server could not check the password. Try again.';
      return;
    }
    el.password.value = '';
    await enter();
  } catch {
    el.loginError.textContent =
      'The household server did not answer. Check that it is running, then try again.';
  } finally {
    el.loginSubmit.disabled = false;
    el.loginSubmit.textContent = 'Unlock';
  }
});

el.lock.addEventListener('click', async () => {
  locked = true;
  await fetch('/v1/web/logout', { method: 'POST', credentials: 'same-origin' }).catch(() => {});
  history.replaceState(null, '', '/');
  showGate();
});

/* ---------- The house (rail) ---------- */

async function loadTree() {
  const [spaces, containers, unsorted] = await Promise.all([
    api('/v1/spaces'),
    api('/v1/containers'),
    api('/v1/items?unsorted=1'),
  ]);
  tree.spaces = spaces.spaces || [];
  tree.containers = containers.containers || [];
  tree.unsorted = unsorted.items || [];
  indexItems(tree.unsorted);
  renderRail();
}

/** Which space and container the list is showing, for highlighting the rail. */
function currentPlace() {
  const route = mainRoute || { name: 'home' };
  if (route.name === 'space') return { spaceId: route.id };
  if (route.name === 'container') {
    if (route.id === DROP_ZONE_ID) return { drop: true };
    const container = containerById(route.id);
    return { spaceId: container?.spaceId, containerId: route.id };
  }
  return { home: route.name === 'home' };
}

function renderRail() {
  if (locked) return;
  const focused = el.rail.contains(document.activeElement)
    ? document.activeElement.getAttribute('href')
    : null;
  const place = currentPlace();
  const waiting = tree.unsorted.length;
  const spaces = tree.spaces
    .map((space) => {
      const current = place.spaceId === space.id;
      const inside = current
        ? tree.containers
            .filter((container) => container.spaceId === space.id)
            .sort(byLabel)
            .map(
              (container) =>
                `<li><a class="rail-sublink" href="/container/${esc(container.id)}" data-link${
                  place.containerId === container.id ? ' aria-current="page"' : ''
                }>${typeIcon(container.visualType)}<span class="rail-name">${
                  container.name ? esc(container.name) : tape(container.shortCode, 's')
                }</span><span class="rail-count">${container.itemCount ?? 0}</span></a></li>`,
            )
            .join('')
        : '';
      return `<li><a class="rail-link" href="/space/${esc(space.id)}" data-link${
        current && !place.containerId ? ' aria-current="page"' : ''
      }>${roomEmoji(space)}<span class="rail-name">${esc(space.name)}</span><span class="rail-count">${
        space.itemCount ?? 0
      }</span></a>${inside ? `<ul class="rail-subs">${inside}</ul>` : ''}</li>`;
    })
    .join('');
  el.rail.innerHTML = `
    <a class="rail-link" href="/" data-link${place.home ? ' aria-current="page"' : ''}>${icon(
      'home',
    )}<span>Overview</span></a>
    <a class="rail-link" href="/container/${DROP_ZONE_ID}" data-link${
      place.drop ? ' aria-current="page"' : ''
    }>${icon('inbox')}<span>Drop zone</span>${
      waiting
        ? `<span class="rail-badge"><span class="sr-only">, </span>${waiting}<span class="sr-only"> waiting</span></span>`
        : ''
    }</a>
    <h2 class="rail-heading">Spaces</h2>
    ${
      spaces
        ? `<ul class="rail-list">${spaces}</ul>`
        : '<p class="rail-empty">No spaces yet. Create them in the phone app.</p>'
    }`;
  if (focused)
    el.rail.querySelector(`a[href="${CSS.escape(focused)}"]`)?.focus({ preventScroll: true });
}

function openRail() {
  el.app.classList.add('rail-open');
  el.railToggle.setAttribute('aria-expanded', 'true');
  el.railToggle.setAttribute('aria-label', 'Hide spaces');
  el.railScrim.hidden = false;
  el.rail.querySelector('[aria-current="page"], a')?.focus();
}

function closeRail() {
  if (!el.app.classList.contains('rail-open')) return;
  el.app.classList.remove('rail-open');
  el.railToggle.setAttribute('aria-expanded', 'false');
  el.railToggle.setAttribute('aria-label', 'Show spaces');
  el.railScrim.hidden = true;
}

el.railToggle.addEventListener('click', () => {
  if (el.app.classList.contains('rail-open')) closeRail();
  else openRail();
});
el.railScrim.addEventListener('click', closeRail);

/* ---------- Routing ---------- */

function currentUrl() {
  return location.pathname + location.search;
}

function parseUrl(url) {
  const parsed = new URL(url, location.origin);
  const path = parsed.pathname.replace(/\/+$/, '') || '/';
  let match = /^\/item\/([^/]+)$/.exec(path);
  if (match) return { name: 'item', id: decodeURIComponent(match[1]) };
  match = /^\/space\/([^/]+)$/.exec(path);
  if (match) return { name: 'space', id: decodeURIComponent(match[1]) };
  match = /^\/container\/([^/]+)$/.exec(path);
  if (match) return { name: 'container', id: decodeURIComponent(match[1]) };
  const q = (parsed.searchParams.get('q') || '').trim();
  return q ? { name: 'search', q } : { name: 'home' };
}

function itemUrl(id) {
  return `/item/${encodeURIComponent(id)}`;
}

/** Navigate to a list view. Moves focus to its heading, like a page load would. */
function go(url, { replace = false } = {}) {
  closeRail();
  if (url !== currentUrl()) history[replace ? 'replaceState' : 'pushState'](null, '', url);
  focusHeadingNext = true;
  render();
}

/** Open an item beside the current list, keeping the list as its backdrop. */
function openItem(id, { focusPanel = !docked.matches } = {}) {
  const route = parseUrl(currentUrl());
  if (route.name === 'item') {
    if (route.id === id) return;
    history.replaceState(history.state, '', itemUrl(id));
  } else {
    history.pushState({ backdrop: currentUrl(), pushed: true }, '', itemUrl(id));
  }
  render({ focusPanel });
}

function closePanel() {
  const state = history.state || {};
  if (state.pushed) {
    history.back();
    return;
  }
  history.replaceState(null, '', state.backdrop || mainUrl || '/');
  render();
}

async function render({ focusPanel = false } = {}) {
  if (locked) return;
  const route = parseUrl(currentUrl());
  if (route.name !== 'item') {
    hidePanel();
    await showMain(currentUrl());
    return;
  }
  const backdrop = history.state?.backdrop || null;
  if (backdrop) showMain(backdrop);
  const item = await showPanel(route.id, { focus: focusPanel });
  if (backdrop || parseUrl(currentUrl()).id !== route.id) return;
  // Opened from a bookmark or a reload: show the container it lives in.
  const fallback = item ? `/container/${encodeURIComponent(item.containerId)}` : '/';
  history.replaceState({ backdrop: fallback, pushed: false }, '');
  showMain(fallback);
}

window.addEventListener('popstate', () => {
  closeRail();
  render();
});

/* ---------- Main list views ---------- */

function mainScroller() {
  return docked.matches ? el.main : document.scrollingElement;
}

async function showMain(url, { quiet = false, force = false } = {}) {
  const route = parseUrl(url);
  const same = url === mainUrl;
  syncSearchBox(route);
  if (same && !quiet && !force) {
    maybeFocusHeading();
    return mainLoad;
  }
  const gen = ++mainGen;
  if (!same) {
    if (mainUrl) scrollMemory.set(mainUrl, mainScroller().scrollTop);
    mainUrl = url;
    mainRoute = route;
    renderRail();
  }
  const cached = viewCache.get(url);
  if (!same) {
    if (cached) paint(route, cached, { scroll: scrollMemory.get(url) ?? 0 });
    else {
      window.setTimeout(() => {
        if (gen === mainGen && !viewCache.has(url)) el.main.innerHTML = skeleton();
      }, 180);
    }
  }
  mainLoad = (async () => {
    try {
      const data = await loadView(route);
      if (gen !== mainGen) return;
      const before = viewCache.get(url);
      viewCache.set(url, data);
      if (!before) {
        paint(route, data, { scroll: 0 });
      } else if (force || JSON.stringify(before) !== JSON.stringify(data)) {
        paint(route, data, { preserve: true });
      }
      if (route.name === 'search' && !quiet) announce(searchSummary(data));
    } catch (error) {
      if (gen !== mainGen || error.status === 401) return;
      if (!cached || force) paintError(route, error);
    }
  })();
  return mainLoad;
}

async function loadView(route) {
  if (route.name === 'search') {
    const data = await api(`/v1/search?q=${encodeURIComponent(route.q)}`);
    indexItems(data.items);
    return {
      q: route.q,
      terms: data.terms || [],
      locations: data.locations || [],
      items: data.items || [],
    };
  }
  if (route.name === 'space') {
    const [space, listed] = await Promise.all([
      api(`/v1/spaces/${encodeURIComponent(route.id)}`),
      api(`/v1/containers?spaceId=${encodeURIComponent(route.id)}`),
    ]);
    const containers = (listed.containers || []).sort(byLabel);
    const contents = await Promise.all(
      containers.map((container) =>
        api(`/v1/items?containerId=${encodeURIComponent(container.id)}`).then(
          (body) => body.items || [],
        ),
      ),
    );
    contents.forEach(indexItems);
    return {
      space,
      containers: containers.map((container, index) => ({ ...container, items: contents[index] })),
    };
  }
  if (route.name === 'container') {
    if (route.id === DROP_ZONE_ID) {
      const listed = await api('/v1/items?unsorted=1');
      indexItems(listed.items);
      return { drop: true, items: listed.items || [] };
    }
    const [container, listed] = await Promise.all([
      api(`/v1/containers/${encodeURIComponent(route.id)}`),
      api(`/v1/items?containerId=${encodeURIComponent(route.id)}`),
    ]);
    indexItems(listed.items);
    const space =
      spaceById(container.spaceId) ||
      (await api(`/v1/spaces/${encodeURIComponent(container.spaceId)}`).catch(() => null));
    return { container, space, items: listed.items || [] };
  }
  const [recent, unsorted] = await Promise.all([
    api('/v1/items?recent=1&limit=60'),
    api('/v1/items?unsorted=1'),
  ]);
  indexItems(recent.items);
  indexItems(unsorted.items);
  return {
    recent: (recent.items || []).filter((item) => item.containerId !== DROP_ZONE_ID),
    unsorted: unsorted.items || [],
  };
}

function paint(route, data, { scroll = null, preserve = false } = {}) {
  pruneQty();
  const focus = preserve ? captureFocus(el.main) : null;
  const scroller = mainScroller();
  const keep = scroller.scrollTop;
  const view = VIEWS[route.name] || VIEWS.home;
  const { html, title } = view(data, route);
  el.main.innerHTML = `<div class="view">${html}</div>`;
  mainTitle = title ? `${title} – ${APP_NAME}` : APP_NAME;
  if (!panelItem) document.title = mainTitle;
  markSelection();
  if (focus) restoreFocus(el.main, focus);
  if (preserve) scroller.scrollTop = keep;
  else if (scroll !== null) scroller.scrollTop = scroll;
  maybeFocusHeading();
}

function maybeFocusHeading() {
  if (!focusHeadingNext) return;
  focusHeadingNext = false;
  if (panelItem) return;
  el.main.querySelector('h1')?.focus({ preventScroll: true });
}

function paintError(route, error) {
  const missing = error.status === 404;
  const what = route.name === 'space' ? 'space' : route.name === 'container' ? 'container' : 'page';
  el.main.innerHTML = `<div class="view"><div class="empty">
    <h1 tabindex="-1">${
      missing
        ? `This ${what} is not in the household any more`
        : 'The household server did not answer'
    }</h1>
    <p>${
      missing
        ? 'It may have been deleted or merged on a phone.'
        : 'Check that the home server is running, then try again.'
    }</p>
    ${
      missing
        ? '<a class="btn" href="/" data-link>Go to the overview</a>'
        : '<button class="btn" type="button" data-retry>Try again</button>'
    }
  </div></div>`;
  mainTitle = APP_NAME;
  if (!panelItem) document.title = mainTitle;
  maybeFocusHeading();
}

function skeleton() {
  return `<div class="skeleton" aria-hidden="true"><div class="sk-title"></div><div class="sk-rows sheet">${'<div class="sk-row"></div>'.repeat(
    6,
  )}</div></div>`;
}

function syncSearchBox(route) {
  if (document.activeElement === el.q) return;
  el.q.value = route.name === 'search' ? route.q : '';
}

/* ---------- Rows ---------- */

function thumb(item) {
  const src = photoUrl(item, true);
  return `<span class="thumb">${icon('photo')}${
    src ? `<img src="${esc(src)}" alt="" loading="lazy" decoding="async" />` : ''
  }</span>`;
}

function whereLine(item) {
  if (item.containerId === DROP_ZONE_ID) {
    return `<span class="row-where">${icon('inbox', 'icon-s')}<span>Drop zone, not filed yet</span></span>`;
  }
  const container = item.containerName
    ? `<span>${esc(item.containerName)}</span>${tape(item.containerShortCode, 's')}`
    : tape(item.containerShortCode, 's');
  return `<span class="row-where">${pip(item.spaceColor)}<span>${esc(
    item.spaceName,
  )}</span><span class="sep" aria-hidden="true">›</span><span class="sr-only">,</span>${container}</span>`;
}

function qtyBadge(quantity) {
  if (quantity === 0) return '<span class="row-aside is-zero">None left</span>';
  if (quantity > 1)
    return `<span class="row-aside"><span class="sr-only">Quantity </span>×${quantity}</span>`;
  return '';
}

/**
 * One item in a list.
 * @param {'where' | 'detail' | 'added'} line what the second line says
 * @param {'stepper' | 'file' | null} tools controls beside the link
 */
function itemRow(item, { line = 'where', terms = null, tools = null } = {}) {
  const named = isNamed(item);
  let second = '';
  if (line === 'where') second = whereLine(item);
  else if (line === 'added')
    second = `<span class="row-meta">Added ${esc(ago(item.createdAt))}</span>`;
  else if (item.category) second = `<span class="row-meta">${esc(item.category)}</span>`;
  const side = tools === 'stepper' ? '' : qtyBadge(item.quantity);
  let controls = '';
  if (tools === 'stepper') controls = `<div class="row-tools">${stepper(item)}</div>`;
  if (tools === 'file') {
    controls = `<div class="row-tools"><button class="btn btn-s" type="button" data-file="${esc(
      item.id,
    )}">${icon('move')}File…</button></div>`;
  }
  return `<li class="row${controls ? ' has-tools' : ''}" data-key="item:${esc(item.id)}">
    <a class="row-link" href="${itemUrl(item.id)}" data-item="${esc(item.id)}" data-row>
      ${thumb(item)}
      <span class="row-text">
        <span class="row-name${named ? '' : ' is-unnamed'}">${
          named ? highlight(item.name, terms) : 'Needs a name'
        }</span>
        ${second}
      </span>
      ${side}
    </a>${controls}
  </li>`;
}

function placeRow(hit, terms) {
  if (hit.kind === 'space') {
    const space = spaceById(hit.id) || { icon: '🏠', color: null };
    return `<li class="row" data-key="space:${esc(hit.id)}">
      <a class="row-link" href="/space/${esc(hit.id)}" data-link data-row>
        ${roomEmoji(space, 'row')}
        <span class="row-text"><span class="row-name">${highlight(hit.title, terms)}</span>
        <span class="row-meta">Space with ${plural(space.containerCount ?? 0, 'container')}</span></span>
        <span class="row-aside">${plural(hit.itemCount, 'item')}</span>
      </a></li>`;
  }
  const container = containerById(hit.id);
  const space = spaceById(hit.spaceId);
  const code = container?.shortCode;
  return `<li class="row" data-key="container:${esc(hit.id)}">
    <a class="row-link" href="/container/${esc(hit.id)}" data-link data-row>
      <span class="thumb thumb-icon">${typeIcon(container?.visualType)}</span>
      <span class="row-text">
        <span class="row-name">${container?.name ? `<span>${highlight(container.name, terms)}</span>` : ''}${
          code ? tape(code, 's') : esc(hit.title)
        }</span>
        <span class="row-where">${space ? `${pip(space.color)}<span>${esc(space.name)}</span>` : ''}</span>
      </span>
      <span class="row-aside">${plural(hit.itemCount, 'item')}</span>
    </a></li>`;
}

function containerRow(container) {
  const named = container.items.filter(isNamed).map((item) => item.name);
  const rest = container.items.length - Math.min(named.length, 4);
  let peek = 'Empty';
  if (named.length) {
    peek = named.slice(0, 4).join(', ') + (rest > 0 ? ` and ${rest} more` : '');
  } else if (container.items.length) {
    peek = `${plural(container.items.length, 'item')} without a name`;
  }
  return `<li class="row" data-key="container:${esc(container.id)}">
    <a class="row-link" href="/container/${esc(container.id)}" data-link data-row>
      <span class="thumb thumb-icon">${typeIcon(container.visualType)}</span>
      <span class="row-text">
        <span class="row-name">${container.name ? `<span>${esc(container.name)}</span>` : ''}${tape(
          container.shortCode,
          's',
        )}</span>
        <span class="row-meta">${esc(peek)}</span>
      </span>
      <span class="row-aside">${plural(container.items.length, 'item')}</span>
    </a></li>`;
}

/* ---------- Views ---------- */

function homeView(data) {
  const itemTotal =
    tree.spaces.reduce((sum, space) => sum + (space.itemCount || 0), 0) + data.unsorted.length;
  const hasAnything = tree.spaces.length || data.unsorted.length || data.recent.length;
  const summary = tree.spaces.length
    ? `${sentenceList([
        plural(tree.spaces.length, 'space'),
        plural(tree.containers.length, 'container'),
        plural(itemTotal, 'item'),
      ])}.`
    : '';
  const parts = [
    `<header class="view-head"><div><h1 class="view-title" tabindex="-1">${esc(
      tree.householdName,
    )}</h1>${summary ? `<p class="view-sub">${summary}</p>` : ''}</div></header>`,
  ];

  if (data.unsorted.length) {
    const count = data.unsorted.length;
    parts.push(`<section class="dz" aria-labelledby="dz-title">
      <ul class="dz-thumbs" aria-hidden="true">${data.unsorted
        .slice(0, 4)
        .map((item) => `<li>${thumb(item)}</li>`)
        .join('')}</ul>
      <div>
        <h2 id="dz-title">${count === 1 ? '1 item is' : `${count} items are`} waiting in the drop zone</h2>
        <p>Photographed on the phone, not filed yet. Name ${count === 1 ? 'it' : 'them'} and give ${
          count === 1 ? 'it' : 'them'
        } a home.</p>
      </div>
      <a class="btn btn-primary" href="/container/${DROP_ZONE_ID}" data-link>Sort the drop zone</a>
    </section>`);
  }

  if (tree.spaces.length) {
    parts.push(`<section class="section home-spaces" aria-labelledby="spaces-title">
      <h2 class="section-title" id="spaces-title">Spaces</h2>
      <ul class="list sheet">${tree.spaces
        .map(
          (space) =>
            `<li class="row" data-key="space:${esc(space.id)}"><a class="row-link" href="/space/${esc(
              space.id,
            )}" data-link data-row>${roomEmoji(space, 'row')}<span class="row-text"><span class="row-name">${esc(
              space.name,
            )}</span><span class="row-meta">${sentenceList([
              plural(space.containerCount ?? 0, 'container'),
              plural(space.itemCount ?? 0, 'item'),
            ])}</span></span></a></li>`,
        )
        .join('')}</ul>
    </section>`);
  }

  if (data.recent.length) {
    const shown = recentExpanded ? data.recent : data.recent.slice(0, RECENT_SHOWN);
    const hidden = data.recent.length - shown.length;
    parts.push(`<section class="section" aria-labelledby="recent-title">
      <h2 class="section-title" id="recent-title">Recently added</h2>
      <div class="sheet"><ul class="list">${shown.map((item) => itemRow(item)).join('')}</ul>${
        hidden > 0
          ? `<div class="more-row"><button class="btn btn-quiet" type="button" data-more>Show ${hidden} more</button></div>`
          : ''
      }</div>
    </section>`);
  }

  if (!hasAnything) {
    parts.push(`<div class="empty"><h2>Nothing is stored here yet</h2>
      <p>Spaces, containers and items you add in the phone app show up here as soon as they are saved.</p></div>`);
  }
  return { html: parts.join(''), title: '' };
}

function searchSummary(data) {
  const parts = [];
  if (data.items.length) parts.push(plural(data.items.length, 'item'));
  if (data.locations.length) parts.push(plural(data.locations.length, 'place'));
  return parts.length ? `${sentenceList(parts)} found` : `Nothing found for ${data.q}`;
}

function searchView(data) {
  const direct = data.items.filter((item) => item.matchKind !== 'location');
  const byPlace = data.items.filter((item) => item.matchKind === 'location');
  const head = `<header class="view-head"><div><h1 class="view-title view-title-s" tabindex="-1">Results for “${esc(
    data.q,
  )}”</h1><p class="view-sub">${esc(searchSummary(data))}.</p></div></header>`;
  if (!data.items.length && !data.locations.length) {
    return {
      title: `“${data.q}”`,
      html: `<div class="empty"><h1 tabindex="-1">Nothing called “${esc(data.q)}”</h1>
        <p>Try fewer letters, the name of a space or container, or the code written on a box label, like BOX-7K2M.</p></div>`,
    };
  }
  const sections = [];
  const itemsSection = (title, list, id) =>
    `<section class="section" aria-labelledby="${id}"><h2 class="section-title" id="${id}">${title}<span class="count">${
      list.length
    }</span></h2><ul class="list sheet">${list
      .map((item) => itemRow(item, { terms: data.terms }))
      .join('')}</ul></section>`;
  if (direct.length) sections.push(itemsSection('Items', direct, 'hits-items'));
  if (data.locations.length) {
    sections.push(
      `<section class="section" aria-labelledby="hits-places"><h2 class="section-title" id="hits-places">Spaces and containers<span class="count">${
        data.locations.length
      }</span></h2><ul class="list sheet">${data.locations
        .map((hit) => placeRow(hit, data.terms))
        .join('')}</ul></section>`,
    );
  }
  if (byPlace.length) sections.push(itemsSection('Kept in those places', byPlace, 'hits-inside'));
  return { title: `“${data.q}”`, html: head + sections.join('') };
}

function spaceView(data) {
  const { space, containers } = data;
  const itemTotal = containers.reduce((sum, container) => sum + container.items.length, 0);
  const head = `<header class="view-head"><div class="view-head-main">${roomEmoji(space, 'l')}<div>
    <h1 class="view-title" tabindex="-1">${esc(space.name)}</h1>
    <p class="view-sub">${sentenceList([plural(containers.length, 'container'), plural(itemTotal, 'item')])}</p>
  </div></div></header>`;
  const body = containers.length
    ? `<ul class="list sheet">${containers.map(containerRow).join('')}</ul>`
    : `<div class="empty"><h2>No containers in ${esc(space.name)} yet</h2>
       <p>Add boxes, drawers and shelves to this space in the phone app, and they will show up here.</p></div>`;
  return { title: space.name, html: head + body };
}

function containerView(data) {
  if (data.drop) return dropZoneView(data);
  const { container, space, items } = data;
  const type = typeName(container.visualType);
  const title = container.name || `Unnamed ${type.toLowerCase()}`;
  const crumbs = space
    ? `<nav class="crumbs" aria-label="Breadcrumb"><a href="/space/${esc(space.id)}" data-link>${pip(
        space.color,
      )}${esc(space.name)}</a></nav>`
    : '';
  const head = `<header class="view-head container-head"><div>
      <h1 class="view-title" tabindex="-1">${esc(title)}</h1>
      <p class="view-sub">${esc(type)}${space ? ` in ${esc(space.name)}` : ''}, ${plural(items.length, 'item')}</p>
    </div><span class="tape tape-l" title="Label code">${esc(container.shortCode)}</span></header>`;
  const sorted = [...items].sort((a, b) =>
    titleOf(a).localeCompare(titleOf(b), 'en', { sensitivity: 'base' }),
  );
  const body = items.length
    ? `<ul class="list sheet">${sorted
        .map((item) => itemRow(item, { line: 'detail', tools: 'stepper' }))
        .join('')}</ul>`
    : `<div class="empty"><h2>This ${esc(type.toLowerCase())} is empty</h2>
       <p>Put things in it with the phone app, or open any item here and choose Move.</p></div>`;
  return { title: container.name || container.shortCode, html: crumbs + head + body };
}

function dropZoneView(data) {
  const count = data.items.length;
  const head = `<header class="view-head"><div class="view-head-main"><span class="thumb thumb-icon">${icon(
    'inbox',
  )}</span><div>
    <h1 class="view-title" tabindex="-1">Drop zone</h1>
    <p class="view-sub">${
      count
        ? `${plural(count, 'item')} photographed on the phone and not filed yet. Open one to name it, then file it.`
        : 'Items photographed with Quick Snap wait here until you give them a home.'
    }</p></div></div></header>`;
  const body = count
    ? `<ul class="list sheet list-photos">${data.items
        .map((item) => itemRow(item, { line: 'added', tools: 'file' }))
        .join('')}</ul>`
    : `<div class="empty"><h2>Everything is filed</h2>
       <p>New Quick Snap photos from the phone will land here.</p></div>`;
  return { title: 'Drop zone', html: head + body };
}

const VIEWS = { home: homeView, search: searchView, space: spaceView, container: containerView };

/* ---------- Selection and focus ---------- */

function markSelection() {
  const id = panelItem?.id ?? (el.panel.hidden ? null : parseUrl(currentUrl()).id);
  for (const link of el.main.querySelectorAll('[data-item]')) {
    if (link.dataset.item === id) link.setAttribute('aria-current', 'true');
    else link.removeAttribute('aria-current');
  }
}

/** Remember what had focus inside `root`, so a live refresh does not steal it. */
function captureFocus(root) {
  const active = document.activeElement;
  if (!active || !root.contains(active) || active === root) return null;
  const row = active.closest('[data-key]');
  const rows = [...root.querySelectorAll('[data-key]')];
  return {
    key: row?.dataset.key ?? null,
    index: row ? rows.indexOf(row) : -1,
    fk: active.dataset.fk ?? (active.tagName === 'H1' ? 'h1' : null),
    part: active.matches('[data-row]')
      ? '[data-row]'
      : active.dataset.qtyDelta
        ? `[data-qty-delta="${active.dataset.qtyDelta}"]`
        : active.matches('[data-file]')
          ? '[data-file]'
          : null,
  };
}

function restoreFocus(root, saved) {
  let target = null;
  if (saved.key) {
    const row = root.querySelector(`[data-key="${CSS.escape(saved.key)}"]`);
    if (row)
      target = (saved.part && row.querySelector(saved.part)) || row.querySelector('a, button');
    if (!target && saved.index >= 0) {
      // The row left (filed, moved away): carry on with the one that took its place.
      const rows = root.querySelectorAll('[data-key]');
      const next = rows[Math.min(saved.index, rows.length - 1)];
      target =
        (saved.part && next?.querySelector(saved.part)) ||
        next?.querySelector('[data-row]') ||
        null;
    }
  } else if (saved.fk) {
    target = root.querySelector(saved.fk === 'h1' ? 'h1' : `[data-fk="${saved.fk}"]`);
  }
  target?.focus({ preventScroll: true });
}

function moveRowFocus(from, direction) {
  const rows = [...el.main.querySelectorAll('[data-row]')];
  const index = rows.indexOf(from);
  const next = rows[index + direction];
  if (!next) {
    if (direction < 0) el.q.focus();
    return;
  }
  next.focus();
  next.scrollIntoView({ block: 'nearest' });
  // With the panel open beside the list, the panel follows the keyboard.
  if (!el.panel.hidden && docked.matches && next.dataset.item) openItem(next.dataset.item);
}

/* ---------- Item panel ---------- */

function showPanelChrome() {
  if (!el.panel.hidden) return;
  el.panel.hidden = false;
  el.app.classList.add('has-panel');
  el.panel.classList.add('is-entering');
  window.setTimeout(() => el.panel.classList.remove('is-entering'), 220);
  if (!docked.matches) document.body.classList.add('panel-overlay');
}

function hidePanel() {
  if (el.panel.hidden) return;
  stashDraft();
  const id = panelItem?.id;
  const hadFocus = el.panel.contains(document.activeElement);
  panelGen += 1;
  panelItem = null;
  panelMode = 'read';
  el.panel.hidden = true;
  el.panel.innerHTML = '';
  el.app.classList.remove('has-panel');
  document.body.classList.remove('panel-overlay');
  document.title = mainTitle;
  markSelection();
  if (hadFocus || document.activeElement === document.body) {
    const row = id && el.main.querySelector(`[data-item="${CSS.escape(id)}"]`);
    if (row) row.focus({ preventScroll: !docked.matches });
  }
}

async function showPanel(id, { quiet = false, focus = false } = {}) {
  const gen = ++panelGen;
  const switching = panelItem?.id !== id;
  if (switching) {
    stashDraft();
    panelMode = 'read';
  }
  showPanelChrome();
  const known = itemIndex.get(id);
  if (switching) {
    if (known) paintPanel(known);
    else {
      panelItem = null;
      el.panel.innerHTML = panelFrame('<div class="panel-empty"><p>Opening…</p></div>');
    }
    if (focus) focusPanel();
  }
  try {
    const item = await getItem(id);
    if (gen !== panelGen) return item;
    itemIndex.set(item.id, item);
    const changed = !panelItem || JSON.stringify(panelItem) !== JSON.stringify(item);
    // While someone is typing, leave panelItem alone: its updatedAt is what
    // makes a save notice a change made on a phone in the meantime.
    if (changed && !(quiet && isPanelBusy())) {
      const saved = captureFocus(el.panel);
      paintPanel(item);
      if (saved) restoreFocus(el.panel, saved);
    }
    return item;
  } catch (error) {
    if (gen !== panelGen || error.status === 401) return null;
    if (error.status === 404) {
      panelItem = null;
      drafts.delete(id);
      el.panel.innerHTML =
        panelFrame(`<div class="panel-empty"><h2 id="panel-title">This item is gone</h2>
        <p>It was deleted, probably on a phone. Nothing else changed.</p></div>`);
      markSelection();
    } else if (!panelItem) {
      el.panel.innerHTML =
        panelFrame(`<div class="panel-empty"><h2 id="panel-title">The item did not load</h2>
        <p>The household server did not answer. Check that it is running, then try again.</p>
        <p><button class="btn" type="button" data-retry-panel>Try again</button></p></div>`);
    }
    return null;
  }
}

/** True while the person is typing in the panel, so live refreshes wait. */
function isPanelBusy() {
  if (panelMode === 'edit' || el.moveDialog.open) return true;
  const nameInput = el.panel.querySelector('[data-name-form] input');
  return Boolean(nameInput && (nameInput.value || document.activeElement === nameInput));
}

function focusPanel() {
  const target =
    el.panel.querySelector('#panel-title[tabindex], [data-name-form] input') ||
    el.panel.querySelector('button');
  target?.focus({ preventScroll: true });
}

function panelFrame(body) {
  return `<div class="panel-head">
      <button class="btn btn-quiet panel-back" type="button" data-close-panel data-fk="back">${icon('back')}Back</button>
      <button class="icon-btn panel-close" type="button" data-close-panel data-fk="close" aria-label="Close item" title="Close (Esc)">${icon(
        'close',
      )}</button>
    </div>${body}`;
}

function paintPanel(item) {
  panelItem = item;
  const draft = drafts.get(item.id);
  if (draft) panelMode = 'edit';
  const photo = photoUrl(item, false);
  const figure = photo
    ? `<figure class="panel-photo"><button class="photo-btn" type="button" data-zoom data-fk="zoom" aria-label="Enlarge the photo of ${esc(
        titleOf(item),
      )}"><img src="${esc(photo)}" alt="" /></button></figure>`
    : '';
  const body = panelMode === 'edit' ? editForm(item, draft) : readBody(item);
  el.panel.innerHTML = panelFrame(`${figure}<div class="panel-body">${body}</div>`);
  document.title = `${titleOf(item)} – ${APP_NAME}`;
  markSelection();
}

function readBody(item) {
  const inDrop = item.containerId === DROP_ZONE_ID;
  const title = isNamed(item)
    ? `<h2 class="item-title" id="panel-title" tabindex="-1" data-fk="title">${esc(item.name)}</h2>`
    : `<h2 class="sr-only" id="panel-title">Item without a name</h2>
       <form class="name-it" data-name-form novalidate>
         <label class="field-label" for="name-it">What is it?</label>
         <div class="name-it-row">
           <input class="input" id="name-it" name="name" autocomplete="off" placeholder="Give it a name" data-fk="name-it" />
           <button class="btn btn-primary" type="submit">Save name</button>
         </div>
         <p class="form-error" data-error role="alert"></p>
       </form>`;
  const where = inDrop
    ? `<p class="where-path">${icon('inbox')}<a href="/container/${DROP_ZONE_ID}" data-link>Drop zone</a><span class="where-note">Not filed yet</span></p>`
    : `<p class="where-path">${pip(item.spaceColor)}<a href="/space/${esc(item.spaceId)}" data-link>${esc(
        item.spaceName,
      )}</a><span class="sep" aria-hidden="true">›</span><span class="sr-only">,</span><a href="/container/${esc(
        item.containerId,
      )}" data-link>${esc(item.containerName || item.containerShortCode)}</a></p>`;
  const facts = [];
  if (item.category) facts.push(`<div><dt>Category</dt><dd>${esc(item.category)}</dd></div>`);
  if (Array.isArray(item.tags) && item.tags.length) {
    facts.push(
      `<div><dt>Tags</dt><dd><ul class="chips">${item.tags
        .map((tag) => `<li class="chip">${esc(tag)}</li>`)
        .join('')}</ul></dd></div>`,
    );
  }
  if (item.notes) facts.push(`<div><dt>Notes</dt><dd class="notes">${esc(item.notes)}</dd></div>`);
  const changed = item.updatedAt - item.createdAt > 60_000;
  return `${title}
    <section class="where-card" aria-label="Where it is">
      ${where}
      <div class="where-foot">${inDrop ? '' : tape(item.containerShortCode)}
        <button class="btn btn-s${inDrop ? ' btn-primary' : ''}" type="button" data-move data-fk="move">${icon('move')}${
          inDrop ? 'File it…' : 'Move…'
        }</button>
      </div>
    </section>
    <div class="qty-row"><span class="field-label" aria-hidden="true">Quantity</span>${stepper(item, 'l')}</div>
    ${item.quantity === 0 ? '<p class="qty-note">None left right now</p>' : ''}
    ${facts.length ? `<dl class="facts">${facts.join('')}</dl>` : ''}
    <div class="panel-actions"><button class="btn" type="button" data-edit data-fk="edit">${icon(
      'edit',
    )}Edit details</button></div>
    <p class="stamp">Added ${esc(DATE_FORMAT.format(item.createdAt))}.${
      changed ? ` Last changed ${esc(ago(item.updatedAt))}.` : ''
    }</p>`;
}

function editForm(item, draft) {
  const values = draft || formValues(item);
  const categories = [
    ...new Set([...itemIndex.values()].map((entry) => entry.category).filter(Boolean)),
  ].sort((a, b) => a.localeCompare(b));
  return `<form class="form" data-edit-form novalidate>
    <h2 class="form-title" id="panel-title" tabindex="-1" data-fk="form-title">Edit details</h2>
    ${draft ? '<p class="notice">These are your unsaved changes from earlier.</p>' : ''}
    <div><label class="field-label" for="f-name">Name</label>
      <input class="input" id="f-name" name="name" autocomplete="off" value="${esc(values.name)}" /></div>
    <div><label class="field-label" for="f-category">Category</label>
      <input class="input" id="f-category" name="category" autocomplete="off" list="f-categories" value="${esc(
        values.category,
      )}" />
      <datalist id="f-categories">${categories.map((c) => `<option value="${esc(c)}"></option>`).join('')}</datalist></div>
    <div><label class="field-label" for="f-tags">Tags</label>
      <input class="input" id="f-tags" name="tags" autocomplete="off" value="${esc(values.tags)}" aria-describedby="f-tags-hint" />
      <p class="field-hint" id="f-tags-hint">Separate tags with commas.</p></div>
    <div><label class="field-label" for="f-notes">Notes</label>
      <textarea class="textarea" id="f-notes" name="notes" rows="4">${esc(values.notes)}</textarea></div>
    <p class="form-error" data-error role="alert"></p>
    <div class="form-actions">
      <button class="btn btn-primary" type="submit" data-fk="save">Save changes</button>
      <button class="btn" type="button" data-cancel-edit data-fk="cancel">Cancel</button>
      <span class="form-hint">Ctrl + Enter saves</span>
    </div>
  </form>`;
}

function formValues(item) {
  return {
    name: item.name || '',
    category: item.category || '',
    tags: Array.isArray(item.tags) ? item.tags.join(', ') : '',
    notes: item.notes || '',
  };
}

function readForm(form) {
  const data = new FormData(form);
  return {
    name: String(data.get('name') ?? ''),
    category: String(data.get('category') ?? ''),
    tags: String(data.get('tags') ?? ''),
    notes: String(data.get('notes') ?? ''),
  };
}

function isDirty(values, item) {
  const base = formValues(item);
  return Object.keys(base).some((key) => values[key].trim() !== base[key].trim());
}

/** Keep an unsaved edit when the panel moves on, instead of losing it. */
function stashDraft() {
  const form = el.panel.querySelector('[data-edit-form]');
  if (!form || !panelItem) return;
  const values = readForm(form);
  if (isDirty(values, panelItem)) {
    if (!drafts.has(panelItem.id))
      toast(`Unsaved changes to “${titleOf(panelItem)}” are kept for later`);
    drafts.set(panelItem.id, values);
  } else {
    drafts.delete(panelItem.id);
  }
}

function startEdit() {
  if (!panelItem) return;
  panelMode = 'edit';
  paintPanel(panelItem);
  const name = el.panel.querySelector('#f-name');
  name?.focus();
  name?.setSelectionRange(name.value.length, name.value.length);
}

function cancelEdit() {
  if (!panelItem) return;
  drafts.delete(panelItem.id);
  panelMode = 'read';
  paintPanel(panelItem);
  el.panel.querySelector('[data-edit]')?.focus();
}

async function saveEdit(form) {
  if (!panelItem || form.dataset.saving) return;
  const item = panelItem;
  const values = readForm(form);
  const error = form.querySelector('[data-error]');
  const name = values.name.trim();
  if (!name && isNamed(item)) {
    error.textContent = 'Give the item a name.';
    form.querySelector('#f-name').focus();
    return;
  }
  const body = {
    category: values.category.trim(),
    tags: values.tags
      .split(',')
      .map((tag) => tag.trim())
      .filter(Boolean),
    notes: values.notes.trim(),
    updatedAt: item.updatedAt,
  };
  if (name) body.name = name;
  form.dataset.saving = '1';
  form.querySelector('[type="submit"]').disabled = true;
  error.textContent = '';
  try {
    await patchItem(item.id, body);
    drafts.delete(item.id);
    panelMode = 'read';
    const fresh = await getItem(item.id);
    itemIndex.set(fresh.id, fresh);
    if (panelItem?.id === item.id) {
      paintPanel(fresh);
      el.panel.querySelector('[data-edit]')?.focus();
    }
    toast('Changes saved');
    refreshSoon();
  } catch (failure) {
    delete form.dataset.saving;
    form.querySelector('[type="submit"]').disabled = false;
    if (failure.status === 401) return;
    if (failure.status === 409) {
      try {
        const fresh = await getItem(item.id);
        itemIndex.set(fresh.id, fresh);
        panelItem = fresh;
      } catch {
        /* keep what was typed either way */
      }
      error.textContent =
        'Someone changed this item on another device while you were editing. Save again to keep your version, or cancel to see theirs.';
      return;
    }
    error.textContent = 'The changes were not saved. They are still here, so try again.';
  }
}

async function saveName(form) {
  if (!panelItem || form.dataset.saving) return;
  const input = form.querySelector('input');
  const error = form.querySelector('[data-error]');
  const name = input.value.trim();
  if (!name) {
    error.textContent = 'Type a name first.';
    input.focus();
    return;
  }
  form.dataset.saving = '1';
  error.textContent = '';
  let item = panelItem;
  try {
    try {
      await patchItem(item.id, { name, updatedAt: item.updatedAt });
    } catch (failure) {
      if (failure.status !== 409) throw failure;
      item = await getItem(item.id);
      if (isNamed(item)) {
        itemIndex.set(item.id, item);
        paintPanel(item);
        toast(`It was just named “${item.name}” on another device`);
        return;
      }
      await patchItem(item.id, { name, updatedAt: item.updatedAt });
    }
    const fresh = await getItem(item.id);
    itemIndex.set(fresh.id, fresh);
    if (panelItem?.id === fresh.id) {
      paintPanel(fresh);
      el.panel
        .querySelector(fresh.containerId === DROP_ZONE_ID ? '[data-move]' : '[data-edit]')
        ?.focus();
    }
    refreshSoon();
  } catch (failure) {
    delete form.dataset.saving;
    if (failure.status === 401) return;
    error.textContent = 'The name was not saved. Try again.';
  }
}

/* ---------- Move ---------- */

function openMove(item) {
  if (!item) return;
  const filing = item.containerId === DROP_ZONE_ID;
  const label = isNamed(item) ? `“${item.name}”` : 'this item';
  moveContext = { item, active: -1, options: [], filing };
  el.moveTitle.textContent = filing ? `File ${label}` : `Move ${label}`;
  el.moveQ.value = '';
  el.moveError.textContent = '';
  el.moveList.removeAttribute('aria-busy');
  renderMoveOptions();
  el.moveDialog.showModal();
  el.moveQ.focus();
}

function renderMoveOptions() {
  const ctx = moveContext;
  if (!ctx) return;
  const terms = compact(el.moveQ.value).split(/\s+/).filter(Boolean);
  const raw = el.moveQ.value.trim();
  ctx.options = [];
  const groups = [];
  for (const space of tree.spaces) {
    const matches = tree.containers
      .filter((container) => container.spaceId === space.id)
      .filter((container) => {
        const hay = compact(
          `${container.name || ''} ${container.shortCode} ${space.name} ${typeName(container.visualType)}`,
        );
        return terms.every((term) => hay.includes(term));
      })
      .sort(byLabel);
    if (!matches.length) continue;
    const options = matches.map((container) => {
      const index = ctx.options.length;
      const here = container.id === ctx.item.containerId;
      ctx.options.push({ id: container.id, disabled: here });
      return `<div class="move-option" role="option" id="move-opt-${index}" data-move-to="${esc(
        container.id,
      )}" aria-selected="false"${here ? ' aria-disabled="true"' : ''}>
        ${typeIcon(container.visualType)}
        <span class="move-option-name">${esc(containerLabel(container))}${
          here ? '<span class="move-here">Here now</span>' : ''
        }</span>
        ${tape(container.shortCode, 's')}
      </div>`;
    });
    groups.push(`<div role="group" aria-labelledby="move-g-${esc(space.id)}">
      <p class="move-group-title" id="move-g-${esc(space.id)}">${pip(space.color)}${esc(space.name)}</p>
      ${options.join('')}</div>`);
  }
  if (!tree.containers.length) {
    el.moveList.innerHTML =
      '<p class="move-empty">There are no containers yet. Create one in the phone app first.</p>';
  } else if (!groups.length) {
    el.moveList.innerHTML = `<p class="move-empty">No container matches “${esc(raw)}”.</p>`;
  } else {
    el.moveList.innerHTML = groups.join('');
  }
  ctx.active = raw ? ctx.options.findIndex((option) => !option.disabled) : -1;
  syncMoveActive();
}

function syncMoveActive() {
  const ctx = moveContext;
  for (const node of el.moveList.querySelectorAll('[role="option"]')) {
    node.setAttribute('aria-selected', 'false');
  }
  if (!ctx || ctx.active < 0) {
    el.moveQ.removeAttribute('aria-activedescendant');
    return;
  }
  const node = $(`move-opt-${ctx.active}`);
  node?.setAttribute('aria-selected', 'true');
  node?.scrollIntoView({ block: 'nearest' });
  el.moveQ.setAttribute('aria-activedescendant', `move-opt-${ctx.active}`);
}

function stepMoveActive(direction) {
  const ctx = moveContext;
  if (!ctx || !ctx.options.length) return;
  let index = ctx.active;
  for (let tries = 0; tries < ctx.options.length; tries += 1) {
    index = index < 0 ? (direction > 0 ? 0 : ctx.options.length - 1) : index + direction;
    if (index < 0 || index >= ctx.options.length) return;
    if (!ctx.options[index].disabled) break;
  }
  if (ctx.options[index]?.disabled) return;
  ctx.active = index;
  syncMoveActive();
}

async function chooseMove(containerId) {
  const ctx = moveContext;
  if (!ctx || containerId === ctx.item.containerId || el.moveList.getAttribute('aria-busy')) return;
  el.moveList.setAttribute('aria-busy', 'true');
  el.moveError.textContent = '';
  const before = ctx.item;
  try {
    let updated;
    try {
      updated = await patchItem(before.id, { containerId, updatedAt: before.updatedAt });
    } catch (failure) {
      if (failure.status !== 409) throw failure;
      // Changed elsewhere since it was opened. Only retry when it is still where we think.
      const fresh = await getItem(before.id);
      itemIndex.set(fresh.id, fresh);
      if (fresh.containerId !== before.containerId) {
        ctx.item = fresh;
        el.moveList.removeAttribute('aria-busy');
        renderMoveOptions();
        el.moveError.textContent = `Someone already moved it to ${
          fresh.containerName || fresh.containerShortCode
        } on another device.`;
        return;
      }
      updated = await patchItem(before.id, { containerId, updatedAt: fresh.updatedAt });
    }
    el.moveDialog.close();
    afterMove(before, containerId, updated, ctx);
  } catch (failure) {
    el.moveList.removeAttribute('aria-busy');
    if (failure.status === 401) return;
    el.moveError.textContent = 'It was not moved. Check the connection and try again.';
  }
}

function afterMove(before, containerId, updated, ctx) {
  const container = containerById(containerId);
  const space = container ? spaceById(container.spaceId) : null;
  const where = container
    ? `${containerLabel(container)}${space ? ` (${space.name})` : ''}`
    : 'its new container';
  toast(`${ctx.filing ? 'Filed in' : 'Moved to'} ${where}`, {
    action: { label: 'Undo', run: () => undoMove(before, updated.updatedAt) },
  });
  const openHere = panelItem?.id === before.id;
  // Filing the drop zone from the panel: go straight to the next thing waiting.
  if (openHere && ctx.filing && mainRoute?.name === 'container' && mainRoute.id === DROP_ZONE_ID) {
    const list = viewCache.get(mainUrl)?.items || [];
    const at = list.findIndex((item) => item.id === before.id);
    const next =
      list.slice(at + 1).find((item) => item.containerId === DROP_ZONE_ID) ||
      list.slice(0, Math.max(at, 0)).find((item) => item.containerId === DROP_ZONE_ID);
    if (next) openItem(next.id, { focusPanel: true });
    else closePanel();
  } else if (openHere) {
    showPanel(before.id, { quiet: false });
  }
  refreshSoon(0);
}

async function undoMove(before, updatedAt) {
  try {
    await patchItem(before.id, { containerId: before.containerId, updatedAt });
    toast('Move undone');
    if (panelItem?.id === before.id) showPanel(before.id);
    refreshSoon(0);
  } catch (failure) {
    if (failure.status === 401) return;
    toast(
      failure.status === 409
        ? 'It could not be undone because the item changed again since.'
        : 'It could not be undone. Check the connection and try again.',
      { tone: 'error' },
    );
  }
}

el.moveQ.addEventListener('input', renderMoveOptions);
el.moveQ.addEventListener('keydown', (event) => {
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault();
    stepMoveActive(event.key === 'ArrowDown' ? 1 : -1);
  } else if (event.key === 'Enter') {
    event.preventDefault();
    const option = moveContext?.options[moveContext.active];
    if (option && !option.disabled) chooseMove(option.id);
  }
});
el.moveList.addEventListener('click', (event) => {
  const option = event.target.closest('[data-move-to]');
  if (option && option.getAttribute('aria-disabled') !== 'true') chooseMove(option.dataset.moveTo);
});
el.moveDialog.addEventListener('close', () => {
  moveContext = null;
  if (document.activeElement && document.activeElement !== document.body) return;
  (el.panel.querySelector('[data-move]') || el.main.querySelector('[data-row]'))?.focus();
});

/* ---------- Photo ---------- */

function openPhoto() {
  if (!panelItem?.photoId) return;
  el.photoFull.src = photoUrl(panelItem, false);
  el.photoFull.alt = `Photo of ${titleOf(panelItem)}`;
  el.photoDialog.showModal();
}

el.photoDialog.addEventListener('click', () => el.photoDialog.close());
el.photoDialog.addEventListener('close', () => {
  if (document.activeElement && document.activeElement !== document.body) return;
  el.panel.querySelector('[data-zoom]')?.focus();
});

function closeDialogs() {
  if (el.moveDialog.open) el.moveDialog.close();
  if (el.photoDialog.open) el.photoDialog.close();
}

/* ---------- Quantity ---------- */

function clampQty(value) {
  if (!Number.isInteger(value)) return QTY_MIN;
  return Math.min(QTY_MAX, Math.max(QTY_MIN, value));
}

function stepper(item, size = '') {
  const rec = qtyWrites.get(item.id);
  const qty = clampQty(
    rec ? (rec.pending ?? rec.quantity) : Number.isInteger(item.quantity) ? item.quantity : 1,
  );
  const updated = rec?.updatedAt ?? item.updatedAt;
  const label = esc(titleOf(item));
  return `<div class="stepper${size ? ` stepper-${size}` : ''}${qty === 0 ? ' is-zero' : ''}" data-qty-item="${esc(
    item.id,
  )}" data-updated="${esc(updated)}">
    <button type="button" class="stepper-btn" data-qty-delta="-1" data-fk="qty-down" aria-label="Decrease quantity of ${label}"${
      qty <= QTY_MIN ? ' disabled' : ''
    }>${icon('minus')}</button>
    <input class="stepper-num" type="text" inputmode="numeric" pattern="[0-9]*" enterkeyhint="done" autocomplete="off" aria-label="Quantity of ${label}" value="${qty}" />
    <button type="button" class="stepper-btn" data-qty-delta="1" data-fk="qty-up" aria-label="Increase quantity of ${label}"${
      qty >= QTY_MAX ? ' disabled' : ''
    }>${icon('plus')}</button>
  </div>`;
}

function qtyBusy() {
  for (const rec of qtyWrites.values()) {
    if (rec.inFlight || rec.pending !== null) return true;
  }
  return false;
}

/** Settled records only describe the past; fresh data wins after a repaint. */
function pruneQty() {
  for (const [id, rec] of qtyWrites) {
    if (!rec.inFlight && rec.pending === null) qtyWrites.delete(id);
  }
}

function qtyRecord(id, root) {
  let rec = qtyWrites.get(id);
  if (!rec) {
    const shown = Number(root.querySelector('.stepper-num')?.value);
    rec = {
      quantity: Number.isInteger(shown) ? shown : QTY_MIN,
      updatedAt: Number(root.dataset.updated),
      pending: null,
      inFlight: false,
    };
    qtyWrites.set(id, rec);
  }
  return rec;
}

/** Paint a quantity into every stepper showing this item (a row and the panel). */
function syncQty(id, quantity, updatedAt) {
  for (const root of document.querySelectorAll(`[data-qty-item="${CSS.escape(id)}"]`)) {
    root.dataset.updated = String(updatedAt);
    root.classList.toggle('is-zero', quantity === 0);
    const input = root.querySelector('.stepper-num');
    if (input && document.activeElement !== input) input.value = String(quantity);
    const minus = root.querySelector('[data-qty-delta="-1"]');
    const plus = root.querySelector('[data-qty-delta="1"]');
    if (minus) minus.disabled = quantity <= QTY_MIN;
    if (plus) plus.disabled = quantity >= QTY_MAX;
  }
  const known = itemIndex.get(id);
  if (known) itemIndex.set(id, { ...known, quantity, updatedAt });
  if (panelItem?.id === id) {
    panelItem = { ...panelItem, quantity, updatedAt };
    const note = el.panel.querySelector('.qty-note');
    if (quantity === 0 && !note) {
      el.panel
        .querySelector('.qty-row')
        ?.insertAdjacentHTML('afterend', '<p class="qty-note">None left right now</p>');
    } else if (quantity !== 0) {
      note?.remove();
    }
  }
}

/**
 * Save the latest wanted quantity, one request at a time per item.
 * Taps made while a request is out collapse into the next one. A conflict
 * refetches the item and re-applies the wanted value: the person's tap wins.
 */
async function flushQty(id) {
  const rec = qtyWrites.get(id);
  if (!rec || rec.inFlight || rec.pending === null) return;
  const target = rec.pending;
  if (target === rec.quantity) {
    rec.pending = null;
    return;
  }
  rec.inFlight = true;
  try {
    const updated = await patchItem(id, { quantity: target, updatedAt: rec.updatedAt });
    rec.quantity = updated.quantity;
    rec.updatedAt = updated.updatedAt;
    if (rec.pending === target) rec.pending = null;
    rec.inFlight = false;
    syncQty(id, rec.pending ?? rec.quantity, rec.updatedAt);
  } catch (error) {
    rec.inFlight = false;
    if (error.status === 401) return;
    if (error.status === 409) {
      try {
        const fresh = await getItem(id);
        rec.quantity = fresh.quantity;
        rec.updatedAt = fresh.updatedAt;
      } catch {
        rec.pending = null;
        syncQty(id, rec.quantity, rec.updatedAt);
        toast('The quantity was not saved. Try again.', { tone: 'error' });
        return;
      }
    } else {
      rec.pending = null;
      syncQty(id, rec.quantity, rec.updatedAt);
      toast('The quantity was not saved. Check the connection and try again.', { tone: 'error' });
      return;
    }
  }
  if (rec.pending !== null) await flushQty(id);
  else refreshSoon();
}

function stepQty(root, delta) {
  if (!root) return;
  const id = root.dataset.qtyItem;
  const rec = qtyRecord(id, root);
  const current = rec.pending ?? rec.quantity;
  const next = clampQty(current + delta);
  if (next === current) return;
  rec.pending = next;
  syncQty(id, next, rec.updatedAt);
  flushQty(id);
}

function commitQtyInput(root) {
  const id = root.dataset.qtyItem;
  const input = root.querySelector('.stepper-num');
  const raw = (input?.value ?? '').trim();
  const parsed = Number(raw);
  const rec = qtyRecord(id, root);
  if (raw === '' || !Number.isInteger(parsed) || parsed < QTY_MIN) {
    input.value = String(rec.pending ?? rec.quantity);
    return;
  }
  rec.pending = clampQty(parsed);
  syncQty(id, rec.pending, rec.updatedAt);
  flushQty(id);
}

function stopQtyRepeat() {
  if (!qtyRepeat) return;
  window.clearTimeout(qtyRepeat.timeout);
  window.clearInterval(qtyRepeat.interval);
  qtyRepeat = null;
}

function startQtyRepeat(button) {
  stopQtyRepeat();
  const root = button.closest('[data-qty-item]');
  const delta = Number(button.dataset.qtyDelta);
  stepQty(root, delta);
  qtyRepeat = {
    timeout: window.setTimeout(() => {
      qtyRepeat.interval = window.setInterval(() => stepQty(root, delta), 80);
    }, 400),
  };
}

document.addEventListener('pointerdown', (event) => {
  const button = event.target.closest('[data-qty-delta]');
  if (!button || button.disabled || event.button !== 0) return;
  event.preventDefault();
  startQtyRepeat(button);
});
document.addEventListener('pointerup', stopQtyRepeat);
document.addEventListener('pointercancel', stopQtyRepeat);
window.addEventListener('blur', stopQtyRepeat);

document.addEventListener('change', (event) => {
  if (event.target.classList?.contains('stepper-num')) {
    commitQtyInput(event.target.closest('[data-qty-item]'));
  }
});

/* ---------- Toasts ---------- */

function toast(message, { action = null, tone = 'info' } = {}) {
  const node = document.createElement('div');
  node.className = `toast${tone === 'error' ? ' is-error' : ''}`;
  if (tone === 'error') node.setAttribute('role', 'alert');
  node.innerHTML = `<span class="toast-text">${esc(message)}</span>${
    action ? `<button class="toast-action" type="button">${esc(action.label)}</button>` : ''
  }<button class="icon-btn" type="button" aria-label="Dismiss">${icon('close')}</button>`;
  let timer = 0;
  const dismiss = () => {
    window.clearTimeout(timer);
    node.remove();
  };
  const arm = () => {
    window.clearTimeout(timer);
    timer = window.setTimeout(dismiss, action ? 9000 : 5000);
  };
  node.querySelector('.toast-action')?.addEventListener('click', () => {
    dismiss();
    action.run();
  });
  node.querySelector('.icon-btn').addEventListener('click', dismiss);
  node.addEventListener('pointerenter', () => window.clearTimeout(timer));
  node.addEventListener('pointerleave', arm);
  node.addEventListener('focusin', () => window.clearTimeout(timer));
  node.addEventListener('focusout', arm);
  el.toasts.append(node);
  while (el.toasts.children.length > 3) el.toasts.firstElementChild.remove();
  arm();
}

/* ---------- Live updates ---------- */

function refreshSoon(delay = 250) {
  window.clearTimeout(refreshTimer);
  refreshTimer = window.setTimeout(refreshAll, delay);
}

async function refreshAll() {
  if (locked) return;
  if (qtyBusy() || document.activeElement?.classList.contains('stepper-num')) {
    refreshSoon(800);
    return;
  }
  try {
    await loadTree();
  } catch {
    return;
  }
  if (mainUrl) showMain(mainUrl, { quiet: true });
  if (panelItem && !isPanelBusy()) showPanel(panelItem.id, { quiet: true });
}

function setLive(ok) {
  window.clearTimeout(liveTimer);
  if (ok) {
    el.liveState.hidden = true;
    return;
  }
  // Brief blips are normal (laptop sleep, tunnel hiccup). Only say so if it lasts.
  liveTimer = window.setTimeout(() => {
    el.liveState.hidden = false;
  }, 2500);
}

function startEvents() {
  if (events) return;
  events = new EventSource('/v1/events', { withCredentials: true });
  events.addEventListener('open', () => setLive(true));
  events.addEventListener('change', (event) => {
    setLive(true);
    let revision = null;
    try {
      revision = JSON.parse(event.data).revision;
    } catch {
      /* treat as a change */
    }
    if (knownRevision === null) {
      knownRevision = revision;
      return;
    }
    if (revision !== null && revision === knownRevision) return;
    knownRevision = revision;
    refreshSoon();
  });
  events.addEventListener('error', () => {
    if (!events) return;
    setLive(false);
    if (events.readyState === EventSource.CLOSED) {
      // The browser gave up (often a 401). Check the session, then try again.
      stopEvents();
      api('/v1/web/me')
        .then(() => window.setTimeout(startEvents, 3000))
        .catch(() => window.setTimeout(() => !locked && startEvents(), 10000));
    }
  });
}

function stopEvents() {
  events?.close();
  events = null;
}

/* ---------- Search ---------- */

function runSearch() {
  window.clearTimeout(searchTimer);
  const text = el.q.value.trim();
  const route = parseUrl(currentUrl());
  if (!text) {
    if (route.name === 'search') clearSearch();
    return;
  }
  const target = `/?q=${encodeURIComponent(text)}`;
  if (target === currentUrl()) return;
  if (route.name === 'search') history.replaceState(history.state, '', target);
  else history.pushState({ searchFrom: mainUrl || '/' }, '', target);
  render();
}

function clearSearch() {
  el.q.value = '';
  if (history.state?.searchFrom) history.back();
  else {
    history.replaceState(null, '', '/');
    render();
  }
}

el.q.addEventListener('input', () => {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(runSearch, 140);
});
el.q.addEventListener('search', () => {
  if (!el.q.value) runSearch();
});
el.searchForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  runSearch();
  if (!docked.matches) {
    el.q.blur();
    return;
  }
  // At the desk, Enter opens the best match.
  await mainLoad;
  el.main.querySelector('[data-row]')?.click();
});

/* ---------- Clicks and keys ---------- */

document.addEventListener('click', (event) => {
  const target = event.target;
  if (!(target instanceof Element) || locked) return;

  const qtyButton = target.closest('[data-qty-delta]');
  if (qtyButton) {
    // Pointer taps are handled on pointerdown (with hold-to-repeat); this is Enter/Space.
    if (event.detail === 0)
      stepQty(qtyButton.closest('[data-qty-item]'), Number(qtyButton.dataset.qtyDelta));
    return;
  }
  const itemLink = target.closest('a[data-item]');
  if (itemLink) {
    if (!isPlainClick(event)) return;
    event.preventDefault();
    if (!el.panel.hidden && parseUrl(currentUrl()).id === itemLink.dataset.item) {
      focusPanel();
      return;
    }
    itemLink.focus({ preventScroll: true });
    // An item with no name is opened to be named: put the cursor there.
    const known = itemIndex.get(itemLink.dataset.item);
    openItem(itemLink.dataset.item, { focusPanel: !docked.matches || (known && !isNamed(known)) });
    return;
  }
  const link = target.closest('a[data-link]');
  if (link) {
    if (!isPlainClick(event)) return;
    event.preventDefault();
    go(link.getAttribute('href'));
    return;
  }
  if (target.closest('[data-close-panel]')) closePanel();
  else if (target.closest('[data-edit]')) startEdit();
  else if (target.closest('[data-cancel-edit]')) cancelEdit();
  else if (target.closest('[data-move]')) openMove(panelItem);
  else if (target.closest('[data-file]'))
    openMove(itemIndex.get(target.closest('[data-file]').dataset.file));
  else if (target.closest('[data-zoom]')) openPhoto();
  else if (target.closest('[data-close-dialog]')) target.closest('dialog')?.close();
  else if (target.closest('[data-retry]')) showMain(mainUrl || currentUrl(), { force: true });
  else if (target.closest('[data-retry-panel]') && parseUrl(currentUrl()).name === 'item') render();
  else if (target.closest('[data-more]')) {
    recentExpanded = true;
    const data = viewCache.get(mainUrl);
    if (data && mainRoute) paint(mainRoute, data, { preserve: true });
  }
});

document.addEventListener('submit', (event) => {
  const form = event.target;
  if (form.matches('[data-edit-form]')) {
    event.preventDefault();
    saveEdit(form);
  } else if (form.matches('[data-name-form]')) {
    event.preventDefault();
    saveName(form);
  }
});

document.addEventListener('input', (event) => {
  const form = event.target.closest?.('[data-edit-form]');
  if (form) form.querySelector('[data-error]').textContent = '';
});

function goUp() {
  const route = mainRoute;
  if (!route) return;
  if (route.name === 'container') {
    const container = route.id === DROP_ZONE_ID ? null : containerById(route.id);
    go(container ? `/space/${encodeURIComponent(container.spaceId)}` : '/');
  } else if (route.name === 'space') {
    go('/');
  }
}

function onEscape(event) {
  if (el.app.classList.contains('rail-open')) {
    closeRail();
    el.railToggle.focus();
    return;
  }
  const form = el.panel.querySelector('[data-edit-form]');
  if (form && !el.panel.hidden) {
    if (isDirty(readForm(form), panelItem)) {
      form.querySelector('[data-error]').textContent =
        'You have unsaved changes. Save them, or choose Cancel to throw them away.';
      return;
    }
    cancelEdit();
    return;
  }
  if (!el.panel.hidden) {
    closePanel();
    return;
  }
  if (event.target === el.q) {
    if (el.q.value) clearSearch();
    else el.q.blur();
    return;
  }
  if (!isField(event.target)) goUp();
}

document.addEventListener('keydown', (event) => {
  if (locked || el.app.hidden) return;
  if (el.moveDialog.open || el.photoDialog.open) return;
  const target = event.target;

  if (event.key === 'Escape') {
    onEscape(event);
    return;
  }
  const searchKey =
    (event.key === '/' && !isField(target) && !event.metaKey && !event.ctrlKey) ||
    ((event.key || '').toLowerCase() === 'k' && (event.metaKey || event.ctrlKey));
  if (searchKey) {
    event.preventDefault();
    closeRail();
    el.q.focus();
    el.q.select();
    return;
  }
  if (target === el.q && event.key === 'ArrowDown') {
    const first = el.main.querySelector('[data-row]');
    if (first) {
      event.preventDefault();
      first.focus();
    }
    return;
  }
  if (target.matches?.('[data-row]') && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
    event.preventDefault();
    moveRowFocus(target, event.key === 'ArrowDown' ? 1 : -1);
    return;
  }
  if (target.classList?.contains('stepper-num')) {
    const root = target.closest('[data-qty-item]');
    if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
      event.preventDefault();
      stepQty(root, event.key === 'ArrowUp' ? 1 : -1);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      target.blur();
    }
    return;
  }
  if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
    const form = target.closest?.('[data-edit-form]');
    if (form) {
      event.preventDefault();
      saveEdit(form);
    }
  }
});

/* Photos that fail to load fall back to the placeholder underneath. */
document.addEventListener(
  'error',
  (event) => {
    const img = event.target;
    if (!(img instanceof HTMLImageElement)) return;
    if (img.closest('.panel-photo')) img.closest('.panel-photo').classList.add('is-missing');
    else if (img.closest('.thumb')) img.remove();
  },
  true,
);

function fitPlaceholder() {
  el.q.placeholder = docked.matches ? 'Find an item, a space or a label code' : 'Find anything';
}

docked.addEventListener('change', () => {
  document.body.classList.toggle('panel-overlay', !el.panel.hidden && !docked.matches);
  if (docked.matches) closeRail();
  fitPlaceholder();
});
fitPlaceholder();

/* ---------- Start ---------- */

(async () => {
  if (location.hash.startsWith('#item/')) {
    history.replaceState(null, '', itemUrl(decodeURIComponent(location.hash.slice(6))));
  }
  try {
    const response = await fetch('/v1/web/me', { credentials: 'same-origin' });
    if (!response.ok) {
      showGate();
      return;
    }
    const me = await response.json().catch(() => ({}));
    if (me.householdName) tree.householdName = me.householdName;
    await enter();
  } catch {
    showGate('The household server did not answer. Check that it is running, then reload.');
  }
})();
