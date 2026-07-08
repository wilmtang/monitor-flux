#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

// Regenerates Sources/MonitorFlux/Resources/places.tsv — the offline city/ZIP index behind
// the Follow-sunset location search (see PlaceIndex.swift and docs/DESIGN.md).
//
// Sources (downloaded on each run unless --cached DIR points at previous downloads):
//   - GeoNames cities15000 (cities with population >= 15k, worldwide) — CC BY 4.0
//   - GeoNames admin1CodesASCII (state/province display names)
//   - US Census ZCTA gazetteer (ZIP-code-area centroids) — public domain
//
// Run from the repo root: `swift script/make_place_index.swift [--cached DIR]`.
// The generated file is committed, so builds never need the network.

import Foundation

let arguments = CommandLine.arguments
let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputURL = repoRoot
    .appendingPathComponent("Sources/MonitorFlux/Resources/places.tsv")

let zctaYear = 2025
let downloads: [(name: String, url: String)] = [
    ("cities15000.zip", "https://download.geonames.org/export/dump/cities15000.zip"),
    ("admin1CodesASCII.txt", "https://download.geonames.org/export/dump/admin1CodesASCII.txt"),
    (
        "\(zctaYear)_Gaz_zcta_national.zip",
        "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/"
            + "\(zctaYear)_Gazetteer/\(zctaYear)_Gaz_zcta_national.zip"
    ),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func run(_ tool: String, _ args: [String], cwd: URL? = nil) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = args
    if let cwd { process.currentDirectoryURL = cwd }
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("\(tool) \(args.joined(separator: " ")) exited \(process.terminationStatus)")
    }
}

// MARK: - Fetch

let workDir: URL
if let flagIndex = arguments.firstIndex(of: "--cached"), arguments.count > flagIndex + 1 {
    workDir = URL(fileURLWithPath: arguments[flagIndex + 1])
} else {
    workDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("monitorflux-place-index", isDirectory: true)
    try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    for (name, url) in downloads {
        print("fetching \(name)…")
        run("/usr/bin/curl", ["-sSL", "-o", workDir.appendingPathComponent(name).path, url])
    }
    for (name, _) in downloads where name.hasSuffix(".zip") {
        run("/usr/bin/unzip", ["-o", "-q", name], cwd: workDir)
    }
}

func lines(of fileName: String) -> [Substring] {
    guard let text = try? String(contentsOf: workDir.appendingPathComponent(fileName), encoding: .utf8) else {
        fail("cannot read \(fileName) in \(workDir.path)")
    }
    return text.split(separator: "\n", omittingEmptySubsequences: true)
}

// MARK: - Transform

// admin1CodesASCII.txt: "CC.ADM1<TAB>UTF-8 name<TAB>ASCII name<TAB>geonameid"
var admin1Names: [String: String] = [:]
for line in lines(of: "admin1CodesASCII.txt") {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 2 else { continue }
    admin1Names[String(fields[0])] = String(fields[1])
}

struct City {
    var name: String
    var adminIndex: Int
    var countryCode: String
    var latitude: Double
    var longitude: Double
    var population: Int
    var timeZoneIndex: Int
}

// Repeated strings (admin names, IANA timezone ids) dominate the raw rows, so they are
// dictionary-encoded: `A`/`T` header lines define them once, cities reference by index.
var adminTable: [String] = []
var adminIndexByName: [String: Int] = [:]
var timeZoneTable: [String] = []
var timeZoneIndexByName: [String: Int] = [:]

func internedAdmin(_ name: String) -> Int {
    if let index = adminIndexByName[name] { return index }
    adminTable.append(name)
    adminIndexByName[name] = adminTable.count - 1
    return adminTable.count - 1
}

func internedTimeZone(_ name: String) -> Int {
    if let index = timeZoneIndexByName[name] { return index }
    timeZoneTable.append(name)
    timeZoneIndexByName[name] = timeZoneTable.count - 1
    return timeZoneTable.count - 1
}

// cities15000.txt columns (tab-separated): 0 geonameid, 1 name, 2 asciiname, 3 alternatenames,
// 4 lat, 5 lon, 6 feature class, 7 feature code, 8 country code, 9 cc2, 10 admin1 code,
// 11–13 admin2–4, 14 population, 15 elevation, 16 dem, 17 timezone, 18 modified.
var cities: [City] = []
for line in lines(of: "cities15000.txt") {
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
    guard fields.count >= 18,
          let latitude = Double(fields[4]),
          let longitude = Double(fields[5])
    else { continue }
    let name = String(fields[1])
    let countryCode = String(fields[8])
    let timeZone = String(fields[17])
    guard !name.isEmpty, !countryCode.isEmpty, !timeZone.isEmpty else { continue }
    let adminName = admin1Names["\(countryCode).\(fields[10])"] ?? ""
    cities.append(City(
        name: name,
        adminIndex: internedAdmin(adminName),
        countryCode: countryCode,
        latitude: latitude,
        longitude: longitude,
        population: Int(fields[14]) ?? 0,
        timeZoneIndex: internedTimeZone(timeZone)
    ))
}
guard cities.count > 20_000 else { fail("suspiciously few cities parsed: \(cities.count)") }

// Population-descending, so a prefix scan's first matches are already the best-ranked ones.
cities.sort { $0.population > $1.population }

// ZCTA gazetteer: pipe-separated since 2025 (tab before). Columns: GEOID|GEOIDFQ|…|INTPTLAT|INTPTLONG.
var zipRows: [String] = []
for line in lines(of: "\(zctaYear)_Gaz_zcta_national.txt").dropFirst() {
    let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.count >= 8, fields[0].count == 5,
          let latitude = Double(fields[6]),
          let longitude = Double(fields[7])
    else { continue }
    zipRows.append("Z\t\(fields[0])\t"
        + String(format: "%.3f", latitude) + "\t"
        + String(format: "%.3f", longitude))
}
guard zipRows.count > 30_000 else { fail("suspiciously few ZCTAs parsed: \(zipRows.count)") }

// MARK: - Emit

var output = """
# MonitorFlux offline place index. GENERATED by script/make_place_index.swift — do not edit.
# Cities/admin names: GeoNames (geonames.org), CC BY 4.0. ZIP centroids: US Census ZCTA
# gazetteer \(zctaYear), public domain.
# T timezone-id | A admin1-name | C name aIdx cc lat lon pop tzIdx | Z zip lat lon

"""
for zone in timeZoneTable { output += "T\t\(zone)\n" }
for admin in adminTable { output += "A\t\(admin)\n" }
for city in cities {
    output += "C\t\(city.name)\t\(city.adminIndex)\t\(city.countryCode)\t"
        + String(format: "%.4f", city.latitude) + "\t"
        + String(format: "%.4f", city.longitude) + "\t"
        + "\(city.population)\t\(city.timeZoneIndex)\n"
}
output += zipRows.joined(separator: "\n") + "\n"

try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
do {
    try output.write(to: outputURL, atomically: true, encoding: .utf8)
} catch {
    fail("cannot write \(outputURL.path): \(error)")
}

let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
print("wrote \(outputURL.path): \(cities.count) cities, \(zipRows.count) ZIPs, "
    + "\(timeZoneTable.count) timezones, \(adminTable.count) admin names, \(sizeBytes / 1024) KB")
