import Foundation

public struct WeatherPlace: Codable, Equatable, Sendable {
    public let name: String
    public let country: String
    public let admin1: String?
    public let latitude: Double?
    public let longitude: Double?
    public let timezone: String
    public let neighbourhood: String?
    public let isCurrentLocation: Bool

    public init(
        name: String, country: String, admin1: String? = nil,
        latitude: Double? = nil, longitude: Double? = nil,
        timezone: String, neighbourhood: String? = nil,
        isCurrentLocation: Bool = false
    ) {
        self.name = name
        self.country = country
        self.admin1 = admin1
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.neighbourhood = neighbourhood
        self.isCurrentLocation = isCurrentLocation
    }

    public var candidateLabel: String {
        let region = [country, admin1].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        return region.isEmpty ? name : "\(name), \(region)"
    }

    var currentPublicName: String {
        var seen = Set<String>()
        let parts = [name, admin1, country].compactMap { component -> String? in
            guard let component else { return nil }
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let identity = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(identity).inserted else { return nil }
            return trimmed
        }
        return parts.joined(separator: ", ")
    }

    fileprivate var cacheKey: String {
        let identity = "\(name)|\(country)|\(admin1 ?? "")"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if isCurrentLocation {
            let city = currentPublicName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return "current|\(city)"
        }
        return identity
    }

    fileprivate var sanitizedForPersistence: WeatherPlace {
        if isCurrentLocation {
            return WeatherPlace(name: currentPublicName, country: "", timezone: "", isCurrentLocation: true)
        }
        return WeatherPlace(name: name, country: country, admin1: admin1,
                            timezone: timezone, isCurrentLocation: false)
    }

    func hasSameIdentity(as other: WeatherPlace) -> Bool {
        cacheKey == other.cacheKey
    }
}

public struct WeatherCurrent: Codable, Equatable, Sendable {
    public let time: Date
    public let temperatureCelsius: Double
    public let weatherCode: Int
    public let windSpeedKmh: Double
    public let windDirectionDegrees: Double
    public let windGustsKmh: Double
    public let isDay: Bool

    public init(time: Date, temperatureCelsius: Double, weatherCode: Int,
                windSpeedKmh: Double, windDirectionDegrees: Double,
                windGustsKmh: Double, isDay: Bool) {
        self.time = time
        self.temperatureCelsius = temperatureCelsius
        self.weatherCode = weatherCode
        self.windSpeedKmh = windSpeedKmh
        self.windDirectionDegrees = windDirectionDegrees
        self.windGustsKmh = windGustsKmh
        self.isDay = isDay
    }
}

public struct WeatherDay: Codable, Equatable, Sendable {
    public let date: String
    public let highCelsius: Double
    public let lowCelsius: Double
    public let sunrise: Date
    public let sunset: Date

    public init(date: String, highCelsius: Double, lowCelsius: Double,
                sunrise: Date, sunset: Date) {
        self.date = date
        self.highCelsius = highCelsius
        self.lowCelsius = lowCelsius
        self.sunrise = sunrise
        self.sunset = sunset
    }
}

public struct WeatherHour: Codable, Equatable, Sendable {
    public let time: Date
    public let precipitationMM: Double
    public let precipitationProbability: Int

    public init(time: Date, precipitationMM: Double, precipitationProbability: Int) {
        self.time = time
        self.precipitationMM = precipitationMM
        self.precipitationProbability = precipitationProbability
    }
}

public enum WeatherUnits: String, Codable, Sendable, CaseIterable {
    case followSystem
    case metric
    case imperial

    public func resolved(locale: Locale = .current) -> WeatherUnits {
        if self != .followSystem { return self }
        return locale.measurementSystem == .us ? .imperial : .metric
    }
}

public struct WeatherRain: Equatable, Sendable {
    public let start: Date?
    public let end: Date?
    public let amountMM: Double
    public let isNow: Bool
    public var isDry: Bool { start == nil }
}

public struct WeatherSunEvent: Equatable, Sendable {
    public enum Kind: Sendable { case sunrise, sunset }
    public let kind: Kind
    public let time: Date
}

public struct WeatherFact: Equatable, Sendable {
    public let symbol: String
    public let firstLine: String
    public let secondLine: String?

    public init(symbol: String, firstLine: String, secondLine: String? = nil) {
        self.symbol = symbol
        self.firstLine = firstLine
        self.secondLine = secondLine
    }
}

public struct WeatherDisplay: Equatable, Sendable {
    public let temperature: String
    public let condition: String
    public let symbol: String
    public let high: String
    public let low: String
    public let facts: [WeatherFact]
    public let summary: String
}

public struct WeatherReading: Codable, Equatable, Sendable {
    public let place: WeatherPlace
    public let current: WeatherCurrent
    public let daily: [WeatherDay]
    public let hourly: [WeatherHour]
    public let fetchedAt: Date
    public let sourceClockTimes: [String: String]?

    public init(place: WeatherPlace, current: WeatherCurrent, daily: [WeatherDay],
                hourly: [WeatherHour], fetchedAt: Date,
                sourceClockTimes: [String: String]? = nil) {
        self.place = place
        self.current = current
        self.daily = daily
        self.hourly = hourly
        self.fetchedAt = fetchedAt
        self.sourceClockTimes = sourceClockTimes
    }

    public func isStale(at date: Date = .now) -> Bool {
        date.timeIntervalSince(fetchedAt) > 30 * 60
    }

    public var rain: WeatherRain {
        guard let first = hourly.firstIndex(where: { $0.precipitationMM >= 0.1 || $0.precipitationProbability >= 50 }) else {
            return WeatherRain(start: nil, end: nil, amountMM: 0, isNow: false)
        }
        let end = hourly[(first + 1)...].firstIndex(where: { $0.precipitationMM < 0.1 && $0.precipitationProbability < 50 })
        let runEnd = end ?? hourly.endIndex
        let amount = hourly[first..<runEnd].reduce(0) { $0 + $1.precipitationMM }
        return WeatherRain(start: hourly[first].time, end: end.map { hourly[$0].time },
                           amountMM: amount, isNow: first == 0)
    }

    public func nextSunEvent(after now: Date? = nil) -> WeatherSunEvent? {
        let reference = now ?? current.time
        let events = daily.flatMap { day in
            [WeatherSunEvent(kind: .sunrise, time: day.sunrise),
             WeatherSunEvent(kind: .sunset, time: day.sunset)]
        }
        return events.filter { $0.time > reference }.min { $0.time < $1.time }
    }

    public func facts(units: WeatherUnits = .followSystem, now: Date? = nil) -> [WeatherFact] {
        let resolved = units.resolved()
        let reference = now ?? current.time
        let rainFact: WeatherFact
        if let start = rain.start {
            let first: String
            if rain.isNow || start <= reference {
                first = "Rain now"
            } else {
                let hours = max(1, Int((start.timeIntervalSince(reference) / 3600).rounded()))
                first = "Rain in \(hours) h"
            }
            let details = [rain.end.map { "until \(clock($0))" },
                           rain.amountMM >= 0.1 ? amount(rain.amountMM, units: resolved) : nil]
                .compactMap { $0 }.joined(separator: " · ")
            rainFact = WeatherFact(symbol: "cloud.rain", firstLine: first,
                                   secondLine: details.isEmpty ? nil : details)
        } else {
            rainFact = WeatherFact(symbol: "cloud", firstLine: "Dry · next 24 h")
        }

        let sunFact: WeatherFact
        if let event = nextSunEvent(after: reference) {
            let verb = event.kind == .sunset ? "Sets" : "Rises"
            let seconds = max(0, event.time.timeIntervalSince(reference))
            let minutes = max(1, Int((seconds / 60).rounded()))
            let hours = minutes / 60
            let remainder = minutes % 60
            let countdown = hours > 0
                ? "in \(hours) h" + (remainder > 0 ? " \(remainder) m" : "")
                : "in \(remainder) m"
            sunFact = WeatherFact(symbol: event.kind == .sunset ? "sunset" : "sunrise",
                                  firstLine: "\(verb) \(clock(event.time))",
                                  secondLine: countdown)
        } else {
            sunFact = WeatherFact(symbol: "sun.max", firstLine: "Sun time unavailable")
        }

        let wind = speed(current.windSpeedKmh, units: resolved)
        let gustValue = resolved == .imperial ? current.windGustsKmh / 1.609344 : current.windGustsKmh
        let gust = current.windGustsKmh > current.windSpeedKmh * 1.5
            ? "gusts \(Int(gustValue.rounded()))" : nil
        let windFact = WeatherFact(symbol: "wind", firstLine: "\(wind) \(Self.compass(current.windDirectionDegrees))",
                                   secondLine: gust)
        return [rainFact, sunFact, windFact]
    }

    public func display(units: WeatherUnits = .followSystem, now: Date = .now,
                        failedReason: String? = nil) -> WeatherDisplay {
        let resolved = units.resolved()
        let day = daily.first
        return WeatherDisplay(
            temperature: temperature(current.temperatureCelsius, units: resolved),
            condition: Self.condition(for: current.weatherCode),
            symbol: Self.symbol(for: current.weatherCode, isDay: current.isDay),
            high: day.map { temperature($0.highCelsius, units: resolved) } ?? "–",
            low: day.map { temperature($0.lowCelsius, units: resolved) } ?? "–",
            facts: displayFacts(units: units, now: now),
            summary: summary(now: now, failedReason: failedReason)
        )
    }

    public func summary(now: Date = .now, failedReason: String? = nil) -> String {
        var parts = [place.name]
        if place.isCurrentLocation {
            if let neighbourhood = place.neighbourhood, !neighbourhood.isEmpty { parts.append(neighbourhood) }
        } else if !place.country.isEmpty {
            parts.append(place.country)
        }
        parts.append("Open-Meteo")
        if failedReason != nil || isStale(at: now) || (place.isCurrentLocation && place.timezone.isEmpty) {
            parts.append(age(at: now))
        } else {
            parts.append(clock(current.time) + (place.isCurrentLocation ? "" : " local"))
        }
        return parts.joined(separator: " · ")
    }

    private func displayFacts(units: WeatherUnits, now: Date) -> [WeatherFact] {
        guard isStale(at: now) else { return facts(units: units, now: now) }
        var snapshot = facts(units: units, now: current.time)
        if snapshot.count > 1 {
            let sun = snapshot[1]
            snapshot[1] = WeatherFact(symbol: sun.symbol, firstLine: sun.firstLine)
        }
        return snapshot
    }

    public func copySummary(units: WeatherUnits = .followSystem, now: Date? = nil,
                            failedReason: String? = nil) -> String {
        let resolved = units.resolved()
        let copyTime = now ?? .now
        let snapshot = failedReason != nil || isStale(at: copyTime)
            || (place.isCurrentLocation && place.timezone.isEmpty)
        let reference = snapshot ? current.time : (now ?? current.time)
        let day = daily.first
        let highLow = day.map {
            "H \(temperature($0.highCelsius, units: resolved).replacingOccurrences(of: "°", with: "")) L \(temperature($0.lowCelsius, units: resolved).replacingOccurrences(of: "°", with: ""))"
        } ?? ""
        let rainText = facts(units: units, now: reference)[0].firstLine.lowercased()
            .replacingOccurrences(of: " · ", with: " ")
        let text = ["\(place.name) \(temperature(current.temperatureCelsius, units: resolved))",
                Self.condition(for: current.weatherCode).lowercased(), highLow, rainText,
                "wind \(speed(current.windSpeedKmh, units: resolved)) \(Self.compass(current.windDirectionDegrees))"]
            .filter { !$0.isEmpty }.joined(separator: ", ")
        return snapshot ? "\(text) (reading \(age(at: copyTime)))" : text
    }

    public static func compass(_ degrees: Double) -> String {
        let labels = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        guard degrees.isFinite else { return "–" }
        let index = Int((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5 + 0.5) % 16
        return labels[index]
    }

    public static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max" : "moon.stars"
        case 1...2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45...48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67: return "cloud.rain"
        case 71...77: return "cloud.snow"
        case 80...82: return "cloud.heavyrain"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    public static func condition(for code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1...2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45...48: return "Foggy"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rainy"
        case 71...77: return "Snowy"
        case 95...99: return "Thunderstorms"
        default: return "Weather unavailable"
        }
    }

    private func temperature(_ celsius: Double, units: WeatherUnits) -> String {
        let value = units == .imperial ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    private func speed(_ kmh: Double, units: WeatherUnits) -> String {
        let value = units == .imperial ? kmh / 1.609344 : kmh
        return "\(Int(value.rounded())) \(units == .imperial ? "mph" : "km/h")"
    }

    private func amount(_ mm: Double, units: WeatherUnits) -> String {
        if units == .imperial { return String(format: "%.2f in", mm / 25.4) }
        return String(format: "%.1f mm", mm)
    }

    private func clock(_ date: Date) -> String {
        if let label = sourceClockTimes?[Self.clockKey(date)] { return label }
        if place.isCurrentLocation && place.timezone.isEmpty { return "–" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: place.timezone) ?? (place.isCurrentLocation ? .current : .gmt)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    fileprivate func sourceClockLabels() -> [String: String] {
        var labels = sourceClockTimes ?? [:]
        guard !place.timezone.isEmpty else { return labels }
        let dates = [current.time] + daily.flatMap { [$0.sunrise, $0.sunset] } + hourly.map(\.time)
        for date in dates { labels[Self.clockKey(date)] = clock(date) }
        return labels
    }

    private static func clockKey(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }

    private func age(at date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(fetchedAt) / 60))
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) h ago"
    }
}

public enum WeatherDataError: Error, Equatable, Sendable {
    case missingCoordinates
    case invalidHost
    case invalidResponse
    case httpStatus(Int)
    case malformedData
}

public struct WeatherTransport: Sendable {
    public let execute: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(execute: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.execute = execute
    }

    public static let live = WeatherTransport { request in
        let session = URLSession(configuration: .ephemeral, delegate: WeatherRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request)
    }
}

private final class WeatherRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(OpenMeteoWeatherClient.isAllowed(request.url) ? request : nil)
    }
}

public actor OpenMeteoWeatherClient {
    private let transport: WeatherTransport

    public init(transport: WeatherTransport = .live) {
        self.transport = transport
    }

    public static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host else { return false }
        return host == "api.open-meteo.com" || host == "geocoding-api.open-meteo.com"
    }

    public func geocode(_ query: String, previouslyUsed: [WeatherPlace] = []) async throws -> [WeatherPlace] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: text), URLQueryItem(name: "count", value: "5")]
        let response: GeocodingResponse = try await fetch(components.url!)
        let places = (response.results ?? []).map {
            WeatherPlace(name: $0.name, country: $0.country, admin1: $0.admin1,
                         latitude: $0.latitude, longitude: $0.longitude, timezone: $0.timezone)
        }
        let prior = Set(previouslyUsed.filter { !$0.isCurrentLocation }.map(\.cacheKey))
        return places.enumerated().sorted {
            let left = prior.contains($0.element.cacheKey)
            let right = prior.contains($1.element.cacheKey)
            return left == right ? $0.offset < $1.offset : left
        }.map(\.element)
    }

    public func forecast(for place: WeatherPlace) async throws -> WeatherReading {
        guard let latitude = place.latitude, let longitude = place.longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw WeatherDataError.missingCoordinates
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "hourly", value: "precipitation,precipitation_probability"),
            URLQueryItem(name: "forecast_hours", value: "24"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        let response: ForecastResponse = try await fetch(components.url!)
        let zone = TimeZone(identifier: response.timezone) ?? TimeZone(identifier: place.timezone)
        let currentZone = response.utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:)) ?? zone
        guard let zone, let currentZone,
              let currentTime = Self.parse(response.current.time, zone: currentZone) else {
            throw WeatherDataError.malformedData
        }
        let current = WeatherCurrent(time: currentTime,
            temperatureCelsius: response.current.temperature2m,
            weatherCode: response.current.weatherCode,
            windSpeedKmh: response.current.windSpeed10m,
            windDirectionDegrees: response.current.windDirection10m,
            windGustsKmh: response.current.windGusts10m,
            isDay: response.current.isDay != 0)
        let daily = zip(response.daily.time.indices, response.daily.time).compactMap { index, date -> WeatherDay? in
            guard response.daily.temperature2mMax.indices.contains(index),
                  response.daily.temperature2mMin.indices.contains(index),
                  response.daily.sunrise.indices.contains(index),
                  response.daily.sunset.indices.contains(index),
                  let sunrise = Self.parse(response.daily.sunrise[index], zone: zone),
                  let sunset = Self.parse(response.daily.sunset[index], zone: zone) else { return nil }
            return WeatherDay(date: date, highCelsius: response.daily.temperature2mMax[index],
                              lowCelsius: response.daily.temperature2mMin[index],
                              sunrise: sunrise, sunset: sunset)
        }
        let hourly = zip(response.hourly.time.indices, response.hourly.time).compactMap { index, time -> WeatherHour? in
            guard response.hourly.precipitation.indices.contains(index),
                  response.hourly.precipitationProbability.indices.contains(index),
                  let parsed = Self.parse(time, zone: zone) else { return nil }
            return WeatherHour(time: parsed, precipitationMM: response.hourly.precipitation[index],
                               precipitationProbability: response.hourly.precipitationProbability[index])
        }
        guard !daily.isEmpty, !hourly.isEmpty else { throw WeatherDataError.malformedData }
        let resolvedPlace = WeatherPlace(name: place.name, country: place.country, admin1: place.admin1,
            latitude: place.latitude, longitude: place.longitude, timezone: response.timezone,
            neighbourhood: place.neighbourhood, isCurrentLocation: place.isCurrentLocation)
        return WeatherReading(place: resolvedPlace, current: current, daily: daily,
                              hourly: hourly, fetchedAt: .now)
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        guard Self.isAllowed(url) else { throw WeatherDataError.invalidHost }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await transport.execute(request)
                try Task.checkCancellation()
                guard Self.isAllowed(response.url) else { throw WeatherDataError.invalidHost }
                guard let http = response as? HTTPURLResponse else { throw WeatherDataError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw WeatherDataError.httpStatus(http.statusCode) }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || error is DecodingError || attempt == 1 { throw error }
                if let dataError = error as? WeatherDataError {
                    if case .httpStatus(let status) = dataError, status == 429 || status >= 500 {
                        attempt += 1
                        continue
                    }
                    throw error
                }
                attempt += 1
            }
        }
    }

    private static func parse(_ value: String, zone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: value)
    }
}

private struct GeocodingResponse: Decodable {
    let results: [Result]?
    struct Result: Decodable {
        let name: String
        let country: String
        let admin1: String?
        let latitude: Double
        let longitude: Double
        let timezone: String
    }
}

private struct ForecastResponse: Decodable {
    let timezone: String
    let utcOffsetSeconds: Int?
    let current: Current
    let daily: Daily
    let hourly: Hourly

    enum CodingKeys: String, CodingKey {
        case timezone, utcOffsetSeconds = "utc_offset_seconds", current, daily, hourly
    }

    struct Current: Decodable {
        let time: String
        let temperature2m: Double
        let weatherCode: Int
        let windSpeed10m: Double
        let windDirection10m: Double
        let windGusts10m: Double
        let isDay: Int
        enum CodingKeys: String, CodingKey {
            case time, temperature2m = "temperature_2m", weatherCode = "weather_code"
            case windSpeed10m = "wind_speed_10m", windDirection10m = "wind_direction_10m"
            case windGusts10m = "wind_gusts_10m", isDay = "is_day"
        }
    }
    struct Daily: Decodable {
        let time: [String]
        let temperature2mMax: [Double]
        let temperature2mMin: [Double]
        let sunrise: [String]
        let sunset: [String]
        enum CodingKeys: String, CodingKey {
            case time, temperature2mMax = "temperature_2m_max", temperature2mMin = "temperature_2m_min"
            case sunrise, sunset
        }
    }
    struct Hourly: Decodable {
        let time: [String]
        let precipitation: [Double]
        let precipitationProbability: [Int]
        enum CodingKeys: String, CodingKey {
            case time, precipitation, precipitationProbability = "precipitation_probability"
        }
    }
}

public actor WeatherReadingCache {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glacier/Weather", isDirectory: true)
    }

    public func read(for place: WeatherPlace) -> WeatherReading? {
        readFile(key: place.cacheKey)?.reading
    }

    public func read(query: String) -> WeatherReading? {
        let query = Self.normalized(query)
        if query.isEmpty {
            return records().filter { $0.reading.place.isCurrentLocation }
                .max { $0.reading.fetchedAt < $1.reading.fetchedAt }?.reading
        }
        let matches = records().filter {
            let place = $0.reading.place
            guard !place.isCurrentLocation else { return false }
            return $0.queryAliases.contains(query)
                || Self.normalized(place.name) == query
                || Self.normalized(place.candidateLabel) == query
        }
        // A shared city name must not silently select one of several cached places.
        return matches.count == 1 ? matches[0].reading : nil
    }

    public func store(_ reading: WeatherReading, query: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safePlace = reading.place.sanitizedForPersistence
        let safeReading = WeatherReading(place: safePlace, current: reading.current,
            daily: reading.daily, hourly: reading.hourly, fetchedAt: reading.fetchedAt,
            sourceClockTimes: reading.sourceClockLabels())
        let key = safePlace.cacheKey
        var aliases = readFile(key: key)?.queryAliases ?? []
        if !safePlace.isCurrentLocation, let query {
            let normalized = Self.normalized(query)
            if !normalized.isEmpty { aliases.insert(normalized) }
        }
        let data = try JSONEncoder().encode(Record(reading: safeReading, queryAliases: aliases))
        try data.write(to: fileURL(key: key), options: .atomic)
    }

    public func previouslyUsedPlaces() -> [WeatherPlace] {
        records().filter { !$0.reading.place.isCurrentLocation }
            .sorted { $0.reading.fetchedAt > $1.reading.fetchedAt }
            .map { $0.reading.place }
    }

    private func records() -> [Record] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    private func readFile(key: String) -> Record? {
        guard let data = try? Data(contentsOf: fileURL(key: key)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func fileURL(key: String) -> URL {
        // Stable FNV-1a keeps filenames independent of user-entered place text.
        let hash = key.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private struct Record: Codable {
        let reading: WeatherReading
        let queryAliases: Set<String>
    }
}
