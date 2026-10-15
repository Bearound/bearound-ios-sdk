//
//  WifiVisitMatcher.swift
//  BearoundSDK
//
//  Pure state machine that turns Wi-Fi observation rounds into visit arrive/depart
//  decisions, by matching the observed `apId` values against the `knownApIds` of each
//  cached place. No CoreLocation, no NetworkExtension, no disk: the caller feeds rounds
//  and acts on the returned actions.
//

import Foundation

final class WifiVisitMatcher {

    struct Observation: Equatable {
        let apId: String
        let observedAt: Date
    }

    /// One completed Wi-Fi observation round. A round is conclusive when the platform could
    /// really answer (authorization and entitlement present): then an empty or different
    /// AP is a real absence. An inconclusive round says nothing either way.
    struct Round: Equatable {
        let at: Date
        let observations: [Observation]
        let conclusive: Bool
    }

    enum Action: Equatable {
        /// `at` is the first observation of the known AP.
        case arrive(environmentId: String, at: Date, observations: [Observation])
        /// `at` is the last observation of the known AP.
        case depart(environmentId: String, at: Date, observations: [Observation])
    }

    private enum State {
        case candidate(first: Date, last: Date, observations: [Observation])
        case open(last: Date, observations: [Observation])
    }

    /// Absent key means idle.
    private var states: [String: State] = [:]

    /// Feeds one round and returns the arrivals and departures it produced.
    func onRound(_ round: Round, places: [PlacesConfig.Place]) -> [Action] {
        let tracked = places.filter { !$0.knownApIds.isEmpty }
        let trackedIds = Set(tracked.map(\.environmentId))
        states = states.filter { trackedIds.contains($0.key) }

        // An inconclusive round does not count, does not contradict and does not close.
        guard round.conclusive else { return [] }

        var actions: [Action] = []
        for place in tracked {
            let id = place.environmentId
            let known = Set(place.knownApIds)
            let matched = round.observations.filter { known.contains($0.apId) }
            let dwell = TimeInterval(place.minDwellMinutes ?? VisitMonitor.defaultMinDwellMinutes) * 60

            if matched.isEmpty {
                switch states[id] {
                case .candidate:
                    states[id] = nil
                case .open(let last, let observations):
                    if round.at.timeIntervalSince(last) >= dwell {
                        states[id] = nil
                        actions.append(.depart(environmentId: id, at: last, observations: observations))
                    }
                case nil:
                    break
                }
                continue
            }

            let seenFirst = matched.map(\.observedAt).min() ?? round.at
            let seenLast = matched.map(\.observedAt).max() ?? round.at
            switch states[id] {
            case .open(let last, _):
                states[id] = .open(last: max(last, seenLast), observations: matched)
            case .candidate(let first, let last, _):
                advance(id, first: first, last: max(last, seenLast), observations: matched,
                        dwell: dwell, actions: &actions)
            case nil:
                advance(id, first: seenFirst, last: seenLast, observations: matched,
                        dwell: dwell, actions: &actions)
            }
        }
        return actions
    }

    private func advance(_ id: String, first: Date, last: Date, observations: [Observation],
                         dwell: TimeInterval, actions: inout [Action]) {
        if last.timeIntervalSince(first) >= dwell {
            states[id] = .open(last: last, observations: observations)
            actions.append(.arrive(environmentId: id, at: first, observations: observations))
        } else {
            states[id] = .candidate(first: first, last: last, observations: observations)
        }
    }
}
