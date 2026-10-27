import Foundation

/// The clothod builds the app installs on machines. They ship deflated (scripts/pack-dist.py), because
/// an iOS app may not contain executables for other platforms. On first use they're inflated into
/// Caches, giving RemoteInstaller the dist directory it expects: manifest.json plus the exact builds.
enum DistBundle {
    private static let lock = NSLock()

    static func directory() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let packed = Bundle.main.url(forResource: "dist", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "This build has no bundled clothod."])
        }
        let manifestURL = packed.appendingPathComponent("manifest.json")
        let manifest = try Data(contentsOf: manifestURL)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("clothod-dist", isDirectory: true)
        let stamp = dir.appendingPathComponent("manifest.json")
        if (try? Data(contentsOf: stamp)) == manifest { return dir }

        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        struct Manifest: Decodable { struct Build: Decodable { var file: String }; var builds: [String: Build] }
        for build in try JSONDecoder().decode(Manifest.self, from: manifest).builds.values {
            let deflated = try Data(contentsOf: packed.appendingPathComponent(build.file + ".deflate"))
            let target = dir.appendingPathComponent(build.file)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (deflated as NSData).decompressed(using: .zlib).write(to: target, options: .atomic)
        }
        // Written last, so a half-unpacked directory is redone next time.
        try manifest.write(to: stamp, options: .atomic)
        return dir
    }
}
