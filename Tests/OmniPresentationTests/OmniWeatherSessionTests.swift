import AppKit
import Foundation
import OmniCore
@testable import OmniPresentation
import Testing

private let weatherTestNow = Date(timeIntervalSince1970: 1_793_455_200)

private func weatherTestPlace(_ name: String = "London", current: Bool = false) -> WeatherPlace {
    WeatherPlace(name: name, country: "United Kingdom", admin1: "England", latitude: 51.5, longitude: -0.1,
                 timezone: "Europe/London", neighbourhood: current ? "Nine Elms" : nil, isCurrentLocation: current)
}

private func weatherTestReading(_ place: WeatherPlace = weatherTestPlace(), age: TimeInterval = 0) -> WeatherReading {
    WeatherReading(place: place,
        current: WeatherCurrent(time: weatherTestNow, temperatureCelsius: 14, weatherCode: 2,
            windSpeedKmh: 19, windDirectionDegrees: 225, windGustsKmh: 34, isDay: true),
        daily: [WeatherDay(date: "2026-10-31", highCelsius: 16, lowCelsius: 9,
            sunrise: weatherTestNow.addingTimeInterval(-7 * 3600), sunset: weatherTestNow.addingTimeInterval(2 * 3600 + 39 * 60))],
        hourly: (0..<24).map { WeatherHour(time: weatherTestNow.addingTimeInterval(Double($0) * 3600),
                                         precipitationMM: $0 == 2 ? 1.4 : 0, precipitationProbability: $0 == 2 ? 60 : 0) },
        fetchedAt: weatherTestNow.addingTimeInterval(-age))
}

@MainActor private final class WeatherTestLocation: OmniWeatherLocationProviding {
    var denied = false
    var requests = 0
    var cancels = 0
    func locate() async throws -> WeatherPlace {
        requests += 1
        if denied { throw WeatherLocationFailure.denied }
        return weatherTestPlace(current: true)
    }
    func cancel() { cancels += 1 }
}

private actor WeatherFetchGate {
    private var pending: [CheckedContinuation<WeatherReading, any Error>] = []
    private(set) var requests = 0
    func fetch(_ place: WeatherPlace) async throws -> WeatherReading {
        requests += 1
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(_ reading: WeatherReading) { pending.removeFirst().resume(returning: reading) }
    func fail() { pending.removeFirst().resume(throwing: URLError(.notConnectedToInternet)) }
}

private actor WeatherGeocodeGate {
    private var pending: CheckedContinuation<[WeatherPlace], Never>?
    private(set) var started = false
    func lookup() async -> [WeatherPlace] {
        started = true
        return await withCheckedContinuation { pending = $0 }
    }
    func complete(_ places: [WeatherPlace]? = nil) {
        pending?.resume(returning: places ?? [weatherTestPlace("Paris"), weatherTestPlace("Paris, Texas")])
        pending = nil
    }
}

private final class RemoteServicesToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ enabled: Bool) { value = enabled }
    var enabled: Bool { lock.withLock { value } }
    func set(_ enabled: Bool) { lock.withLock { value = enabled } }
}

@MainActor private final class WeatherLocationGate: OmniWeatherLocationProviding {
    private var pending: CheckedContinuation<WeatherPlace, any Error>?
    var started = false
    func locate() async throws -> WeatherPlace {
        started = true
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(_ place: WeatherPlace) { pending?.resume(returning: place); pending = nil }
    func cancel() { pending?.resume(throwing: CancellationError()); pending = nil }
}

@MainActor private func waitWeather(_ predicate: () -> Bool) async {
    for _ in 0..<200 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Weather did not reach the expected state")
}

@Test @MainActor
func weatherOfflineUsesCachedReadingWithoutLocationOrRemoteCalls() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glacier-weather-offline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(), query: "london")
    let location = WeatherTestLocation()
    let session = OmniWeatherSession(cache: cache, location: location, now: { weatherTestNow },
        debounce: .zero, remoteServicesEnabled: { false },
        geocode: { _, _ in Issue.record("Offline weather must not geocode"); return [] },
        forecast: { _ in Issue.record("Offline weather must not forecast"); return weatherTestReading() })
    session.open(input: "london")
    await waitWeather { !session.isLoading }
    #expect(session.reading != nil)
    #expect(session.copyText?.contains("London") == true)
    #expect(session.failureReason == "Offline · showing the last reading")
    #expect(location.requests == 0)
    session.open()
    await waitWeather { !session.isLoading }
    #expect(location.requests == 0)
    #expect(session.failureReason == "Offline · no saved weather for this place")
    session.close()
}

@Test @MainActor
func weatherSwitchToOfflineCancelsLateForecast() async {
    let toggle = RemoteServicesToggle(true)
    let gate = WeatherFetchGate()
    let session = OmniWeatherSession(location: WeatherTestLocation(), debounce: .zero,
        remoteServicesEnabled: { toggle.enabled },
        geocode: { _, _ in [weatherTestPlace()] },
        forecast: { try await gate.fetch($0) })
    session.open(input: "london")
    for _ in 0..<100 {
        if await gate.requests > 0 { break }
        await Task.yield()
    }
    #expect(await gate.requests == 1)
    toggle.set(false)
    session.refreshRemoteServices()
    #expect(!session.isLoading)
    #expect(session.failureReason == "Offline · no saved weather for this place")
    await gate.complete(weatherTestReading())
    #expect(session.reading == nil)
    session.close()
}

@Test @MainActor
func weatherCurrentCancellationExitsLoading() async {
    let geocodeSession = OmniWeatherSession(location: WeatherTestLocation(), debounce: .zero,
        geocode: { _, _ in throw CancellationError() }, forecast: { weatherTestReading($0) })
    geocodeSession.open(input: "london")
    await waitWeather { !geocodeSession.isLoading }
    #expect(geocodeSession.failureReason == "Open-Meteo is unavailable. Try again.")
    geocodeSession.close()

    let forecastSession = OmniWeatherSession(location: WeatherTestLocation(), debounce: .zero,
        geocode: { _, _ in [weatherTestPlace()] }, forecast: { _ in throw CancellationError() })
    forecastSession.open(input: "london")
    await waitWeather { !forecastSession.isLoading }
    #expect(forecastSession.failureReason == "Open-Meteo is unavailable. Try again.")
    forecastSession.close()
}

@Test @MainActor
func weatherLocationDeniedStillAllowsTypedPlace() async {
    let location = WeatherTestLocation()
    location.denied = true
    let session = OmniWeatherSession(location: location, now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [weatherTestPlace("Lisbon")] }, forecast: { weatherTestReading($0) })
    session.open()
    await waitWeather { session.locationDenied }
    #expect(session.summary == "Location off · type a place")
    #expect(session.reading == nil)
    session.inputChanged("lisbon")
    await waitWeather { session.reading != nil }
    #expect(!session.locationDenied)
    #expect(session.summary.contains("local"))
    #expect(location.requests == 1)
    session.close()
}

@Test @MainActor
func weatherAmbiguityRequiresSelectionAndEnterChooses() async {
    _ = NSApplication.shared
    let gate = WeatherFetchGate()
    let session = OmniWeatherSession(location: WeatherTestLocation(), now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [weatherTestPlace("Paris"), weatherTestPlace("Paris, Texas")] },
        forecast: { try await gate.fetch($0) })
    let window = OmniWeatherWindowController(session: session, presentsInterface: false)
    window.show(input: "paris")
    await waitWeather { session.candidates.count == 2 }
    #expect(await gate.requests == 0)
    #expect(session.copyText == nil)
    #expect(session.moveSelection(by: 1))
    window.copySelectionAndClose()
    await waitWeather { session.candidates.isEmpty && session.isLoading }
    for _ in 0..<100 { if await gate.requests == 1 { break }; await Task.yield() }
    #expect(await gate.requests == 1)
    await gate.complete(weatherTestReading(weatherTestPlace("Paris, Texas")))
    await waitWeather { session.copyText != nil }
    var copied: String?
    window.onCopy = { copied = $0 }
    window.copySelectionAndClose()
    #expect(copied?.hasPrefix("Paris, Texas 14°") == true)
    #expect(!session.isOpen)
}

@Test @MainActor
func weatherCachedReadingAppearsBeforeRefreshAndFailureKeepsItDimmed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(age: 3 * 3600), query: "london")
    let gate = WeatherFetchGate()
    let session = OmniWeatherSession(cache: cache, location: WeatherTestLocation(), now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [weatherTestPlace()] }, forecast: { try await gate.fetch($0) })
    session.open(input: "london")
    await waitWeather { session.reading != nil }
    #expect(session.isLoading)
    #expect(session.isDimmed)
    #expect(session.summary.contains("3 h ago"))
    for _ in 0..<100 { if await gate.requests == 1 { break }; await Task.yield() }
    await gate.fail()
    await waitWeather { session.failureReason != nil }
    #expect(session.reading != nil && session.isDimmed)
    #expect(session.copyText != nil)
    session.close()
}

@Test @MainActor
func weatherCloseAndEditRejectLateResults() async {
    let gate = WeatherFetchGate()
    let location = WeatherTestLocation()
    let session = OmniWeatherSession(location: location, now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [weatherTestPlace()] }, forecast: { try await gate.fetch($0) })
    session.open(input: "london")
    for _ in 0..<100 { if await gate.requests == 1 { break }; await Task.yield() }
    session.close()
    await gate.complete(weatherTestReading())
    await Task.yield()
    #expect(session.reading == nil && session.input.isEmpty && !session.isOpen)
    #expect(session.copyText == nil)
    #expect(location.cancels > 0)
}

@Test @MainActor
func weatherCachedAmbiguousNameCannotCopyBeforeGeocodingOrBypassChoice() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(weatherTestPlace("Paris")), query: "paris")
    let geocoder = WeatherGeocodeGate()
    let session = OmniWeatherSession(cache: cache, location: WeatherTestLocation(), now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in await geocoder.lookup() }, forecast: { weatherTestReading($0) })
    session.open(input: "paris")
    await waitWeather { session.reading != nil }
    #expect(session.copyText == nil)
    for _ in 0..<100 { if await geocoder.started { break }; await Task.yield() }
    await geocoder.complete()
    await waitWeather { session.candidates.count == 2 }
    #expect(session.copyText == nil && session.reading == nil)
    session.selectCandidate(0)
    await waitWeather { !session.isLoading }
    #expect(session.copyText?.hasPrefix("Paris 14°") == true)
    session.close()
}

@Test @MainActor
func weatherResolvedUniquePlaceMustMatchCachedQueryBeforeCopying() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(weatherTestPlace("Old city")), query: "alias")
    let geocoder = WeatherGeocodeGate()
    let forecast = WeatherFetchGate()
    let session = OmniWeatherSession(cache: cache, location: WeatherTestLocation(), now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in await geocoder.lookup() }, forecast: { try await forecast.fetch($0) })
    session.open(input: "alias")
    await waitWeather { session.reading != nil }
    #expect(session.copyText == nil)
    for _ in 0..<100 { if await geocoder.started { break }; await Task.yield() }
    await geocoder.complete([weatherTestPlace("New city")])
    for _ in 0..<100 { if await forecast.requests == 1 { break }; await Task.yield() }
    #expect(session.reading == nil && session.copyText == nil)
    await forecast.complete(weatherTestReading(weatherTestPlace("New city")))
    await waitWeather { !session.isLoading }
    #expect(session.copyText?.hasPrefix("New city") == true)
    session.close()
}

@Test @MainActor
func weatherNoGeocodingResultsClearCachedAlias() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(weatherTestPlace("Old city")), query: "alias")
    let geocoder = WeatherGeocodeGate()
    let session = OmniWeatherSession(cache: cache, location: WeatherTestLocation(), now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in await geocoder.lookup() }, forecast: { weatherTestReading($0) })
    session.open(input: "alias")
    await waitWeather { session.reading != nil }
    for _ in 0..<100 { if await geocoder.started { break }; await Task.yield() }
    await geocoder.complete([])
    await waitWeather { !session.isLoading }
    #expect(session.reading == nil && session.copyText == nil)
    #expect(session.failureReason?.contains("No places") == true)
    session.close()
}

@Test @MainActor
func weatherHereCacheWaitsForLocationAndDropsPreviousCityAfterTravel() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(weatherTestPlace(current: true)))
    let location = WeatherLocationGate()
    let forecast = WeatherFetchGate()
    let session = OmniWeatherSession(cache: cache, location: location, now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [] }, forecast: { try await forecast.fetch($0) })
    session.open()
    await waitWeather { session.reading != nil && location.started }
    #expect(session.copyText == nil)
    location.complete(weatherTestPlace("Bristol", current: true))
    for _ in 0..<100 { if await forecast.requests == 1 { break }; await Task.yield() }
    #expect(session.reading == nil && session.copyText == nil)
    await forecast.complete(weatherTestReading(weatherTestPlace("Bristol", current: true)))
    await waitWeather { !session.isLoading }
    #expect(session.copyText?.hasPrefix("Bristol") == true)
    session.close()
}

@Test @MainActor
func weatherSameCityNameCacheWaitsForFreshCurrentLocationReading() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = WeatherReadingCache(directory: directory)
    try await cache.store(weatherTestReading(weatherTestPlace(current: true)))
    let location = WeatherLocationGate()
    let forecast = WeatherFetchGate()
    let session = OmniWeatherSession(cache: cache, location: location, now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [] }, forecast: { try await forecast.fetch($0) })
    session.open()
    await waitWeather { session.reading != nil && location.started }
    let canada = WeatherPlace(name: "London", country: "Canada", admin1: "Ontario", latitude: 42.98, longitude: -81.25,
                              timezone: "America/Toronto", isCurrentLocation: true)
    location.complete(canada)
    for _ in 0..<100 { if await forecast.requests == 1 { break }; await Task.yield() }
    #expect(session.copyText == nil)
    await forecast.complete(weatherTestReading(canada))
    await waitWeather { !session.isLoading }
    #expect(session.reading?.place.country == "Canada")
    #expect(session.copyText != nil)
    session.close()
}

@Test @MainActor
func weatherUnitsReformatWithoutRefetchAndEmptyFailureHasNoResultRegion() async throws {
    _ = NSApplication.shared
    let preferences = OmniPreferencesStore(url: nil)
    let gate = WeatherFetchGate()
    let session = OmniWeatherSession(location: WeatherTestLocation(),
        units: { WeatherUnits(rawValue: preferences.current.weatherUnits.rawValue) ?? .metric }, now: { weatherTestNow }, debounce: .zero,
        geocode: { _, _ in [weatherTestPlace()] }, forecast: { try await gate.fetch($0) })
    let window = OmniWeatherWindowController(session: session, presentsInterface: false)
    window.show(input: "london")
    for _ in 0..<100 { if await gate.requests == 1 { break }; await Task.yield() }
    await gate.complete(weatherTestReading())
    await waitWeather { session.reading != nil }
    try preferences.update { $0.weatherUnits = .imperial }
    session.refreshUnits()
    #expect(session.display?.temperature == "57°")
    #expect(session.display?.facts.last?.firstLine.contains("mph") == true)
    #expect(await gate.requests == 1)
    #expect(window.viewController.resultView.superview != nil)
    window.dismiss()
    window.show(input: "offline")
    for _ in 0..<100 { if await gate.requests == 2 { break }; await Task.yield() }
    await gate.fail()
    await waitWeather { session.failureReason != nil }
    #expect(window.viewController.resultView.superview == nil)
    #expect(window.viewController.view.frame.height == 106)
    #expect(window.viewController.routeText.contains("●"))
    #expect(window.viewController.routeLabel.toolTip?.isEmpty == false)
    window.dismiss()
}

@Test @MainActor
func weatherNativeStatesRenderWithOptionalFactLinesAndNoEmptyPad() async throws {
    _ = NSApplication.shared
    let folder = ProcessInfo.processInfo.environment["OMNI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
    if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for state in ["london", "lisbon", "offline", "candidates"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WeatherReadingCache(directory: directory)
        let base = weatherTestReading(weatherTestPlace(current: true), age: state == "offline" ? 3 * 3600 : 0)
        let night = WeatherReading(place: WeatherPlace(name: "Lisbon", country: "Portugal", timezone: "Europe/Lisbon"),
            current: WeatherCurrent(time: weatherTestNow, temperatureCelsius: 17, weatherCode: 0,
                windSpeedKmh: 11, windDirectionDegrees: 0, windGustsKmh: 11, isDay: false),
            daily: [WeatherDay(date: "2026-10-31", highCelsius: 21, lowCelsius: 14,
                        sunrise: weatherTestNow.addingTimeInterval(-14 * 3600), sunset: weatherTestNow.addingTimeInterval(-5 * 3600)),
                    WeatherDay(date: "2026-11-01", highCelsius: 21, lowCelsius: 14,
                        sunrise: weatherTestNow.addingTimeInterval(9 * 3600 + 20 * 60), sunset: weatherTestNow.addingTimeInterval(19 * 3600))],
            hourly: (0..<24).map { WeatherHour(time: weatherTestNow.addingTimeInterval(Double($0) * 3600), precipitationMM: 0, precipitationProbability: 0) },
            fetchedAt: weatherTestNow)
        if state == "offline" { try await cache.store(base, query: "") }
        let session = OmniWeatherSession(cache: cache, location: WeatherTestLocation(), units: { .metric },
            now: { weatherTestNow }, debounce: .zero,
            geocode: { _, _ in state == "candidates" ? [weatherTestPlace("Paris"), weatherTestPlace("Paris, Texas")] : [night.place] },
            forecast: { _ in if state == "offline" { throw URLError(.notConnectedToInternet) }; return state == "lisbon" ? night : base })
        let window = OmniWeatherWindowController(session: session, presentsInterface: false)
        window.show(input: state == "lisbon" || state == "candidates" ? state : "")
        await waitWeather { !session.isLoading }
        #expect(window.viewController.resultView.contentHeight > 0)
        if state == "offline" {
            let controller = window.viewController
            #expect(controller.routeLabel.frame.width >= controller.routeLabel.attributedStringValue.size().width)
            #expect(controller.routeLabel.frame.minY > controller.keyHintsView.frame.maxY)
        }
        if state == "lisbon" {
            #expect(session.display?.facts[0].firstLine == "Dry · next 24 h")
            #expect(session.display?.facts[0].secondLine == nil)
            #expect(session.display?.facts[1].firstLine.hasPrefix("Rises") == true)
            #expect(session.display?.facts[2].secondLine == nil)
        }
        if let folder {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                OmniNativeCaptureHarness.prepare(window.viewController.view, scenario: .longEditor, treatment: .opaqueFallback, appearance: appearance)
                let image = OmniNativeCaptureHarness.image(of: window.viewController.view)
                let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("weather-\(state)-\(appearance.rawValue).png"))
            }
        }
        window.dismiss()
    }
}
