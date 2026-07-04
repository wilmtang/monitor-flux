import Foundation

/// One resolved location from the offline place index: a city, a US ZIP area, or a raw
/// coordinate pair. Only ever used to fill the Follow-sunset latitude/longitude (plus a
/// display name and, for the timezone-staleness hint, an IANA zone id).
struct Place: Equatable, Sendable {
    var name: String
    /// State/province display name ("Washington"); empty when GeoNames has none.
    var admin: String
    /// ISO 3166-1 alpha-2, empty for coordinate results.
    var countryCode: String
    var latitude: Double
    var longitude: Double
    var population: Int
    /// IANA zone id ("America/Los_Angeles"); drives the traveling-mismatch hint.
    var timeZoneID: String
    /// Set when the result came from a ZIP query; lat/long are then the ZIP centroid.
    var zip: String?

    /// The stored/row label: "Seattle, Washington", "Paris, France",
    /// "San Francisco, California 94107", or the bare coordinate string.
    var displayName: String {
        if let zip {
            return admin.isEmpty ? "\(name) \(zip)" : "\(name), \(admin) \(zip)"
        }
        if countryCode == "US", !admin.isEmpty {
            return "\(name), \(admin)"
        }
        let country = Self.countryName(countryCode)
        return country.isEmpty ? name : "\(name), \(country)"
    }

    /// The suggestion-list label, fully disambiguated: "Portland, Oregon, United States".
    var qualifiedName: String {
        if zip != nil {
            return displayName
        }
        let parts = [name, admin, Self.countryName(countryCode)]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Fixed English (the app's UI language) so results don't shift with the system locale.
    static func countryName(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }
}

/// Pure, offline search over the bundled city/ZIP dataset (`Resources/places.tsv`, generated
/// by `script/make_place_index.swift`). No network, nothing leaves the machine — which is what
/// lets the Follow-sunset pane keep saying "Computed on-device".
struct PlaceIndex: Sendable {
    /// What a raw query string means. Exposed for the view (a coordinate query gets
    /// different affordance copy) and directly testable.
    enum Query: Equatable {
        case empty
        case city(String)
        case zip(String)
        case coordinate(latitude: Double, longitude: Double)
    }

    private struct CityRecord {
        var name: String
        /// Diacritic/case-folded words of `name`, matched by word-boundary prefix.
        var foldedWords: [String]
        var adminIndex: Int
        var countryCode: String
        var latitude: Double
        var longitude: Double
        var population: Int
        var timeZoneIndex: Int
    }

    /// Population-descending (the generator pre-sorts), so the first N prefix matches of a
    /// linear scan are already the top-ranked suggestions — no post-sort needed.
    private var cities: [CityRecord] = []
    private var zips: [String: (latitude: Double, longitude: Double)] = [:]
    private var adminNames: [String] = []
    private var timeZoneIDs: [String] = []

    var isEmpty: Bool { cities.isEmpty }

    init() {}

    // MARK: - Loading

    static func load(from text: String) -> PlaceIndex {
        var index = PlaceIndex()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch fields.first {
            case "T" where fields.count >= 2:
                index.timeZoneIDs.append(String(fields[1]))
            case "A" where fields.count >= 2:
                index.adminNames.append(String(fields[1]))
            case "C" where fields.count >= 8:
                guard let adminIndex = Int(fields[2]),
                      let latitude = Double(fields[4]),
                      let longitude = Double(fields[5]),
                      let population = Int(fields[6]),
                      let timeZoneIndex = Int(fields[7])
                else { continue }
                let name = String(fields[1])
                index.cities.append(CityRecord(
                    name: name,
                    foldedWords: Self.foldedWords(of: name),
                    adminIndex: adminIndex,
                    countryCode: String(fields[3]),
                    latitude: latitude,
                    longitude: longitude,
                    population: population,
                    timeZoneIndex: timeZoneIndex
                ))
            case "Z" where fields.count >= 4:
                guard let latitude = Double(fields[2]), let longitude = Double(fields[3]) else {
                    continue
                }
                index.zips[String(fields[1])] = (latitude, longitude)
            default:
                continue // comments and unknown record types
            }
        }
        return index
    }

    /// The committed dataset, or nil when the resource can't be found (the caller logs and
    /// degrades to no suggestions — never a crash; see build_and_run.sh's bundle copy).
    static func loadBundled() -> PlaceIndex? {
        guard let url = bundledResourceURL(),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return load(from: text)
    }

    private static func bundledResourceURL() -> URL? {
        // Deliberately not Bundle.module: its generated fallback is an absolute .build path
        // that only resolves on the machine that compiled the binary. The SwiftPM resource
        // bundle sits in Contents/Resources in the .app (build_and_run.sh copies it), or
        // beside the raw binary under `swift run`/`swift build`.
        let bundleName = "MonitorFlux_MonitorFlux.bundle"
        var containers: [URL] = []
        if let resources = Bundle.main.resourceURL {
            containers.append(resources)
        }
        if let binaryDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            containers.append(binaryDirectory)
        }
        for container in containers {
            if let bundle = Bundle(url: container.appendingPathComponent(bundleName)),
               let resource = bundle.url(forResource: "places", withExtension: "tsv") {
                return resource
            }
        }
        return nil
    }

    // MARK: - Queries

    static func classify(_ raw: String) -> Query {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        if trimmed.count == 5, trimmed.allSatisfy(\.isNumber) {
            return .zip(trimmed)
        }
        // "47.61, -122.33" (or space-separated): exactly two numbers in coordinate range.
        let numberTokens = trimmed
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map(String.init)
        if numberTokens.count == 2,
           let latitude = Double(numberTokens[0]),
           let longitude = Double(numberTokens[1]),
           (-90.0...90.0).contains(latitude),
           (-180.0...180.0).contains(longitude) {
            return .coordinate(latitude: latitude, longitude: longitude)
        }
        return .city(trimmed)
    }

    /// Top suggestions for a raw query. City queries match every query word against a
    /// word-boundary prefix of the folded city name ("new y" → New York), ranked by
    /// population. ZIP and coordinate queries resolve to a single synthesized result named
    /// via the nearest indexed city.
    func search(_ raw: String, limit: Int = 5) -> [Place] {
        switch Self.classify(raw) {
        case .empty:
            return []
        case let .zip(code):
            guard let centroid = zips[code] else {
                return []
            }
            guard var zipPlace = nearest(latitude: centroid.latitude, longitude: centroid.longitude) else {
                return []
            }
            zipPlace.latitude = centroid.latitude
            zipPlace.longitude = centroid.longitude
            zipPlace.population = 0
            zipPlace.zip = code
            return [zipPlace]
        case let .coordinate(latitude, longitude):
            return [Place(
                name: Self.coordinateName(latitude: latitude, longitude: longitude),
                admin: "",
                countryCode: "",
                latitude: latitude,
                longitude: longitude,
                population: 0,
                timeZoneID: nearest(latitude: latitude, longitude: longitude)?.timeZoneID ?? "",
                zip: nil
            )]
        case let .city(query):
            let queryWords = Self.foldedWords(of: query)
            guard !queryWords.isEmpty else {
                return []
            }
            var results: [Place] = []
            for city in cities {
                guard matches(city, queryWords: queryWords) else {
                    continue
                }
                results.append(place(for: city))
                if results.count >= limit {
                    break
                }
            }
            return results
        }
    }

    /// The closest indexed city — names a Core Location fix or a typed coordinate, and
    /// supplies the timezone for the staleness check. Equirectangular metric: exact enough
    /// at city scale, and it keeps the scan to two multiplications per row.
    func nearest(latitude: Double, longitude: Double) -> Place? {
        var best: (record: CityRecord, distance: Double)?
        let cosLatitude = cos(latitude * .pi / 180)
        for city in cities {
            var deltaLongitude = abs(city.longitude - longitude)
            if deltaLongitude > 180 {
                deltaLongitude = 360 - deltaLongitude // date-line wrap
            }
            let deltaLatitude = city.latitude - latitude
            let distance = deltaLatitude * deltaLatitude
                + (deltaLongitude * cosLatitude) * (deltaLongitude * cosLatitude)
            if best == nil || distance < best!.distance {
                best = (city, distance)
            }
        }
        return best.map { place(for: $0.record) }
    }

    /// The IANA zone of the place nearest the given stored coordinates — the "where the
    /// schedule thinks you are" side of the traveling-mismatch check.
    func timeZoneID(nearLatitude latitude: Double, longitude: Double) -> String? {
        nearest(latitude: latitude, longitude: longitude)?.timeZoneID
    }

    // MARK: - Internals

    private func place(for record: CityRecord) -> Place {
        Place(
            name: record.name,
            admin: adminNames.indices.contains(record.adminIndex) ? adminNames[record.adminIndex] : "",
            countryCode: record.countryCode,
            latitude: record.latitude,
            longitude: record.longitude,
            population: record.population,
            timeZoneID: timeZoneIDs.indices.contains(record.timeZoneIndex)
                ? timeZoneIDs[record.timeZoneIndex]
                : "",
            zip: nil
        )
    }

    private func matches(_ city: CityRecord, queryWords: [String]) -> Bool {
        queryWords.allSatisfy { queryWord in
            city.foldedWords.contains { $0.hasPrefix(queryWord) }
        }
    }

    private static func coordinateName(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// Case/diacritic/width folding so "zurich" finds "Zürich"; fixed locale so matching
    /// doesn't change with system language.
    private static func foldedWords(of text: String) -> [String] {
        text
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US")
            )
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
