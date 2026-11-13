// Builds media/icon.png: the winged boot (media/src/boot.webp) with the
// classic Mac OS wristwatch "busy" cursor drawn as
// crisp pixel art in the lower-right corner.
//
//   npm install sharp   (anywhere on NODE_PATH)
//   node tools/make-icon.js
const path = require('path');
const sharp = require('sharp');

const SIZE = 512;   // output size
const PX = 13;      // size of one cursor pixel in the output
const MARGIN = 6;

// Classic Mac OS watch cursor, 10x16. '#' = black.
const WATCH = [
  '..######..',
  '..######..',
  '..######..',
  '..######..',
  '.#......#.',
  '#....#...#',
  '#....#...#',
  '#....#...##',
  '#..###...##',
  '#........#',
  '#........#',
  '.#......#.',
  '..######..',
  '..######..',
  '..######..',
  '..######..',
].map((r) => r.padEnd(11, '.'));

const H = WATCH.length, W = WATCH[0].length;
const black = (x, y) => y >= 0 && y < H && x >= 0 && x < W && WATCH[y][x] === '#';

// Cells reachable from the border without crossing black are "outside";
// everything else that isn't black is the white watch face.
const outside = new Set();
const key = (x, y) => `${x},${y}`;
const stack = [[-1, -1]];
while (stack.length) {
  const [x, y] = stack.pop();
  if (x < -1 || y < -1 || x > W || y > H || outside.has(key(x, y)) || black(x, y)) continue;
  outside.add(key(x, y));
  stack.push([x + 1, y], [x - 1, y], [x, y + 1], [x, y - 1]);
}

function watchSvg() {
  const rects = [];
  const cell = (x, y, fill) =>
    rects.push(`<rect x="${(x + 1) * PX}" y="${(y + 1) * PX}" width="${PX}" height="${PX}" fill="${fill}"/>`);
  for (let y = -1; y <= H; y++) {
    for (let x = -1; x <= W; x++) {
      if (black(x, y)) { cell(x, y, '#000'); continue; }
      if (!outside.has(key(x, y))) { cell(x, y, '#fff'); continue; }
      // 1px white mask around the cursor so it reads on any background.
      let near = false;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) if (black(x + dx, y + dy)) near = true;
      if (near) cell(x, y, '#fff');
    }
  }
  const w = (W + 2) * PX, h = (H + 2) * PX;
  return {
    w, h,
    svg: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" shape-rendering="crispEdges">${rects.join('')}</svg>`),
  };
}

(async () => {
  const root = path.join(__dirname, '..', 'media');
  const base = await sharp(path.join(root, 'src', 'boot.webp'))
    .resize(SIZE, SIZE, { kernel: 'lanczos3' })
    .png()
    .toBuffer();

  const watch = watchSvg();
  await sharp(base)
    .composite([{ input: watch.svg, left: SIZE - watch.w - MARGIN, top: SIZE - watch.h - MARGIN }])
    .png()
    .toFile(path.join(root, 'icon.png'));
  console.log('wrote media/icon.png');
})();
