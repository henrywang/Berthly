#!/usr/bin/env python3
"""Generate production SVG sources for the Berthly C2a 'Made fast' icon."""
import math, os

OUT = os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)

def superellipse_path(cx, cy, a, n=5.0, steps=256):
    """Apple-style squircle: |x/a|^n + |y/a|^n = 1, n≈5."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2 / n), c)
        y = cy + a * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M" + " L".join(pts) + " Z"

GRADIENT = """<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3F82EC"/>
      <stop offset="1" stop-color="#2361C7"/>
    </linearGradient>"""

# C2a artwork, full detail, in 512-space
FULL_ART = """<rect x="-40" y="384" width="592" height="180" fill="#B9D4FB"/>
      <rect x="-40" y="384" width="592" height="12" fill="#8FB6F0"/>
      <path d="M-40 65 Q110 140 176 232" stroke="#8FB6F0" stroke-width="30" stroke-linecap="round" fill="none"/>
      <path d="M176 232 Q256 196 336 232" stroke="#8FB6F0" stroke-width="30" stroke-linecap="round" fill="none"/>
      <path d="M176 266 Q256 230 336 266" stroke="#8FB6F0" stroke-width="30" stroke-linecap="round" fill="none"/>
      <rect x="166" y="120" width="180" height="64" rx="32" fill="#FFFFFF"/>
      <rect x="198" y="166" width="116" height="228" fill="#FFFFFF"/>
      <rect x="154" y="352" width="204" height="52" rx="14" fill="#FFFFFF"/>
      <path d="M176 232 Q256 278 336 232" stroke="#8FB6F0" stroke-width="30" stroke-linecap="round" fill="none"/>
      <path d="M176 266 Q256 312 336 266" stroke="#8FB6F0" stroke-width="30" stroke-linecap="round" fill="none"/>
      <path d="M336 266 Q384 326 378 392" stroke="#8FB6F0" stroke-width="30" stroke-linecap="round" fill="none"/>"""

# Simplified artwork for 16/32 px targets: one heavy wrap, thicker forms
SMALL_ART = """<rect x="-40" y="380" width="592" height="184" fill="#B9D4FB"/>
      <rect x="-40" y="380" width="592" height="16" fill="#8FB6F0"/>
      <path d="M-40 76 Q104 150 162 246" stroke="#8FB6F0" stroke-width="44" stroke-linecap="round" fill="none"/>
      <path d="M162 246 Q256 202 350 246" stroke="#8FB6F0" stroke-width="44" stroke-linecap="round" fill="none"/>
      <rect x="150" y="104" width="212" height="76" rx="38" fill="#FFFFFF"/>
      <rect x="190" y="160" width="132" height="236" fill="#FFFFFF"/>
      <rect x="140" y="346" width="232" height="58" rx="16" fill="#FFFFFF"/>
      <path d="M162 246 Q256 298 350 246" stroke="#8FB6F0" stroke-width="44" stroke-linecap="round" fill="none"/>
      <path d="M350 246 Q396 300 390 368" stroke="#8FB6F0" stroke-width="44" stroke-linecap="round" fill="none"/>"""

def margined_icon(canvas, art, shadow_dy, shadow_blur):
    """macOS app-icon layout: squircle body at 80.5% of canvas, centered, drop shadow."""
    body = canvas * 824 / 1024 / 2          # half-width of the squircle body
    margin = (canvas - 2 * body) / 2
    scale = (2 * body) / 512
    sq = superellipse_path(canvas / 2, canvas / 2, body)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{canvas}" height="{canvas}" viewBox="0 0 {canvas} {canvas}">
  <defs>
    {GRADIENT}
    <clipPath id="body"><path d="{sq}"/></clipPath>
    <filter id="shadow" x="-15%" y="-15%" width="130%" height="130%">
      <feDropShadow dx="0" dy="{shadow_dy}" stdDeviation="{shadow_blur}" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <g filter="url(#shadow)">
    <path d="{sq}" fill="url(#bg)"/>
    <g clip-path="url(#body)">
      <g transform="translate({margin:.2f} {margin:.2f}) scale({scale:.6f})">
      {art}
      </g>
    </g>
  </g>
</svg>
"""

def fullbleed_squircle(art, canvas=512):
    """Squircle fills the whole canvas, no margin/shadow.

    Used for favicons AND the app-icon catalog: Berthly targets macOS 26+,
    and Tahoe puts any icon artwork smaller than its canvas on a white
    system backdrop ("icon jail"). Full-bleed art is displayed as-is;
    the system supplies masking and shadow.
    """
    half = canvas / 2
    scale = canvas / 512
    sq = superellipse_path(half, half, half)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{canvas}" height="{canvas}" viewBox="0 0 {canvas} {canvas}">
  <defs>
    {GRADIENT}
    <clipPath id="body"><path d="{sq}"/></clipPath>
  </defs>
  <path d="{sq}" fill="url(#bg)"/>
  <g clip-path="url(#body)">
    <g transform="scale({scale:.6f})">
    {art}
    </g>
  </g>
</svg>
"""

def fullbleed_square(art):
    """apple-touch-icon: square full-bleed artwork, iOS applies its own mask."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">
  <defs>
    {GRADIENT}
    <clipPath id="body"><rect width="512" height="512"/></clipPath>
  </defs>
  <rect width="512" height="512" fill="url(#bg)"/>
  <g clip-path="url(#body)">
  {art}
  </g>
</svg>
"""

MENUBAR = """<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">
  <!-- authored in 144-space: qlmanage's SVG thumbnailer lays out at user-unit size
       and ignores the width attribute, so viewBox scaling can't be relied on -->
  <g transform="scale(4)">
    <rect x="11" y="4" width="14" height="6" rx="3" fill="#000000"/>
    <rect x="14" y="8" width="8" height="18" fill="#000000"/>
    <rect x="9" y="26" width="18" height="6" rx="2" fill="#000000"/>
    <path d="M9 16 Q18 21.5 27 16" stroke="#000000" stroke-width="2.5" stroke-linecap="round" fill="none"/>
    <path d="M9 16 Q5.5 21 5 27" stroke="#000000" stroke-width="2.5" stroke-linecap="round" fill="none"/>
  </g>
</svg>
"""

files = {
    # app icon (macOS 26+): full-bleed, system applies mask + shadow
    "berthly-dock-1024.svg":   fullbleed_squircle(FULL_ART, 1024),
    # margined Big Sur-style masters, kept ONLY for the dmg volume icon
    "berthly-master-1024.svg": margined_icon(1024, FULL_ART, 10, 10),
    "berthly-small-512.svg":   margined_icon(512, SMALL_ART, 5, 5),
    "berthly-favicon-512.svg": fullbleed_squircle(SMALL_ART),
    "berthly-touch-512.svg":   fullbleed_square(FULL_ART),
    "berthly-menubar-36.svg":  MENUBAR,
}
for name, content in files.items():
    with open(os.path.join(OUT, name), "w") as f:
        f.write(content)
    print(name)
