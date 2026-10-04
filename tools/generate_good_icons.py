"""Generate placeholder 64x64 SVG icons for every tradable good (plus gold).

Output: assets/icons/goods/<name>.svg  (Godot imports SVG as Texture2D).
Flat shapes, dark outline, one fill color per good -- readable at 16-24px.
Colors mirror Commodity.DATA in scripts/sim/records/commodity.gd; keep in sync.
Swap any file for a real asset later without touching code (same filename).

Run: python tools/generate_good_icons.py
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "icons" / "goods"
OL = "#23232b"  # outline


def svg(body: str) -> str:
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64" viewBox="0 0 64 64" '
        f'stroke="{OL}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round">{body}</svg>\n'
    )


def grain() -> str:
    c = "#d9b44a"
    kernels = "".join(
        f'<ellipse cx="{x}" cy="{y}" rx="5" ry="8" transform="rotate({r} {x} {y})" fill="{c}"/>'
        for x, y, r in [(24, 20, -30), (40, 20, 30), (22, 34, -30), (42, 34, 30), (32, 14, 0)]
    )
    return svg(f'<path d="M32 58V30" fill="none"/>{kernels}<ellipse cx="32" cy="28" rx="5" ry="8" fill="{c}"/>')


def cattle() -> str:
    c = "#a9744f"
    return svg(
        f'<path d="M8 18c2 8 6 10 10 10M56 18c-2 8-6 10-10 10" fill="none"/>'
        f'<path d="M18 22h28l4 14c0 10-8 20-18 20S14 46 14 36z" fill="{c}"/>'
        '<ellipse cx="32" cy="46" rx="9" ry="6" fill="#e6c3a3"/>'
        f'<circle cx="25" cy="34" r="2" fill="{OL}"/><circle cx="39" cy="34" r="2" fill="{OL}"/>'
    )


def sheep() -> str:
    return svg(
        '<circle cx="22" cy="28" r="10" fill="#e8e4d8"/><circle cx="34" cy="24" r="11" fill="#e8e4d8"/>'
        '<circle cx="44" cy="30" r="9" fill="#e8e4d8"/><circle cx="30" cy="36" r="11" fill="#e8e4d8"/>'
        f'<path d="M16 38v14M42 40v12" fill="none"/>'
        f'<ellipse cx="50" cy="38" rx="7" ry="8" fill="#4a4a52"/>'
    )


def wool() -> str:
    return svg(
        '<circle cx="32" cy="32" r="22" fill="#cfc6b4"/>'
        '<path d="M14 26c12 6 24 6 36 0M12 36c14 8 26 8 40 0M18 46c10 5 18 5 28 0M20 16c8 5 16 5 24 0" fill="none"/>'
    )


def timber() -> str:
    b = "#8b5a2b"
    return svg(
        f'<rect x="6" y="22" width="52" height="20" rx="3" fill="{b}"/>'
        '<ellipse cx="54" cy="32" rx="5" ry="10" fill="#d9b27c"/>'
        '<ellipse cx="54" cy="32" rx="2" ry="5" fill="none" stroke-width="2"/>'
        '<path d="M14 28h24M14 36h18" fill="none" stroke-width="2"/>'
    )


def charcoal() -> str:
    c = "#4a4a52"
    return svg(
        f'<path d="M10 50l6-16 14-4 10 8 12-4 4 16z" fill="{c}"/>'
        f'<path d="M22 32l8-14 12 6 4 12z" fill="#3a3a42"/>'
        '<path d="M28 24l4-4M36 30l6 2" fill="none" stroke="#8a8a96" stroke-width="2"/>'
    )


def iron_ore() -> str:
    return svg(
        '<path d="M8 48l6-20 16-12 18 8 10 22-12 8H18z" fill="#7b5e57"/>'
        '<circle cx="26" cy="32" r="4" fill="#c46a3a" stroke-width="2"/>'
        '<circle cx="40" cy="38" r="5" fill="#c46a3a" stroke-width="2"/>'
        '<circle cx="34" cy="24" r="3" fill="#9aa5b1" stroke-width="2"/>'
    )


def iron_ingot() -> str:
    return svg(
        '<path d="M6 44l10-22h32l10 22z" fill="#9aa5b1"/>'
        '<path d="M16 22l-4 10h40l-4-10z" fill="#c9d1d9" stroke-width="0"/>'
        '<path d="M6 44h52v6H6z" fill="#6f7a86"/>'
        '<path d="M22 28h12" fill="none" stroke="#ffffff" stroke-width="2.5"/>'
    )


def tools() -> str:
    return svg(
        '<path d="M14 52L36 30" stroke-width="7" fill="none"/><path d="M14 52L36 30" stroke="#b58b5a" stroke-width="3.5" fill="none"/>'
        '<path d="M30 14c10-4 20 4 18 14l-8 2-6-6z" fill="#9aa5b1"/>'
        '<path d="M50 52L28 30" stroke-width="7" fill="none"/><path d="M50 52L28 30" stroke="#b58b5a" stroke-width="3.5" fill="none"/>'
    )


def gold() -> str:
    return svg(
        '<circle cx="32" cy="32" r="24" fill="#f2c230"/>'
        '<circle cx="32" cy="32" r="16" fill="none" stroke="#b8860b" stroke-width="3"/>'
        '<path d="M26 32h12M32 24v16" stroke="#b8860b" stroke-width="3" fill="none"/>'
    )


ICONS = {
    "grain": grain, "cattle": cattle, "sheep": sheep, "wool": wool, "timber": timber,
    "charcoal": charcoal, "iron_ore": iron_ore, "iron_ingot": iron_ingot, "tools": tools, "gold": gold,
}

if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in ICONS.items():
        (OUT / f"{name}.svg").write_text(fn(), encoding="utf-8")
        print("wrote", OUT / f"{name}.svg")
