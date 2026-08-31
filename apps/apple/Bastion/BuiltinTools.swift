import Foundation

/// The tools `BuiltinServer` exposes, and what they do.
///
/// Every one of these delegates to the store method the window already calls.
/// That is the whole design: `remove_server` goes through `ServerStore.remove`,
/// so it stops the children, sweeps the Keychain and deletes the downloaded code
/// in exactly the order the confirmation dialog promises. A tool that
/// reimplemented any of that would be a second copy of a cascade that can drift
/// from the first, and the drift would be invisible until somebody's credential
/// was left behind in the Keychain.
@MainActor
enum BuiltinTools {

  // MARK: - Failures

  /// Refusals a model can act on.
  ///
  /// Written as sentences rather than codes because they come back inside the
  /// tool result, addressed to whatever is reading it: "turn on Allow writes for
  /// this profile" is something an agent can relay to a person, and `EPERM` is
  /// not.
  enum ToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case badArgument(name: String, expected: String)
    case writesDisabled(String)
    case refusedBuiltin(String)
    case noSuchServer(String)
    case noSuchProfile(profile: String, server: String)
    case noSuchClient(id: String, known: [String])
    case unknownVariable(variable: String, server: String)
    case wireRefused(String)

    var errorDescription: String? {
      switch self {
      case .unknownTool(let name):
        return "'\(name)' is not a tool this server has"
      case .missingArgument(let name):
        return "'\(name)' is required"
      case .badArgument(let name, let expected):
        return "'\(name)' should be \(expected)"
      case .writesDisabled(let tool):
        return
          "'\(tool)' changes Bastion's configuration, and this profile's write gate is off. Turn "
          + "on \"Allow writes\" for this profile in Bastion, or use a profile that has it."
      case .refusedBuiltin(let action):
        return
          "Bastion's own server cannot \(action) itself — that would leave no way to undo it from "
          + "here. Do it in the Bastion window instead."
      case .noSuchServer(let id):
        return "'\(id)' is not in your server list"
      case .noSuchProfile(let profile, let server):
        return "there is no profile '\(profile)' for '\(server)'"
      case .noSuchClient(let id, let known):
        // The known ids are passed in rather than read here: `errorDescription`
        // is nonisolated and `ClientWiring.all` is not.
        return
          "'\(id)' is not a client Bastion knows how to configure — try "
          + known.joined(separator: ", ")
      case .wireRefused(let why):
        // `ClientWiring.WireError` already says what happened and what a person
        // would change. This adds the half only a caller of this tool can act
        // on, rather than making the pane's alert talk about arguments.
        return "\(why) To replace them anyway, call wire_client again with force: true."
      case .unknownVariable(let variable, let server):
        return
          "'\(server)' does not read a variable called '\(variable)'. Bastion passes only the "
          + "variables a server's definition lists, so setting it would have no effect."
      }
    }
  }

  // MARK: - The table

  /// One tool, as declared to a client.
  private struct Declaration {
    let name: String
    let title: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    /// Whether it changes anything. Mutating tools are not merely refused when
    /// the profile's gate is off — they are absent from `tools/list` entirely,
    /// so a model never plans around a tool it cannot use.
    let mutates: Bool

    init(
      _ name: String, title: String, _ description: String,
      properties: [String: Any] = [:], required: [String] = [], mutates: Bool = false
    ) {
      self.name = name
      self.title = title
      self.description = description
      self.properties = properties
      self.required = required
      self.mutates = mutates
    }

    var json: [String: Any] {
      [
        "name": name,
        "title": title,
        "description": description,
        "inputSchema": [
          "type": "object",
          "properties": properties,
          "required": required,
        ],
        "annotations": [
          "readOnlyHint": !mutates,
          "destructiveHint": mutates,
        ],
      ]
    }
  }

  private static func schema(_ type: String, _ description: String) -> [String: Any] {
    ["type": type, "description": description]
  }

  private static let table: [Declaration] = [
    // MARK: Read

    Declaration(
      "list_servers", title: "List servers",
      "Every server in this Bastion's list: whether it is enabled, whether its code is "
        + "installed, how many profiles it has and how many instances are running."),

    Declaration(
      "get_server", title: "Describe a server",
      "One server in full: the package it comes from, the protocol it speaks, its write gate, "
        + "and every environment variable it reads with whether that variable is required and "
        + "whether it is a secret.",
      properties: ["id": schema("string", "The server id, as listed by list_servers.")],
      required: ["id"]),

    Declaration(
      "list_catalog", title: "List the catalog",
      "Servers Bastion ships a definition for that are not in your list yet. These can be added "
        + "with install_server by id alone."),

    Declaration(
      "list_profiles", title: "List profiles",
      "Every profile: its server, whether its write gate is on, its non-secret values, which of "
        + "its secrets are set, and anything still missing before it can start. Secret VALUES are "
        + "never returned.",
      properties: [
        "server": schema("string", "Optional. Only profiles for this server id.")
      ]),

    Declaration(
      "list_clients", title: "List clients",
      "The MCP clients Bastion can configure — Claude Code, Claude Desktop, VS Code, Cursor, "
        + "and ChatGPT & Codex, which share one file — whether each is installed, and whether "
        + "its config currently points at Bastion."),

    Declaration(
      "status", title: "Bastion status",
      "The gateway's port and version, the licence state, and every supervised instance running "
        + "right now with its pid, uptime, attached clients and call count."),

    Declaration(
      "recent_activity", title: "Recent activity",
      "Bastion's recent log: which profile, which method, and the name of whatever each request "
        + "reached for. Your own profile's lines also carry the arguments they were called with, "
        + "and their results if this profile records those. Credentials are never recorded. "
        + "Other profiles' lines never carry arguments or results.",
      properties: [
        "limit": schema("integer", "How many entries, newest last. Default 50, max 500."),
        "origin": schema("string", "Optional. Only lines from this '<profile>/<server>'."),
      ]),

    // MARK: Write

    Declaration(
      "enable_server", title: "Enable a server",
      "Let a server answer again. Nothing is downloaded and no profile changes.",
      properties: ["id": schema("string", "The server id.")],
      required: ["id"], mutates: true),

    Declaration(
      "disable_server", title: "Disable a server",
      "Stop a server answering and shut down any instance of it that is running. Its profiles, "
        + "their credentials and its downloaded code are all kept — this is 'not right now', not "
        + "'never again'. Client configs are left untouched.",
      properties: ["id": schema("string", "The server id.")],
      required: ["id"], mutates: true),

    Declaration(
      "install_server", title: "Install a catalog server",
      "Add a server from Bastion's catalog to this install's list and start downloading its code. "
        + "The download runs in the background; poll list_servers for 'installed'.",
      properties: ["id": schema("string", "A catalog id, as listed by list_catalog.")],
      required: ["id"], mutates: true),

    Declaration(
      "add_custom_server", title: "Add a custom server",
      "Add any MCP server, as either an npm package or a remote https endpoint. Give npm_name "
        + "for one Bastion runs, or url for one somebody else runs — never both. Bastion runs a "
        + "package by package and bin name, never by command line, so there is no way to specify "
        + "arguments or a path; and a url must be https to a public host, so it cannot be pointed "
        + "at this machine or this network.",
      properties: [
        "id": schema("string", "Kebab-case. Becomes a URL path segment and a directory name."),
        "display_name": schema("string", "Shown in the window."),
        "summary": schema("string", "One line describing what it does."),
        "npm_name": schema(
          "string", "The npm package, e.g. '@scope/mcp-thing'. Omit for a remote server."),
        "bin_name": schema("string", "The bin entry to run. Optional; resolved from the package."),
        "url": schema(
          "string",
          "For a REMOTE server: the https endpoint, e.g. 'https://mcp.example.com'. Nothing is "
            + "installed and no process is started. Every variable then needs a header, because "
            + "there is no environment to put it in."),
        "docs_url": schema("string", "Optional documentation URL."),
        "dialect": schema(
          "string",
          "Optional MCP revision the server speaks. Defaults to 2025-11-25, which is what an SDK "
            + "built this year negotiates."),
        "write_gate": schema(
          "string",
          "Optional env var that turns the server's destructive tools on. Package servers only — "
            + "a remote server has no environment."),
        "write_tools": [
          "type": "array", "items": ["type": "string"],
          "description":
            "REMOTE servers only, and the counterpart to write_gate: tool names Bastion will not "
            + "forward while the profile's write gate is off. A filter over what Bastion sends, "
            + "never a promise about what the server will refuse — the credential's own scopes "
            + "are the real limit.",
        ],
        "state_env": [
          "type": "array", "items": ["type": "string"],
          "description":
            "Optional env vars naming on-disk state. Bastion redirects each into the profile's "
            + "own directory so two profiles never share one token file.",
        ],
        "env": [
          "type": "array",
          "description": "The environment variables the server reads. At least one.",
          "items": [
            "type": "object",
            "properties": [
              "name": schema("string", "UPPER_SNAKE_CASE."),
              "required": schema("boolean", "Whether the server cannot start without it."),
              "secret": schema(
                "boolean", "Whether it holds a credential. Secrets go to the Keychain."),
              "description": schema("string", "What it is, for whoever fills it in."),
              "header": [
                "type": "object",
                "description":
                  "REMOTE servers only, and required for each of their variables: the request "
                  + "header this value becomes. A variable with no header would be collected, "
                  + "stored and then never sent.",
                "properties": [
                  "name": schema("string", "Header name, e.g. 'Authorization'."),
                  "format": schema(
                    "string",
                    "Template containing {value}, e.g. 'Bearer {value}', so the profile holds the "
                      + "credential rather than the scheme."),
                ],
                "required": ["name", "format"],
              ],
            ],
            "required": ["name"],
          ],
        ],
      ],
      required: ["id", "display_name", "env"], mutates: true),

    Declaration(
      "remove_server", title: "Remove a server",
      "Delete a server, its profiles, their credentials in the Keychain and its downloaded code. "
        + "All four together and irreversibly. To stop a server temporarily use disable_server.",
      properties: ["id": schema("string", "The server id.")],
      required: ["id"], mutates: true),

    Declaration(
      "upsert_profile", title: "Create or update a profile",
      "Create a profile or change an existing one. Values given here are NON-SECRET configuration "
        + "and are written to disk — use set_credential for anything a server's definition marks "
        + "secret.",
      properties: [
        "name": schema("string", "Kebab-case, unique within the server. E.g. 'prod'."),
        "server": schema("string", "The server id this profile is for."),
        "values": [
          "type": "object",
          "description":
            "Non-secret variables, as a name-to-value map. Merged into what is already there; a "
            + "variable set to an empty string is cleared.",
          "additionalProperties": ["type": "string"],
        ],
        "allow_writes": schema(
          "boolean",
          "Whether this profile may use the server's destructive tools. Per profile, never "
            + "global."),
      ],
      required: ["name", "server"], mutates: true),

    Declaration(
      "remove_profile", title: "Remove a profile",
      "Delete a profile and every credential it owns in the Keychain.",
      properties: [
        "name": schema("string", "The profile name."),
        "server": schema("string", "The server id."),
      ],
      required: ["name", "server"], mutates: true),

    Declaration(
      "set_credential", title: "Set a credential",
      "Put a secret into the Keychain for one profile. Write-only: no tool returns a credential, "
        + "and this one cannot read back what it wrote.",
      properties: [
        "profile": schema("string", "The profile name."),
        "server": schema("string", "The server id."),
        "variable": schema(
          "string", "The variable name, which must be one the server's definition lists."),
        "value": schema("string", "The secret. Stored in the Keychain, never written to disk."),
      ],
      required: ["profile", "server", "variable", "value"], mutates: true),

    Declaration(
      "wire_client", title: "Wire a client",
      "Write Bastion's entries into a client's MCP config, so it reaches these profiles over the "
        + "gateway instead of spawning its own servers. The client's other entries are left alone "
        + "and a backup is written first. What lands in the file is a revocable loopback token, "
        + "never a credential.",
      properties: [
        "client": schema("string", "The client id, as listed by list_clients."),
        "profiles": [
          "type": "array", "items": ["type": "string"],
          "description":
            "Optional '<profile>/<server>' ids to wire. Defaults to every profile whose server is "
            + "enabled.",
        ],
        "force": schema(
          "boolean",
          "Overwrite entries the config already has under those names that Bastion did not "
            + "write. Off by default, and wiring is refused rather than silently replacing a "
            + "server the user configured themselves."),
      ],
      required: ["client"], mutates: true),

    Declaration(
      "unwire_client", title: "Unwire a client",
      "Remove Bastion's entries from a client's config, leaving everything else in the file "
        + "untouched. A backup is written first.",
      properties: ["client": schema("string", "The client id.")],
      required: ["client"], mutates: true),
  ]

  /// What `tools/list` returns.
  ///
  /// The gate hides rather than refuses. A model handed a tool it will always be
  /// refused for will plan around it and then report a failure the person cannot
  /// act on; a model that never saw the tool asks for what it needs instead.
  static func declarations(allowWrites: Bool) -> [[String: Any]] {
    table.filter { allowWrites || !$0.mutates }.map(\.json)
  }

  // MARK: - Dispatch

  /// `caller` is the `<profile>/<server>` the request arrived on, used by
  /// `recent_activity` to scope what it will report. Optional so a caller with
  /// no profile context reads nothing profile-shaped rather than everything.
  static func invoke(
    name: String, arguments: [String: Any], allowWrites: Bool, caller: String? = nil
  ) throws -> Any {
    guard let declaration = table.first(where: { $0.name == name }) else {
      throw ToolError.unknownTool(name)
    }
    // Checked here and not only at list time. `tools/list` is advisory — a
    // client may have cached an older list, or simply call a name it guessed —
    // so the gate has to hold at the point of use as well.
    guard allowWrites || !declaration.mutates else {
      throw ToolError.writesDisabled(name)
    }

    switch name {
    case "list_servers": return listServers()
    case "get_server": return try getServer(arguments)
    case "list_catalog": return listCatalog()
    case "list_profiles": return listProfiles(arguments)
    case "list_clients": return listClients()
    case "status": return status()
    case "recent_activity": return recentActivity(arguments, caller: caller)

    case "enable_server": return try setEnabled(arguments, to: true)
    case "disable_server": return try setEnabled(arguments, to: false)
    case "install_server": return try installServer(arguments)
    case "add_custom_server": return try addCustomServer(arguments)
    case "remove_server": return try removeServer(arguments)
    case "upsert_profile": return try upsertProfile(arguments)
    case "remove_profile": return try removeProfile(arguments)
    case "set_credential": return try setCredential(arguments)
    case "wire_client": return try wireClient(arguments)
    case "unwire_client": return try unwireClient(arguments)

    default: throw ToolError.unknownTool(name)
    }
  }

  // MARK: - Reading

  private static func listServers() -> Any {
    let profiles = ProfileStore.shared.profiles
    let running = Supervisor.shared.running
    return ServerStore.shared.servers.map { server -> [String: Any] in
      var row: [String: Any] = [
        "id": server.id,
        "display_name": server.displayName,
        "summary": server.summary,
        "origin": describe(server.origin),
        "enabled": server.isEnabled,
        "profiles": profiles.filter { $0.serverID == server.id }.count,
        "running": running.filter { $0.id.hasSuffix("/\(server.id)") }.count,
      ]
      if server.origin == .builtin {
        row["installed"] = true
        row["note"] = "runs inside Bastion; nothing to install"
      } else {
        row["installed"] = ServerInstaller.isInstalled(server)
        if let version = ServerInstaller.installedVersion(of: server) {
          row["installed_version"] = version
        }
        if ServerInstaller.shared.isRunning(server.id) { row["installing"] = true }
        if let failure = ServerInstaller.shared.failures[server.id] { row["last_error"] = failure }
      }
      return row
    }
  }

  private static func getServer(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "id")
    guard let server = ServerStore.shared.server(id: id) else { throw ToolError.noSuchServer(id) }

    var out: [String: Any] = [
      "id": server.id,
      "display_name": server.displayName,
      "summary": server.summary,
      "origin": describe(server.origin),
      "enabled": server.isEnabled,
      "dialect": server.dialect.rawValue,
      "env": server.env.map {
        [
          "name": $0.name, "required": $0.isRequired, "secret": $0.isSecret,
          "description": $0.summary,
        ]
      },
      "profiles": ProfileStore.shared.profiles.filter { $0.serverID == server.id }.map(\.name),
    ]
    // The transport, said in whatever terms make sense for it. An agent asking
    // about a remote server wants the endpoint and the fact that there is
    // nothing to install; npm fields would be four nulls it has to interpret.
    switch server.transport {
    case .inProcess:
      out["transport"] = "in-process"
      out["note"] = "Bastion itself. Runs in-process, installs nothing, and cannot be removed."
    case .remote(let endpoint):
      out["transport"] = "remote"
      out["url"] = endpoint.absoluteString
      out["note"] =
        "Somebody else runs this one. Bastion relays to it with the profile's credential, "
        + "records every call, and installs nothing. There is no process to supervise."
      if !server.writeTools.isEmpty {
        out["write_tools"] = server.writeTools
        out["write_tools_note"] =
          "Hidden from tools/list while the profile's write gate is off. This filters what "
          + "Bastion forwards; it does not bind the server, so the credential's own scopes "
          + "remain the real boundary."
      }
    case .child(let package):
      out["transport"] = "child"
      out["npm_name"] = package.npmName
      out["bin_name"] = package.binName
      out["published"] = package.distribution == .npm
      out["installed"] = ServerInstaller.isInstalled(server)
      if let version = ServerInstaller.installedVersion(of: server) {
        out["installed_version"] = version
      }
    }
    if let gate = server.writeGate { out["write_gate"] = gate }
    if let docs = server.docsURL { out["docs_url"] = docs.absoluteString }
    if !server.stateEnv.isEmpty { out["state_env"] = server.stateEnv }
    if !server.callbackEnv.isEmpty { out["callback_env"] = server.callbackEnv }
    if !server.authModes.isEmpty {
      out["auth_modes"] = server.authModes.map {
        ["id": $0.id, "display_name": $0.displayName, "env": $0.env]
      }
    }
    return out
  }

  private static func listCatalog() -> Any {
    ServerStore.shared.available.map { server -> [String: Any] in
      var row: [String: Any] = [
        "id": server.id, "display_name": server.displayName, "summary": server.summary,
      ]
      switch server.transport {
      case .child(let package):
        row["transport"] = "child"
        row["npm_name"] = package.npmName
        row["published"] = package.distribution == .npm
      case .remote(let endpoint):
        row["transport"] = "remote"
        row["url"] = endpoint.absoluteString
      case .inProcess:
        row["transport"] = "in-process"
      }
      return row
    }
  }

  /// Profiles, with the one thing this server will never say: a secret's value.
  ///
  /// `secrets_set` reports which secret variables have something in the
  /// Keychain, because "is it configured" is the question worth answering and
  /// it is answered from account names alone — nothing here decrypts, so
  /// listing profiles cannot raise a Keychain prompt.
  ///
  /// One `accounts` query for the whole call, not one per profile and certainly
  /// not one per variable: this used to read every secret of every profile
  /// three times over, which on a dozen items meant dozens of ACL checks for a
  /// question none of them had to answer.
  private static func listProfiles(_ arguments: [String: Any]) -> Any {
    let filter = arguments["server"] as? String
    let accounts = CredentialStore.accounts(.profile)
    return ProfileStore.shared.profiles
      .filter { filter == nil || $0.serverID == filter }
      .map { profile -> [String: Any] in
        var row: [String: Any] = [
          "name": profile.name,
          "server": profile.serverID,
          "endpoint": "/s/\(profile.name)/\(profile.serverID)",
          "allow_writes": profile.allowWrites,
          "values": profile.values,
        ]
        guard let server = ServerStore.shared.server(id: profile.serverID) else { return row }
        let stored = CredentialStore.storedVariables(
          in: accounts, profile: profile.name, server: profile.serverID)
        let secrets = server.env.filter(\.isSecret).map(\.name)
        row["secrets_set"] = secrets.filter { stored.contains($0) }
        row["secrets_unset"] = secrets.filter { !stored.contains($0) }
        let present = ProfileEnvironment.present(for: profile, server: server, stored: stored)
        let missing = ProfileEnvironment.missing(for: profile, server: server, present: present)
        if !missing.isEmpty { row["missing"] = missing }
        return row
      }
  }

  private static func listClients() -> Any {
    let profiles = ProfileStore.shared.profiles
    return ClientWiring.all.map { client -> [String: Any] in
      var row: [String: Any] = [
        "id": client.id,
        "display_name": client.displayName,
        "config_path": client.configURL.path,
        "installed": client.isInstalled,
        "status": ClientWiring.status(of: client, profiles: profiles).summary,
        "transport": client.transport == .http ? "http" : "bridge",
        // So a reader knows what it is about to open before it goes looking for
        // JSON and finds TOML.
        "format": client.format == .toml ? "toml" : "json",
      ]
      if let caveat = client.caveat { row["note"] = caveat }
      return row
    }
  }

  private static func status() -> Any {
    let entitlement: [String: Any] =
      switch Entitlement.current {
      case .licensed(let license): ["state": "licensed", "email": license.email]
      case .trial: ["state": "trial"]
      case .refused(let reason): ["state": "unlicensed", "reason": reason]
      }

    return [
      "version": AppInfo.version,
      "build": AppInfo.build,
      "debug_build": AppInfo.isDebugBuild,
      "port": Int(Gateway.shared.port),
      "base_url": "http://127.0.0.1:\(Gateway.shared.port)",
      "licence": entitlement,
      "protocol_versions": Dialect.supportedVersions.map(\.rawValue),
      "running": Activity.shared.instances.map { instance in
        var row: [String: Any] = [
          "id": instance.id, "profile": instance.profile, "server": instance.server,
          "started_at": ISO8601DateFormatter().string(from: instance.startedAt),
          "allow_writes": instance.allowWrites, "calls": instance.calls,
          "restarts": instance.restarts,
          "clients": instance.clients.map { ["id": $0.id, "calls": $0.calls] },
        ]
        // A pid or a host, never a zero standing in for one. An agent reading
        // `"pid": 0` would have to know that means "no process"; a missing key
        // beside `"host"` says it.
        if let pid = instance.pid { row["pid"] = Int(pid) }
        if let host = instance.remoteHost { row["host"] = host }
        return row
      },
    ]
  }

  /// The recent log, scoped to the profile that asked.
  ///
  /// `caller` is the `<profile>/<server>` the request arrived on. Scoping to it
  /// is the important part and it is new: `origin` used to be an optional
  /// *filter*, so an agent on `home/unifi-network` could omit it and read every
  /// line `prod/shopify` had produced. That was harmless while a row was a tool
  /// name and stopped being harmless the moment rows carried arguments.
  ///
  /// Handing back a profile's own payloads is safe by construction — the agent
  /// sent those arguments and received those results, so it learns nothing it
  /// did not already have. Another profile's row never carries them, whatever
  /// the setting says.
  ///
  /// A caller with no profile context reads nothing rather than everything.
  ///
  /// The residual, worth knowing: two clients sharing one profile share one
  /// scope, so one can read the other's calls. Narrowing to per-client is
  /// possible; profile is the boundary everything else in Bastion uses.
  private static func recentActivity(_ arguments: [String: Any], caller: String?) -> Any {
    let limit = min(max(arguments["limit"] as? Int ?? 50, 1), 500)
    let requested = arguments["origin"] as? String
    let widened = CallCapture.reportsAllProfiles
    let formatter = ISO8601DateFormatter()

    return LogStore.shared.entries
      .filter { entry in
        // Exactly the caller's own lines, and nothing else.
        //
        // Subsystem lines (`servers`, `profiles`) were let through at first, on
        // the reasoning that they name no profile and carry no payload. They do
        // name one: `[servers] info: saved custom server 'checkscratch'` tells
        // whoever is asking what someone ELSE just configured. builtin-check
        // caught it. An agent that needs Bastion's global state has `status`
        // and `list_servers`, which are gated tools; this one is a window onto
        // your own traffic.
        guard widened || entry.origin == caller else { return false }
        return requested == nil || entry.origin == requested
      }
      .suffix(limit)
      .map { entry -> [String: Any] in
        var row: [String: Any] = [
          "at": formatter.string(from: entry.at), "origin": entry.origin,
          "level": entry.level.rawValue, "text": entry.text,
        ]
        guard entry.origin == caller else { return row }
        if let arguments = entry.arguments { row["arguments"] = arguments }
        if let result = entry.result { row["result"] = result }
        if entry.failed { row["failed"] = true }
        return row
      }
  }

  /// Argument names on Bastion's OWN tools that carry a credential.
  ///
  /// `set_credential`'s whole argument list is exempted from capture by
  /// `CallCapture.neverCapture`, which is the real defence; this is the second
  /// line under it, so a future tool that takes a secret in a differently
  /// named field is still blanked rather than recorded.
  /// `nonisolated` because the audit line is written on the connection's own
  /// thread, not the main actor — `BuiltinServer.handle` reads this twice per
  /// call. An immutable `Set<String>` is `Sendable` and its initialisation is
  /// already once-only, so this states what was always true rather than
  /// changing anything; without it the secrets wall does not compile under the
  /// Swift 6 language mode.
  nonisolated static let secretArgumentNames: Set<String> = [
    "value", "values", "token", "secret",
  ]

  // MARK: - Writing

  private static func setEnabled(_ arguments: [String: Any], to enabled: Bool) throws -> Any {
    let id = try string(arguments, "id")
    guard let server = ServerStore.shared.server(id: id) else { throw ToolError.noSuchServer(id) }
    // Invariant 2. Disabling the control plane through the control plane leaves
    // no way to undo it from here, and an agent that did it by accident would
    // strand the person who asked.
    if !enabled, server.origin == .builtin { throw ToolError.refusedBuiltin("disable") }

    try ServerStore.shared.setEnabled(enabled, for: id)
    return [
      "id": id, "enabled": enabled,
      "note": enabled
        ? "'\(id)' answers again."
        : "'\(id)' is off and any running instance was stopped. Its profiles, their credentials "
          + "and its downloaded code are untouched.",
    ]
  }

  private static func installServer(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "id")
    try ServerStore.shared.install(catalogEntry: id)
    guard let server = ServerStore.shared.server(id: id) else { throw ToolError.noSuchServer(id) }
    // The download is deliberately not awaited: npm against a cold cache is
    // tens of seconds, which is longer than a tool call should hold a
    // connection open for. The list entry exists either way, which is what
    // makes a failure retryable rather than a dead end.
    // A remote catalog entry has nothing to download, so telling an agent to
    // poll for "installed" would be telling it to wait for an event that never
    // comes. `install_server` still names the step it performed: adding it.
    guard server.package != nil else {
      return [
        "id": id, "added": true,
        "note": "'\(id)' is in your list. It is a remote server — nothing is downloaded and no "
          + "process is started. It needs a profile before any client can reach it.",
      ]
    }
    Task { await ServerInstaller.shared.install(server) }
    return [
      "id": id, "added": true,
      "note": "'\(id)' is in your list and its code is downloading. Poll list_servers for "
        + "'installed'. It needs a profile before any client can reach it.",
    ]
  }

  private static func addCustomServer(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "id")
    // A package or an endpoint, never both and never neither. Refused here with
    // the sentence rather than defaulted, because guessing which one was meant
    // is guessing whether to run code on this machine or send a credential off
    // it — the two things this argument chooses between.
    let npmName = arguments["npm_name"] as? String
    let url = arguments["url"] as? String
    switch (npmName?.isEmpty == false, url?.isEmpty == false) {
    case (false, false):
      throw ToolError.badArgument(
        name: "npm_name", expected: "a package name, or a url for a remote server")
    case (true, true):
      throw ToolError.badArgument(
        name: "url", expected: "either npm_name or url, not both — they are different servers")
    default: break
    }
    let isRemote = url?.isEmpty == false

    guard let rawEnv = arguments["env"] as? [[String: Any]], !rawEnv.isEmpty else {
      throw ToolError.badArgument(name: "env", expected: "a non-empty array of variable objects")
    }

    let env = try rawEnv.map { entry -> ServerStore.Definition.Variable in
      guard let name = entry["name"] as? String else {
        throw ToolError.badArgument(name: "env[].name", expected: "a string")
      }
      return .init(
        name: name,
        required: entry["required"] as? Bool ?? false,
        secret: entry["secret"] as? Bool ?? false,
        description: entry["description"] as? String ?? "",
        header: (entry["header"] as? [String: Any]).flatMap { raw in
          guard let name = raw["name"] as? String, let format = raw["format"] as? String
          else { return nil }
          return .init(name: name, format: format)
        })
    }

    let definition = ServerStore.Definition(
      displayName: arguments["display_name"] as? String ?? id,
      summary: arguments["summary"] as? String ?? "",
      npmName: isRemote ? nil : npmName,
      // A package is free to put its entry point anywhere, and `ServerInstaller`
      // resolves it from the installed package.json when this is empty. Guessing
      // `<id>-mcp` is a catalog convention, not a fact about somebody else's
      // package.
      binName: isRemote ? nil : (arguments["bin_name"] as? String ?? ""),
      url: url,
      docsUrl: arguments["docs_url"] as? String,
      dialect: arguments["dialect"] as? String ?? BastionServer.Dialect.v2025_11_25.rawValue,
      writeGate: isRemote ? nil : arguments["write_gate"] as? String,
      writeTools: isRemote ? arguments["write_tools"] as? [String] : nil,
      stateEnv: isRemote ? [] : (arguments["state_env"] as? [String] ?? []),
      env: env)

    try ServerStore.shared.upsert(
      custom: id, definition: definition,
      replacing: ServerStore.shared.contains(id) ? id : nil)

    // Nothing to fetch for a remote server, and `install` would return silently
    // — but the NOTE is the part that matters: telling an agent to poll for
    // "installed" on a server that never installs is telling it to wait forever.
    if !isRemote, let server = ServerStore.shared.server(id: id) {
      Task { await ServerInstaller.shared.install(server) }
    }
    return [
      "id": id, "added": true,
      "note": isRemote
        ? "'\(id)' is in your list and points at \(url ?? ""). Nothing is downloaded and no "
          + "process is started. It needs a profile before any client can reach it."
        : "'\(id)' is in your list and \(npmName ?? id) is downloading. It needs a profile "
          + "before any client can reach it.",
    ]
  }

  private static func removeServer(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "id")
    guard let server = ServerStore.shared.server(id: id) else { throw ToolError.noSuchServer(id) }
    // Invariant 3. `ServerStore.remove` refuses this too; restated so the caller
    // gets the sentence rather than a caught store error.
    guard server.origin != .builtin else { throw ToolError.refusedBuiltin("remove") }

    let profiles = ProfileStore.shared.profiles.filter { $0.serverID == id }.count
    try ServerStore.shared.remove(server)
    return [
      "id": id, "removed": true,
      "note": "'\(id)', \(profiles) profile\(profiles == 1 ? "" : "s"), "
        + "\(profiles == 1 ? "its" : "their") credentials in the Keychain and its downloaded code "
        + "are all gone.",
    ]
  }

  private static func upsertProfile(_ arguments: [String: Any]) throws -> Any {
    let name = try string(arguments, "name")
    let serverID = try string(arguments, "server")
    guard Profile.isValidName(name) else {
      throw ToolError.badArgument(
        name: "name", expected: "lowercase letters, digits and dashes — it becomes a URL path "
          + "segment and a Keychain account component")
    }
    guard let server = ServerStore.shared.server(id: serverID) else {
      throw ToolError.noSuchServer(serverID)
    }

    let existing = ProfileStore.shared.profile(named: name, server: serverID)
    var values = existing?.values ?? [:]
    var ignored: [String] = []
    if let given = arguments["values"] as? [String: String] {
      let known = Set(server.env.map(\.name))
      let secrets = Set(server.env.filter(\.isSecret).map(\.name))
      for (key, value) in given {
        // A secret handed to this tool would be written to profiles.json in
        // plaintext, which is the exact file this app exists to empty. Refused
        // rather than quietly stored, and named so the caller knows to use
        // set_credential.
        guard !secrets.contains(key) else {
          throw ToolError.badArgument(
            name: "values.\(key)",
            expected: "set with set_credential — '\(key)' is a secret and would otherwise be "
              + "written to disk in plaintext")
        }
        guard known.contains(key) else {
          ignored.append(key)
          continue
        }
        if value.isEmpty { values.removeValue(forKey: key) } else { values[key] = value }
      }
    }

    let profile = Profile(
      name: name, serverID: serverID, values: values,
      allowWrites: arguments["allow_writes"] as? Bool ?? existing?.allowWrites ?? false,
      // Carried over rather than defaulted, like `values` and `allowWrites`
      // above. This tool takes no capture argument, so rebuilding the profile
      // without it would let an agent editing an unrelated field silently
      // reset a choice the person made in the window.
      captureMode: existing?.captureMode)
    try ProfileStore.shared.upsert(profile)

    var out: [String: Any] = [
      "name": name, "server": serverID,
      "created": existing == nil,
      "endpoint": "http://127.0.0.1:\(Gateway.shared.port)/s/\(name)/\(serverID)",
      "allow_writes": profile.allowWrites,
    ]
    let missing = ProfileEnvironment.missing(for: profile, server: server)
    if !missing.isEmpty { out["missing"] = missing }
    if !ignored.isEmpty {
      out["ignored"] = ignored
      out["note"] =
        "'\(serverID)' does not read \(ignored.joined(separator: ", ")), so \(ignored.count == 1 ? "it was" : "they were") dropped."
    }
    return out
  }

  private static func removeProfile(_ arguments: [String: Any]) throws -> Any {
    let name = try string(arguments, "name")
    let serverID = try string(arguments, "server")
    guard let profile = ProfileStore.shared.profile(named: name, server: serverID) else {
      throw ToolError.noSuchProfile(profile: name, server: serverID)
    }
    Supervisor.shared.stop(profile: name, server: serverID)
    try ProfileStore.shared.remove(profile)
    return [
      "name": name, "server": serverID, "removed": true,
      "note": "The profile and every credential it owned in the Keychain are gone. Any client "
        + "still pointing at it will stop working.",
    ]
  }

  /// Write one secret. There is deliberately no `get_credential`.
  private static func setCredential(_ arguments: [String: Any]) throws -> Any {
    let profileName = try string(arguments, "profile")
    let serverID = try string(arguments, "server")
    let variable = try string(arguments, "variable")
    let value = try string(arguments, "value")

    guard let server = ServerStore.shared.server(id: serverID) else {
      throw ToolError.noSuchServer(serverID)
    }
    guard let profile = ProfileStore.shared.profile(named: profileName, server: serverID) else {
      throw ToolError.noSuchProfile(profile: profileName, server: serverID)
    }
    // Bastion passes a child only the variables its definition lists, so
    // accepting an unknown one would store a credential nothing will ever read
    // — a silent no-op the caller would believe had worked.
    guard server.env.contains(where: { $0.name == variable }) else {
      throw ToolError.unknownVariable(variable: variable, server: serverID)
    }

    let account = CredentialStore.account(
      profile: profileName, server: serverID, variable: variable)
    try CredentialStore.write(.profile, account: account, value: value)
    // The child in memory is holding the old value in its environment; only a
    // restart picks up the new one.
    Supervisor.shared.stop(profile: profileName, server: serverID)

    var out: [String: Any] = [
      "profile": profileName, "server": serverID, "variable": variable, "stored": true,
      "note": "Stored in the Keychain. Any running instance was stopped so the next request "
        + "starts one holding the new value.",
    ]
    let missing = ProfileEnvironment.missing(for: profile, server: server)
    if !missing.isEmpty { out["still_missing"] = missing }
    return out
  }

  private static func wireClient(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "client")
    guard let client = ClientWiring.all.first(where: { $0.id == id }) else {
      throw ToolError.noSuchClient(id: id, known: ClientWiring.all.map(\.id))
    }

    let enabled = Set(ServerStore.shared.servers.filter(\.isEnabled).map(\.id))
    var profiles = ProfileStore.shared.profiles.filter { enabled.contains($0.serverID) }
    if let wanted = arguments["profiles"] as? [String] {
      let set = Set(wanted)
      profiles = profiles.filter { set.contains($0.id) }
      guard !profiles.isEmpty else {
        throw ToolError.badArgument(
          name: "profiles",
          expected: "'<profile>/<server>' ids that exist and whose server is enabled")
      }
    }

    let backup: URL?
    do {
      backup = try ClientWiring.wire(
        client, profiles: profiles, force: arguments["force"] as? Bool ?? false)
    } catch let error as ClientWiring.WireError {
      // Only a collision has an override. `ambiguousKeys` is a prefix the user
      // has to change, and telling an agent to force it would be advice that
      // cannot work.
      guard case .collision = error else { throw error }
      throw ToolError.wireRefused(error.errorDescription ?? "\(error)")
    }

    var out: [String: Any] = [
      "client": id, "wired": profiles.map(\.id),
      "config_path": client.configURL.path,
    ]
    if let backup { out["backup"] = backup.path }
    out["note"] =
      "The config carries a revocable loopback token, never a credential. "
      + (client.transport == .bridge
        ? "This client spawns bastion-bridge, which starts Bastion on demand."
        : "This client reaches Bastion over HTTP, so Bastion has to be running.")
    return out
  }

  private static func unwireClient(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "client")
    guard let client = ClientWiring.all.first(where: { $0.id == id }) else {
      throw ToolError.noSuchClient(id: id, known: ClientWiring.all.map(\.id))
    }
    let backup = try ClientWiring.unwire(client)
    var out: [String: Any] = ["client": id, "unwired": true]
    if let backup { out["backup"] = backup.path }
    out["note"] = "Only Bastion's own entries were removed; everything else in the file is as it was."
    return out
  }

  // MARK: - Arguments

  private static func string(_ arguments: [String: Any], _ key: String) throws -> String {
    guard let value = arguments[key] as? String, !value.isEmpty else {
      throw ToolError.missingArgument(key)
    }
    return value
  }

  private static func describe(_ origin: BastionServer.Origin) -> String {
    switch origin {
    case .catalog: "catalog"
    case .custom: "custom"
    case .builtin: "built-in"
    }
  }
}
