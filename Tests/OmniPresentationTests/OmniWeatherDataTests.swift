import Foundation
import XCTest
@testable import OmniPresentation

final class OmniWeatherDataTests: XCTestCase {
    private let london = WeatherPlace(name: "London", country: "United Kingdom",
        latitude: 51.5, longitude: -0.1, timezone: "Europe/London")

    func testRainRunAndDryNextDay() {
        let reading = fixture(hourAmounts: [0, 0.2, 0.4, 0, 2], probabilities: [0, 60, 50, 0, 90])
        XCTAssertEqual(reading.rain.amountMM, 0.6, accuracy: 0.0001)
        XCTAssertFalse(reading.rain.isNow)
        XCTAssertEqual(reading.facts(units: .metric)[0].firstLine, "Rain in 1 h")
        XCTAssertEqual(reading.facts(units: .metric)[0].secondLine, "until 15:00 · 0.6 mm")

        let dry = fixture(hourAmounts: [0, 0, 0], probabilities: [0, 10, 49])
        XCTAssertEqual(dry.facts(units: .metric)[0].firstLine, "Dry · next 24 h")
        XCTAssertTrue(dry.rain.isDry)
        let now = fixture(hourAmounts: [0.1, 0], probabilities: [0, 0])
        XCTAssertEqual(now.facts(units: .metric)[0].firstLine, "Rain now")
    }

    func testSunBeforeDawnAndAfterSunset() {
        let beforeDawn = fixture(currentTime: date("2026-10-31T05:30:00Z"))
        XCTAssertEqual(beforeDawn.nextSunEvent()?.kind, .sunrise)
        XCTAssertEqual(beforeDawn.facts(units: .metric)[1].firstLine, "Rises 07:00")

        let afterSunset = fixture(currentTime: date("2026-10-31T18:00:00Z"))
        XCTAssertEqual(afterSunset.nextSunEvent()?.kind, .sunrise)
        XCTAssertEqual(afterSunset.facts(units: .metric)[1].firstLine, "Rises 07:01")
    }

    func testFormattingCanChangeUnitsWithoutNetwork() {
        let reading = fixture()
        XCTAssertEqual(reading.display(units: .metric).temperature, "14°")
        XCTAssertEqual(reading.display(units: .imperial).temperature, "57°")
        XCTAssertEqual(reading.display(units: .metric).facts[2].firstLine, "19 km/h SW")
        XCTAssertEqual(reading.display(units: .imperial).facts[2].firstLine, "12 mph SW")
        XCTAssertEqual(reading.display(units: .metric, now: reading.fetchedAt).facts[2].secondLine, "gusts 34")
        XCTAssertTrue(reading.copySummary(units: .metric).contains("H 16 L 9"))
        XCTAssertEqual(WeatherReading.compass(360), "N")
        XCTAssertEqual(WeatherReading.symbol(for: 2, isDay: false), "cloud.moon")
        XCTAssertTrue(reading.isStale(at: reading.fetchedAt.addingTimeInterval(1801)))
        XCTAssertFalse(reading.isStale(at: reading.fetchedAt.addingTimeInterval(1800)))
        let old = reading.fetchedAt.addingTimeInterval(3 * 3600)
        let staleCopy = reading.copySummary(units: .metric, now: old)
        XCTAssertTrue(staleCopy.contains("(reading 3 h ago)"))
        let offlineCopy = reading.copySummary(units: .metric, now: old, failedReason: "Offline")
        XCTAssertEqual(offlineCopy, staleCopy)
        let rainSnapshot = fixture(hourAmounts: [0, 0.4, 0], probabilities: [0, 60, 0])
        let rainCopy = rainSnapshot.copySummary(units: .metric, now: old, failedReason: "Offline")
        XCTAssertTrue(rainCopy.contains("rain in 1 h"))
        XCTAssertFalse(rainCopy.contains("rain now"))
        XCTAssertEqual(reading.summary(now: old, failedReason: "Offline"),
                       "London · United Kingdom · Open-Meteo · 3 h ago")
    }

    func testForecastQueryAndLocalTimeAcrossDST() async throws {
        let capture = RequestCapture()
        let transport = WeatherTransport { request in
            await capture.append(request)
            return (Data(Self.forecastJSON.utf8), Self.okResponse(for: request.url!))
        }
        let client = OpenMeteoWeatherClient(transport: transport)
        let reading = try await client.forecast(for: london)
        XCTAssertEqual(reading.current.time, date("2026-10-25T01:30:00Z"))
        XCTAssertEqual(reading.summary(now: reading.fetchedAt), "London · United Kingdom · Open-Meteo · 01:30 local")
        XCTAssertEqual(reading.nextSunEvent()?.kind, .sunrise)
        let requests = await capture.requests
        XCTAssertEqual(requests.count, 1)
        let query = URLComponents(url: try XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "timezone" })?.value, "auto")
        XCTAssertEqual(query?.first(where: { $0.name == "forecast_hours" })?.value, "24")
        XCTAssertEqual(query?.first(where: { $0.name == "current" })?.value,
            "temperature_2m,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day")
        XCTAssertEqual(requests[0].timeoutInterval, 5)
    }

    func testGeocodingOrdersPreviouslyUsedCandidateWithoutAutoSelection() async throws {
        let json = """
        {"results":[
          {"name":"Paris","country":"France","admin1":"Île-de-France","latitude":48.85,"longitude":2.35,"timezone":"Europe/Paris"},
          {"name":"Paris","country":"United States","admin1":"Texas","latitude":33.66,"longitude":-95.56,"timezone":"America/Chicago"}
        ]}
        """
        let client = OpenMeteoWeatherClient(transport: WeatherTransport { request in
            (Data(json.utf8), Self.okResponse(for: request.url!))
        })
        let prior = WeatherPlace(name: "Paris", country: "United States", admin1: "Texas",
                                 timezone: "America/Chicago")
        let candidates = try await client.geocode("paris", previouslyUsed: [prior])
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].candidateLabel, "Paris, United States · Texas")
        XCTAssertEqual(candidates[1].candidateLabel, "Paris, France · Île-de-France")
    }

    func testDisallowedHostAndRedirectedResponseAreRejected() async {
        XCTAssertFalse(OpenMeteoWeatherClient.isAllowed(URL(string: "https://api.open-meteo.com.evil.test/v1/forecast")))
        XCTAssertFalse(OpenMeteoWeatherClient.isAllowed(URL(string: "http://api.open-meteo.com/v1/forecast")))
        XCTAssertTrue(OpenMeteoWeatherClient.isAllowed(URL(string: "https://api.open-meteo.com/v1/forecast")))
        let client = OpenMeteoWeatherClient(transport: WeatherTransport { _ in
            let response = HTTPURLResponse(url: URL(string: "https://other.test/redirect")!,
                                           statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.forecastJSON.utf8), response)
        })
        do {
            _ = try await client.forecast(for: london)
            XCTFail("Expected redirected response to be rejected")
        } catch let error as WeatherDataError {
            XCTAssertEqual(error, .invalidHost)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTransientFailureRetriesOnceAndCancellationStopsRetry() async throws {
        let attempts = AttemptCounter()
        let retry = OpenMeteoWeatherClient(transport: WeatherTransport { request in
            let count = await attempts.increment()
            if count == 1 { throw URLError(.timedOut) }
            return (Data(Self.forecastJSON.utf8), Self.okResponse(for: request.url!))
        })
        _ = try await retry.forecast(for: london)
        let retryCount = await attempts.value
        XCTAssertEqual(retryCount, 2)

        let cancelledAttempts = AttemptCounter()
        let cancelled = OpenMeteoWeatherClient(transport: WeatherTransport { _ in
            _ = await cancelledAttempts.increment()
            throw CancellationError()
        })
        do {
            _ = try await cancelled.forecast(for: london)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let cancelledCount = await cancelledAttempts.value
            XCTAssertEqual(cancelledCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCacheRoundTripAndCurrentLocationPrivacy() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WeatherReadingCache(directory: directory)
        let here = WeatherPlace(name: "London", country: "United Kingdom", latitude: 51.5,
            longitude: -0.1, timezone: "Europe/London", neighbourhood: "Nine Elms",
            isCurrentLocation: true)
        let reading = fixture(place: here)
        try await cache.store(reading, query: "secret typed alias")
        let cachedCurrent = await cache.read(query: "")
        let saved = try XCTUnwrap(cachedCurrent)
        XCTAssertNil(saved.place.latitude)
        XCTAssertNil(saved.place.longitude)
        XCTAssertNil(saved.place.neighbourhood)
        XCTAssertEqual(saved.place.name, "London, United Kingdom")
        XCTAssertEqual(saved.place.country, "")
        XCTAssertEqual(saved.place.timezone, "")
        XCTAssertEqual(saved.summary(now: saved.fetchedAt.addingTimeInterval(10 * 60)),
                       "London, United Kingdom · Open-Meteo · 10 min ago")
        let leakedAlias = await cache.read(query: "secret typed alias")
        XCTAssertNil(leakedAlias)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let disk = try String(contentsOf: try XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertFalse(disk.contains("Nine Elms"))
        XCTAssertFalse(disk.contains("51.5"))
        XCTAssertFalse(disk.contains("secret typed alias"))

        try await cache.store(fixture(), query: "london")
        let cachedNamed = await cache.read(query: "LONDON")
        let previouslyUsed = await cache.previouslyUsedPlaces()
        XCTAssertEqual(cachedNamed?.place.name, "London")
        XCTAssertNil(cachedNamed?.place.latitude)
        XCTAssertNil(cachedNamed?.place.longitude)
        XCTAssertEqual(previouslyUsed.count, 1)
        XCTAssertNil(previouslyUsed.first?.latitude)
        let namedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let namedJSON = try namedFiles.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(namedJSON.contains("\"latitude\""))
        XCTAssertFalse(namedJSON.contains("\"longitude\""))

        let bristol = WeatherPlace(name: "Bristol", country: "United Kingdom", latitude: 51.45,
            longitude: -2.58, timezone: "Europe/London", neighbourhood: "Clifton", isCurrentLocation: true)
        let bristolBase = fixture(place: bristol)
        let bristolReading = WeatherReading(place: bristol, current: bristolBase.current,
            daily: bristolBase.daily, hourly: bristolBase.hourly,
            fetchedAt: bristolBase.fetchedAt.addingTimeInterval(60))
        try await cache.store(bristolReading)
        let latestCurrent = await cache.read(query: "")
        let londonCurrent = await cache.read(for: here)
        XCTAssertEqual(latestCurrent?.place.name, "Bristol, United Kingdom")
        XCTAssertEqual(londonCurrent?.place.name, "London, United Kingdom")
        XCTAssertNil(latestCurrent?.place.latitude)
        XCTAssertNil(latestCurrent?.place.longitude)

        let londonCanada = WeatherPlace(name: "London", country: "Canada", admin1: "Ontario",
            latitude: 42.98, longitude: -81.25, timezone: "America/Toronto", isCurrentLocation: true)
        XCTAssertFalse(here.hasSameIdentity(as: londonCanada))
        XCTAssertEqual(londonCanada.currentPublicName, "London, Ontario, Canada")
        let canadaBase = fixture(place: londonCanada)
        try await cache.store(WeatherReading(place: londonCanada, current: canadaBase.current,
            daily: canadaBase.daily, hourly: canadaBase.hourly,
            fetchedAt: canadaBase.fetchedAt.addingTimeInterval(120)))
        let latestLondon = await cache.read(query: "")
        let ukLondon = await cache.read(for: here)
        let canadaLondon = await cache.read(for: londonCanada)
        XCTAssertEqual(latestLondon?.place.name, "London, Ontario, Canada")
        XCTAssertEqual(ukLondon?.place.name, "London, United Kingdom")
        XCTAssertEqual(canadaLondon?.place.name, "London, Ontario, Canada")

        let parisFrance = WeatherPlace(name: "Paris", country: "France", timezone: "Europe/Paris")
        let parisTexas = WeatherPlace(name: "Paris", country: "United States", admin1: "Texas",
                                      timezone: "America/Chicago")
        try await cache.store(fixture(place: parisFrance))
        try await cache.store(fixture(place: parisTexas))
        let ambiguous = await cache.read(query: "Paris")
        let explicit = await cache.read(query: "Paris, United States · Texas")
        XCTAssertNil(ambiguous)
        XCTAssertEqual(explicit?.place.country, "United States")
    }

    func testCachedCurrentLocationKeepsSourceLocalClocksWithoutTimezone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WeatherReadingCache(directory: directory)
        let tokyo = WeatherPlace(name: "Tokyo", country: "Japan", latitude: 35.68,
            longitude: 139.69, timezone: "Asia/Tokyo", neighbourhood: "Shinjuku",
            isCurrentLocation: true)
        let live = fixture(place: tokyo, hourAmounts: [0, 0.4, 0], probabilities: [0, 60, 0])
        try await cache.store(live)
        let loaded = await cache.read(for: tokyo)
        let cached = try XCTUnwrap(loaded)
        XCTAssertEqual(cached.place.timezone, "")
        XCTAssertEqual(cached.sourceClockTimes?[String(Int(live.current.time.timeIntervalSince1970))], "21:00")
        XCTAssertEqual(cached.facts(units: .metric)[0].secondLine, "until 23:00 · 0.4 mm")
        XCTAssertEqual(cached.facts(units: .metric)[1].firstLine, "Sets 01:42")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let disk = try String(contentsOf: try XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertFalse(disk.contains("Asia/Tokyo"))
        XCTAssertFalse(disk.contains("Shinjuku"))
    }

    private func fixture(place: WeatherPlace? = nil,
                         currentTime: Date? = nil,
                         hourAmounts: [Double] = [0, 0, 0],
                         probabilities: [Int] = [0, 0, 0]) -> WeatherReading {
        let time = currentTime ?? date("2026-10-31T12:00:00Z")
        let current = WeatherCurrent(time: time, temperatureCelsius: 14, weatherCode: 2,
            windSpeedKmh: 19, windDirectionDegrees: 225, windGustsKmh: 34, isDay: true)
        let days = [
            WeatherDay(date: "2026-10-31", highCelsius: 16, lowCelsius: 9,
                sunrise: date("2026-10-31T07:00:00Z"), sunset: date("2026-10-31T16:42:00Z")),
            WeatherDay(date: "2026-11-01", highCelsius: 15, lowCelsius: 8,
                sunrise: date("2026-11-01T07:01:00Z"), sunset: date("2026-11-01T16:40:00Z"))
        ]
        let hours = hourAmounts.enumerated().map { index, amount in
            WeatherHour(time: date("2026-10-31T12:00:00Z").addingTimeInterval(Double(index) * 3600),
                precipitationMM: amount, precipitationProbability: probabilities[index])
        }
        return WeatherReading(place: place ?? london, current: current, daily: days,
                              hourly: hours, fetchedAt: date("2026-10-31T12:00:00Z"))
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func okResponse(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private static let forecastJSON = """
    {"timezone":"Europe/London","utc_offset_seconds":0,
     "current":{"time":"2026-10-25T01:30","temperature_2m":14,"weather_code":2,"wind_speed_10m":19,"wind_direction_10m":225,"wind_gusts_10m":34,"is_day":0},
     "daily":{"time":["2026-10-25","2026-10-26"],"temperature_2m_max":[16,15],"temperature_2m_min":[9,8],"sunrise":["2026-10-25T06:45","2026-10-26T06:47"],"sunset":["2026-10-25T16:42","2026-10-26T16:40"]},
     "hourly":{"time":["2026-10-25T01:00","2026-10-25T02:00"],"precipitation":[0,0.2],"precipitation_probability":[0,60]}}
    """
}

private actor RequestCapture {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

private actor AttemptCounter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}
