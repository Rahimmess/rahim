/* OpenWalls preview.
 *
 * Loads model.json -- written by tools/demo.rb with no SketchUp involved --
 * and renders it. The point of this page is to make the headless core
 * visible: if the engine can draw a building here, in a browser, from a
 * terminal, then the SketchUp adapter really is a thin shell over it.
 */
import * as THREE from 'three';

const stage = document.getElementById('stage');
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x11131a);
scene.fog = new THREE.Fog(0x11131a, 18000, 48000);

const camera = new THREE.PerspectiveCamera(45, 1, 10, 200000);
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap;
stage.appendChild(renderer.domElement);

/* ------------------------------------------------------------- lighting */

scene.add(new THREE.HemisphereLight(0xcfe0ff, 0x2a2d35, 1.5));
const sun = new THREE.DirectionalLight(0xffffff, 2.1);
sun.position.set(-9000, -14000, 16000);
sun.castShadow = true;
sun.shadow.mapSize.set(2048, 2048);
const d = 14000;
Object.assign(sun.shadow.camera, { left: -d, right: d, top: d, bottom: -d, near: 100, far: 60000 });
scene.add(sun);

const ground = new THREE.Mesh(
  new THREE.PlaneGeometry(120000, 120000),
  new THREE.ShadowMaterial({ opacity: 0.35 })
);
ground.receiveShadow = true;
scene.add(ground);

const grid = new THREE.GridHelper(60000, 60, 0x2b3240, 0x1d222c);
grid.rotation.x = Math.PI / 2;
grid.position.z = -1;
scene.add(grid);

/* --------------------------------------------------- minimal orbit camera */

const target = new THREE.Vector3();
const orbit = { radius: 26000, theta: -1.15, phi: 1.02 };
let dragging = null;
let prev = { x: 0, y: 0 };

function applyCamera() {
  orbit.phi = Math.max(0.08, Math.min(Math.PI / 2 - 0.02, orbit.phi));
  const r = orbit.radius;
  camera.position.set(
    target.x + r * Math.sin(orbit.phi) * Math.cos(orbit.theta),
    target.y + r * Math.sin(orbit.phi) * Math.sin(orbit.theta),
    target.z + r * Math.cos(orbit.phi)
  );
  camera.up.set(0, 0, 1);
  camera.lookAt(target);
}

renderer.domElement.addEventListener('pointerdown', (e) => {
  dragging = e.button === 2 || e.shiftKey ? 'pan' : 'orbit';
  prev = { x: e.clientX, y: e.clientY };
  renderer.domElement.setPointerCapture(e.pointerId);
});
renderer.domElement.addEventListener('pointerup', (e) => {
  dragging = null;
  renderer.domElement.releasePointerCapture(e.pointerId);
});
renderer.domElement.addEventListener('contextmenu', (e) => e.preventDefault());
renderer.domElement.addEventListener('pointermove', (e) => {
  if (!dragging) return;
  const dx = e.clientX - prev.x;
  const dy = e.clientY - prev.y;
  prev = { x: e.clientX, y: e.clientY };
  if (dragging === 'orbit') {
    orbit.theta -= dx * 0.006;
    orbit.phi -= dy * 0.006;
  } else {
    const scale = orbit.radius * 0.0012;
    const right = new THREE.Vector3().subVectors(camera.position, target).cross(camera.up).normalize();
    const up = new THREE.Vector3().crossVectors(right, new THREE.Vector3().subVectors(camera.position, target)).normalize();
    target.addScaledVector(right, -dx * scale).addScaledVector(up, -dy * scale);
  }
  applyCamera();
});
renderer.domElement.addEventListener('wheel', (e) => {
  e.preventDefault();
  orbit.radius = Math.max(1500, Math.min(90000, orbit.radius * (1 + Math.sign(e.deltaY) * 0.12)));
  applyCamera();
}, { passive: false });

function resize() {
  const w = stage.clientWidth;
  const h = stage.clientHeight;
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.setSize(w, h);
}
addEventListener('resize', resize);

/* ------------------------------------------------------------- the model */

const root = new THREE.Group();
scene.add(root);
const byKind = new Map();
const byWall = new Map();
let edgeGroups = [];
let exploded = false;

function build(model) {
  const bounds = new THREE.Box3();

  model.walls.forEach((wall) => {
    const wallGroup = new THREE.Group();
    wallGroup.name = wall.name;
    root.add(wallGroup);
    byWall.set(wall.id, wallGroup);

    wall.layers.forEach((layer) => {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(layer.positions, 3));
      geometry.computeVertexNormals();
      geometry.computeBoundingBox();

      const mesh = new THREE.Mesh(geometry, new THREE.MeshLambertMaterial({
        color: new THREE.Color(layer.colour),
        side: THREE.DoubleSide
      }));
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      mesh.userData = { kind: layer.kind, wall: wall.id };
      wallGroup.add(mesh);

      const edgeGeometry = new THREE.BufferGeometry();
      edgeGeometry.setAttribute('position', new THREE.Float32BufferAttribute(layer.edges, 3));
      const lines = new THREE.LineSegments(edgeGeometry, new THREE.LineBasicMaterial({
        color: 0x11131a, transparent: true, opacity: 0.45
      }));
      lines.userData = { kind: layer.kind, wall: wall.id, edges: true };
      wallGroup.add(lines);
      edgeGroups.push(lines);

      if (!byKind.has(layer.kind)) byKind.set(layer.kind, { colour: layer.colour, objects: [], volume: 0 });
      const bucket = byKind.get(layer.kind);
      bucket.objects.push(mesh, lines);
      bucket.volume += layer.volume_m3;

      bounds.union(geometry.boundingBox);
    });
  });

  bounds.getCenter(target);
  orbit.radius = Math.max(bounds.max.distanceTo(bounds.min) * 1.15, 6000);
  applyCamera();
  renderHud(model);
}

function renderHud(model) {
  const s = model.stats;
  document.getElementById('stats').innerHTML = [
    ['Walls', s.walls], ['Faces', s.faces.toLocaleString()],
    ['Material', s.volume_m3 + ' m\u00b3'], ['Build', s.build_ms + ' ms']
  ].map(([k, v]) => `<div><b>${v}</b><span>${k}</span></div>`).join('') +
    `<div><b class="pill ${s.watertight ? 'ok' : 'bad'}">${s.watertight ? 'watertight' : 'open'}</b>
     <span>every solid</span></div>`;

  const kinds = document.getElementById('kinds');
  kinds.innerHTML = '';
  [...byKind.entries()].sort((a, b) => b[1].volume - a[1].volume).forEach(([kind, data]) => {
    const row = document.createElement('label');
    row.className = 'row';
    row.innerHTML = `<input type="checkbox" checked>
      <span class="sw" style="background:${data.colour}"></span>
      <span class="nm">${kind}</span>
      <span class="vl">${data.volume.toFixed(2)} m\u00b3</span>`;
    row.querySelector('input').addEventListener('change', (e) => {
      data.objects.forEach((o) => { o.visible = e.target.checked; });
    });
    kinds.appendChild(row);
  });

  const walls = document.getElementById('walls');
  walls.innerHTML = '';
  model.walls.forEach((wall) => {
    const row = document.createElement('label');
    row.className = 'row';
    row.innerHTML = `<input type="checkbox" checked>
      <span class="nm">${wall.name}</span>
      <span class="vl">${wall.volume_m3.toFixed(2)} m\u00b3</span>`;
    row.querySelector('input').addEventListener('change', (e) => {
      byWall.get(wall.id).visible = e.target.checked;
    });
    walls.appendChild(row);
  });
}

document.getElementById('toggle-edges').addEventListener('click', () => {
  edgeGroups.forEach((l) => { l.visible = !l.visible; });
});

/* Pulls the layer stack apart across its own thickness, which is the clearest
   way to show that a cavity wall really is separate solids and not a texture
   on a box. */
document.getElementById('toggle-explode').addEventListener('click', () => {
  exploded = !exploded;
  const order = [...byKind.keys()];
  byKind.forEach((data, kind) => {
    const shift = (order.indexOf(kind) - (order.length - 1) / 2) * (exploded ? 900 : 0);
    data.objects.forEach((o) => {
      o.position.set(0, 0, 0);
      o.translateOnAxis(new THREE.Vector3(0, 0, 1), shift * 0.6);
      o.position.x += shift * 0.9;
    });
  });
});

document.getElementById('reset-view').addEventListener('click', () => {
  orbit.theta = -1.15;
  orbit.phi = 1.02;
  applyCamera();
});

function animate() {
  requestAnimationFrame(animate);
  renderer.render(scene, camera);
}

fetch('model.json', { cache: 'no-store' })
  .then((r) => { if (!r.ok) throw new Error(r.status + ' ' + r.statusText); return r.json(); })
  .then((model) => { build(model); resize(); animate(); })
  .catch((err) => {
    document.getElementById('err').style.display = 'grid';
    document.getElementById('err-detail').textContent = String(err);
  });
