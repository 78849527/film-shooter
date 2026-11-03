import Foundation

/// Viewfinder colour tables: baked by the engine once per recipe, then kept in
/// memory and on disk (Caches) so switching film is instant from then on.
@MainActor
final class LUTStore {
    private var memory: [String: FilmLUT] = [:]
    private var order: [String] = []
    private let capacity = 48
    private let directory: URL
    private var inFlight: [String: Task<FilmLUT, Error>] = [:]
    private var prebakeTask: Task<Void, Never>?
    let size = 33
    /// Background bakes wait while this returns true (e.g. a frame is developing).
    var shouldPause: () -> Bool = { false }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let stamp = Self.fnv(String(cString: spk_build_info()))
        directory = caches.appendingPathComponent("LUT-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func key(for recipe: DevelopRecipe) -> String { FilmEngine.lutKey(recipe, size: size) }

    /// A table already baked for this recipe, without touching the engine.
    func cached(for recipe: DevelopRecipe) -> FilmLUT? {
        let k = key(for: recipe)
        if let l = memory[k] { touch(k); return l }
        if let l = loadFromDisk(k) { remember(l); return l }
        return nil
    }

    /// The table for `recipe`, baking it if needed. Concurrent requests for the
    /// same recipe share one bake.
    func lut(for recipe: DevelopRecipe) async throws -> FilmLUT {
        if let l = cached(for: recipe) { return l }
        let k = key(for: recipe)
        if let t = inFlight[k] { return try await t.value }
        let size = self.size
        let task = Task { try await FilmEngine.shared.bakeLUT(recipe: recipe, size: size) }
        inFlight[k] = task
        defer { inFlight[k] = nil }
        let l = try await task.value
        remember(l)
        saveToDisk(l)
        return l
    }

    /// Bake the tables for every film (with this recipe's print settings) in
    /// the background, so scrolling through the film carousel never waits.
    func prebake(around recipe: DevelopRecipe) {
        prebakeTask?.cancel()
        prebakeTask = Task { [weak self] in
            // Nearest films first.
            let films = FilmCatalog.films
            let start = films.firstIndex { $0.id == recipe.filmID } ?? 0
            let ordered = films.indices.sorted { abs($0 - start) < abs($1 - start) }.map { films[$0] }
            for film in ordered {
                if Task.isCancelled { return }
                // Never hold up a development: the engine runs one job at a time.
                while self?.shouldPause() == true {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if Task.isCancelled { return }
                }
                var r = recipe
                r.selectFilm(film.id)
                guard let self else { return }
                if self.cached(for: r) != nil { continue }
                _ = try? await self.lut(for: r)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    func cancelPrebake() {
        prebakeTask?.cancel()
        prebakeTask = nil
    }

    // MARK: storage

    private func remember(_ l: FilmLUT) {
        memory[l.key] = l
        touch(l.key)
        while order.count > capacity {
            let old = order.removeFirst()
            memory.removeValue(forKey: old)
        }
    }

    private func touch(_ k: String) {
        order.removeAll { $0 == k }
        order.append(k)
    }

    private func fileURL(_ k: String) -> URL {
        let safe = k.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe + ".lut")
    }

    private func saveToDisk(_ l: FilmLUT) {
        let url = fileURL(l.key)
        let data = l.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    private func loadFromDisk(_ k: String) -> FilmLUT? {
        let url = fileURL(k)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let count = size * size * size * 4
        guard data.count == count * MemoryLayout<Float16>.stride else { return nil }
        var values = [Float16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return FilmLUT(size: size, rgba: values, key: k)
    }

    private static func fnv(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
