import Foundation
import Observation

/// One entry from a `prompts/list`.
///
/// The same shape and the same bargain as `MCPTool`: what arrived, kept as
/// something that can cross a thread boundary, with the wire size measured
/// before anything was dropped.
nonisolated struct MCPPrompt: Identifiable, Sendable {
  /// One declared argument. A struct rather than a tuple because these are
  /// rendered in a `ForEach` and need an id.
  struct Argument: Identifiable, Sendable {
    let name: String
    let summary: String
    let required: Bool
    var id: String { name }
  }

  let name: String
  let summary: String
  let arguments: [Argument]
  let wireBytes: Int

  var id: String { name }

  init?(json: [String: Any]) {
    guard let name = json["name"] as? String else { return nil }
    self.name = name
    summary = json["description"] as? String ?? json["title"] as? String ?? ""
    arguments = (json["arguments"] as? [[String: Any]] ?? []).compactMap { raw in
      guard let name = raw["name"] as? String else { return nil }
      return Argument(
        name: name,
        summary: raw["description"] as? String ?? "",
        // Absent means optional, which is what the spec says and is the only
        // reading that does not invent a requirement the server never stated.
        required: raw["required"] as? Bool ?? false)
    }
    wireBytes = ToolCost.bytes(of: json)
  }
}

/// One entry from a `resources/list` or a `resources/templates/list`.
///
/// Both in one type because they differ in exactly one field — a concrete `uri`
/// against a `uriTemplate` — and a reader looking for "what can this server
/// hand me" wants them in one column, with the difference marked.
nonisolated struct MCPResource: Identifiable, Sendable {
  /// The concrete `uri`, or the `uriTemplate` when this is a template.
  let uri: String
  let name: String
  let summary: String
  let mimeType: String?
  let isTemplate: Bool
  let wireBytes: Int

  /// Prefixed, because a template and a concrete resource may legitimately
  /// carry the same string and a `ForEach` over duplicate ids draws neither.
  var id: String { (isTemplate ? "template:" : "resource:") + uri }

  init?(json: [String: Any], isTemplate: Bool) {
    guard let uri = json[isTemplate ? "uriTemplate" : "uri"] as? String else { return nil }
    self.uri = uri
    self.isTemplate = isTemplate
    name = json["name"] as? String ?? json["title"] as? String ?? uri
    summary = json["description"] as? String ?? ""
    mimeType = json["mimeType"] as? String
    wireBytes = ToolCost.bytes(of: json)
  }
}

/// Everything one profile exposes, read from the live server: its tools, its
/// prompts and its resources.
///
/// **Why this is not a static table.** A Bastion listing is per profile and per
/// client — `allowWrites` decides which tools come back, and
/// `ToolFacade.clientDefersSchemas` decides whether a listing is replaced by
/// three declarations — which is the reason `Dialect.listCacheScope` is
/// `private`. So "what does this server expose" has no answer in `servers.json`
/// and cannot have one: it is a question you can only ask a running server,
/// through a profile, and the answer belongs to that profile.
///
/// **Why it is not `ServerCheck`.** A check is an account of one moment: did it
/// start, did it answer, how long did it take. Its `tools` array exists to feed
/// the deep check and the cost card, it stops at page one on purpose, and it
/// never asks for anything but tools. This walks every page of all three
/// surfaces, which is a different request with a different cost, and a check
/// that quietly did it would stop being the cheap thing a row can offer.
///
/// **Never persisted**, for the reason `ServerCheck.runs` gives: a listing
/// written to disk becomes a confident claim about a server that has since been
/// updated, reconfigured or replaced. What survives a relaunch is
/// `ToolCostStore`'s measurement, which carries the version and the gate that
/// would falsify it.
@Observable
final class CapabilityStore {
  static let shared = CapabilityStore()

  /// The three lists, as a reader thinks of them.
  ///
  /// `resources/templates/list` is folded into `.resources` rather than given a
  /// fourth tab: a template is a resource whose address has a hole in it, and
  /// splitting them would put two nearly-empty tabs where one short list works.
  nonisolated enum Surface: String, CaseIterable, Sendable, Identifiable {
    case tools, prompts, resources

    var id: String { rawValue }

    var label: String {
      switch self {
      case .tools: "Tools"
      case .prompts: "Prompts"
      case .resources: "Resources"
      }
    }

    /// What the handshake calls this, in its `capabilities` object.
    var capabilityKey: String { rawValue }
  }

  nonisolated struct Snapshot: Sendable {
    let profileID: String
    let takenAt: Date
    /// The gate this was read under. Kept so the sheet can say which of the two
    /// possible answers it is showing, and so a stale one can be recognised.
    let allowWrites: Bool
    /// The installed package version at the time, and nil for a remote server.
    /// Read by `isCurrent` through the same rule `ToolCostStore` uses.
    let version: String?
    /// The server's own name and version from the handshake, when it gave one.
    /// A `var` because it arrives one call after the rest of this is built.
    var identity: String?

    var tools: [MCPTool] = []
    var prompts: [MCPPrompt] = []
    var resources: [MCPResource] = []

    /// The surfaces the handshake declared. A surface that is not here was
    /// never asked for — asking earns a -32601 that says nothing about the
    /// server, and reporting that as a failure would be an accusation.
    var declared: Set<Surface> = []
    /// Why a declared surface has no list, when it has none.
    var failures: [Surface: String] = [:]
    /// Surfaces where the walk stopped at the page limit, so the list below is
    /// a floor rather than a total.
    var truncated: Set<Surface> = []

    /// Tool names Bastion has positive evidence will change something: the
    /// manifest's list and the server's own annotations, ORed, intersected with
    /// what is actually in the listing. The same computation
    /// `Supervisor.facadeWriteTools` makes, and for the same reason it makes
    /// it — a name that is not in the listing cannot be marked in it.
    var writeTools: Set<String> = []
    /// Tool names the manifest declares as writes that are NOT in the listing.
    ///
    /// Only ever non-empty for a remote server with its gate off, which is the
    /// one case where the tools are missing because *Bastion* removed them. A
    /// child server with its gate off never registered them in the first place,
    /// so there is nothing here to report and the sheet says that instead.
    var hiddenWriteTools: [String] = []

    /// What the whole tool listing costs the client it is sent to.
    var toolBytes: Int { tools.reduce(0) { $0 + $1.wireBytes } }

    var isEmpty: Bool { tools.isEmpty && prompts.isEmpty && resources.isEmpty }

    func count(of surface: Surface) -> Int {
      switch surface {
      case .tools: tools.count
      case .prompts: prompts.count
      case .resources: resources.count
      }
    }
  }

  /// Keyed by `profile.id`. See the note above: never written to disk.
  private(set) var snapshots: [String: Snapshot] = [:]
  private(set) var loading: Set<String> = []

  /// What is still true about this profile, or nothing.
  ///
  /// `ToolCost.isCurrent` rather than a second rule: an npm update rewrites the
  /// package under a profile nobody edited, and flipping the write gate changes
  /// the tool list without touching the code on disk. Both move this listing,
  /// and a listing that cannot go stale silently is a different object from a
  /// cached one.
  func snapshot(for profile: Profile, server: BastionServer) -> Snapshot? {
    guard let held = snapshots[profile.id] else { return nil }
    guard
      ToolCost.isCurrent(
        measuredVersion: held.version, measuredAllowWrites: held.allowWrites,
        version: ServerInstaller.installedVersion(of: server),
        allowWrites: profile.allowWrites)
    else { return nil }
    return held
  }

  func isLoading(_ profile: Profile) -> Bool { loading.contains(profile.id) }

  /// Called where `ProfileStore.upsert` stops the child, for the reason given
  /// there: what was read describes a process that is about to stop existing.
  func forget(_ profileID: String) {
    snapshots[profileID] = nil
    loading.remove(profileID)
  }

  func load(profile: Profile, server: BastionServer) {
    guard !loading.contains(profile.id) else { return }
    loading.insert(profile.id)

    // A dedicated thread rather than a detached task, because `Supervisor.call`
    // blocks by contract — the bargain `ServerCheck.start` explains and every
    // other caller of that seam makes.
    onDedicatedThread("bastion.capabilities") {
      let snapshot = Self.read(profile: profile, server: server)
      Task { @MainActor in
        CapabilityStore.shared.snapshots[profile.id] = snapshot
        CapabilityStore.shared.loading.remove(profile.id)
      }
    }
  }

  // MARK: - The read, off the main actor

  /// The same page limit the gateway's own catalog walk uses. A server that
  /// keeps asking for another page is a server that is not going to stop.
  nonisolated private static let pageLimit = 20

  /// Ask one profile's server what it has.
  ///
  /// Through `ServerCheck.call`, which is the path a real client takes: the
  /// child is the supervised one, the write gate has already been applied, and
  /// the facade has not — `Supervisor.handle` exempts `ServerCheck.client` by
  /// name, so what comes back is the server's own listing rather than the three
  /// declarations a client may be sent in its place. The sheet has to say so,
  /// and does.
  nonisolated private static func read(profile: Profile, server: BastionServer) -> Snapshot {
    let version = ServerInstaller.installedVersion(of: server)
    var snapshot = Snapshot(
      profileID: profile.id, takenAt: Date(), allowWrites: profile.allowWrites,
      version: version)

    // Cheap, local, and first: a profile missing a credential cannot list
    // anything, and spawning it anyway only feeds the circuit breaker a failure
    // whose cause the user already knows. `ServerCheck.perform` opens the same
    // way for the same reason.
    let missing = ProfileEnvironment.missing(for: profile, server: server)
    guard missing.isEmpty else {
      let reason = "the profile is not configured — missing \(missing.joined(separator: ", "))"
      for surface in Surface.allCases { snapshot.failures[surface] = reason }
      snapshot.declared = Set(Surface.allCases)
      return snapshot
    }

    // The handshake, which is also the spawn: `handshakeReply` opens with
    // `ensureRunning()`. Its `capabilities` decide which lists are worth asking
    // for at all.
    let handshake: [String: Any]
    do {
      handshake = try ServerCheck.call(
        profile: profile, server: server, era: .legacy, method: "initialize",
        params: [
          "protocolVersion": Dialect.latest.rawValue,
          "capabilities": [:],
          "clientInfo": ["name": "bastion-capabilities", "version": AppInfo.version],
        ], id: 1)
    } catch {
      let reason = error.localizedDescription
      for surface in Surface.allCases { snapshot.failures[surface] = reason }
      snapshot.declared = Set(Surface.allCases)
      return snapshot
    }

    let info = handshake["serverInfo"] as? [String: Any]
    if let name = info?["name"] as? String {
      snapshot.identity = name + ((info?["version"] as? String).map { " \($0)" } ?? "")
    }

    let capabilities = handshake["capabilities"] as? [String: Any] ?? [:]
    // Tools are asked for whatever the handshake said. Every other caller in
    // the app asks unconditionally, a server that exposes tools without
    // declaring them is common enough to have been met, and the cost of being
    // wrong here is one -32601. Prompts and resources are asked for only when
    // declared, because there the cost of being wrong is a red line on a sheet
    // about a server that is behaving correctly.
    snapshot.declared.insert(.tools)
    for surface in [Surface.prompts, .resources] where capabilities[surface.capabilityKey] != nil {
      snapshot.declared.insert(surface)
    }

    var nextID = 2

    // 1 — tools.
    do {
      let (entries, truncated) = try walk(
        profile: profile, server: server, method: "tools/list", key: "tools", id: &nextID)
      snapshot.tools = entries.compactMap(MCPTool.init(json:))
      if truncated { snapshot.truncated.insert(.tools) }

      // Off the raw entries, not the parsed tools: `WriteGate` reads the
      // annotations as they arrived, which is the same bytes the gateway sees,
      // and `MCPTool` keeps only one of the two hints it looks at.
      let present = Set(entries.compactMap { $0["name"] as? String })
      snapshot.writeTools =
        Set(server.writeTools)
        .union(WriteGate.annotatedWriteTools(in: entries))
        .intersection(present)
      // What the gate took away, and only when it is Bastion that took it. A
      // child's gate is an environment variable and the tool was never
      // registered; there is nothing to name.
      if !profile.allowWrites {
        snapshot.hiddenWriteTools = Set(server.writeTools).subtracting(present).sorted()
      }

      // Upsert the cost, for the reason `ServerCheck` gives where it does the
      // same: this is a measurement somebody asked for. Better than the check's,
      // and marked as such — the walk above followed every page, so `partial`
      // is only true when a server would not stop paginating.
      if !entries.isEmpty {
        let bytes = entries.reduce(0) { $0 + ToolCost.bytes(of: $1) }
        let (profileID, allowWrites) = (profile.id, profile.allowWrites)
        let (count, writes) = (entries.count, snapshot.writeTools.count)
        Task { @MainActor in
          ToolCostStore.shared.record(
            profileID: profileID, bytes: bytes, toolCount: count, partial: truncated,
            version: version, allowWrites: allowWrites, writeToolCount: writes)
        }
      }
    } catch {
      snapshot.failures[.tools] = error.localizedDescription
    }

    // 2 — prompts.
    if snapshot.declared.contains(.prompts) {
      do {
        let (entries, truncated) = try walk(
          profile: profile, server: server, method: "prompts/list", key: "prompts", id: &nextID)
        snapshot.prompts = entries.compactMap(MCPPrompt.init(json:))
        if truncated { snapshot.truncated.insert(.prompts) }
      } catch {
        snapshot.failures[.prompts] = error.localizedDescription
      }
    }

    // 3 — resources, then the templates, into one list.
    if snapshot.declared.contains(.resources) {
      do {
        let (entries, truncated) = try walk(
          profile: profile, server: server, method: "resources/list", key: "resources", id: &nextID)
        snapshot.resources = entries.compactMap { MCPResource(json: $0, isTemplate: false) }
        if truncated { snapshot.truncated.insert(.resources) }
      } catch {
        snapshot.failures[.resources] = error.localizedDescription
      }
      // Templates are optional even for a server that declares resources, so a
      // refusal here is not worth a line of its own: it means there are none.
      if let (entries, truncated) = try? walk(
        profile: profile, server: server, method: "resources/templates/list",
        key: "resourceTemplates", id: &nextID)
      {
        snapshot.resources += entries.compactMap { MCPResource(json: $0, isTemplate: true) }
        if truncated { snapshot.truncated.insert(.resources) }
      }
    }

    return snapshot
  }

  /// One list, following `nextCursor` to the end.
  ///
  /// The whole list rather than the first page, which is where this differs
  /// from the check: a sheet whose whole purpose is "what is in here" and which
  /// silently stopped at page one would be answering a different question than
  /// the one it was opened to answer.
  nonisolated private static func walk(
    profile: Profile, server: BastionServer, method: String, key: String, id: inout Int
  ) throws -> (entries: [[String: Any]], truncated: Bool) {
    var collected: [[String: Any]] = []
    var cursor: String?
    var pages = 0
    repeat {
      var params: [String: Any] = [:]
      if let cursor { params["cursor"] = cursor }
      let result = try ServerCheck.call(
        profile: profile, server: server, era: .legacy, method: method, params: params, id: id)
      id += 1
      guard let entries = result[key] as? [[String: Any]] else {
        throw ServerCheck.CheckError.malformedReply(method)
      }
      collected += entries
      cursor = result["nextCursor"] as? String
      pages += 1
    } while cursor != nil && pages < pageLimit
    return (collected, cursor != nil)
  }
}

#if DEBUG
  extension CapabilityStore {
    /// Read one profile's three lists from the command line and print them.
    ///
    /// `Bastion --capabilities=prod/shopify`.
    ///
    /// The argument `ServerCheck.runHeadless` makes, unchanged: Bastion is
    /// `LSUIElement` and this lives behind a button in a sheet, so without a
    /// flag the only path that walks every page of `prompts/list` could be
    /// exercised only by hand, on a server that happens to have prompts.
    static func runHeadless(_ argument: String) {
      let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2,
        let server = ServerStore.lookup(parts[1]),
        let profile = ProfileStore.lookup(name: parts[0], server: parts[1])
      else {
        FileHandle.standardError.write(
          Data("no profile '\(argument)' — expected <profile>/<server>\n".utf8))
        exit(2)
      }

      shared.load(profile: profile, server: server)
      Task { @MainActor in
        while shared.isLoading(profile) { try? await Task.sleep(for: .milliseconds(100)) }
        // Off `snapshots` rather than `snapshot(for:server:)`: the staleness
        // rule would hide a listing taken four milliseconds ago if an install
        // landed between the two, and a tool that printed nothing without
        // saying why would be worse than useless.
        guard let held = shared.snapshots[profile.id] else { leave(3) }

        print("\n\(profile.name)/\(server.id) — \(held.identity ?? server.displayName)")
        print("  writes \(held.allowWrites ? "on" : "off")")

        for surface in Surface.allCases {
          let state =
            held.failures[surface].map { "FAILED — \($0)" }
            ?? (held.declared.contains(surface)
              ? "\(held.count(of: surface))\(held.truncated.contains(surface) ? "+" : "")"
              : "not declared")
          print("\n  \(surface.label): \(state)")
        }

        for tool in held.tools {
          let mark =
            held.writeTools.contains(tool.name) ? "w" : (tool.readOnlyHint == true ? "r" : "?")
          print(
            "    \(mark)  \(String(format: "%6d", ToolCost.tokens(bytes: tool.wireBytes)))  \(tool.name)"
          )
        }
        for name in held.hiddenWriteTools {
          print("    -  \(String(repeating: " ", count: 6))  \(name) (gated)")
        }
        for prompt in held.prompts {
          let required = prompt.arguments.filter(\.required).map(\.name)
          print(
            "    \(prompt.name)\(required.isEmpty ? "" : " <\(required.joined(separator: ", "))>")")
        }
        for resource in held.resources {
          print("    \(resource.isTemplate ? "t" : "r")  \(resource.uri)")
        }

        // A failure on a surface the server declared is a real one; a surface
        // it never declared was never asked for and is not.
        leave(held.failures.isEmpty ? 0 : 1)
      }
    }

    /// `exit` runs no `defer` and no `applicationWillTerminate`, so without this
    /// the child this walk started outlives the process that started it —
    /// `ServerCheck.leave`'s reason, and the same leak.
    private static func leave(_ code: Int32) -> Never {
      Supervisor.shared.stopAll()
      exit(code)
    }
  }
#endif
