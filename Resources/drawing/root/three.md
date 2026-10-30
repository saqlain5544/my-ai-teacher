---
name: three
title: three.js in a ```visual (libs: three)
summary: three.js r158 for 3D scenes: geometry, lights, cameras, animation (global THREE).
aliases: three.js, threejs, 3d, webgl
needs: visual
order: 51
---
The core three.js r158 build with WebGL, as the global `THREE`. Core only, no addons: no `OrbitControls`, `GLTFLoader`, `TextGeometry` or `EffectComposer`. Rotate with a few lines of pointer code (below), label with HTML laid over the canvas, build geometry in code, and make textures from a canvas (`THREE.CanvasTexture`); nothing loads from files or the web.

```visual
<!-- title: A unit cube on its axes (drag to turn); libs: three; height: 320 -->
<div id="stage"></div>
<script>
const W = Math.min(document.body.clientWidth - 16, 560), H = 300;
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
renderer.setPixelRatio(devicePixelRatio);
renderer.setSize(W, H);
document.getElementById('stage').appendChild(renderer.domElement);
const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(45, W / H, 0.1, 100);
camera.position.set(3, 2.4, 4);
camera.lookAt(0, 0, 0);
scene.add(new THREE.AmbientLight(0xffffff, 0.6));
const sun = new THREE.DirectionalLight(0xffffff, 1.5);
sun.position.set(3, 5, 2);
scene.add(sun);
const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#2f6fec';
const cube = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshStandardMaterial({ color: accent }));
scene.add(cube, new THREE.AxesHelper(1.6));
let drag = null, rx = 0.4, ry = 0.6;
renderer.domElement.addEventListener('pointerdown', e => { drag = [e.clientX, e.clientY, rx, ry]; });
addEventListener('pointerup', () => { drag = null; });
addEventListener('pointermove', e => {
  if (drag) { ry = drag[3] + (e.clientX - drag[0]) / 100; rx = drag[2] + (e.clientY - drag[1]) / 100; }
});
renderer.setAnimationLoop(() => {
  if (!drag) ry += 0.005;
  cube.rotation.set(rx, ry, 0);
  renderer.render(scene, camera);
});
</script>
```

- Size the renderer to the frame (`document.body.clientWidth - 16`); `alpha: true` keeps the reply's background behind the scene.
- `MeshStandardMaterial` needs lights; `MeshBasicMaterial` and `LineBasicMaterial` don't. Colours take CSS strings, so theme colours work.
- Animate with `renderer.setAnimationLoop`; keep scenes to thousands of objects, not millions.
- Everything else about the frame (header, sandbox, errors): `draw` visual.
