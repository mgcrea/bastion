import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  /// Server profiles dragged within Bastion, a sidebar row moving between
  /// workspaces. Exported by `Bastion-Info.plist`, conforming to `public.data`
  /// only, so another app the drag reaches finds nothing it can read as text,
  /// a URL or a file.
  nonisolated static let bastionProfiles = UTType(
    exportedAs: "io.mgcrea.bastion.profiles", conformingTo: .data)
}

/// What a dragged server row carries: the profiles it holds and the section
/// they came from, which is what a move needs to know to take them out of it.
nonisolated struct ServerDragPayload: Codable, Transferable, Sendable {
  let serverID: String
  let profileIDs: [String]
  let from: ServerSectionKind

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .bastionProfiles)
      .visibility(.ownProcess)
  }
}

/// The sidebar's `ServerDropTargeting` for the drag in progress, shared through
/// the environment by the rows that report it and the ones that draw it.
/// Cadence's `SectionDropHighlight`, which this follows line for line.
///
/// A section lights at once and goes dark a moment late. The sidebar says a
/// drag left a row before it says it entered the next, and a section that went
/// dark in between would blink at every row. The sidebar also reports no drag
/// session, so the drag is over when the mouse button comes up, whatever the
/// targets last said.
@Observable
final class ServerDropHighlight {
  private(set) var lit: ServerSectionKind?

  @ObservationIgnored private var targeting = ServerDropTargeting()
  @ObservationIgnored private var darkening: Task<Void, Never>?
  @ObservationIgnored private var release: Task<Void, Never>?

  func dragBegan(in kind: ServerSectionKind) {
    watchForRelease()
    guard targeting.source != kind else { return }
    targeting = ServerDropTargeting(source: kind)
    show()
  }

  func target(_ kind: ServerSectionKind, isTargeted: Bool) {
    if isTargeted { watchForRelease() }
    targeting.target(kind, isTargeted: isTargeted)
    show()
  }

  func dragEnded() {
    targeting = ServerDropTargeting()
    darkening?.cancel()
    darkening = nil
    release?.cancel()
    release = nil
    lit = nil
  }

  private func show() {
    let next = targeting.lit
    darkening?.cancel()
    darkening = nil
    guard next == nil, lit != nil else {
      if lit != next { lit = next }
      return
    }
    darkening = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled, let self else { return }
      lit = targeting.lit
    }
  }

  private func watchForRelease() {
    guard release == nil else { return }
    release = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(150))
        guard NSEvent.pressedMouseButtons & 1 == 0 else { continue }
        self?.dragEnded()
        return
      }
    }
  }
}

/// An empty workspace's one row: somewhere to drop, so a workspace just made
/// is visibly a place.
struct DropHereRow: View {
  var body: some View {
    Text("Drag servers here")
      .font(.callout)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("No servers in this workspace")
  }
}

extension View {
  /// Makes this row draggable with the profiles it holds. A row holding none,
  /// a server with no credentials, has nothing to move and is left alone.
  func serverDragSource(_ row: ServerRow, in section: ServerSection) -> some View {
    modifier(ServerDragSource(row: row, kind: section.kind))
  }

  /// Makes this row somewhere to drop server rows into `section`. While a drag
  /// is over any of its targets the whole section is washed in the accent
  /// colour, so it is the section that reads as the destination, not the row.
  func serverDropTarget(
    _ section: ServerSection, drop: @escaping (ServerDragPayload) -> Bool
  ) -> some View {
    modifier(ServerDropTarget(kind: section.kind, drop: drop))
  }
}

private struct ServerDragSource: ViewModifier {
  @Environment(ServerDropHighlight.self) private var highlight: ServerDropHighlight?

  let row: ServerRow
  let kind: ServerSectionKind

  @ViewBuilder
  func body(content: Content) -> some View {
    if row.profileIDs.isEmpty {
      content
    } else {
      content.draggable(payload())
    }
  }

  /// Asked for once, as the drag begins, so it is also where the drag is seen
  /// to begin: the sidebar's rows report no drag session of their own.
  private func payload() -> ServerDragPayload {
    highlight?.dragBegan(in: kind)
    return ServerDragPayload(serverID: row.serverID, profileIDs: row.profileIDs, from: kind)
  }
}

private struct ServerDropTarget: ViewModifier {
  @Environment(ServerDropHighlight.self) private var highlight: ServerDropHighlight?

  let kind: ServerSectionKind
  let drop: (ServerDragPayload) -> Bool

  func body(content: Content) -> some View {
    content
      .background {
        // Grown to meet the rows either side, so a lit section reads as one
        // block. The sidebar draws no row background to borrow.
        if highlight?.lit == kind {
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(0.18))
            .padding(.horizontal, -6)
            .padding(.vertical, -4)
        }
      }
      .dropDestination(for: ServerDragPayload.self) { payloads, _ in
        highlight?.dragEnded()
        // One row per drag on the Mac, but the API hands a list.
        let moved = payloads.filter { $0.from != kind }
        guard !moved.isEmpty else { return false }
        return moved.allSatisfy(drop)
      } isTargeted: { isTargeted in
        highlight?.target(kind, isTargeted: isTargeted)
      }
  }
}

/// Turns off the drop feedback the sidebar's table draws on its own. It draws
/// the row under a dragged server exactly like a selection, which says the
/// row is where the server will land, when it is the section that is. The
/// section's wash says that instead. From Cadence, without its selection
/// change: Bastion's sidebar keeps the system selection.
///
/// SwiftUI has no say in this, so it finds the `NSTableView` behind the `List`
/// it is put behind and sets it there.
struct SidebarTableFeedback: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    // Not yet in the hierarchy; one runloop hop later it is.
    DispatchQueue.main.async { Self.apply(from: view) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    Self.apply(from: nsView)
  }

  /// The nearest table: up from this view, one level at a time, so another
  /// table elsewhere in the window is never the one found.
  private static func apply(from view: NSView) {
    var ancestor = view.superview
    while let current = ancestor {
      if let table = firstTable(in: current) {
        if table.draggingDestinationFeedbackStyle != .none {
          table.draggingDestinationFeedbackStyle = .none
        }
        return
      }
      ancestor = current.superview
    }
  }

  private static func firstTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
      if let table = firstTable(in: subview) { return table }
    }
    return nil
  }
}
