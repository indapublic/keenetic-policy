// KeeneticPolicy — switches the Keenetic access policy of this Mac from the
// menu bar, over the router's local RCI API.
//
// Build: make            (see Makefile)
// CLI:   KeeneticPolicy --help

import AppKit
import CryptoKit
import Darwin
import ServiceManagement

let agentLabel = "com.indapublic.keeneticpolicy"

// MARK: - Paths

enum AppPaths {
    /// The path the process was started from. CommandLine.arguments[0] is the
    /// word as typed, so for `keenetic-policy` it has no directory at all;
    /// _NSGetExecutablePath always knows the real one.
    static let executable: URL = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        _NSGetExecutablePath(&buffer, &size)
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }()

    /// The .app bundle, also when the binary is started through a symlink
    /// (Homebrew installs one into bin/).
    static let bundle: Bundle = {
        let executable = AppPaths.executable
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        if contents.lastPathComponent == "Contents",
           contents.deletingLastPathComponent().pathExtension == "app",
           let bundle = Bundle(url: contents.deletingLastPathComponent()) {
            return bundle
        }
        return Bundle.main
    }()

    static let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    static let home: URL = {
        if let env = ProcessInfo.processInfo.environment["HOME"], !env.isEmpty,
           FileManager.default.fileExists(atPath: env) {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static let configDir = home.appendingPathComponent(".config/keenetic-policy", isDirectory: true)
    static let configFile = configDir.appendingPathComponent("config.json")
    static let setupCommand = configDir.appendingPathComponent("Setup.command")
    static let logFile = home.appendingPathComponent("Library/Logs/KeeneticPolicy.log")
    static let oldLogFile = home.appendingPathComponent("Library/Logs/KeeneticPolicy.old.log")
}

// MARK: - Log

enum Log {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let manager = FileManager.default
        try? manager.createDirectory(at: AppPaths.logFile.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)

        let attributes = try? manager.attributesOfItem(atPath: AppPaths.logFile.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size > 512 * 1024 {
            try? manager.removeItem(at: AppPaths.oldLogFile)
            try? manager.moveItem(at: AppPaths.logFile, to: AppPaths.oldLogFile)
        }

        if let handle = try? FileHandle(forWritingTo: AppPaths.logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: AppPaths.logFile)
        }
    }
}

// MARK: - Config

struct Config: Codable {
    var host = "192.168.1.1"
    var login = "admin"
    var mac = ""
    var language: String?
    var labels: [String: String] = [:]
    var lastPolicy: String?

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "192.168.1.1"
        login = try container.decodeIfPresent(String.self, forKey: .login) ?? "admin"
        mac = try container.decodeIfPresent(String.self, forKey: .mac) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        lastPolicy = try container.decodeIfPresent(String.self, forKey: .lastPolicy)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: AppPaths.configFile),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: AppPaths.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: AppPaths.configFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: AppPaths.configFile.path)
    }

    var baseURL: String {
        if host.hasPrefix("http://") || host.hasPrefix("https://") { return host }
        return "http://" + host
    }
}

// MARK: - Localization

enum L10n {
    private static var overrideBundle: Bundle?

    /// Call after the config may have changed.
    static func refresh() {
        overrideBundle = nil
        guard let code = Config.load().language, !code.isEmpty, code != "system",
              let path = AppPaths.bundle.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return }
        overrideBundle = bundle
    }

    static func t(_ key: String) -> String {
        (overrideBundle ?? AppPaths.bundle).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}

// MARK: - Keychain

enum Keychain {
    static let service = "keenetic-policy"

    @discardableResult
    static func run(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return (-1, "") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, text)
    }

    static func password(login: String) -> String? {
        // Test hook: lets `make test` run against a mock router without
        // touching the real keychain.
        if let injected = ProcessInfo.processInfo.environment["KEENETIC_POLICY_PASSWORD"],
           !injected.isEmpty {
            return injected
        }
        let (status, output) = run(["find-generic-password", "-s", service, "-a", login, "-w"])
        return status == 0 && !output.isEmpty ? output : nil
    }

    static func store(password: String, login: String) {
        run(["delete-generic-password", "-s", service, "-a", login])
        run(["add-generic-password", "-s", service, "-a", login, "-w", password, "-U"])
    }
}

// MARK: - Errors

enum RouterError: LocalizedError {
    case network(String)
    case auth
    case api(String)
    case noConfig

    var errorDescription: String? {
        switch self {
        case .network(let detail): return L10n.t("error.network", detail)
        case .auth: return L10n.t("error.auth")
        case .api(let detail): return L10n.t("error.api", detail)
        case .noConfig: return L10n.t("error.notConfigured")
        }
    }
}

// MARK: - RCI client

struct Policy {
    let name: String
    let description: String

    var isDefault: Bool { name.isEmpty }
}

final class Router {
    private let base: String
    private let login: String
    private let password: String
    let mac: String
    private let session: URLSession
    private var authenticated = false

    init(config: Config, password: String) {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        self.base = base
        self.login = config.login
        self.password = password
        self.mac = config.mac

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration, delegate: TrustAll(), delegateQueue: nil)
    }

    private func send(_ request: URLRequest) throws -> (Any?, HTTPURLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        var payload = Data()
        var response: HTTPURLResponse?
        var failure: Error?

        session.dataTask(with: request) { data, resp, error in
            payload = data ?? Data()
            response = resp as? HTTPURLResponse
            failure = error
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 25) == .success else {
            throw RouterError.network(L10n.t("error.timeout"))
        }
        if let failure {
            throw RouterError.network(failure.localizedDescription)
        }
        guard let http = response else {
            throw RouterError.network(L10n.t("error.emptyResponse"))
        }
        let object = payload.isEmpty ? nil : try? JSONSerialization.jsonObject(with: payload)
        return (object, http)
    }

    private func authenticate() throws {
        var probe = URLRequest(url: URL(string: base + "/auth")!)
        probe.setValue("application/json", forHTTPHeaderField: "Accept")

        let (_, probeResponse) = try send(probe)
        if probeResponse.statusCode == 200 {
            authenticated = true
            return
        }
        guard let realm = probeResponse.value(forHTTPHeaderField: "X-NDM-Realm"),
              let challenge = probeResponse.value(forHTTPHeaderField: "X-NDM-Challenge"),
              !challenge.isEmpty else {
            throw RouterError.auth
        }

        let inner = Insecure.MD5.hash(data: Data("\(login):\(realm):\(password)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let outer = SHA256.hash(data: Data((challenge + inner).utf8))
            .map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: URL(string: base + "/auth")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["login": login, "password": outer])

        let (object, response) = try send(request)
        guard response.statusCode == 200 else { throw RouterError.auth }
        if let dictionary = object as? [String: Any],
           let state = dictionary["auth"] as? String, state != "ok" {
            throw RouterError.auth
        }
        authenticated = true
    }

    func get(_ path: String) throws -> Any {
        if !authenticated { try authenticate() }

        var (object, response) = try send(URLRequest(url: URL(string: base + "/" + path)!))
        if response.statusCode == 401 {
            authenticated = false
            try authenticate()
            (object, response) = try send(URLRequest(url: URL(string: base + "/" + path)!))
        }
        guard response.statusCode == 200 else {
            throw RouterError.api("HTTP \(response.statusCode)")
        }
        return object ?? [:]
    }

    func post(_ path: String, _ body: [String: Any]) throws -> Any {
        if !authenticated { try authenticate() }

        var request = URLRequest(url: URL(string: base + "/" + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (object, response) = try send(request)
        if response.statusCode == 401 {
            authenticated = false
            try authenticate()
            return try post(path, body)
        }
        guard response.statusCode == 200 else {
            throw RouterError.api("HTTP \(response.statusCode)")
        }
        if let dictionary = object as? [String: Any], let error = dictionary["error"] as? String {
            throw RouterError.api(error)
        }
        return object ?? [:]
    }

    // MARK: policies

    func policies() throws -> [Policy] {
        let object = try get("rci/show/ip/policy")
        var result: [Policy] = []

        func append(_ name: String, _ value: Any) {
            guard !name.isEmpty else { return }
            var description = ""
            if let dictionary = value as? [String: Any] {
                guard dictionary["mark"] != nil || dictionary["table4"] != nil
                        || dictionary["description"] != nil || dictionary["route4"] != nil else { return }
                description = (dictionary["description"] as? String) ?? ""
            } else if !(value is String) {
                return
            }
            result.append(Policy(name: name, description: description))
        }

        if let dictionary = object as? [String: Any] {
            if let inner = dictionary["policy"] {
                if let nested = inner as? [String: Any] {
                    for (name, value) in nested { append(name, value) }
                } else if let array = inner as? [Any] {
                    for element in array {
                        if let name = element as? String {
                            append(name, name)
                        } else if let item = element as? [String: Any], let name = item["name"] as? String {
                            append(name, item)
                        }
                    }
                }
            } else {
                for (name, value) in dictionary { append(name, value) }
            }
        } else if let array = object as? [Any] {
            for element in array {
                if let name = element as? String {
                    append(name, name)
                } else if let item = element as? [String: Any], let name = item["name"] as? String {
                    append(name, item)
                }
            }
        }

        var seen = Set<String>()
        result = result.filter { seen.insert($0.name).inserted }
        result.sort { rank($0.name) < rank($1.name) }
        // "Default policy" is not an object on the router: it is the absence
        // of a policy on the client.
        result.insert(Policy(name: "", description: ""), at: 0)
        return result
    }

    private func rank(_ name: String) -> (Int, String) {
        if name.hasPrefix("Policy"), let index = Int(name.dropFirst(6)) { return (index, name) }
        return (1000, name)
    }

    /// Empty string means the default policy, nil means the router did not say.
    func currentPolicy() throws -> String? {
        for path in ["rci/show/ip/hotspot", "rci/show/ip/hotspot/host"] {
            guard let object = try? get(path), let host = findHost(object) else { continue }
            if let policy = host["policy"] as? String, !policy.isEmpty { return policy }
            return ""
        }
        return nil
    }

    private func findHost(_ object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if let candidate = dictionary["mac"] as? String, candidate.lowercased() == mac.lowercased() {
                return dictionary
            }
            for (key, value) in dictionary where key != "mac" {
                if let found = findHost(value) { return found }
            }
        } else if let array = object as? [Any] {
            for element in array {
                if let found = findHost(element) { return found }
            }
        }
        return nil
    }

    func setPolicy(_ name: String) throws {
        if name.isEmpty {
            _ = try post("rci/ip/hotspot/host/policy", ["mac": mac, "no": true])
        } else {
            _ = try post("rci/ip/hotspot/host/policy", ["mac": mac, "policy": name])
        }
    }
}

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Helpers

func detectMAC() -> String? {
    func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    var interfaces: [String] = []
    for line in run("/sbin/route", ["-n", "get", "default"]).split(separator: "\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" {
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { interfaces.append(name) }
        }
    }
    interfaces += ["en0", "en1"]

    for name in interfaces {
        for line in run("/sbin/ifconfig", [name]).split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, parts[0] == "ether" {
                return parts[1].lowercased()
            }
        }
    }
    return nil
}

func readPassword(prompt: String) -> String {
    FileHandle.standardOutput.write(Data(prompt.utf8))
    let descriptor = STDIN_FILENO
    let interactive = isatty(descriptor) == 1
    var original = termios()
    if interactive {
        tcgetattr(descriptor, &original)
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(descriptor, TCSANOW, &hidden)
    }
    let line = readLine() ?? ""
    if interactive {
        tcsetattr(descriptor, TCSANOW, &original)
        print("")
    }
    return line
}

func labelKey(_ name: String) -> String {
    name.isEmpty ? "default" : name
}

func displayTitle(for policy: Policy, config: Config) -> String {
    if let label = config.labels[labelKey(policy.name)], !label.isEmpty { return label }
    if !policy.description.isEmpty { return policy.description }
    if policy.isDefault { return L10n.t("policy.default") }
    return policy.name
}

// MARK: - Login agent (SMAppService)

func loginAgent() -> SMAppService? {
    if #available(macOS 13.0, *) {
        return SMAppService.agent(plistName: agentLabel + ".plist")
    }
    return nil
}

func registerLoginAgentIfNeeded() {
    guard #available(macOS 13.0, *), let agent = loginAgent() else { return }
    guard agent.status == .notRegistered || agent.status == .notFound else { return }
    do {
        try agent.register()
        Log.write("registered login agent")
    } catch {
        Log.write("could not register login agent: \(error.localizedDescription)")
    }
}

func unregisterLoginAgent() -> Bool {
    guard #available(macOS 13.0, *), let agent = loginAgent() else { return false }
    do {
        try agent.unregister()
        Log.write("unregistered login agent")
        return true
    } catch {
        Log.write("could not unregister login agent: \(error.localizedDescription)")
        return false
    }
}

/// True when Finder (or `open`) started us: launchd names that job
/// application.<bundle id>.<number>.
func openedFromFinder() -> Bool {
    let job = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? ""
    return job.hasPrefix("application." + agentLabel + ".")
}

func installedByHomebrew() -> Bool {
    let path = AppPaths.executable.path
    return path.contains("/Cellar/") || path.contains("/opt/homebrew/opt/") || path.contains("/usr/local/opt/")
}

// MARK: - CLI

func cliRouter() -> Router? {
    let config = Config.load()
    guard !config.mac.isEmpty else {
        FileHandle.standardError.write(Data((L10n.t("cli.noConfig") + "\n").utf8))
        return nil
    }
    guard let password = Keychain.password(login: config.login) else {
        FileHandle.standardError.write(Data((L10n.t("cli.noPassword") + "\n").utf8))
        return nil
    }
    return Router(config: config, password: password)
}

func printPolicies(_ policies: [Policy], config: Config, current: String?) {
    for policy in policies {
        let mark = policy.name == current ? "●" : "○"
        let title = displayTitle(for: policy, config: config)
        if policy.isDefault {
            print("  \(mark) \(title)")
        } else if title == policy.name {
            print("  \(mark) \(policy.name)")
        } else {
            print("  \(mark) \(title)  (\(policy.name))")
        }
    }
}

func cliSetup() -> Int32 {
    var config = Config.load()

    print(L10n.t("setup.title"))
    print(L10n.t("setup.router", config.host), terminator: "")
    if let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty { config.host = line }

    print(L10n.t("setup.login", config.login), terminator: "")
    if let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty { config.login = line }

    let password = readPassword(prompt: L10n.t("setup.password"))
    guard !password.isEmpty else {
        print(L10n.t("setup.noPassword"))
        return 1
    }

    let detected = detectMAC()
    let suggestion = config.mac.isEmpty ? (detected ?? "") : config.mac
    print(L10n.t("setup.mac", suggestion), terminator: "")
    if let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty {
        config.mac = line.lowercased()
    } else if config.mac.isEmpty, let detected {
        config.mac = detected
    }
    guard !config.mac.isEmpty else {
        print(L10n.t("setup.noMAC"))
        return 1
    }

    print(L10n.t("setup.checking"))
    let router = Router(config: config, password: password)
    do {
        let policies = try router.policies()
        let current = try? router.currentPolicy()
        Keychain.store(password: password, login: config.login)
        try config.save()
        Log.write("configured \(config.host), mac \(config.mac)")

        print(L10n.t("setup.done"))
        print(L10n.t("setup.policies"))
        printPolicies(policies, config: config, current: current ?? nil)
        print("")
        print(L10n.t("setup.labelsHint", AppPaths.configFile.path))
        print("")
        print(L10n.t("setup.cliHint"))
        print(L10n.t("setup.appHint", AppPaths.bundle.bundlePath))
        return 0
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        print(L10n.t("setup.failed", message))
        Log.write("setup failed: \(message)")
        return 1
    }
}

func cliMain(_ arguments: [String]) -> Int32 {
    switch arguments[0] {
    case "--setup":
        return cliSetup()

    case "--list":
        guard let router = cliRouter() else { return 1 }
        do {
            let config = Config.load()
            let policies = try router.policies()
            let current = try? router.currentPolicy()
            printPolicies(policies, config: config, current: current ?? nil)
            return 0
        } catch {
            FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription).utf8))
            return 1
        }

    case "--current":
        guard let router = cliRouter() else { return 1 }
        do {
            if let current = try router.currentPolicy() {
                print(current)
                return 0
            }
            FileHandle.standardError.write(Data((L10n.t("cli.currentUnknown") + "\n").utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription).utf8))
            return 1
        }

    case "--set":
        guard arguments.count > 1 else {
            FileHandle.standardError.write(Data((L10n.t("cli.setUsage") + "\n").utf8))
            return 2
        }
        guard let router = cliRouter() else { return 1 }
        var target = arguments[1]
        if target == "default" || target == "по умолчанию" { target = "" }
        do {
            try router.setPolicy(target)
            var config = Config.load()
            config.lastPolicy = target
            try? config.save()
            Log.write("policy set to \(target.isEmpty ? "default" : target)")
            print(L10n.t("cli.policy", target.isEmpty ? L10n.t("cli.policyDefault") : target))
            return 0
        } catch {
            FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription).utf8))
            return 1
        }

    case "--check":
        guard let router = cliRouter() else { return 1 }
        do {
            let config = Config.load()
            let policies = try router.policies()
            let current = try? router.currentPolicy()
            print(L10n.t("cli.mac", config.mac))
            printPolicies(policies, config: config, current: current ?? nil)
            return 0
        } catch {
            FileHandle.standardError.write(Data(((error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription).utf8))
            return 1
        }

    case "--register":
        registerLoginAgentIfNeeded()
        return loginAgent()?.status == .enabled ? 0 : 1

    case "--unregister":
        return unregisterLoginAgent() ? 0 : 1

    case "--version":
        print("KeeneticPolicy \(AppPaths.version) (\(AppPaths.build))")
        return 0

    case "--help", "-h":
        print(L10n.t("cli.help"))
        return 0

    default:
        print(L10n.t("cli.help"))
        return 2
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let queue = DispatchQueue(label: "keenetic-policy.worker")

    private var config = Config.load()
    private var policies: [Policy] = []
    private var current: String?
    private var lastError: String?
    private var busy = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusItem.button?.title = "…"

        menu.delegate = self
        statusItem.menu = menu

        L10n.refresh()
        rebuild()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() {
        refresh()
    }

    // MARK: state

    private func refresh(completion: (() -> Void)? = nil) {
        if busy { return }
        busy = true

        L10n.refresh()
        let config = Config.load()
        self.config = config

        guard !config.mac.isEmpty, let password = Keychain.password(login: config.login) else {
            busy = false
            policies = []
            current = nil
            lastError = L10n.t("error.notConfigured")
            rebuild()
            completion?()
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            let router = Router(config: config, password: password)
            var loaded: [Policy] = []
            var state: String?
            var failureMessage: String?

            do {
                loaded = try router.policies()
                state = try router.currentPolicy()
            } catch {
                failureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            DispatchQueue.main.async {
                self.busy = false
                if let message = failureMessage {
                    self.lastError = message
                } else {
                    self.lastError = nil
                    self.policies = loaded
                    self.current = state ?? config.lastPolicy
                }
                self.rebuild()
                completion?()
            }
        }
    }

    private func apply(_ name: String) {
        let config = Config.load()
        self.config = config
        guard let password = Keychain.password(login: config.login) else {
            lastError = L10n.t("error.noKeychain")
            rebuild()
            return
        }

        statusItem.button?.title = "…"
        queue.async { [weak self] in
            guard let self else { return }
            let router = Router(config: config, password: password)
            var failureMessage: String?
            var state: String?

            do {
                try router.setPolicy(name)
                var updated = Config.load()
                updated.lastPolicy = name
                try? updated.save()
                state = try? router.currentPolicy()
                Log.write("policy set to \(name.isEmpty ? "default" : name)")
            } catch {
                failureMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Log.write("could not set policy: \(failureMessage ?? "")")
            }

            DispatchQueue.main.async {
                if let message = failureMessage {
                    self.lastError = message
                    self.rebuild()
                    NSSound.beep()
                    return
                }
                self.lastError = nil
                self.config.lastPolicy = name
                self.current = state ?? name
                self.rebuild()
                self.refresh()
            }
        }
    }

    // MARK: menu

    private func rebuild() {
        menu.removeAllItems()

        if lastError == L10n.t("error.notConfigured") {
            statusItem.button?.title = "⚠︎"
            statusItem.button?.toolTip = L10n.t("status.notConfigured")
            menu.addItem(disabled(L10n.t("menu.header")))
            menu.addItem(.separator())
            menu.addItem(item(L10n.t("menu.setup"), #selector(openSetup)))
            menu.addItem(.separator())
            menu.addItem(item(L10n.t("menu.quit"), #selector(quit)))
            return
        }

        if let current, let policy = policies.first(where: { $0.name == current }) {
            let title = displayTitle(for: policy, config: config)
            if policy.isDefault && config.labels["default"] == nil {
                statusItem.button?.title = "🌐"
            } else if title.count > 18 {
                statusItem.button?.title = String(title.prefix(17)) + "…"
            } else {
                statusItem.button?.title = title
            }
            statusItem.button?.toolTip = L10n.t("status.tooltip", title)
        } else {
            statusItem.button?.title = "🌐"
            statusItem.button?.toolTip = L10n.t("status.unknown")
        }

        menu.addItem(disabled(L10n.t("menu.header")))
        menu.addItem(.separator())

        if policies.isEmpty {
            menu.addItem(disabled(lastError ?? L10n.t("policy.emptyList")))
        } else {
            for policy in policies {
                let entry = item(displayTitle(for: policy, config: config), #selector(selectPolicy(_:)))
                entry.representedObject = policy.name
                entry.state = policy.name == current ? .on : .off
                entry.toolTip = policy.isDefault ? "policy: no" : policy.name
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())

        if let lastError, lastError != L10n.t("error.notConfigured") {
            let errorItem = disabled(lastError)
            errorItem.attributedTitle = NSAttributedString(
                string: lastError,
                attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(errorItem)
            menu.addItem(.separator())
        }

        let refreshItem = item(L10n.t("menu.refresh"), #selector(refreshNow))
        refreshItem.keyEquivalent = "r"
        menu.addItem(refreshItem)
        menu.addItem(item(L10n.t("menu.web"), #selector(openWebUI)))
        menu.addItem(.separator())
        menu.addItem(item(L10n.t("menu.setup"), #selector(openSetup)))
        menu.addItem(item(L10n.t("menu.quit"), #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: actions

    @objc private func selectPolicy(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        apply(name)
    }

    @objc private func refreshNow() {
        refresh()
    }

    @objc private func openWebUI() {
        let config = Config.load()
        if let url = URL(string: config.baseURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSetup() {
        try? FileManager.default.createDirectory(at: AppPaths.configDir, withIntermediateDirectories: true)
        let binary = AppPaths.executable.path
        let script = """
        #!/bin/bash
        exec "\(binary)" --setup
        """
        try? script.write(to: AppPaths.setupCommand, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: AppPaths.setupCommand.path)
        NSWorkspace.shared.open(AppPaths.setupCommand)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

L10n.refresh()

let arguments = CommandLine.arguments
if arguments.count > 1, arguments[1].hasPrefix("--") || arguments[1] == "-h" {
    exit(cliMain(Array(arguments.dropFirst())))
}

if let identifier = AppPaths.bundle.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .filter { $0.processIdentifier != getpid() }
    if !others.isEmpty {
        Log.write("another instance is running, exiting")
        exit(0)
    }
}

Log.write("KeeneticPolicy \(AppPaths.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) (pid \(getpid()))")

if openedFromFinder() && !installedByHomebrew() {
    registerLoginAgentIfNeeded()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
