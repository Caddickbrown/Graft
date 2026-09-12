# Fonts

Geist, Geist Mono and Bricolage Grotesque — the same three families the web
client loads from Google Fonts — bundled so iOS renders the design in the same
type as the web, and so the app does not depend on the network for its text.

All three are SIL Open Font License 1.1; the licences are beside the files and
must ship with the app.

These are **static instances** cut from the upstream variable fonts
(github.com/google/fonts, ofl/{geist,geistmono,bricolagegrotesque}) with
fontTools, one file per weight. SwiftUI's `Font.custom` addresses a weight by
PostScript name and does not drive variation axes, so a single variable file
would have rendered every weight at its default. Bricolage is pinned to
`opsz 24, wdth 100` — it is only used at display sizes.

Subset to Latin plus the punctuation the app draws, which is what takes the
nine files to ~357 KB in total.

To regenerate, see the `build()` helper recorded in the commit that added this
directory.
