import Foundation

/// Account model entitlement is independent of the remaining quota fraction.
public enum AntigravityModelAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

public enum AntigravityModelAccessParser {
    public static func thirdPartyAvailability(data: Data?) -> AntigravityModelAvailability {
        availability(data: data, family: .thirdParty)
    }

    public static func argonAvailability(data: Data?) -> AntigravityModelAvailability {
        availability(data: data, family: .argon)
    }

    private enum Family { case thirdParty, argon }

    private static func availability(data: Data?, family: Family) -> AntigravityModelAvailability {
        guard let data,
              let envelope = try? JSONDecoder().decode(StatusEnvelope.self, from: data),
              let status = envelope.userStatus ?? envelope.response?.userStatus ?? envelope.response?.directStatus ?? envelope.directStatus,
              let models = status.cascadeModelConfigData?.clientModelConfigs else {
            return .unknown
        }

        let tier = status.planStatus?.planInfo?.teamsTier
        var hasUnknown = false
        for model in models {
            if model.disabled == true { continue }
            let identifiers = [model.modelId, model.modelOrAlias?.model, model.label]
                .compactMap { $0?.lowercased() }
            let isThirdParty = identifiers.contains { $0.hasPrefix("claude") || $0.hasPrefix("gpt") }
            let isGemini = identifiers.contains { $0.hasPrefix("gemini") }
            let isArgon = identifiers.contains { $0.hasPrefix("gemini") && $0.contains("argon") }
            let matches = family == .thirdParty ? isThirdParty : isArgon
            guard matches else {
                // A future family must not be interpreted as a denial.
                if !isGemini && !isThirdParty { hasUnknown = true }
                continue
            }
            if let allowedTiers = model.allowedTiers {
                guard let tier, !allowedTiers.isEmpty else {
                    hasUnknown = true
                    continue
                }
                guard allowedTiers.contains(tier) else { continue }
            }
            // quotaInfo is intentionally ignored: zero quota is still access.
            return .available
        }
        return hasUnknown ? .unknown : .unavailable
    }
}

private struct StatusEnvelope: Decodable {
    let userStatus: ModelStatus?
    let response: ModelStatusResponse?
    let cascadeModelConfigData: ModelConfigData?
    let planStatus: ModelPlanStatus?

    var directStatus: ModelStatus? {
        guard cascadeModelConfigData != nil else { return nil }
        return ModelStatus(cascadeModelConfigData: cascadeModelConfigData, planStatus: planStatus)
    }
}

private struct ModelStatusResponse: Decodable {
    let userStatus: ModelStatus?
    let cascadeModelConfigData: ModelConfigData?
    let planStatus: ModelPlanStatus?

    var directStatus: ModelStatus? {
        guard cascadeModelConfigData != nil else { return nil }
        return ModelStatus(cascadeModelConfigData: cascadeModelConfigData, planStatus: planStatus)
    }
}

private struct ModelStatus: Decodable {
    let cascadeModelConfigData: ModelConfigData?
    let planStatus: ModelPlanStatus?
}

private struct ModelConfigData: Decodable {
    let clientModelConfigs: [ModelConfig]?
}

private struct ModelConfig: Decodable {
    let label: String?
    let modelId: String?
    let modelOrAlias: ModelAlias?
    let disabled: Bool?
    let allowedTiers: [String]?
}

private struct ModelAlias: Decodable { let model: String? }
private struct ModelPlanStatus: Decodable { let planInfo: ModelPlanInfo? }
private struct ModelPlanInfo: Decodable { let teamsTier: String? }
