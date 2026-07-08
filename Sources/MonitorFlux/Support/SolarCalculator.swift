// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import Foundation

/// Pure sunrise/sunset computation using the NOAA "sunrise equation"
/// (en.wikipedia.org/wiki/Sunrise_equation). Accurate to a minute or two — plenty for
/// driving a color schedule. Returns local minute-of-day, or `nil` for polar
/// day/night when the sun does not cross the horizon.
enum SolarCalculator {
    struct Times: Equatable, Sendable {
        var sunriseMinutes: Int?
        var sunsetMinutes: Int?
    }

    /// Standard altitude of the sun's center at sunrise/sunset (accounts for refraction).
    private static let sunriseZenith = -0.833

    static func times(
        latitude: Double,
        longitude: Double,
        date: Date,
        timeZone: TimeZone
    ) -> Times {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return Times(sunriseMinutes: nil, sunsetMinutes: nil)
        }

        let degToRad = Double.pi / 180.0
        let radToDeg = 180.0 / Double.pi

        // Days since the J2000.0 epoch.
        let n = Double(julianDayNumber(year: year, month: month, day: day)) - 2451545.0 + 0.0008

        // Mean solar time. Western (negative) longitudes reach solar noon later in UTC,
        // so subtracting an east-positive longitude advances the transit accordingly.
        let meanSolarTime = n - longitude / 360.0

        let solarMeanAnomaly = normalizeDegrees(357.5291 + 0.98560028 * meanSolarTime)
        let anomalyRad = solarMeanAnomaly * degToRad

        // Equation of the center.
        let center = 1.9148 * sin(anomalyRad)
            + 0.0200 * sin(2 * anomalyRad)
            + 0.0003 * sin(3 * anomalyRad)

        let eclipticLongitude = normalizeDegrees(solarMeanAnomaly + center + 180.0 + 102.9372)
        let eclipticRad = eclipticLongitude * degToRad

        let solarTransit = 2451545.0
            + meanSolarTime
            + 0.0053 * sin(anomalyRad)
            - 0.0069 * sin(2 * eclipticRad)

        let declination = asin(sin(eclipticRad) * sin(23.44 * degToRad))

        let latitudeRad = latitude * degToRad
        let cosHourAngle = (sin(sunriseZenith * degToRad) - sin(latitudeRad) * sin(declination))
            / (cos(latitudeRad) * cos(declination))

        // Polar day (sun always up) or polar night (sun always down).
        guard cosHourAngle >= -1, cosHourAngle <= 1 else {
            return Times(sunriseMinutes: nil, sunsetMinutes: nil)
        }

        let hourAngle = acos(cosHourAngle) * radToDeg
        let julianRise = solarTransit - hourAngle / 360.0
        let julianSet = solarTransit + hourAngle / 360.0

        let sunrise = localMinuteOfDay(julianDate: julianRise, calendar: calendar)
        let sunset = localMinuteOfDay(julianDate: julianSet, calendar: calendar)

        // When the entered coordinates don't match the system time zone (longitude far from
        // the zone's UTC offset), the computed rise/set can land on different local days and
        // come back inverted (sunrise after sunset). Feeding that into the schedule would
        // make it run backwards — warm at midday, cool at night — so discard it and let the
        // caller fall back to the manual sunrise/sunset anchors.
        guard sunrise < sunset else {
            return Times(sunriseMinutes: nil, sunsetMinutes: nil)
        }

        return Times(sunriseMinutes: sunrise, sunsetMinutes: sunset)
    }

    private static func localMinuteOfDay(julianDate: Double, calendar: Calendar) -> Int {
        let unix = (julianDate - 2440587.5) * 86400.0
        let date = Date(timeIntervalSince1970: unix)
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return ((minutes % 1440) + 1440) % 1440
    }

    private static func julianDayNumber(year: Int, month: Int, day: Int) -> Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day
            + (153 * m + 2) / 5
            + 365 * y
            + y / 4
            - y / 100
            + y / 400
            - 32045
    }

    private static func normalizeDegrees(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 360.0)
        return remainder < 0 ? remainder + 360.0 : remainder
    }
}
