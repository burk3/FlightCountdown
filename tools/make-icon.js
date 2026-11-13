// Builds media/icon.svg (and media/icon.png if @resvg/resvg-js is available):
// a grey flight-path badge with a 1-bit classic-Mac-style hourglass cursor.
//   node tools/make-icon.js
const fs = require('fs');
const path = require('path');

const SIZE = 512;

// ---- Hourglass: 16x22 pixel grid ------------------------------------------
const W = 16, H = 22;
const inside = (x, y) => {
  if (x < 0 || x >= W || y < 0 || y >= H) return false;
  if (y <= 2 || y >= 19) return true;                 // caps
  const hw = [7, 7, 6, 5, 4, 3, 2, 1, 1, 2, 3, 4, 5, 6, 7, 7][y - 3];
  return x >= 8 - hw && x <= 7 + hw;
};
const sand = (x, y) =>
  (y >= 8 && y <= 10) ||                              // last of the top bulb
  (y >= 11 && y <= 14 && x === 7) ||                  // falling stream
  (y >= 15 && y <= 18);                               // pile in the bottom bulb
const color = (x, y) => {
  if (!inside(x, y)) return null;
  if (y === 0 || y === 2 || y === 19 || y === 21) return '#000';
  if (x === 0 || x === W - 1) return '#000';
  if (y === 1 || y === 20) return '#fff';
  const edge = !inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1);
  if (edge) return '#000';
  return sand(x, y) ? '#000' : '#fff';
};

function hourglass(ox, oy, px) {
  const rects = [];
  // White 1px mask around the cursor, like classic cursors have.
  for (let y = -1; y <= H; y++) for (let x = -1; x <= W; x++) {
    if (inside(x, y)) continue;
    let near = false;
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) if (inside(x + dx, y + dy)) near = true;
    if (near) rects.push(`<rect x="${ox + x * px}" y="${oy + y * px}" width="${px}" height="${px}" fill="#fff"/>`);
  }
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const c = color(x, y);
    if (c) rects.push(`<rect x="${ox + x * px}" y="${oy + y * px}" width="${px}" height="${px}" fill="${c}"/>`);
  }
  return `<g shape-rendering="crispEdges">${rects.join('')}</g>`;
}

// ---- Badge + winged boot ---------------------------------------------------
const cx = 232, cy = 228, r = 206;
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">
  <defs>
    <linearGradient id="ring" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#d4d7db"/><stop offset="0.5" stop-color="#8a8e95"/><stop offset="1" stop-color="#55595f"/>
    </linearGradient>
    <radialGradient id="disc" cx="0.42" cy="0.36" r="0.75">
      <stop offset="0" stop-color="#6d7178"/><stop offset="1" stop-color="#2c2f34"/>
    </radialGradient>
    <linearGradient id="metal" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#f1f2f4"/><stop offset="1" stop-color="#a9adb3"/>
    </linearGradient>
  </defs>
  <circle cx="${cx}" cy="${cy}" r="${r}" fill="#1d1f23"/>
  <circle cx="${cx}" cy="${cy}" r="${r - 8}" fill="url(#ring)"/>
  <circle cx="${cx}" cy="${cy}" r="${r - 30}" fill="#1d1f23"/>
  <circle cx="${cx}" cy="${cy}" r="${r - 36}" fill="url(#disc)"/>

  <g transform="translate(${cx - 22} ${cy - 14}) scale(0.78) translate(-217 -219)" stroke="#1d1f23" stroke-width="7" stroke-linejoin="round" fill="url(#metal)">
    <!-- wing: three feathers sweeping back from the ankle -->
    <path d="M196,168 C154,118 114,96 70,100 C100,126 138,162 192,204 Z"/>
    <path d="M194,198 C146,160 100,146 50,154 C88,180 134,206 192,230 Z"/>
    <path d="M194,228 C150,206 112,202 74,214 C108,232 148,248 194,254 Z"/>
    <!-- boot -->
    <path d="M190,118 L270,118 L274,250 C288,262 318,266 346,276 C372,286 382,304 380,330
             L380,342 L186,342 L186,322 C180,270 182,190 190,118 Z"/>
    <!-- cuff and sole -->
    <path d="M178,96 L282,96 L282,128 L178,128 Z"/>
    <path d="M180,330 L384,330 L384,352 L180,352 Z" fill="#7d8188"/>
  </g>

  ${hourglass(SIZE - 18 * 9 - 6, SIZE - 24 * 9 - 6, 9)}
</svg>
`;

const outDir = path.join(__dirname, '..', 'media');
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'icon.svg'), svg);
try {
  const { Resvg } = require('@resvg/resvg-js');
  fs.writeFileSync(path.join(outDir, 'icon.png'), new Resvg(svg).render().asPng());
  console.log('wrote media/icon.svg and media/icon.png');
} catch (e) {
  console.log('wrote media/icon.svg (install @resvg/resvg-js to also render the PNG)');
}
