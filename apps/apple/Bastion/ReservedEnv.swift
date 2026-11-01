import Foundation

/// The environment names a custom server may not declare.
///
/// A custom entry already cannot name a command line: it supplies a package or
/// an endpoint, and `ServerStore.upsert` checks both. The environment is the
/// same hole by another door. A child is spawned with whatever variables its
/// definition lists, so a definition that lists `NODE_OPTIONS` and a profile
/// that fills it with `--import=data:…` runs code nobody installed, and a
/// `PATH` puts a different `npm` in front of the bundled one. Each family below
/// is here for a reason of that kind:
///
/// - `PATH` and `HOME` are set by Bastion at spawn time, and a profile value
///   would win over them.
/// - `NODE_*` reaches node itself: `NODE_OPTIONS` loads code before the server's
///   first line, and `NODE_EXTRA_CA_CERTS` changes whom it trusts.
/// - `NPM_CONFIG_*` reaches npm, whose `script-shell` and `userconfig` choose
///   what runs when a server shells out to it. npm reads these names in any
///   case, which is why the match ignores case.
/// - `DYLD_*` injects libraries into the process.
/// - `XDG_*` is set by Bastion per profile, so two identities never share a
///   state directory.
///
/// The catalog is exempt. It is compiled into the app, and a profile can only
/// set names its server declares (`ProfileEnvironment.values` drops the rest),
/// so for a catalog server the catalog is the only place a reserved name can
/// come from. The generator lets one in only as a per-Mac variable — npm's
/// `NPM_CONFIG_USERCONFIG` is the one today.
///
/// The list may grow with names of the same kind. It must never shrink: iCloud
/// sync relies on it to keep a value set on one Mac from choosing code on
/// another.
///
/// Its own file, and Foundation only, so `scripts/unit-check.swift` compiles it.
nonisolated enum ReservedEnv {
  private static let exact: Set<String> = ["PATH", "HOME"]
  private static let prefixes = ["NODE_", "NPM_CONFIG_", "DYLD_", "XDG_"]

  static func isReserved(_ name: String) -> Bool {
    let upper = name.uppercased()
    return exact.contains(upper) || prefixes.contains { upper.hasPrefix($0) }
  }

  /// The first reserved name in `names`, in their order, for a refusal that
  /// names the variable the user actually typed.
  static func firstReserved(in names: [String]) -> String? {
    names.first(where: isReserved)
  }

  /// The values a child may be given, and the reserved names left out.
  ///
  /// `skipped` is sorted so the log line it feeds reads the same every spawn.
  static func admit(_ values: [String: String], declaredByCatalog: Bool)
    -> (admitted: [String: String], skipped: [String])
  {
    if declaredByCatalog { return (values, []) }
    let admitted = values.filter { !isReserved($0.key) }
    let skipped = values.keys.filter(isReserved).sorted()
    return (admitted, skipped)
  }

  /// Whether Bastion writes a server's write gate at spawn. It is written
  /// after the profile's values and wins over them, so a custom gate named
  /// `NODE_TLS_REJECT_UNAUTHORIZED` would turn certificate checks off whenever
  /// writes are, and one named `PATH` would replace Bastion's own.
  static func admitsGate(_ gate: String, declaredByCatalog: Bool) -> Bool {
    declaredByCatalog || !isReserved(gate)
  }

  /// The log line for names left out of a custom server's environment.
  ///
  /// Not "edited by hand" alone: before this rule, the editor and
  /// `add_custom_server` accepted any of these names, so the likeliest row
  /// carrying one was saved normally by an earlier version.
  static func skipNotice(server: String, skipped: [String]) -> String {
    let names = skipped.joined(separator: ", ")
    let verb = skipped.count == 1 ? "it was" : "they were"
    return "'\(server)' declares \(names), which a custom server cannot set; its row was "
      + "saved by an earlier version of Bastion, or edited by hand, so \(verb) left out"
  }
}
