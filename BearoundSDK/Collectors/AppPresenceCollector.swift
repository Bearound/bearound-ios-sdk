//
//  AppPresenceCollector.swift
//  BearoundSDK
//
//  Checks the configured targets with `canOpenURL`, restricted to schemes the host declared
//  in `LSApplicationQueriesSchemes`. Never opens a URL. `true` means a handler for the scheme
//  exists; it does not verify which app is behind it.
//

import Foundation
import UIKit

struct AppPresenceCollector {
    /// Host Info.plist (Bundle.main in production).
    let infoPlist: [String: Any]
    let bundleIdentifier: String?
    /// Platform check. Called on the main thread only, once per distinct scheme per round.
    let canOpenURL: (URL) -> Bool
    let now: () -> Date

    static func live() -> AppPresenceCollector {
        AppPresenceCollector(
            infoPlist: Bundle.main.infoDictionary ?? [:],
            bundleIdentifier: Bundle.main.bundleIdentifier,
            canOpenURL: { UIApplication.shared.canOpenURL($0) },
            now: { Date() }
        )
    }

    /// One result per target, in the configured order. Must run on the main thread.
    func collect(_ targets: [AppPresenceTarget]) -> [AppPresenceResult] {
        dispatchPrecondition(condition: .onQueue(.main))

        let budgetExceeded = AppPresenceSchemeBudget.isExceeded(infoPlist: infoPlist, bundleIdentifier: bundleIdentifier)
        let declared = Set(AppPresenceSchemeBudget.declaredSchemes(infoPlist: infoPlist))
        // Physical queries are deduplicated per round: two targets sharing a scheme
        // produce one canOpenURL call.
        var answers: [String: Bool] = [:]

        return targets.map { target in
            guard let scheme = target.normalizedIosScheme else {
                return unknown(target, .unsupportedPlatform)
            }
            if budgetExceeded {
                return unknown(target, .schemeBudgetExceeded)
            }
            guard declared.contains(scheme) else {
                return unknown(target, .notDeclared)
            }
            let answer: Bool
            if let cached = answers[scheme] {
                answer = cached
            } else {
                guard let url = URL(string: "\(scheme)://") else {
                    return unknown(target, .queryFailed)
                }
                answer = canOpenURL(url)
                answers[scheme] = answer
            }
            return AppPresenceResult(
                targetId: target.id,
                state: answer ? .present : .absent,
                reason: nil,
                checkedAt: now(),
                detectionMethod: .iosUrlScheme
            )
        }
    }

    private func unknown(_ target: AppPresenceTarget, _ reason: AppPresenceReason) -> AppPresenceResult {
        AppPresenceResult(
            targetId: target.id,
            state: .unknown,
            reason: reason,
            checkedAt: now(),
            detectionMethod: .none
        )
    }
}
