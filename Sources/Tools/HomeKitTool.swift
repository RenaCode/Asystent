import HomeKit

/// Sterowanie HomeKit: włącz/wyłącz urządzenie albo uruchom scenę.
@MainActor
final class HomeManagerProvider: NSObject, HMHomeManagerDelegate {
    static let shared = HomeManagerProvider()
    private let manager = HMHomeManager()
    private var ready: [CheckedContinuation<Void, Never>] = []
    private var loaded = false

    override init() { super.init(); manager.delegate = self }

    func homes() async -> [HMHome] {
        if !loaded { await withCheckedContinuation { ready.append($0) } }
        return manager.homes
    }

    nonisolated func homeManagerDidUpdateHomes(_ m: HMHomeManager) {
        Task { @MainActor in
            loaded = true
            ready.forEach { $0.resume() }
            ready.removeAll()
        }
    }
}

struct HomeKitTool: AssistantTool {
    let spec = ToolSpec(
        name: "home_control",
        description: """
        Steruje HomeKit. action: "list" (lista urządzeń i scen), "on", "off" (urządzenie po nazwie), \
        "scene" (uruchom scenę po nazwie).
        """,
        input_schema: schema([
            "action": ("string", "list | on | off | scene"),
            "name": ("string", "Nazwa urządzenia lub sceny (nie dla list)"),
        ], required: ["action"])
    )

    func run(_ input: JSONValue) async throws -> String {
        let homes = await HomeManagerProvider.shared.homes()
        guard let home = homes.first(where: \.isPrimary) ?? homes.first else { throw ToolError("Brak domu w HomeKit") }
        let action = input["action"]?.string ?? "list"
        let name = input["name"]?.string?.lowercased() ?? ""

        switch action {
        case "list":
            let acc = home.accessories.map { "\($0.name) (\($0.room?.name ?? "-"))" }
            let scenes = home.actionSets.map(\.name)
            return "Urządzenia: \(acc.joined(separator: ", "))\nSceny: \(scenes.joined(separator: ", "))"

        case "scene":
            guard let set = home.actionSets.first(where: { $0.name.lowercased().contains(name) }) else {
                throw ToolError("Nie znaleziono sceny \(name)")
            }
            try await home.executeActionSet(set)
            return "Uruchomiono scenę \(set.name)"

        case "on", "off":
            guard let acc = home.accessories.first(where: { $0.name.lowercased().contains(name) }) else {
                throw ToolError("Nie znaleziono urządzenia \(name)")
            }
            let power = acc.services.flatMap(\.characteristics)
                .first { $0.characteristicType == HMCharacteristicTypePowerState }
            guard let power else { throw ToolError("\(acc.name) nie obsługuje włącz/wyłącz") }
            try await power.writeValue(action == "on")
            return "\(acc.name): \(action == "on" ? "włączone" : "wyłączone")"

        default:
            throw ToolError("Nieznana akcja \(action)")
        }
    }
}
