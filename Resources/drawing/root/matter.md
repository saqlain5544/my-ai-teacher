---
name: matter
title: Matter.js in a ```visual (libs: matter)
summary: Matter.js 0.20 for 2D physics: gravity, collisions, friction, springs, pendulums, things to drag (global Matter).
aliases: matter.js, matterjs, physics
needs: visual
order: 54
---
```visual
<!-- title: Drop boxes and drag them; libs: matter; height: 320 -->
<div id="world"></div>
<button id="drop">Drop a box</button>
<script>
const { Engine, Render, Runner, Bodies, Composite, Mouse, MouseConstraint } = Matter;
const W = Math.min(document.body.clientWidth - 16, 560), H = 260;
const engine = Engine.create();
const render = Render.create({ element: document.getElementById('world'), engine,
  options: { width: W, height: H, wireframes: false, background: 'transparent' } });
const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#2f6fec';
const wall = { isStatic: true, render: { visible: false } };
Composite.add(engine.world, [
  Bodies.rectangle(W / 2, H + 25, W, 50, wall), Bodies.rectangle(-25, H / 2, 50, H * 2, wall), Bodies.rectangle(W + 25, H / 2, 50, H * 2, wall),
  Bodies.rectangle(W / 2, 40, 50, 50, { restitution: 0.4, render: { fillStyle: accent } }),
]);
const mouse = Mouse.create(render.canvas);
mouse.element.removeEventListener('wheel', mouse.mousewheel);   // let the lesson scroll over the canvas
Composite.add(engine.world, MouseConstraint.create(engine, { mouse }));
document.getElementById('drop').addEventListener('click', () => Composite.add(engine.world,
  Bodies.rectangle(40 + Math.random() * (W - 80), 0, 40, 40, { restitution: 0.4, render: { fillStyle: '#f76b15' } })));
Render.run(render);
Runner.run(Runner.create(), engine);
</script>
```

- `wireframes: false` shows fill colours; `background: 'transparent'` keeps the reply's background.
- Walls are static bodies just outside the canvas, or everything falls away.
- `Mouse.create` captures the wheel, which stops the lesson scrolling: remove its listener as above.
- Units are pixels and engine steps (about 60 a second); gravity is `engine.gravity.y` (default 1).
- Frame, sandbox and errors: `draw` visual.
