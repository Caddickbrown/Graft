# Design

Graft's look is its own. This folder records it; the shared parts underneath
(checks, wording, keyboard map, helpers) come from `../kit/`, copied in from the
kit's home and checked for drift. See `../kit/README.md`.

## Identity

| | |
|---|---|
| Palette | `tokens.json`, recorded from `ios/Views/DesignSystem.swift`; the web UI (`web/style.css`) uses its dark values |
| Modes | Light and dark on iOS; the web is dark |
| Type | Bricolage Grotesque for display, Geist for text, Geist Mono for figures |
| Shape | Small radii (xs to pill), hairline rows |

`tokens.json` records the current values unchanged. Nothing is generated from it
yet: screens still read the original file. When they move over, add `css` and/or
`swift` outputs under `build` (see `../kit/specs/TOKENS.md`).

## Against the kit

Run `python3 kit/tools/build_tokens.py --check` and `python3 kit/tools/kit_check.py`
from the repo root; CI runs both in `.github/workflows/kit.yml`.

Contrast:

- None: every required pair passes in light and dark.

Notes:

- Fonts are bundled with the app; nothing loads from an outside font host.
- Animations stop under Reduce Motion.
