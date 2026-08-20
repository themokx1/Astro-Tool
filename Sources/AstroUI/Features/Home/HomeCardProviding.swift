import SwiftUI

/// Wave 0 seam (V3 pre-stack program, `docs/superpowers/specs/
/// 2026-08-20-v3-prestack-program.md` section 6, "Home-kompozíció" row): the
/// extension point section 5.1 (Ingest-figyelő's mounted-volume banner) and
/// section 5.6 (Élő éjszaka-mód's live-session card) will each use to
/// register their OWN Home card from their OWN file, instead of both editing
/// `HomeView.libraryOverview`'s shared body directly -- the exact
/// "two features want the same file" collision the wave plan calls out.
///
/// A provider decides per-render whether it has anything to show at all:
/// `card(store:)` returns `nil` when there is nothing real to say (no source
/// volume mounted, no live session running), following this file's own
/// "nothing real, nothing shown" rule that `HomeView.ratingGateCard`/
/// `.cloudyDarksCard` already use for their own cards. Returning `AnyView`
/// type-erases at this ONE seam only -- the alternative, giving this
/// protocol an associated `Card: View` type, would make `[any
/// HomeCardProviding]` impossible to write, since an existential collection
/// can't hold a plain associated-type protocol. `WorkspaceActionItem`'s own
/// doc comment (`Sources/AstroUI/App/WorkspaceActions.swift`) documents why
/// an `AnyView` is dangerous behind a `.focusedSceneValue` -- a fresh,
/// incomparable instance re-published every body pass caused a real
/// invalidation storm there. That risk does not apply here: this value is
/// read once per `HomeView.body` evaluation, straight into that same body's
/// own view tree, never published through a separately-diffed channel of
/// its own.
///
/// `HomeView.init` defaults `extraCardProviders` to `[]` -- until 5.1/5.6
/// land and actually register a provider, this seam contributes zero cards
/// and therefore zero behavior change, this wave's own acceptance
/// criterion.
@MainActor
public protocol HomeCardProviding {
    func card(store: HomeStore) -> AnyView?
}
