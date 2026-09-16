/* Household desk page. Capture stays on the phone. */
'use strict';

const DROP_ZONE_ID = 'drop-zone';
const CONTAINER_ICONS = {
  box: '📦',
  drawer: '🗄️',
  shelf: '🗂️',
  cabinet: '🚪',
  bin: '🗑️',
  bag: '👜',
  crate: '🧰',
  other: '📥',
};

const gate = document.getElementById('gate');
const app = document.getElementById('app');
const loginForm = document.getElementById('login');
const password = document.getElementById('password');
const loginError = document.getElementById('login-error');
const q = document.getElementById('q');
const results = document.getElementById('results');
const browse = document.getElementById('browse');
const status = document.getElementById('status');
const searchView = document.getElementById('search-view');
const spaceView = document.getElementById('space-view');
const containerView = document.getElementById('container-view');
const itemView = document.getElementById('item-view');
const spaceEl = document.getElementById('space');
const containerEl = document.getElementById('container');
const itemRead = document.getElementById('item-read');
const editForm = document.getElementById('edit-form');
const editName = document.getElementById('edit-name');
const editCategory = document.getElementById('edit-category');
const editTags = document.getElementById('edit-tags');
const editQuantity = document.getElementById('edit-quantity');
editQuantity.min = '0';
const editQtyDec = document.getElementById('edit-qty-dec');
const editQtyInc = document.getElementById('edit-qty-inc');
const editNotes = document.getElementById('edit-notes');
const editError = document.getElementById('edit-error');
const editSave = document.getElementById('edit-save');
const movePanel = document.getElementById('move-panel');
const moveList = document.getElementById('move-list');
const moveError = document.getElementById('move-error');

const VIEWS = {
  home: searchView,
  space: spaceView,
  container: containerView,
  item: itemView,
};

let currentItem = null;
let containerContext = null;
let editDirty = false;
let saving = false;
let searchTimer = 0;
let searchGen = 0;
let renderGen = 0;
let events = null;
const qtyWrites = new Map();
const QTY_MIN = 0;
const QTY_MAX = 9999;
let qtyRepeat = null;

function esc(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function loc(item) {
  return [item.spaceName, item.containerName || item.containerShortCode]
    .filter(Boolean)
    .join(' / ');
}

function photoUrl(item, thumb) {
  return item.photoId
    ? `/v1/photos/${encodeURIComponent(item.photoId)}${thumb ? '?thumb=1' : ''}`
    : '';
}

function titleOf(item) {
  return item.name && item.name.trim() ? item.name : 'Needs a name';
}

function luminance(hex) {
  const value = String(hex || '').replace('#', '');
  const full =
    value.length === 3
      ? value
          .split('')
          .map((c) => c + c)
          .join('')
      : value;
  if (full.length !== 6) return 0;
  const channel = (offset) => {
    const srgb = parseInt(full.slice(offset, offset + 2), 16) / 255;
    return srgb <= 0.03928 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(0) + 0.7152 * channel(2) + 0.0722 * channel(4);
}

function onColor(hex) {
  const background = luminance(hex);
  const ratio = (a, b) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  return ratio(luminance('#FFFFFF'), background) >= ratio(luminance('#12161C'), background)
    ? '#FFFFFF'
    : '#12161C';
}

function counts(n, noun) {
  return `${n} ${noun}${n === 1 ? '' : 's'}`;
}

async function api(path, init = {}) {
  const response = await fetch(path, { credentials: 'same-origin', ...init });
  if (response.status === 401) throw Object.assign(new Error('unauthorized'), { status: 401 });
  if (response.status === 409) {
    const body = await response.json().catch(() => ({}));
    throw Object.assign(new Error('conflict'), { status: 409, updatedAt: body.updatedAt });
  }
  if (response.status === 404) throw Object.assign(new Error('not_found'), { status: 404 });
  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    throw Object.assign(new Error(body.error || 'request failed'), { status: response.status });
  }
  if (response.status === 204) return {};
  return response.json();
}

function showLoggedOut() {
  stopEvents();
  closeEditors();
  app.classList.add('hidden');
  gate.classList.remove('hidden');
  password.focus();
}

function showLoggedIn() {
  gate.classList.add('hidden');
  app.classList.remove('hidden');
  startEvents();
}

function showView(name) {
  for (const [key, el] of Object.entries(VIEWS)) {
    el.classList.toggle('hidden', key !== name);
  }
}

function parseRoute() {
  const path = location.pathname.replace(/\/+$/, '') || '/';
  const query = new URLSearchParams(location.search).get('q') ?? '';
  const item = /^\/item\/([^/]+)$/.exec(path);
  if (item) return { name: 'item', id: decodeURIComponent(item[1]) };
  const space = /^\/space\/([^/]+)$/.exec(path);
  if (space) return { name: 'space', id: decodeURIComponent(space[1]) };
  const container = /^\/container\/([^/]+)$/.exec(path);
  if (container) return { name: 'container', id: decodeURIComponent(container[1]) };
  return { name: 'home', q: query };
}

function navigate(path) {
  const url = path || '/';
  if (url !== location.pathname + location.search) history.pushState(null, '', url);
  closeEditors();
  render();
}

function qtySuffix(item) {
  return item.quantity != null && item.quantity !== 1 ? ` · Qty ${item.quantity}` : '';
}

function clampQty(value) {
  if (!Number.isInteger(value)) return QTY_MIN;
  if (value < QTY_MIN) return QTY_MIN;
  if (value > QTY_MAX) return QTY_MAX;
  return value;
}

function qtyBusy() {
  for (const rec of qtyWrites.values()) {
    if (rec.inFlight || rec.pending !== null) return true;
  }
  return false;
}

function qtyStepper(item, compact) {
  const qty = clampQty(Number.isInteger(item.quantity) ? item.quantity : 1);
  return `<div class="qty${compact ? ' compact' : ''}" data-qty-item="${esc(item.id)}" data-updated="${esc(item.updatedAt)}">
    <button type="button" class="qty-btn" data-qty-delta="-1" aria-label="Decrease quantity"${
      qty <= QTY_MIN ? ' disabled' : ''
    }>−</button>
    <input class="qty-num" inputmode="numeric" enterkeyhint="done" aria-label="Quantity" value="${esc(qty)}" />
    <button type="button" class="qty-btn" data-qty-delta="1" aria-label="Increase quantity"${
      qty >= QTY_MAX ? ' disabled' : ''
    }>+</button>
  </div>`;
}

function applyQtyDom(root, quantity, updatedAt) {
  if (!root) return;
  root.dataset.updated = String(updatedAt);
  const input = root.querySelector('.qty-num');
  if (input && document.activeElement !== input) input.value = String(quantity);
  const minus = root.querySelector('[data-qty-delta="-1"]');
  const plus = root.querySelector('[data-qty-delta="1"]');
  if (minus) minus.disabled = quantity <= QTY_MIN;
  if (plus) plus.disabled = quantity >= QTY_MAX;
}

function qtyRecord(id, quantity, updatedAt) {
  let rec = qtyWrites.get(id);
  if (!rec) {
    rec = { quantity, updatedAt, pending: null, inFlight: false };
    qtyWrites.set(id, rec);
  }
  return rec;
}

async function flushSavedQuantity(id, root) {
  const rec = qtyWrites.get(id);
  if (!rec || rec.inFlight) return;
  const target = rec.pending;
  if (target === null) return;
  if (target === rec.quantity) {
    rec.pending = null;
    return;
  }
  rec.inFlight = true;
  try {
    const updated = await api(`/v1/items/${encodeURIComponent(id)}`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ quantity: target, updatedAt: rec.updatedAt }),
    });
    rec.quantity = updated.quantity;
    rec.updatedAt = updated.updatedAt;
    rec.pending = rec.pending === target ? null : rec.pending;
    applyQtyDom(root, rec.pending ?? rec.quantity, rec.updatedAt);
    if (currentItem?.id === id) {
      currentItem = {
        ...currentItem,
        quantity: rec.pending ?? rec.quantity,
        updatedAt: rec.updatedAt,
      };
    }
  } catch (error) {
    rec.inFlight = false;
    if (error.status === 401) {
      showLoggedOut();
      return;
    }
    if (error.status === 409) {
      try {
        const fresh = await api(`/v1/items/${encodeURIComponent(id)}`);
        rec.updatedAt = fresh.updatedAt;
        rec.quantity = fresh.quantity;
        if (currentItem?.id === id) currentItem = fresh;
      } catch {
        rec.pending = null;
        applyQtyDom(root, rec.quantity, rec.updatedAt);
        return;
      }
    } else {
      rec.pending = null;
      applyQtyDom(root, rec.quantity, rec.updatedAt);
      return;
    }
  }
  rec.inFlight = false;
  if (rec.pending !== null) await flushSavedQuantity(id, root);
}

function stepSavedQuantity(root, delta) {
  if (!root) return;
  const id = root.getAttribute('data-qty-item');
  const input = root.querySelector('.qty-num');
  const shown = Number(input?.value);
  const rec = qtyRecord(
    id,
    Number.isInteger(shown) ? shown : QTY_MIN,
    Number(root.dataset.updated),
  );
  const current = rec.pending ?? rec.quantity;
  const next = clampQty(current + delta);
  if (next === current) return;
  rec.pending = next;
  applyQtyDom(root, next, rec.updatedAt);
  if (currentItem?.id === id) currentItem = { ...currentItem, quantity: next };
  flushSavedQuantity(id, root);
}

function commitQtyInput(root) {
  const input = root.querySelector('.qty-num');
  const raw = (input?.value ?? '').trim();
  const parsed = Number(raw);
  if (raw === '' || !Number.isInteger(parsed) || parsed < QTY_MIN) {
    const rec = qtyWrites.get(root.getAttribute('data-qty-item'));
    applyQtyDom(
      root,
      rec?.pending ?? rec?.quantity ?? QTY_MIN,
      rec?.updatedAt ?? root.dataset.updated,
    );
    return;
  }
  const id = root.getAttribute('data-qty-item');
  const rec = qtyRecord(id, recQuantityFallback(root), Number(root.dataset.updated));
  rec.pending = clampQty(parsed);
  applyQtyDom(root, rec.pending, rec.updatedAt);
  flushSavedQuantity(id, root);
}

function recQuantityFallback(root) {
  const shown = Number(root.querySelector('.qty-num')?.value);
  return Number.isInteger(shown) ? shown : QTY_MIN;
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
  const delta = Number(button.getAttribute('data-qty-delta'));
  if (!root || !Number.isInteger(delta)) return;
  stepSavedQuantity(root, delta);
  qtyRepeat = {
    timeout: window.setTimeout(() => {
      qtyRepeat.interval = window.setInterval(() => stepSavedQuantity(root, delta), 80);
    }, 400),
  };
}

function stepEditQuantity(delta) {
  const n = Number(editQuantity.value);
  const current = Number.isInteger(n) && n >= QTY_MIN ? n : QTY_MIN;
  editQuantity.value = String(clampQty(current + delta));
  editDirty = true;
}

function itemRow(item, { stepper = false } = {}) {
  const named = item.name && item.name.trim();
  const src = photoUrl(item, true);
  const thumb = src
    ? `<img class="thumb" alt="" src="${esc(src)}" />`
    : `<div class="thumb empty">no photo</div>`;
  const via =
    item.matchKind === 'location' ? `<div class="via">Matched the place, not the name</div>` : '';
  const inner = `${thumb}
    <div class="meta">
      <p class="name${named ? '' : ' unnamed'}">${esc(titleOf(item))}</p>
      <span class="where">${esc(loc(item) || 'Unknown place')}${stepper ? '' : esc(qtySuffix(item))}</span>
      ${via}
    </div>`;
  if (!stepper) {
    return `<button class="row" type="button" data-go="/item/${esc(item.id)}">${inner}</button>`;
  }
  return `<div class="row with-qty">
    <button class="row-main" type="button" data-go="/item/${esc(item.id)}">${inner}</button>
    ${qtyStepper(item, true)}
  </div>`;
}

function placeRow(locationHit) {
  const href =
    locationHit.kind === 'space' ? `/space/${locationHit.id}` : `/container/${locationHit.id}`;
  const glyph = locationHit.kind === 'space' ? '🏠' : '📦';
  return `<button class="row" type="button" data-go="${esc(href)}">
    <div class="thumb empty">${glyph}</div>
    <div class="meta">
      <p class="name">${esc(locationHit.title)}</p>
      <span class="where">${esc(locationHit.subtitle)}</span>
    </div>
  </button>`;
}

function spaceTile(space) {
  const fg = onColor(space.color);
  return `<button class="tile" type="button" data-go="/space/${esc(space.id)}"
      style="background:${esc(space.color)};color:${fg}">
    <div class="tile-icon">${esc(space.icon || '🏠')}</div>
    <div>
      <div class="tile-name">${esc(space.name)}</div>
      <div class="tile-meta">${esc(counts(space.itemCount ?? 0, 'item'))}</div>
    </div>
  </button>`;
}

function containerCard(container) {
  const title = container.name || container.shortCode;
  const icon = CONTAINER_ICONS[container.visualType] || CONTAINER_ICONS.other;
  return `<button class="card" type="button" data-go="/container/${esc(container.id)}">
    <div class="card-icon">${icon}</div>
    <div>
      <p class="name">${esc(title)}</p>
      <span class="where">${esc(container.shortCode)} · ${esc(counts(container.itemCount ?? 0, 'item'))}</span>
    </div>
  </button>`;
}

function closeEditors() {
  editDirty = false;
  saving = false;
  currentItem = null;
  editForm.classList.add('hidden');
  movePanel.classList.add('hidden');
  itemRead.classList.remove('hidden');
  editError.textContent = '';
  moveError.textContent = '';
  editSave.disabled = false;
}

function openEdit() {
  if (!currentItem) return;
  movePanel.classList.add('hidden');
  itemRead.classList.add('hidden');
  editForm.classList.remove('hidden');
  editName.value = currentItem.name || '';
  editCategory.value = currentItem.category || '';
  editTags.value = Array.isArray(currentItem.tags) ? currentItem.tags.join(', ') : '';
  editQuantity.value = String(currentItem.quantity ?? 1);
  editNotes.value = currentItem.notes || '';
  editError.textContent = '';
  editDirty = false;
  editName.focus();
}

function onField(target) {
  const tag = target && target.tagName;
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
}

async function loadHome(query) {
  const gen = ++searchGen;
  const trimmed = query.trim();
  if (document.activeElement !== q) q.value = trimmed;

  if (trimmed) {
    browse.innerHTML = '';
    status.textContent = 'Looking…';
    try {
      const body = await api(`/v1/search?q=${encodeURIComponent(trimmed)}`);
      if (gen !== searchGen) return;
      const locations = body.locations || [];
      const items = body.items || [];
      const parts = [];
      if (locations.length) {
        parts.push(`<p class="section">Places</p>${locations.map(placeRow).join('')}`);
      }
      if (items.length) {
        parts.push(`<p class="section">Items</p>${items.map(itemRow).join('')}`);
      }
      results.innerHTML = parts.length
        ? parts.join('')
        : `<p class="empty">Nothing under that name.</p>`;
      const total = locations.length + items.length;
      status.textContent = total ? `${total} match${total === 1 ? '' : 'es'}` : 'No matches';
    } catch (error) {
      if (gen !== searchGen) return;
      if (error.status === 401) {
        showLoggedOut();
        return;
      }
      status.textContent = 'Could not reach the household list';
    }
    return;
  }

  status.textContent = 'Type what you remember';
  results.innerHTML = '';
  browse.innerHTML = `<p class="empty">Opening…</p>`;
  try {
    const [spacesBody, recentBody, unsortedBody] = await Promise.all([
      api('/v1/spaces'),
      api('/v1/items?recent=1'),
      api('/v1/items?unsorted=1'),
    ]);
    if (gen !== searchGen) return;
    const spaces = spacesBody.spaces || [];
    const recent = recentBody.items || [];
    const unsorted = unsortedBody.items || [];
    const chunks = [];
    if (spaces.length) {
      chunks.push(
        `<p class="section">Spaces</p><div class="tiles">${spaces.map(spaceTile).join('')}</div>`,
      );
    }
    if (unsorted.length) {
      chunks.push(
        `<button class="banner" type="button" data-go="/container/${DROP_ZONE_ID}">
          <strong>Drop zone</strong>
          <span>${esc(counts(unsorted.length, 'item'))} waiting</span>
        </button>`,
      );
    }
    if (recent.length) {
      chunks.push(
        `<p class="section">Recently added</p><div class="list">${recent.map(itemRow).join('')}</div>`,
      );
    } else if (!spaces.length && !unsorted.length) {
      chunks.push(`<p class="empty">The household inventory is empty.</p>`);
    }
    browse.innerHTML = chunks.join('');
  } catch (error) {
    if (gen !== searchGen) return;
    if (error.status === 401) {
      showLoggedOut();
      return;
    }
    browse.innerHTML = `<p class="empty">Could not reach the household list</p>`;
  }
}

async function loadSpace(id, gen) {
  spaceEl.innerHTML = `<p class="empty">Opening…</p>`;
  try {
    const [space, listed] = await Promise.all([
      api(`/v1/spaces/${encodeURIComponent(id)}`),
      api(`/v1/containers?spaceId=${encodeURIComponent(id)}`),
    ]);
    if (gen !== renderGen) return;
    const containers = listed.containers || [];
    const cards = containers.length
      ? `<div class="list">${containers.map(containerCard).join('')}</div>`
      : `<p class="empty">No containers in this space yet.</p>`;
    spaceEl.innerHTML = `<h1 class="page-title">${esc(space.icon || '')} ${esc(space.name)}</h1>
      <p class="hint">${esc(counts(containers.length, 'container'))}</p>
      ${cards}`;
  } catch (error) {
    if (gen !== renderGen) return;
    if (error.status === 401) showLoggedOut();
    else spaceEl.innerHTML = `<p class="empty">That space could not be opened.</p>`;
  }
}

async function loadContainer(id, gen) {
  containerEl.innerHTML = `<p class="empty">Opening…</p>`;
  containerContext = null;
  try {
    const itemsQuery =
      id === DROP_ZONE_ID
        ? '/v1/items?unsorted=1'
        : `/v1/items?containerId=${encodeURIComponent(id)}`;
    const [container, listed] = await Promise.all([
      api(`/v1/containers/${encodeURIComponent(id)}`),
      api(itemsQuery),
    ]);
    if (gen !== renderGen) return;
    containerContext = container;
    const items = listed.items || [];
    const title = id === DROP_ZONE_ID ? 'Drop zone' : container.name || container.shortCode;
    const meta =
      id === DROP_ZONE_ID
        ? 'Waiting for a home'
        : `${container.shortCode} · ${counts(items.length, 'item')}`;
    const list = items.length
      ? `<div class="list">${items.map((item) => itemRow(item, { stepper: true })).join('')}</div>`
      : `<p class="empty">${id === DROP_ZONE_ID ? 'Nothing waiting.' : 'This container is empty.'}</p>`;
    containerEl.innerHTML = `<h1 class="page-title">${esc(title)}</h1>
      <p class="hint">${esc(meta)}</p>
      ${list}`;
    const back = document.getElementById('container-back');
    back.textContent = id === DROP_ZONE_ID || !container.spaceId ? 'Back to home' : 'Back to space';
  } catch (error) {
    if (gen !== renderGen) return;
    if (error.status === 401) showLoggedOut();
    else containerEl.innerHTML = `<p class="empty">That container could not be opened.</p>`;
  }
}

function locationButtons(item) {
  if (item.containerId === DROP_ZONE_ID) {
    return `<button class="where" type="button" data-go="/container/${DROP_ZONE_ID}">Drop zone</button>`;
  }
  const space = item.spaceId
    ? `<button class="where" type="button" data-go="/space/${esc(item.spaceId)}">${esc(item.spaceName || 'Space')}</button>`
    : '';
  const container = `<button class="where" type="button" data-go="/container/${esc(item.containerId)}">${esc(
    item.containerName || item.containerShortCode || 'Container',
  )}</button>`;
  return [space, container].filter(Boolean).join(' ');
}

function renderItemRead(item) {
  const src = photoUrl(item, false);
  const hero = src
    ? `<img class="hero" alt="${esc(titleOf(item))}" src="${esc(src)}" />`
    : `<div class="hero-empty">No photo</div>`;
  const notes = item.notes ? `<p class="notes">${esc(item.notes)}</p>` : '';
  const tags =
    Array.isArray(item.tags) && item.tags.length
      ? `<p class="tags">${esc(item.tags.join(' · '))}</p>`
      : '';
  const category = item.category ? `<p class="category">${esc(item.category)}</p>` : '';
  itemRead.innerHTML = `${hero}
    <h2>${esc(titleOf(item))}</h2>
    <div class="loc-line">${locationButtons(item)}</div>
    <div class="qty-block">
      <p class="section">Quantity</p>
      ${qtyStepper(item, false)}
    </div>
    ${category}${notes}${tags}
    <div class="actions">
      <button class="btn" type="button" data-action="edit">Edit</button>
      <button class="btn ghost" type="button" data-action="move">Move</button>
    </div>`;
}

async function loadItem(id, gen) {
  if (!currentItem || currentItem.id !== id) {
    itemRead.innerHTML = `<p class="empty">Opening…</p>`;
  }
  itemRead.classList.remove('hidden');
  editForm.classList.add('hidden');
  movePanel.classList.add('hidden');
  try {
    const item = await api(`/v1/items/${encodeURIComponent(id)}`);
    if (gen !== undefined && gen !== renderGen) return;
    currentItem = item;
    renderItemRead(item);
  } catch (error) {
    if (gen !== undefined && gen !== renderGen) return;
    currentItem = null;
    if (error.status === 401) showLoggedOut();
    else itemRead.innerHTML = `<p class="empty">That item could not be opened.</p>`;
  }
}

async function saveEdit(event) {
  event.preventDefault();
  if (!currentItem || saving) return;
  const name = editName.value.trim();
  const rawQuantity = editQuantity.value.trim();
  const quantity = Number(rawQuantity);
  if (!name) {
    editError.textContent = 'A name is required.';
    return;
  }
  if (rawQuantity === '' || !Number.isInteger(quantity) || quantity < 0) {
    editError.textContent = 'Quantity must be a whole number of 0 or more.';
    return;
  }
  saving = true;
  editSave.disabled = true;
  editError.textContent = '';
  try {
    await api(`/v1/items/${encodeURIComponent(currentItem.id)}`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        name,
        category: editCategory.value.trim(),
        tags: editTags.value
          .split(',')
          .map((tag) => tag.trim())
          .filter(Boolean),
        quantity,
        notes: editNotes.value.trim(),
        updatedAt: currentItem.updatedAt,
      }),
    });
    editDirty = false;
    saving = false;
    editSave.disabled = false;
    editForm.classList.add('hidden');
    itemRead.classList.remove('hidden');
    await loadItem(currentItem.id, renderGen);
  } catch (error) {
    saving = false;
    editSave.disabled = false;
    if (error.status === 401) {
      showLoggedOut();
      return;
    }
    if (error.status === 409) {
      editError.textContent = 'Someone changed this on a phone. Reload and try again.';
      try {
        const fresh = await api(`/v1/items/${encodeURIComponent(currentItem.id)}`);
        currentItem = fresh;
      } catch {
        /* keep typed values even if refetch fails */
      }
      return;
    }
    editError.textContent = 'The item could not be saved. Your changes are still here.';
  }
}

async function openMove() {
  if (!currentItem) return;
  editForm.classList.add('hidden');
  itemRead.classList.add('hidden');
  movePanel.classList.remove('hidden');
  moveError.textContent = '';
  moveList.innerHTML = `<p class="empty">Loading containers…</p>`;
  try {
    const body = await api('/v1/containers');
    const containers = body.containers || [];
    if (!containers.length) {
      moveList.innerHTML = `<p class="empty">No containers yet. Make one on the phone first.</p>`;
      return;
    }
    moveList.innerHTML = containers
      .map((container) => {
        const title = container.name || container.shortCode;
        const current = container.id === currentItem.containerId ? ' (here)' : '';
        return `<button class="move-choice" type="button" data-move="${esc(container.id)}">
          ${esc(title)}${current}
          <span class="sub">${esc(container.spaceName || '')} · ${esc(container.shortCode)}</span>
        </button>`;
      })
      .join('');
  } catch (error) {
    if (error.status === 401) showLoggedOut();
    else moveList.innerHTML = `<p class="empty">Could not load containers.</p>`;
  }
}

async function moveTo(containerId) {
  if (!currentItem || saving || containerId === currentItem.containerId) {
    if (containerId === currentItem?.containerId) {
      movePanel.classList.add('hidden');
      itemRead.classList.remove('hidden');
    }
    return;
  }
  saving = true;
  moveError.textContent = '';
  try {
    await api(`/v1/items/${encodeURIComponent(currentItem.id)}`, {
      method: 'PATCH',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        containerId,
        updatedAt: currentItem.updatedAt,
      }),
    });
    saving = false;
    editDirty = false;
    navigate(`/container/${containerId}`);
  } catch (error) {
    saving = false;
    if (error.status === 401) {
      showLoggedOut();
      return;
    }
    if (error.status === 409) {
      moveError.textContent = 'Someone changed this on a phone. Reload and try again.';
      try {
        currentItem = await api(`/v1/items/${encodeURIComponent(currentItem.id)}`);
      } catch {
        /* keep the picker open */
      }
      return;
    }
    moveError.textContent = 'The item could not be moved.';
  }
}

async function render() {
  const gen = ++renderGen;
  if (!qtyBusy()) qtyWrites.clear();
  const route = parseRoute();
  if (route.name !== 'item') closeEditors();
  showView(route.name === 'home' ? 'home' : route.name);
  if (route.name === 'home') {
    await loadHome(route.q || '');
  } else if (route.name === 'space') {
    await loadSpace(route.id, gen);
  } else if (route.name === 'container') {
    await loadContainer(route.id, gen);
  } else if (route.name === 'item') {
    await loadItem(route.id, gen);
  }
  if (gen !== renderGen) return;
}

function refreshIfIdle() {
  if (editDirty || saving || !editForm.classList.contains('hidden')) return;
  if (!movePanel.classList.contains('hidden')) return;
  if (qtyBusy()) return;
  render();
}

function startEvents() {
  if (events) return;
  events = new EventSource('/v1/events', { withCredentials: true });
  events.addEventListener('change', refreshIfIdle);
}

function stopEvents() {
  events?.close();
  events = null;
}

app.addEventListener('click', (event) => {
  if (event.target.closest('[data-qty-item]')) return;
  const go = event.target.closest('[data-go]');
  if (go) {
    event.preventDefault();
    navigate(go.getAttribute('data-go'));
    return;
  }
  const action = event.target.closest('[data-action]');
  if (action) {
    if (action.getAttribute('data-action') === 'edit') openEdit();
    if (action.getAttribute('data-action') === 'move') openMove();
    return;
  }
  const move = event.target.closest('[data-move]');
  if (move) moveTo(move.getAttribute('data-move'));
});

document.getElementById('space-back').addEventListener('click', () => navigate('/'));
document.getElementById('container-back').addEventListener('click', () => {
  if (containerContext?.id === DROP_ZONE_ID || !containerContext?.spaceId) navigate('/');
  else navigate(`/space/${containerContext.spaceId}`);
});
document.getElementById('item-back').addEventListener('click', () => {
  if (currentItem?.containerId) navigate(`/container/${currentItem.containerId}`);
  else navigate('/');
});

q.addEventListener('input', () => {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(() => {
    const trimmed = q.value.trim();
    const next = trimmed ? `/?q=${encodeURIComponent(trimmed)}` : '/';
    history.replaceState(null, '', next);
    loadHome(q.value);
  }, 180);
});
document.getElementById('search-form').addEventListener('submit', (event) => {
  event.preventDefault();
  window.clearTimeout(searchTimer);
  const trimmed = q.value.trim();
  history.replaceState(null, '', trimmed ? `/?q=${encodeURIComponent(trimmed)}` : '/');
  loadHome(q.value);
});

document.getElementById('logout').addEventListener('click', async () => {
  await fetch('/v1/web/logout', { method: 'POST', credentials: 'same-origin' });
  history.replaceState(null, '', '/');
  showLoggedOut();
});

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  loginError.textContent = '';
  try {
    const response = await fetch('/v1/web/login', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ password: password.value }),
    });
    if (!response.ok) {
      loginError.textContent = 'That password was not accepted.';
      return;
    }
    password.value = '';
    showLoggedIn();
    await render();
    if (parseRoute().name === 'home') q.focus();
  } catch {
    loginError.textContent = 'Could not reach the household server.';
  }
});

app.addEventListener('pointerdown', (event) => {
  const button = event.target.closest('[data-qty-delta]');
  if (!button || !button.closest('[data-qty-item]')) return;
  event.preventDefault();
  startQtyRepeat(button);
});
document.addEventListener('pointerup', stopQtyRepeat);
document.addEventListener('pointercancel', stopQtyRepeat);
app.addEventListener('change', (event) => {
  const root = event.target.closest('[data-qty-item]');
  if (root && event.target.classList.contains('qty-num')) commitQtyInput(root);
});
app.addEventListener('keydown', (event) => {
  const root = event.target.closest('[data-qty-item]');
  if (!root || !event.target.classList.contains('qty-num')) return;
  if (event.key === 'ArrowUp') {
    event.preventDefault();
    stepSavedQuantity(root, 1);
  } else if (event.key === 'ArrowDown') {
    event.preventDefault();
    stepSavedQuantity(root, -1);
  } else if (event.key === 'Enter') {
    event.preventDefault();
    event.target.blur();
  }
});

editForm.addEventListener('submit', saveEdit);
editForm.addEventListener('input', () => {
  editDirty = true;
});
editQtyDec.addEventListener('click', () => stepEditQuantity(-1));
editQtyInc.addEventListener('click', () => stepEditQuantity(1));
document.getElementById('edit-cancel').addEventListener('click', () => {
  editDirty = false;
  editForm.classList.add('hidden');
  itemRead.classList.remove('hidden');
  editError.textContent = '';
});
document.getElementById('move-cancel').addEventListener('click', () => {
  movePanel.classList.add('hidden');
  itemRead.classList.remove('hidden');
  moveError.textContent = '';
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    if (!editForm.classList.contains('hidden')) {
      document.getElementById('edit-cancel').click();
      return;
    }
    if (!movePanel.classList.contains('hidden')) {
      document.getElementById('move-cancel').click();
      return;
    }
    const route = parseRoute();
    if (route.name === 'item') document.getElementById('item-back').click();
    else if (route.name === 'container') document.getElementById('container-back').click();
    else if (route.name === 'space') document.getElementById('space-back').click();
    return;
  }
  if (event.key === '/' && !onField(event.target) && !searchView.classList.contains('hidden')) {
    event.preventDefault();
    q.focus();
  }
});

window.addEventListener('popstate', () => {
  closeEditors();
  render();
});

(async () => {
  if (location.hash.startsWith('#item/')) {
    history.replaceState(null, '', `/item/${location.hash.slice(6)}`);
  }
  try {
    const me = await fetch('/v1/web/me', { credentials: 'same-origin' });
    if (!me.ok) {
      showLoggedOut();
      return;
    }
    showLoggedIn();
    await render();
    if (parseRoute().name === 'home') q.focus();
  } catch {
    showLoggedOut();
  }
})();
