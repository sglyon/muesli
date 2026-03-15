import Foundation

struct RuntimePaths {
    let repoRoot: URL
    let pythonExecutable: URL?
    let workerScript: URL?
    let pasteScript: URL?
    let menuIcon: URL?
    let appIcon: URL?
    let bundlePath: URL?

    static func resolve() throws -> RuntimePaths {
        let fileManager = FileManager.default

        if let bundleResource = Bundle.main.resourceURL {
            // Check for runtime.json (Python-bundled app)
            let runtimeURL = bundleResource.appendingPathComponent("runtime.json")
            if fileManager.fileExists(atPath: runtimeURL.path) {
                let data = try Data(contentsOf: runtimeURL)
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let isBundled = payload?["bundled"] as? String == "true" || payload?["bundled"] as? Bool == true

                let repoRoot = isBundled ? bundleResource : URL(fileURLWithPath: payload?["repo_root"] as? String ?? "")

                let pythonExecutable: URL
                if isBundled {
                    let relativePython = payload?["python_executable"] as? String ?? "python-runtime/bin/python3"
                    pythonExecutable = bundleResource.appendingPathComponent(relativePython)
                } else {
                    pythonExecutable = URL(fileURLWithPath: payload?["python_executable"] as? String ?? "")
                }

                return RuntimePaths(
                    repoRoot: repoRoot,
                    pythonExecutable: pythonExecutable,
                    workerScript: bundleResource.appendingPathComponent("worker.py"),
                    pasteScript: bundleResource.appendingPathComponent("paste_text.py"),
                    menuIcon: bundleResource.appendingPathComponent("menu_m_template.png"),
                    appIcon: bundleResource.appendingPathComponent("muesli.icns"),
                    bundlePath: Bundle.main.bundleURL
                )
            }

            // Native-only bundle (no Python runtime, no runtime.json)
            return RuntimePaths(
                repoRoot: bundleResource,
                pythonExecutable: nil,
                workerScript: nil,
                pasteScript: nil,
                menuIcon: bundleResource.appendingPathComponent("menu_m_template.png"),
                appIcon: bundleResource.appendingPathComponent("muesli.icns"),
                bundlePath: Bundle.main.bundleURL
            )
        }

        // Dev fallback: search up for bridge/worker.py
        var searchURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = searchURL.appendingPathComponent("bridge/worker.py")
            if fileManager.fileExists(atPath: candidate.path) {
                return RuntimePaths(
                    repoRoot: searchURL,
                    pythonExecutable: searchURL.appendingPathComponent(".venv/bin/python"),
                    workerScript: candidate,
                    pasteScript: searchURL.appendingPathComponent("bridge/paste_text.py"),
                    menuIcon: searchURL.appendingPathComponent("assets/menu_m_template.png"),
                    appIcon: searchURL.appendingPathComponent("assets/muesli.icns"),
                    bundlePath: nil
                )
            }
            searchURL.deleteLastPathComponent()
        }

        throw NSError(domain: "MuesliRuntime", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate app bundle or repo root.",
        ])
    }
}
