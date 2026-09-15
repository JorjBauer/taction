import AppKit
import Security
import TactionDaemon

/// Updates from GitHub Releases, with no framework and no server of our own.
///
/// A release is a git tag `vX.Y.Z` with an asset `Taction-X.Y.Z.zip` containing `Taction.app`
/// (scripts/release.sh produces both). The check compares the tag with this bundle's version.
/// A newer release is downloaded, unzipped, and its code signature verified: it must be validly
/// signed by the same Team ID as the running app, or it is discarded. Then the bundle on disk is
/// swapped and the app relaunches. With "Automatically apply updates" off, the user is asked first.
final class Updater {
    struct Release {
        var version: String
        var tag: String
        var zipURL: URL
        var notes: String
    }

    enum UpdateError: LocalizedError {
        case badResponse(String)
        case noAsset
        case unsigned(String)
        case teamMismatch(expected: String, got: String)
        case noAppInArchive
        case install(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let s): return "GitHub answered unexpectedly: \(s)"
            case .noAsset: return "The release has no Taction-*.zip asset."
            case .unsigned(let s): return "The downloaded app is not validly signed: \(s)"
            case .teamMismatch(let e, let g): return "The downloaded app is signed by team \(g), not \(e). Refusing to install it."
            case .noAppInArchive: return "The archive does not contain Taction.app."
            case .install(let s): return "Installing failed: \(s)"
            }
        }
    }

    private var timer: Timer?
    private var checking = false
    private let session = URLSession(configuration: .ephemeral)

    /// First check half a minute after launch, then daily.
    func scheduleChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard !checking else { return }
        checking = true
        Log.info("update", "checking \(AppInfo.updateRepo) for a release newer than \(AppInfo.version)")
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checking = false
                switch result {
                case .failure(let error):
                    Log.error("update", "check failed: \(error.localizedDescription)")
                case .success(let release):
                    guard Updater.isVersion(release.version, newerThan: AppInfo.version) else {
                        Log.info("update", "up to date (latest is \(release.version))")
                        return
                    }
                    if UserDefaults.standard.string(forKey: AppInfo.Defaults.skippedUpdateVersion) == release.version {
                        Log.info("update", "\(release.version) available but skipped by the user")
                        return
                    }
                    Log.info("update", "\(release.version) is available")
                    if UserDefaults.standard.bool(forKey: AppInfo.Defaults.autoApplyUpdates) {
                        self.downloadAndInstall(release, interactive: false)
                    } else {
                        self.offer(release)
                    }
                }
            }
        }
    }

    // MARK: GitHub

    private func fetchLatestRelease(_ completion: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.updateRepo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppInfo.name)/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { data, response, error in
            if let error = error { return completion(.failure(error)) }
            guard let http = response as? HTTPURLResponse, let data = data else {
                return completion(.failure(UpdateError.badResponse("no response")))
            }
            guard http.statusCode == 200 else {
                return completion(.failure(UpdateError.badResponse("HTTP \(http.statusCode)")))
            }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    throw UpdateError.badResponse("missing tag_name")
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let assets = json["assets"] as? [[String: Any]] ?? []
                let zip = assets.first { a in
                    let n = (a["name"] as? String) ?? ""
                    return n.hasPrefix("\(AppInfo.name)-") && n.hasSuffix(".zip")
                }
                guard let urlString = zip?["browser_download_url"] as? String, let url = URL(string: urlString) else {
                    throw UpdateError.noAsset
                }
                completion(.success(Release(version: version, tag: tag, zipURL: url, notes: (json["body"] as? String) ?? "")))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Dotted-integer comparison; "1.2.10" is newer than "1.2.9". Non-numeric parts compare as 0.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Asking

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = AppInfo.appIcon
        alert.messageText = "\(AppInfo.name) \(release.version) is available"
        var detail = "You have \(AppInfo.version). Installing takes a few seconds, during which \(AppInfo.name) quits and reopens by itself."
        if !release.notes.isEmpty { detail += "\n\n" + release.notes.prefix(600) }
        alert.informativeText = detail
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        NSApp.bringForward()
        switch alert.runModal() {
        case .alertFirstButtonReturn: downloadAndInstall(release, interactive: true)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.version, forKey: AppInfo.Defaults.skippedUpdateVersion)
        default: break
        }
    }

    // MARK: Download, verify, install

    private func downloadAndInstall(_ release: Release, interactive: Bool) {
        Log.info("update", "downloading \(release.zipURL)")
        session.downloadTask(with: release.zipURL) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            do {
                if let error = error { throw error }
                guard let tempURL = tempURL else { throw UpdateError.badResponse("no file") }
                let newApp = try self.unpack(tempURL)
                try self.verify(newApp)
                DispatchQueue.main.async {
                    do {
                        try self.install(newApp)
                    } catch {
                        self.report(error, interactive: interactive)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.report(error, interactive: interactive) }
            }
        }.resume()
    }

    private func report(_ error: Error, interactive: Bool) {
        Log.error("update", error.localizedDescription)
        guard interactive else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update \(AppInfo.name)"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func unpack(_ zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Taction-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.install("ditto exited \(p.terminationStatus)") }
        if let direct = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) {
            return direct
        }
        // One level down, in case the archive has a wrapping folder.
        for sub in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            if let app = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        throw UpdateError.noAppInArchive
    }

    /// The downloaded bundle must be validly signed by the same Team ID as the running app.
    private func verify(_ newApp: URL) throws {
        guard let ownTeam = Updater.teamIdentifier(of: Bundle.main.bundleURL) else {
            throw UpdateError.unsigned("this copy of \(AppInfo.name) is not signed with a Team ID, so updates cannot be trusted")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &code) == errSecSuccess, let staticCode = code else {
            throw UpdateError.unsigned("cannot read code signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(staticCode, flags, nil, &cfError)
        guard status == errSecSuccess else {
            let message = (cfError?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(status)"
            throw UpdateError.unsigned(message)
        }
        guard let newTeam = Updater.teamIdentifier(of: newApp) else { throw UpdateError.unsigned("no Team ID") }
        guard newTeam == ownTeam else { throw UpdateError.teamMismatch(expected: ownTeam, got: newTeam) }
        Log.info("update", "signature verified (team \(newTeam))")
    }

    static func teamIdentifier(of bundle: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let staticCode = code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Swap the bundle on disk and relaunch. The old bundle goes to the Trash.
    private func install(_ newApp: URL) throws {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        let parked = parent.appendingPathComponent(".\(current.lastPathComponent).old-\(getpid())")
        do {
            try fm.moveItem(at: current, to: parked)
        } catch {
            throw UpdateError.install("cannot replace \(current.path): \(error.localizedDescription)")
        }
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            try? fm.moveItem(at: parked, to: current)     // put the old one back
            throw UpdateError.install("cannot move the new version into place: \(error.localizedDescription)")
        }
        try? fm.trashItem(at: parked, resultingItemURL: nil)
        Log.info("update", "installed at \(current.path); relaunching")
        Installer.relaunch(at: current)
    }
}
