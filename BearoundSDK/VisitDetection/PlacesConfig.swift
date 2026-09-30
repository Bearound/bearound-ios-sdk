//
//  PlacesConfig.swift
//  BearoundSDK
//
//  Visit detection config: the nearby target environments and the kill switch,
//  served by `GET /sdk/places/nearby` on the Bearound backend (the SDK host, `apiBaseURL`).
//

import Foundation
import UIKit

// MARK: - Response model

/// Body of `GET /sdk/places/nearby`. The list keeps the name `places` for payload
/// compatibility, but every item is an environment.
struct PlacesConfig: Codable, Equatable {

    struct Coordinate: Codable, Equatable {
        let lat: Double
        let lng: Double
    }

    /// `point` carries `lat`/`lng`; `polygon` carries `rings` plus the circumscribed
    /// circle (`center`). Both carry `radiusMeters`. Only the circle is used on device:
    /// CLCircularRegion accepts nothing else, and the ingest decides the environment.
    struct Geometry: Codable, Equatable {
        let type: String
        let lat: Double?
        let lng: Double?
        let center: Coordinate?
        let radiusMeters: Double
        let rings: [[Coordinate]]?

        /// The circle registered with the OS, nil when the geometry is incomplete.
        var circleCenter: Coordinate? {
            if type == "polygon" { return center }
            if let lat, let lng { return Coordinate(lat: lat, lng: lng) }
            return center
        }
    }

    struct Place: Codable, Equatable {
        let environmentId: String
        let businessId: String?
        let name: String?
        let gpsVisitClass: String?
        let geometry: Geometry
        let distanceMeters: Double
        let minDwellMinutes: Int?
        /// Hashed identifiers (`ApIdentifier`) of the access points known to belong to the
        /// environment. Absent from older responses, which decode as an empty list.
        let knownApIds: [String]

        init(environmentId: String, businessId: String?, name: String?, gpsVisitClass: String?,
             geometry: Geometry, distanceMeters: Double, minDwellMinutes: Int?,
             knownApIds: [String] = []) {
            self.environmentId = environmentId
            self.businessId = businessId
            self.name = name
            self.gpsVisitClass = gpsVisitClass
            self.geometry = geometry
            self.distanceMeters = distanceMeters
            self.minDwellMinutes = minDwellMinutes
            self.knownApIds = knownApIds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            environmentId = try container.decode(String.self, forKey: .environmentId)
            businessId = try container.decodeIfPresent(String.self, forKey: .businessId)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            gpsVisitClass = try container.decodeIfPresent(String.self, forKey: .gpsVisitClass)
            geometry = try container.decode(Geometry.self, forKey: .geometry)
            distanceMeters = try container.decode(Double.self, forKey: .distanceMeters)
            minDwellMinutes = try container.decodeIfPresent(Int.self, forKey: .minDwellMinutes)
            knownApIds = try container.decodeIfPresent([String].self, forKey: .knownApIds) ?? []
        }
    }

    let origin: Coordinate
    let refreshAfterMeters: Double
    let maxAgeSeconds: Double
    let visitDetectionEnabled: Bool
    let places: [Place]

    enum CodingKeys: String, CodingKey {
        case origin, refreshAfterMeters, maxAgeSeconds, places
        case visitDetectionEnabled = "visit_detection_enabled"
    }

    init(origin: Coordinate, refreshAfterMeters: Double, maxAgeSeconds: Double,
         visitDetectionEnabled: Bool, places: [Place]) {
        self.origin = origin
        self.refreshAfterMeters = refreshAfterMeters
        self.maxAgeSeconds = maxAgeSeconds
        self.visitDetectionEnabled = visitDetectionEnabled
        self.places = places
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        origin = try container.decode(Coordinate.self, forKey: .origin)
        refreshAfterMeters = try container.decode(Double.self, forKey: .refreshAfterMeters)
        maxAgeSeconds = try container.decode(Double.self, forKey: .maxAgeSeconds)
        // The API defaults the flag to true; an absent field keeps that default.
        visitDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .visitDetectionEnabled) ?? true
        // One malformed item must not throw away the whole list.
        places = try container.decode([LossyPlace].self, forKey: .places).compactMap(\.place)
    }

    private struct LossyPlace: Decodable {
        let place: Place?
        init(from decoder: Decoder) throws {
            place = try? Place(from: decoder)
        }
    }
}

// MARK: - Client

enum PlacesConfigFetchResult {
    case updated(PlacesConfig, etag: String?)
    case notModified
    case failed(Error)
}

protocol PlacesConfigFetching: AnyObject {
    func fetch(latitude: Double, longitude: Double, etag: String?,
               completion: @escaping (PlacesConfigFetchResult) -> Void)
}

/// `GET {apiBaseURL}/sdk/places/nearby?lat=&lng=` on the ingest host (the same one as
/// `/ingest`), authenticated with the raw business token exactly like `/ingest`
/// (`Authorization: <businessToken>`).
///
/// One instance (and one `URLSession`) lives as long as the SDK: the configuration is read
/// at every fetch, so a reconfigure never needs a new client.
final class PlacesConfigClient: PlacesConfigFetching {

    enum ClientError: Error {
        case notConfigured
    }

    private let configuration: () -> SDKConfiguration?
    private let session: URLSession
    private let backgroundTasks: VisitBackgroundTasking

    init(configuration: @escaping () -> SDKConfiguration?, session: URLSession? = nil,
         backgroundTasks: VisitBackgroundTasking = UIApplicationBackgroundTasks()) {
        self.configuration = configuration
        self.backgroundTasks = backgroundTasks
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 15
            config.allowsCellularAccess = true
            return URLSession(configuration: config)
        }()
    }

    static func makeRequest(baseURL: String, businessToken: String,
                            latitude: Double, longitude: Double, etag: String?) -> URLRequest? {
        guard var components = URLComponents(string: "\(baseURL)/sdk/places/nearby") else { return nil }
        // The server rounds to 3 decimals (~110 m) anyway; rounding here keeps the finer fix
        // on the device and lets unchanged neighbourhoods hit the ETag.
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "lng", value: String(format: "%.3f", longitude)),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(businessToken, forHTTPHeaderField: "Authorization")
        if let etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        // Our own ETag logic decides freshness; never answer from a URL cache.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    func fetch(latitude: Double, longitude: Double, etag: String?,
               completion: @escaping (PlacesConfigFetchResult) -> Void) {
        guard let config = configuration() else {
            completion(.failed(ClientError.notConfigured))
            return
        }
        guard let request = Self.makeRequest(baseURL: config.apiBaseURL, businessToken: config.businessToken,
                                             latitude: latitude, longitude: longitude, etag: etag) else {
            completion(.failed(APIError.invalidURL))
            return
        }

        // A fence exit relaunches the app for ~10 s; hold an assertion so the request can land.
        let assertion = VisitBackgroundAssertion(name: "BeAroundPlacesConfig", tasks: backgroundTasks)
        assertion.begin()
        let finish: (PlacesConfigFetchResult) -> Void = { result in
            DispatchQueue.main.async {
                completion(result)
                assertion.end()
            }
        }

        session.dataTask(with: request) { data, response, error in
            if let error {
                finish(.failed(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failed(APIError.invalidResponse))
                return
            }
            if http.statusCode == 304 {
                finish(.notModified)
                return
            }
            guard (200..<300).contains(http.statusCode), let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(512)) }
                finish(.failed(APIError.httpError(statusCode: http.statusCode, body: body)))
                return
            }
            do {
                let config = try JSONDecoder().decode(PlacesConfig.self, from: data)
                finish(.updated(config, etag: http.value(forHTTPHeaderField: "ETag")))
            } catch {
                finish(.failed(error))
            }
        }.resume()
    }
}

// MARK: - Persistence

/// Last good config plus the open-stop bookkeeping, persisted so a failed fetch keeps the
/// last list and the last `visit_detection_enabled`, and so a departure delivered
/// after a relaunch still pairs with the arrival sent by the previous process.
final class VisitStateStore {

    static let defaultSuiteName = "com.bearound.sdk.visit"

    private static let keyConfig = "places_config"
    private static let keyEtag = "places_etag"
    private static let keyFetchedAt = "places_fetched_at"
    private static let keyLastFailedFetchAt = "places_last_failed_fetch_at"
    private static let keyOpenStop = "open_stop"
    private static let keyLastDepartureAt = "last_departure_at"

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = UserDefaults(suiteName: VisitStateStore.defaultSuiteName)) {
        self.defaults = defaults ?? .standard
    }

    struct CachedConfig: Equatable {
        let config: PlacesConfig
        let etag: String?
        let fetchedAt: Date
    }

    func loadConfig() -> CachedConfig? {
        guard let data = defaults.data(forKey: Self.keyConfig),
              let config = try? JSONDecoder().decode(PlacesConfig.self, from: data),
              let fetchedAt = defaults.object(forKey: Self.keyFetchedAt) as? Date
        else { return nil }
        return CachedConfig(config: config, etag: defaults.string(forKey: Self.keyEtag), fetchedAt: fetchedAt)
    }

    func saveConfig(_ config: PlacesConfig, etag: String?, fetchedAt: Date) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.keyConfig)
        if let etag { defaults.set(etag, forKey: Self.keyEtag) } else { defaults.removeObject(forKey: Self.keyEtag) }
        defaults.set(fetchedAt, forKey: Self.keyFetchedAt)
    }

    /// 304: the list is still current as of `date`.
    func touchConfig(fetchedAt date: Date) {
        guard defaults.data(forKey: Self.keyConfig) != nil else { return }
        defaults.set(date, forKey: Self.keyFetchedAt)
    }

    var lastFailedFetchAt: Date? {
        get { defaults.object(forKey: Self.keyLastFailedFetchAt) as? Date }
        set { defaults.set(newValue, forKey: Self.keyLastFailedFetchAt) }
    }

    /// A stop whose arrival was sent and whose departure was not yet.
    struct OpenStop: Codable, Equatable {
        let latitude: Double
        let longitude: Double
        let arrivalAt: Date
        let environmentId: String?
        /// Set only for a stop a geofence entry opened: past this instant, with no CLVisit
        /// confirming the dwell, the stop is dropped (drive-by). nil for a CLVisit stop.
        let fenceExpiresAt: Date?

        init(latitude: Double, longitude: Double, arrivalAt: Date, environmentId: String?,
             fenceExpiresAt: Date? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.arrivalAt = arrivalAt
            self.environmentId = environmentId
            self.fenceExpiresAt = fenceExpiresAt
        }
    }

    var openStop: OpenStop? {
        get {
            defaults.data(forKey: Self.keyOpenStop).flatMap { try? JSONDecoder().decode(OpenStop.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.keyOpenStop)
            } else {
                defaults.removeObject(forKey: Self.keyOpenStop)
            }
        }
    }

    /// Departure time of the last stop closed, so a CLVisit redelivered after a relaunch
    /// does not produce a second departure.
    var lastDepartureAt: Date? {
        get { defaults.object(forKey: Self.keyLastDepartureAt) as? Date }
        set { defaults.set(newValue, forKey: Self.keyLastDepartureAt) }
    }
}
