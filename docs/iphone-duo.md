# Graft on the iPhone Duo

Design notes: [the Duo canvas](https://claude.ai/artifact/L8kjQ6MXNqsNdFPr6WpGPX); Apple: https://developer.apple.com/iphone-duo/.

## Closed (≈ 466 × 678 pt, compact width)

The phone app as it is: `GraftTabBar` (Inbox · Projects · Settings) at the
bottom, the floating + on the Inbox, and an issue pushed over the list.

## Open (≈ 890 × 626 pt, regular × regular)

The iPad layout (`ios/GraftApp.swift`, `ios/Views/Sidebar.swift`,
`ios/Views/InboxView.swift`):

- `GraftSideBar` stacks Inbox · Projects · Settings down the leading edge,
  the amber pending count on Settings included, with the favourite projects
  under them. It folds to a 52 pt strip (`⌃⌘S`, remembered).
- With 700 pt for the Inbox, the list (380 pt) sits on the left and the open
  issue on the right; the + is "+ Issue" in the list header, never floating.
- The external display takes its screen from the window scene already.

## Fold and unfold

Nothing is sized from the screen or the device, only from the size class and
the width the Inbox is given. The Inbox draws one view tree in both layouts,
so the list keeps its scroll position and search field across the switch.
The open issue survives both ways: closing pushes it over the list; opening
takes it (or one tapped on the phone, while it is still on top) off the stack
and back into the right pane (`InboxView.setSplit`, `push`).

## Waiting on the iOS 27.1 SDK or a device

- `GraftTabBar` is hand-built (`Views/Chrome.swift`), so it stays at the
  bottom when the SDK turns system bars vertical. Closed, that is the right
  place; open, the sidebar replaces it. Check it against the SDK's bars.
- Unfolding while an issue is pushed: check that the split's width change
  reaches the Inbox while it is covered, so the issue moves back beside the list.
- The hinge against the 380 pt list and the status area on the right edge.
