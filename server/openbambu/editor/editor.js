// Editor de placas de OpenBambu (three.js). Funciona en el navegador y dentro de la app.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/OrbitControls.js';
import { TransformControls } from 'three/addons/TransformControls.js';

THREE.Object3D.DEFAULT_UP.set(0, 0, 1); // los modelos 3MF usan Z hacia arriba

// ---- parámetros ------------------------------------------------------------------------------
const qs = new URLSearchParams(location.search);
const token = qs.get('token') || '';
const lid = qs.get('lid');
const printerId = qs.get('printer') || '';
const theme = qs.get('theme') || 'dark';
document.documentElement.dataset.theme = theme;

const $ = (id) => document.getElementById(id);
const PALETTE = ['#F2F2F2', '#2B2B2B', '#E5484D', '#3E8BFF', '#F5B23D', '#34C77B', '#B47CFF', '#FF7AB6'];
const GAP = 6; // mm entre piezas al acomodar

function css(name) { return getComputedStyle(document.documentElement).getPropertyValue(name).trim(); }

async function api(path, opts = {}) {
  const url = path + (path.includes('?') ? '&' : '?') + 'token=' + encodeURIComponent(token);
  const r = await fetch(url, opts);
  if (!r.ok) {
    let msg = `Error ${r.status}`;
    try { const j = await r.json(); msg = j.detail?.[0]?.msg || j.detail || msg; } catch {}
    throw new Error(msg);
  }
  return r;
}

// ---- estado ----------------------------------------------------------------------------------
const state = {
  name: '', source: '', bed: { w: 256, d: 256 }, plates: [{ index: 1, name: '' }], filaments: [],
  objects: new Map(), // key -> {name, extruder, parts:[{geometry, transform:Matrix4, extruder, subtype}]}
  items: [], // {uid, key, plate, extruder, node}
  plate: 1, selected: null, mode: 'translate', flatArmed: false, dirty: false,
};
let uidSeq = 1;
const undoStack = [], redoStack = [];

// ---- three.js ----------------------------------------------------------------------------------
const canvas = $('view');
const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
const scene = new THREE.Scene();
scene.background = new THREE.Color(css('--bg') || '#101214');
const camera = new THREE.PerspectiveCamera(38, 1, 1, 5000);
scene.add(new THREE.HemisphereLight(0xffffff, 0x404850, 1.6));
const sun = new THREE.DirectionalLight(0xffffff, 1.6);
sun.position.set(-150, -250, 400);
scene.add(sun);
const fill = new THREE.DirectionalLight(0xffffff, 0.5);
fill.position.set(300, 300, 200);
scene.add(fill);

const orbit = new OrbitControls(camera, canvas);
orbit.enableDamping = true;
orbit.dampingFactor = 0.12;
orbit.screenSpacePanning = true;
orbit.maxPolarAngle = Math.PI * 0.495;

const tc = new TransformControls(camera, canvas);
tc.setSize(window.matchMedia('(pointer: coarse)').matches ? 1.35 : 1);
tc.setSpace('world');
scene.add(tc.getHelper());
tc.addEventListener('dragging-changed', (e) => {
  orbit.enabled = !e.value;
  if (!e.value) { afterEdit(); }
});
tc.addEventListener('objectChange', () => updatePanel());

const bedGroup = new THREE.Group();
scene.add(bedGroup);
const selBox = new THREE.Box3Helper(new THREE.Box3(), new THREE.Color(css('--accent') || '#34c77b'));
selBox.visible = false;
scene.add(selBox);

function buildBed() {
  bedGroup.clear();
  const { w, d } = state.bed;
  const light = document.documentElement.dataset.theme === 'light' ||
    (theme === 'system' && matchMedia('(prefers-color-scheme: light)').matches);
  const plate = new THREE.Mesh(new THREE.PlaneGeometry(w, d),
    new THREE.MeshStandardMaterial({ color: light ? 0xdfe3e1 : 0x2a2f33, roughness: 0.95 }));
  plate.position.set(w / 2, d / 2, -0.05);
  plate.receiveShadow = true;
  bedGroup.add(plate);
  const pts = [], major = [];
  for (let x = 0; x <= w + 0.01; x += 10) (x % 50 === 0 ? major : pts).push(x, 0, 0, x, d, 0);
  for (let y = 0; y <= d + 0.01; y += 10) (y % 50 === 0 ? major : pts).push(0, y, 0, w, y, 0);
  const line = (arr, color, opacity) => {
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(arr, 3));
    return new THREE.LineSegments(g, new THREE.LineBasicMaterial({ color, transparent: true, opacity }));
  };
  bedGroup.add(line(pts, light ? 0x9aa3a0 : 0x4a5257, 0.5));
  bedGroup.add(line(major, light ? 0x6f7774 : 0x6a7378, 0.8));
  const border = [0, 0, 0, w, 0, 0, w, 0, 0, w, d, 0, w, d, 0, 0, d, 0, 0, d, 0, 0, 0, 0];
  const b = line(border, 0x34c77b, 0.9);
  b.position.z = 0.02;
  bedGroup.add(b);
}

function resize() {
  const r = canvas.parentElement.getBoundingClientRect();
  renderer.setSize(r.width, r.height, false);
  camera.aspect = r.width / Math.max(r.height, 1);
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(canvas.parentElement);

function setView(kind) {
  const { w, d } = state.bed;
  const c = new THREE.Vector3(w / 2, d / 2, 0);
  const dist = Math.max(w, d) * (camera.aspect < 1 ? 2.3 : 1.55);
  if (kind === 'top') camera.position.set(c.x, c.y - 0.01, dist * 1.05);
  else if (kind === 'front') camera.position.set(c.x, c.y - dist, dist * 0.22);
  else camera.position.set(c.x - dist * 0.25, c.y - dist * 0.75, dist * 0.62);
  orbit.target.copy(c);
  orbit.update();
  document.querySelectorAll('#viewbar .mini').forEach((b) => b.classList.toggle('active', b.dataset.view === kind));
}

function loop() {
  orbit.update();
  if (state.selected) {
    const it = item(state.selected);
    if (it) selBox.box.setFromObject(it.node, false);
  }
  renderer.render(scene, camera);
  requestAnimationFrame(loop);
}

// ---- matrices 3MF <-> three ---------------------------------------------------------------------
function m12ToMatrix(m) {
  return new THREE.Matrix4().fromArray([m[0], m[1], m[2], 0, m[3], m[4], m[5], 0, m[6], m[7], m[8], 0, m[9], m[10], m[11], 1]);
}
function matrixToM12(mat) {
  const e = mat.elements;
  return [e[0], e[1], e[2], e[4], e[5], e[6], e[8], e[9], e[10], e[12], e[13], e[14]].map((x) => +x.toFixed(6));
}

// ---- carga de mallas -------------------------------------------------------------------------------
const geoCache = new Map();
async function loadGeometry(url) {
  if (geoCache.has(url)) return geoCache.get(url);
  const p = api(url).then((r) => r.arrayBuffer()).then((buf) => {
    const dv = new DataView(buf);
    const nv = dv.getUint32(0, true), nt = dv.getUint32(4, true);
    const pos = new Float32Array(buf, 8, nv * 3);
    const idx = new Uint32Array(buf, 8 + nv * 12, nt * 3);
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3));
    g.setIndex(new THREE.BufferAttribute(idx, 1));
    g.computeVertexNormals();
    g.computeBoundingBox();
    return g;
  });
  geoCache.set(url, p);
  return p;
}

async function loadSceneObjects(data) {
  for (const o of data.objects) {
    if (state.objects.has(o.key)) continue;
    const parts = await Promise.all(o.parts.map(async (p) => ({
      geometry: await loadGeometry(p.mesh), transform: m12ToMatrix(p.transform),
      extruder: p.extruder, subtype: p.subtype,
    })));
    state.objects.set(o.key, { name: o.name, extruder: o.extruder || 1, parts });
  }
}

// ---- piezas en la escena -------------------------------------------------------------------------------
function filamentColor(ext) {
  const f = state.filaments[(ext || 1) - 1];
  return f?.color || PALETTE[((ext || 1) - 1) % PALETTE.length];
}

function makeNode(it) {
  const obj = state.objects.get(it.key);
  const node = new THREE.Group();
  node.userData.uid = it.uid;
  const multi = new Set(obj.parts.map((p) => p.extruder || 0)).size > 1;
  for (const p of obj.parts) {
    const normal = p.subtype === 'normal_part' || !p.subtype;
    const ext = multi && p.extruder ? p.extruder : it.extruder || obj.extruder;
    const mat = new THREE.MeshStandardMaterial({
      color: filamentColor(ext), roughness: 0.55, metalness: 0.05, flatShading: true,
      transparent: !normal, opacity: normal ? 1 : 0.25, depthWrite: normal,
    });
    mat.userData.part = { ext: multi && p.extruder ? p.extruder : null };
    const mesh = new THREE.Mesh(p.geometry, mat);
    mesh.matrixAutoUpdate = false;
    mesh.matrix.copy(p.transform);
    mesh.userData.uid = it.uid;
    mesh.userData.normal = normal;
    node.add(mesh);
  }
  scene.add(node);
  return node;
}

function recolor(it) {
  const obj = state.objects.get(it.key);
  for (const m of it.node.children) {
    const ext = m.material.userData.part?.ext || it.extruder || obj.extruder;
    m.material.color.set(filamentColor(ext));
  }
}

function addItem({ key, plate, matrix, extruder }, select = false) {
  const it = { uid: uidSeq++, key, plate, extruder: extruder || null };
  it.node = makeNode(it);
  if (matrix instanceof THREE.Matrix4) it.node.applyMatrix4(matrix);
  else it.node.applyMatrix4(m12ToMatrix(matrix));
  state.items.push(it);
  if (select) selectItem(it.uid);
  return it;
}

const item = (uid) => state.items.find((i) => i.uid === uid);
const plateItems = (plate = state.plate) => state.items.filter((i) => i.plate === plate);

function bboxOf(node, precise = true) {
  node.updateMatrixWorld(true);
  return new THREE.Box3().setFromObject(node, precise);
}

function dropToBed(node) {
  const b = bboxOf(node);
  if (isFinite(b.min.z)) node.position.z -= b.min.z;
}

function outOfBed(it) {
  const b = bboxOf(it.node, false);
  const { w, d } = state.bed;
  return b.min.x < -0.5 || b.min.y < -0.5 || b.max.x > w + 0.5 || b.max.y > d + 0.5 || b.max.z > Math.max(w, d) + 0.5;
}

// ---- selección y modos --------------------------------------------------------------------------------
function selectItem(uid) {
  state.selected = uid;
  const it = item(uid);
  for (const i of state.items) {
    for (const m of i.node.children) m.material.emissive?.set(i.uid === uid ? 0x0b3b22 : 0x000000);
  }
  if (it && it.plate === state.plate) {
    tc.attach(it.node);
    selBox.visible = true;
  } else {
    tc.detach();
    selBox.visible = false;
    state.selected = null;
  }
  applyMode();
  updatePanel();
  updateTools();
}

function applyMode() {
  tc.setMode(state.mode);
  tc.showZ = state.mode !== 'translate';
  tc.showX = true;
  tc.showY = true;
  document.querySelectorAll('.tool[data-mode]').forEach((b) => b.classList.toggle('active', b.dataset.mode === state.mode));
  document.querySelectorAll('#panel section[data-for]').forEach((s) => { s.hidden = s.dataset.for !== state.mode; });
}

function setMode(mode) { state.mode = mode; applyMode(); }

// ---- historial ----------------------------------------------------------------------------------------
function snapshot() {
  return {
    plates: state.plates.map((p) => ({ ...p })),
    items: state.items.map((i) => ({ uid: i.uid, key: i.key, plate: i.plate, extruder: i.extruder,
      matrix: i.node.matrix.clone() })),
  };
}
let lastSnap = null;
function commit() {
  const snap = snapshot();
  if (lastSnap) undoStack.push(lastSnap);
  if (undoStack.length > 60) undoStack.shift();
  redoStack.length = 0;
  lastSnap = snap;
  state.dirty = true;
  updateTools();
}
function restore(snap) {
  const keep = new Map(state.items.map((i) => [i.uid, i]));
  for (const i of state.items) scene.remove(i.node);
  state.items = [];
  state.plates = snap.plates.map((p) => ({ ...p }));
  for (const s of snap.items) {
    const old = keep.get(s.uid);
    const it = { uid: s.uid, key: s.key, plate: s.plate, extruder: s.extruder };
    it.node = old && old.key === s.key ? old.node : makeNode(it);
    it.node.matrix.copy(s.matrix);
    it.node.matrix.decompose(it.node.position, it.node.quaternion, it.node.scale);
    scene.add(it.node);
    state.items.push(it);
    recolor(it);
  }
  lastSnap = snap;
  if (!state.plates.some((p) => p.index === state.plate)) state.plate = state.plates[0].index;
  showPlate(state.plate, false);
  selectItem(state.items.some((i) => i.uid === state.selected) ? state.selected : null);
}
function undo() { if (!undoStack.length) return; redoStack.push(snapshot()); restore(undoStack.pop()); }
function redo() { if (!redoStack.length) return; undoStack.push(snapshot()); restore(redoStack.pop()); }

function afterEdit() {
  const it = item(state.selected);
  if (it) dropToBed(it.node);
  checkBounds();
  updatePanel();
  commit();
}

// ---- placas ---------------------------------------------------------------------------------------------
function showPlate(index, resetSel = true) {
  state.plate = index;
  for (const i of state.items) i.node.visible = i.plate === index;
  if (resetSel && item(state.selected)?.plate !== index) selectItem(null);
  renderPlates();
  checkBounds();
}

function renderPlates() {
  const bar = $('plates');
  bar.innerHTML = '';
  state.plates.sort((a, b) => a.index - b.index);
  for (const p of state.plates) {
    const b = document.createElement('button');
    b.className = 'plate-tab' + (p.index === state.plate ? ' active' : '');
    b.innerHTML = `<span>${escapeHtml(p.name || 'Placa ' + p.index)}</span><span class="count">${plateItems(p.index).length}</span>`;
    b.onclick = () => showPlate(p.index);
    b.ondblclick = () => plateMenu(p);
    let t;
    b.addEventListener('pointerdown', () => { t = setTimeout(() => plateMenu(p), 600); });
    b.addEventListener('pointerup', () => clearTimeout(t));
    b.addEventListener('pointerleave', () => clearTimeout(t));
    bar.appendChild(b);
  }
  const add = document.createElement('button');
  add.className = 'plate-tab add';
  add.textContent = '+ Placa';
  add.onclick = () => {
    const index = Math.max(...state.plates.map((p) => p.index)) + 1;
    state.plates.push({ index, name: '' });
    showPlate(index);
    commit();
    toast(`Placa ${index} creada: pasale piezas desde el panel o agregá modelos`);
  };
  bar.appendChild(add);
  const sel = $('sel-plate');
  sel.innerHTML = state.plates.map((p) => `<option value="${p.index}">${escapeHtml(p.name || 'Placa ' + p.index)}</option>`).join('');
}

function plateMenu(p) {
  openSheet(p.name || `Placa ${p.index}`, [
    { label: 'Renombrar', action: () => {
      const n = prompt('Nombre de la placa', p.name || '');
      if (n !== null) { p.name = n.trim(); renderPlates(); commit(); }
    } },
    { label: 'Acomodar esta placa', action: () => { showPlate(p.index); arrange(); } },
    { label: 'Borrar placa', hint: plateItems(p.index).length ? 'Borra también sus piezas' : '', action: () => {
      if (state.plates.length === 1) return toast('Tiene que quedar al menos una placa');
      for (const i of plateItems(p.index)) scene.remove(i.node);
      state.items = state.items.filter((i) => i.plate !== p.index);
      state.plates = state.plates.filter((x) => x !== p);
      showPlate(state.plates[0].index);
      commit();
    } },
  ]);
}

// ---- operaciones -----------------------------------------------------------------------------------------
function center(it) {
  const b = bboxOf(it.node, false);
  it.node.position.x += state.bed.w / 2 - (b.min.x + b.max.x) / 2;
  it.node.position.y += state.bed.d / 2 - (b.min.y + b.max.y) / 2;
}

function rotateItem(it, axis, deg) {
  const b = bboxOf(it.node, false);
  const c = b.getCenter(new THREE.Vector3());
  const v = { x: new THREE.Vector3(1, 0, 0), y: new THREE.Vector3(0, 1, 0), z: new THREE.Vector3(0, 0, 1) }[axis];
  it.node.rotateOnWorldAxis(v, THREE.MathUtils.degToRad(deg));
  it.node.updateMatrixWorld(true);
  const c2 = bboxOf(it.node, false).getCenter(new THREE.Vector3());
  it.node.position.x += c.x - c2.x;
  it.node.position.y += c.y - c2.y;
  dropToBed(it.node);
}

function layOn(it, worldNormal) {
  const b = bboxOf(it.node, false);
  const c = b.getCenter(new THREE.Vector3());
  const q = new THREE.Quaternion().setFromUnitVectors(worldNormal.clone().normalize(), new THREE.Vector3(0, 0, -1));
  it.node.quaternion.premultiply(q);
  it.node.updateMatrixWorld(true);
  const c2 = bboxOf(it.node, false).getCenter(new THREE.Vector3());
  it.node.position.x += c.x - c2.x;
  it.node.position.y += c.y - c2.y;
  dropToBed(it.node);
}

function autoFlat(it) {
  // La orientación con más superficie apoyada (normales agrupadas por dirección)
  const buckets = new Map();
  const a = new THREE.Vector3(), b = new THREE.Vector3(), c = new THREE.Vector3(), n = new THREE.Vector3();
  it.node.updateMatrixWorld(true);
  for (const mesh of it.node.children) {
    if (!mesh.userData.normal) continue;
    const pos = mesh.geometry.attributes.position, idx = mesh.geometry.index.array;
    const mw = mesh.matrixWorld;
    const step = Math.max(1, Math.floor(idx.length / 3 / 40000));
    for (let t = 0; t < idx.length; t += 3 * step) {
      a.fromBufferAttribute(pos, idx[t]).applyMatrix4(mw);
      b.fromBufferAttribute(pos, idx[t + 1]).applyMatrix4(mw);
      c.fromBufferAttribute(pos, idx[t + 2]).applyMatrix4(mw);
      n.subVectors(c, b).cross(a.clone().sub(b));
      const area = n.length() / 2;
      if (area < 1e-6) continue;
      n.normalize();
      const k = `${Math.round(n.x * 20)},${Math.round(n.y * 20)},${Math.round(n.z * 20)}`;
      const e = buckets.get(k) || { area: 0, n: new THREE.Vector3() };
      e.area += area;
      e.n.addScaledVector(n, area);
      buckets.set(k, e);
    }
  }
  let best = null;
  for (const e of buckets.values()) if (!best || e.area > best.area) best = e;
  if (best) layOn(it, best.n.normalize());
}

function footprint(it) {
  const b = bboxOf(it.node, false);
  return { it, b, w: b.max.x - b.min.x, d: b.max.y - b.min.y };
}

function arrange(plate = state.plate) {
  const list = plateItems(plate).map(footprint).sort((p, q) => q.d * q.w - p.d * p.w);
  if (!list.length) return;
  const { w, d } = state.bed;
  // Estanterías: filas de izquierda a derecha, de adelante hacia atrás
  let x = GAP, y = GAP, rowH = 0;
  const placed = [];
  for (const f of list) {
    if (x + f.w > w - GAP && x > GAP) { x = GAP; y += rowH + GAP; rowH = 0; }
    placed.push({ f, x, y });
    x += f.w + GAP;
    rowH = Math.max(rowH, f.d);
  }
  const usedW = Math.max(...placed.map((p) => p.x + p.f.w)) + GAP;
  const usedD = Math.max(...placed.map((p) => p.y + p.f.d)) + GAP;
  const ox = Math.max(0, (w - usedW) / 2), oy = Math.max(0, (d - usedD) / 2);
  for (const p of placed) {
    p.f.it.node.position.x += p.x + ox - p.f.b.min.x;
    p.f.it.node.position.y += p.y + oy - p.f.b.min.y;
  }
  checkBounds();
  commit();
  if (usedD > d) toast('No entra todo en la placa: pasá algunas piezas a otra placa');
}

function freeSpot(size, ignore, near) {
  // El lugar libre más cercano a ``near`` (o a la esquina) donde entra la pieza
  const { w, d } = state.bed;
  const boxes = plateItems().filter((i) => i !== ignore).map((i) => bboxOf(i.node, false));
  const fits = (x, y) => boxes.every((b) =>
    x + size.x + GAP / 2 <= b.min.x || x - GAP / 2 >= b.max.x || y + size.y + GAP / 2 <= b.min.y || y - GAP / 2 >= b.max.y);
  const target = near || new THREE.Vector2(GAP, GAP);
  let best = null, bestD = Infinity;
  for (let y = GAP; y + size.y <= d - GAP; y += 4) {
    for (let x = GAP; x + size.x <= w - GAP; x += 4) {
      const dist = (x - target.x) ** 2 + (y - target.y) ** 2;
      if (dist < bestD && fits(x, y)) { best = new THREE.Vector2(x, y); bestD = dist; }
    }
  }
  return best;
}

function placeFree(it, near) {
  const b = bboxOf(it.node, false);
  const size = new THREE.Vector2(b.max.x - b.min.x, b.max.y - b.min.y);
  const spot = freeSpot(size, it, near || new THREE.Vector2(b.min.x, b.min.y));
  if (spot) {
    it.node.position.x += spot.x - b.min.x;
    it.node.position.y += spot.y - b.min.y;
    return true;
  }
  return false;
}

function duplicate(count = 1) {
  const src = item(state.selected);
  if (!src) return;
  let last = null, lost = 0;
  for (let n = 0; n < count; n++) {
    src.node.updateMatrix();
    const it = addItem({ key: src.key, plate: src.plate, matrix: src.node.matrix.clone(), extruder: src.extruder });
    const sb = bboxOf(src.node, false);
    if (!placeFree(it, new THREE.Vector2(sb.max.x + GAP, sb.min.y))) { lost++; it.node.position.x += 10 * (n + 1); it.node.position.y += 10 * (n + 1); }
    last = it;
  }
  checkBounds();
  selectItem(last.uid);
  renderPlates();
  commit();
  if (lost) toast('No hay más lugar libre: acomodá o pasá piezas a otra placa');
}

function remove() {
  const it = item(state.selected);
  if (!it) return;
  scene.remove(it.node);
  state.items = state.items.filter((i) => i !== it);
  selectItem(null);
  renderPlates();
  checkBounds();
  commit();
}

function checkBounds() {
  let out = 0;
  for (const it of state.items) {
    const bad = it.plate === state.plate && outOfBed(it);
    if (bad) out++;
    for (const m of it.node.children) {
      if (it.uid === state.selected) m.material.emissive.set(bad ? 0x5a1010 : 0x0b3b22);
      else m.material.emissive.set(bad ? 0x5a1010 : 0x000000);
    }
  }
  const w = $('warning');
  w.hidden = !out;
  w.textContent = out === 1 ? '1 pieza fuera de la cama' : `${out} piezas fuera de la cama`;
  renderPlatesCounts();
}
function renderPlatesCounts() {
  document.querySelectorAll('#plates .plate-tab:not(.add)').forEach((b, i) => {
    const p = state.plates[i];
    if (p) b.querySelector('.count').textContent = plateItems(p.index).length;
  });
}

// ---- panel de la pieza seleccionada -------------------------------------------------------------------------
function updatePanel() {
  const it = item(state.selected);
  const panel = $('panel');
  const wide = matchMedia('(min-width: 900px)').matches;
  panel.hidden = !it && !wide;
  panel.classList.toggle('empty', !it);
  if (!it) return;
  const obj = state.objects.get(it.key);
  const b = bboxOf(it.node, false);
  const size = b.getSize(new THREE.Vector3());
  $('sel-name').textContent = obj.name;
  $('sel-size').textContent = `${size.x.toFixed(1)} × ${size.y.toFixed(1)} × ${size.z.toFixed(1)} mm`;
  $('sel-swatch').style.background = filamentColor(it.extruder || obj.extruder);
  const c = b.getCenter(new THREE.Vector3());
  setVal('pos-x', c.x.toFixed(1));
  setVal('pos-y', c.y.toFixed(1));
  const e = new THREE.Euler().setFromQuaternion(it.node.quaternion, 'XYZ');
  setVal('rot-z', THREE.MathUtils.radToDeg(e.z).toFixed(0));
  setVal('scale-pct', (it.node.scale.x * 100).toFixed(0));
  const local = localSize(it);
  setVal('size-x', local.x.toFixed(1));
  setVal('size-y', local.y.toFixed(1));
  setVal('size-z', local.z.toFixed(1));
  $('sel-plate').value = it.plate;
  const fils = state.filaments.length ? state.filaments : [1, 2, 3, 4].map((id) => ({ id, type: '' }));
  $('filaments').innerHTML = fils.map((f) =>
    `<button class="chipbtn fil ${(it.extruder || obj.extruder) === f.id ? 'active' : ''}" data-ext="${f.id}">
       <i style="background:${filamentColor(f.id)}"></i>${f.id}${f.type ? ' · ' + escapeHtml(f.type) : ''}</button>`).join('');
}
function setVal(id, v) { const el = $(id); if (document.activeElement !== el) el.value = v; }
function localSize(it) {
  const box = new THREE.Box3();
  for (const m of it.node.children) {
    m.geometry.computeBoundingBox();
    box.union(m.geometry.boundingBox.clone().applyMatrix4(m.matrix));
  }
  return box.getSize(new THREE.Vector3()).multiply(it.node.scale);
}

function bindPanel() {
  const onNum = (id, fn) => $(id).addEventListener('change', (e) => {
    const it = item(state.selected);
    const v = parseFloat(e.target.value);
    if (!it || !isFinite(v)) return;
    fn(it, v);
    it.node.updateMatrixWorld(true);
    afterEdit();
  });
  onNum('pos-x', (it, v) => { const b = bboxOf(it.node, false); it.node.position.x += v - (b.min.x + b.max.x) / 2; });
  onNum('pos-y', (it, v) => { const b = bboxOf(it.node, false); it.node.position.y += v - (b.min.y + b.max.y) / 2; });
  onNum('rot-z', (it, v) => {
    const e = new THREE.Euler().setFromQuaternion(it.node.quaternion, 'XYZ');
    rotateItem(it, 'z', v - THREE.MathUtils.radToDeg(e.z));
  });
  onNum('scale-pct', (it, v) => { const s = Math.max(1, v) / 100; it.node.scale.setScalar(s); });
  for (const axis of ['x', 'y', 'z']) {
    onNum('size-' + axis, (it, v) => {
      const cur = localSize(it)[axis];
      if (cur <= 0 || v <= 0) return;
      const f = v / cur;
      if ($('uniform').checked) it.node.scale.multiplyScalar(f);
      else it.node.scale[axis] *= f;
    });
  }
  $('btn-center').onclick = () => { const it = item(state.selected); if (it) { center(it); afterEdit(); } };
  $('btn-reset-rot').onclick = () => {
    const it = item(state.selected);
    if (!it) return;
    it.node.quaternion.identity();
    dropToBed(it.node);
    afterEdit();
  };
  document.querySelectorAll('[data-rot]').forEach((b) => b.onclick = () => {
    const it = item(state.selected);
    if (!it) return;
    const [axis, deg] = b.dataset.rot.split(',');
    rotateItem(it, axis, +deg);
    afterEdit();
  });
  $('filaments').addEventListener('click', (e) => {
    const b = e.target.closest('[data-ext]');
    const it = item(state.selected);
    if (!b || !it) return;
    it.extruder = +b.dataset.ext;
    recolor(it);
    updatePanel();
    commit();
  });
  $('sel-plate').onchange = (e) => {
    const it = item(state.selected);
    if (!it) return;
    it.plate = +e.target.value;
    placeFree(it);
    showPlate(it.plate, false);
    selectItem(it.uid);
    commit();
  };
  $('btn-close-panel').onclick = () => selectItem(null);
}

// ---- puntero: seleccionar, arrastrar y apoyar caras ----------------------------------------------------------
const ray = new THREE.Raycaster();
const ndc = new THREE.Vector2();
let down = null, drag = null;
function pick(ev) {
  const r = canvas.getBoundingClientRect();
  ndc.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
  ray.setFromCamera(ndc, camera);
  const meshes = plateItems().flatMap((i) => i.node.children);
  return ray.intersectObjects(meshes, false)[0] || null;
}
canvas.addEventListener('pointerdown', (ev) => {
  down = { x: ev.clientX, y: ev.clientY, t: Date.now() };
  if (tc.dragging || state.mode !== 'translate' || state.flatArmed) return;
  const hit = pick(ev);
  if (hit && hit.object.userData.uid === state.selected) {
    // Arrastrar la pieza seleccionada sobre la cama
    const it = item(state.selected);
    const plane = new THREE.Plane(new THREE.Vector3(0, 0, 1), -hit.point.z);
    drag = { it, plane, start: hit.point.clone(), pos: it.node.position.clone(), id: ev.pointerId };
    orbit.enabled = false;
    canvas.setPointerCapture(ev.pointerId);
  }
});
canvas.addEventListener('pointermove', (ev) => {
  if (!drag || ev.pointerId !== drag.id) return;
  const r = canvas.getBoundingClientRect();
  ndc.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
  ray.setFromCamera(ndc, camera);
  const p = new THREE.Vector3();
  if (ray.ray.intersectPlane(drag.plane, p)) {
    drag.it.node.position.x = drag.pos.x + p.x - drag.start.x;
    drag.it.node.position.y = drag.pos.y + p.y - drag.start.y;
    updatePanel();
  }
});
canvas.addEventListener('pointerup', (ev) => {
  const moved = down ? Math.hypot(ev.clientX - down.x, ev.clientY - down.y) : 99;
  if (drag) {
    orbit.enabled = true;
    const d = drag;
    drag = null;
    if (moved > 3) { afterEdit(); return; }
    d.it.node.position.copy(d.pos);
  }
  if (moved > 6 || tc.dragging || !down || Date.now() - down.t > 600) return;
  const hit = pick(ev);
  if (state.flatArmed) {
    if (hit) {
      const it = item(hit.object.userData.uid);
      const n = hit.face.normal.clone().transformDirection(hit.object.matrixWorld);
      layOn(it, n);
      selectItem(it.uid);
      afterEdit();
    }
    state.flatArmed = false;
    $('btn-flat').classList.remove('armed');
    return;
  }
  if (hit) selectItem(hit.object.userData.uid);
  else if (!tc.axis) selectItem(null);
});

// ---- herramientas --------------------------------------------------------------------------------------
function updateTools() {
  const has = !!item(state.selected);
  for (const id of ['btn-duplicate', 'btn-delete']) $(id).disabled = !has;
  $('btn-undo').disabled = !undoStack.length;
  $('btn-redo').disabled = !redoStack.length;
}

function bindTools() {
  document.querySelectorAll('.tool[data-mode]').forEach((b) => b.onclick = () => setMode(b.dataset.mode));
  $('btn-duplicate').onclick = () => duplicate(1);
  $('btn-delete').onclick = remove;
  $('btn-arrange').onclick = () => arrange();
  $('btn-flat').onclick = () => {
    state.flatArmed = !state.flatArmed;
    $('btn-flat').classList.toggle('armed', state.flatArmed);
    if (state.flatArmed) toast('Tocá la cara de la pieza que querés apoyar sobre la cama');
  };
  $('btn-add').onclick = addFromLibrary;
  $('btn-more').onclick = moreMenu;
  $('btn-undo').onclick = undo;
  $('btn-redo').onclick = redo;
  $('btn-save').onclick = save;
  $('btn-back').onclick = back;
  document.querySelectorAll('#viewbar .mini').forEach((b) => b.onclick = () => setView(b.dataset.view));
  $('name').addEventListener('change', (e) => { state.name = e.target.value.trim() || state.name; state.dirty = true; });
  window.addEventListener('keydown', (e) => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
    const k = e.key.toLowerCase();
    if ((e.ctrlKey || e.metaKey) && k === 'z') { e.preventDefault(); e.shiftKey ? redo() : undo(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'y') { e.preventDefault(); redo(); }
    else if ((e.ctrlKey || e.metaKey) && k === 'd') { e.preventDefault(); duplicate(1); }
    else if (k === 'delete' || k === 'backspace') remove();
    else if (k === 'm') setMode('translate');
    else if (k === 'r') setMode('rotate');
    else if (k === 's') setMode('scale');
    else if (k === 'f') $('btn-flat').click();
    else if (k === 'a') arrange();
    else if (k === 'escape') selectItem(null);
  });
}

function moreMenu() {
  const it = item(state.selected);
  openSheet('Más opciones', [
    { label: 'Apoyar automáticamente', hint: 'Gira la pieza para apoyarla sobre su cara más grande', disabled: !it,
      action: () => { autoFlat(it); afterEdit(); } },
    { label: 'Centrar en la cama', disabled: !it, action: () => { center(it); afterEdit(); } },
    { label: 'Hacer copias…', hint: 'Llena la placa con varias copias', disabled: !it, action: () => {
      const n = parseInt(prompt('¿Cuántas copias más?', '3'), 10);
      if (n > 0 && n <= 100) duplicate(n);
    } },
    { label: 'Restablecer tamaño', disabled: !it, action: () => { it.node.scale.setScalar(1); afterEdit(); } },
    { label: 'Acomodar todas las placas', action: () => { const cur = state.plate; for (const p of state.plates) arrange(p.index); showPlate(cur); } },
    { label: 'Renombrar o borrar la placa', action: () => plateMenu(state.plates.find((p) => p.index === state.plate)) },
  ]);
}

// ---- hojas ----------------------------------------------------------------------------------------------
function openSheet(title, entries, html) {
  $('sheet-title').textContent = title;
  const body = $('sheet-body');
  body.innerHTML = html || '';
  for (const e of entries || []) {
    const b = document.createElement('button');
    b.className = 'menu-item';
    b.disabled = !!e.disabled;
    if (e.disabled) b.style.opacity = 0.4;
    b.innerHTML = `<div><div>${escapeHtml(e.label)}</div>${e.hint ? `<small>${escapeHtml(e.hint)}</small>` : ''}</div>`;
    b.onclick = () => { closeSheet(); e.action(); };
    body.appendChild(b);
  }
  $('sheet').hidden = false;
  return body;
}
function closeSheet() { $('sheet').hidden = true; }
$('sheet-close').onclick = closeSheet;
$('sheet').addEventListener('click', (e) => { if (e.target.id === 'sheet') closeSheet(); });

async function addFromLibrary() {
  const body = openSheet('Agregar de la biblioteca', [], '<div class="spinner" style="margin:24px auto"></div>');
  try {
    const items = await (await api('/api/library')).json();
    const ok = items.filter((i) => !i.meta?.sliced && /\.(stl|obj|3mf)$/i.test(i.filename));
    body.innerHTML = ok.length ? '' : '<p style="color:var(--muted)">No hay modelos sin laminar en la biblioteca.</p>';
    for (const i of ok) {
      const b = document.createElement('button');
      b.className = 'lib-item';
      const thumb = i.meta?.catalog?.image
        ? `/api/catalog/image?url=${encodeURIComponent(i.meta.catalog.image)}&w=160&token=${encodeURIComponent(token)}`
        : (i.meta?.project_plates || []).some((p) => p.thumbnail)
          ? `/api/library/${i.id}/plates/${i.meta.project_plates.find((p) => p.thumbnail).index}/thumbnail.png?token=${encodeURIComponent(token)}`
          : null;
      b.innerHTML = `${thumb ? `<img src="${thumb}" alt="">` : '<span class="ph"></span>'}
        <div><div>${escapeHtml(i.name)}</div><small>${(i.meta?.format || '3mf').toUpperCase()}</small></div>`;
      b.onclick = async () => {
        closeSheet();
        await addLibraryItem(i.id);
      };
      body.appendChild(b);
    }
  } catch (e) {
    body.innerHTML = `<p style="color:var(--danger)">${escapeHtml(e.message)}</p>`;
  }
}

async function addLibraryItem(id) {
  showLoading('Cargando modelo…');
  try {
    const data = await (await api(`/api/library/${id}/scene?printer_id=${encodeURIComponent(printerId)}`)).json();
    await loadSceneObjects(data);
    const src = data.items.filter((i) => i.plate === (data.items[0]?.plate ?? 1));
    let last = null, lost = 0;
    for (const s of src) {
      const it = addItem({ ...s, plate: state.plate });
      dropToBed(it.node);
      if (!placeFree(it, new THREE.Vector2(state.bed.w / 2, state.bed.d / 2))) lost++;
      last = it;
    }
    if (last) selectItem(last.uid);
    renderPlates();
    checkBounds();
    commit();
    toast(lost ? 'Agregado, pero no entra: pasalo a otra placa' : 'Modelo agregado');
  } catch (e) {
    toast(e.message);
  } finally {
    hideLoading();
  }
}

// ---- guardar ------------------------------------------------------------------------------------------------
function thumbnails() {
  const out = {};
  const size = renderer.getSize(new THREE.Vector2());
  const oldPos = camera.position.clone(), oldTarget = orbit.target.clone(), oldAspect = camera.aspect;
  const oldSel = selBox.visible, oldBg = scene.background;
  tc.getHelper().visible = false;
  selBox.visible = false;
  renderer.setSize(512, 512, false);
  camera.aspect = 1;
  camera.updateProjectionMatrix();
  for (const p of state.plates) {
    const its = plateItems(p.index);
    if (!its.length) continue;
    for (const i of state.items) i.node.visible = i.plate === p.index;
    const box = new THREE.Box3();
    for (const i of its) box.union(bboxOf(i.node, false));
    const c = box.getCenter(new THREE.Vector3());
    const r = Math.max(box.getSize(new THREE.Vector3()).length(), 30);
    camera.position.set(c.x - r * 0.35, c.y - r * 1.05, c.z + r * 0.85);
    camera.lookAt(c);
    bedGroup.visible = false;
    scene.background = null;
    renderer.setClearColor(0x000000, 0);
    renderer.render(scene, camera);
    out[p.index] = renderer.domElement.toDataURL('image/png');
  }
  bedGroup.visible = true;
  scene.background = oldBg;
  renderer.setSize(size.x, size.y, false);
  camera.aspect = oldAspect;
  camera.updateProjectionMatrix();
  camera.position.copy(oldPos);
  orbit.target.copy(oldTarget);
  orbit.update();
  tc.getHelper().visible = true;
  selBox.visible = oldSel;
  showPlate(state.plate, false);
  return out;
}

async function save() {
  if (!state.items.length) return toast('No hay piezas para guardar');
  const out = state.items.filter((i) => { const v = i.node.visible; i.node.visible = true; const o = outOfBed(i); i.node.visible = v; return o; });
  if (out.length && !confirm(`${out.length === 1 ? 'Hay 1 pieza' : `Hay ${out.length} piezas`} fuera de la cama. ¿Guardar igual?`)) return;
  const btn = $('btn-save');
  btn.disabled = true;
  btn.textContent = 'Guardando…';
  try {
    const used = [...new Set(state.items.map((i) => i.plate))];
    const body = {
      name: $('name').value.trim() || state.name || 'Proyecto',
      printer_id: printerId || null,
      plates: state.plates.filter((p) => used.includes(p.index)),
      items: state.items.map((i) => { i.node.updateMatrix(); return { key: i.key, plate: i.plate, matrix: matrixToM12(i.node.matrix), extruder: i.extruder }; }),
      thumbnails: thumbnails(),
      replace: state.source.startsWith('editor'),
    };
    const res = await (await api(`/api/library/${lid}/scene`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    })).json();
    state.dirty = false;
    notifyHost({ type: 'saved', id: res.id, slice: true });
    if (!hostAvailable()) toast('Guardado en la biblioteca. Volvé a OpenBambu para laminarlo.');
  } catch (e) {
    toast('No se pudo guardar: ' + e.message);
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<span class="long">Guardar y laminar</span><span class="short">Laminar</span>';
  }
}

function hostAvailable() { return !!window.OpenBambu || window.parent !== window; }
function notifyHost(msg) {
  if (window.OpenBambu?.postMessage) window.OpenBambu.postMessage(JSON.stringify(msg));
  else if (window.parent !== window) window.parent.postMessage({ source: 'openbambu-editor', ...msg }, '*');
}
function back() {
  if (state.dirty && !confirm('Hay cambios sin guardar. ¿Salir igual?')) return;
  if (hostAvailable()) notifyHost({ type: 'close' });
  else history.length > 1 ? history.back() : window.close();
}

// ---- utilidades ------------------------------------------------------------------------------------------
let toastTimer;
function toast(text) {
  const t = $('toast');
  t.textContent = text;
  t.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove('show'), 3200);
}
function showLoading(text) { $('loading-text').textContent = text; $('loading').classList.remove('hidden'); }
function hideLoading() { $('loading').classList.add('hidden'); }
function escapeHtml(s) { return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])); }

// ---- arranque -------------------------------------------------------------------------------------------
async function init() {
  bindTools();
  bindPanel();
  resize();
  if (!lid || !token) { $('loading-text').textContent = 'Falta el archivo a editar'; return; }
  try {
    const data = await (await api(`/api/library/${lid}/scene?printer_id=${encodeURIComponent(printerId)}`)).json();
    state.name = data.name;
    state.source = data.source || '';
    state.bed = data.bed;
    state.plates = data.plates.length ? data.plates : [{ index: 1, name: '' }];
    state.filaments = data.filaments || [];
    $('name').value = data.name;
    $('subtitle').textContent = `${data.items.length} ${data.items.length === 1 ? 'pieza' : 'piezas'} · cama ${data.bed.w}×${data.bed.d} mm`;
    buildBed();
    showLoading(`Cargando ${data.objects.length === 1 ? 'la pieza' : data.objects.length + ' piezas'}…`);
    await loadSceneObjects(data);
    for (const s of data.items) addItem(s);
    const first = +(qs.get('plate') || 0);
    showPlate(state.plates.some((p) => p.index === first) ? first : state.plates[0].index);
    setView('iso');
    lastSnap = snapshot();
    updateTools();
    updatePanel();
    hideLoading();
    if (data.objects.some((o) => o.parts.some((p) => p.painted))) toast('Las piezas pintadas conservan sus colores al laminar');
  } catch (e) {
    $('loading-text').textContent = 'No se pudo abrir: ' + e.message;
    document.querySelector('#loading .spinner').style.display = 'none';
  }
  loop();
}
init();
