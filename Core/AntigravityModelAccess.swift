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

    static func cliAvailability(
        data: Data?
    ) -> (thirdParty: AntigravityModelAvailability, argon: AntigravityModelAvailability) {
        guard let data, let list = String(data: data, encoding: .utf8) else { return (.unknown, .unknown) }
        let rows = list.split(whereSeparator: \.isNewline)
        let models = rows.compactMap { row -> String? in
            let columns = row.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard columns.count == 2, !columns[0].isEmpty, !columns[1].isEmpty,
                !columns[0].contains(where: \.isWhitespace)
            else { return nil }
            return columns[0].lowercased()
        }
        guard !models.isEmpty, models.count == rows.count else { return (.unknown, .unknown) }
        let hasUnknown = models.contains { !$0.hasPrefix("gemini") && !Family.thirdParty.matches($0) }
        let missing: AntigravityModelAvailability = hasUnknown ? .unknown : .unavailable
        return (
            models.contains(where: Family.thirdParty.matches) ? .available : missing,
            models.contains(where: Family.argon.matches) ? .available : missing
        )
    }

    private enum Family {
        case thirdParty, argon

        func matches(_ identifier: String) -> Bool {
            switch self {
            case .thirdParty: identifier.hasPrefix("claude") || identifier.hasPrefix("gpt")
            case .argon: identifier.hasPrefix("gemini") && identifier.contains("argon")
            }
        }
    }

    private static func availability(data: Data?, family: Family) -> AntigravityModelAvailability {
        guard let data,
            let envelope = try? JSONDecoder().decode(StatusEnvelope.self, from: data),
            let status = envelope.userStatus ?? envelope.response?.userStatus ?? envelope.response?.directStatus
                ?? envelope.directStatus,
            let models = status.cascadeModelConfigData?.clientModelConfigs
        else {
            return .unknown
        }

        let tier = status.planStatus?.planInfo?.teamsTier
        var hasUnknown = false
        for model in models {
            if model.disabled == true { continue }
            let identifiers = [model.modelId, model.modelOrAlias?.model, model.label]
                .compactMap { $0?.lowercased() }
            guard identifiers.contains(where: family.matches) else {
                // A future family must not be interpreted as a denial.
                if !identifiers.contains(where: { $0.hasPrefix("gemini") || Family.thirdParty.matches($0) }) {
                    hasUnknown = true
                }
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
