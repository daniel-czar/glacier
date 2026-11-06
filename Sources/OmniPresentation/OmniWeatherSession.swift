import Foundation

public enum WeatherLocationFailure: Error, Sendable {
    case denied
    case unavailable
}

public enum WeatherOfflineError: Error, Sendable { case offline }

@MainActor
public protocol OmniWeatherLocationProviding: AnyObject {
    func locate() async throws -> WeatherPlace
    func cancel()
}

/// A disposable lookup. Only the sanitized last-reading cache survives closing.
@MainActor
public final class OmniWeatherSession {
    public var onChange: (() -> Void)?
    public private(set) var isOpen = false
    public private(set) var input = ""
    public private(set) var reading: WeatherReading?
    public private(set) var candidates: [WeatherPlace] = []
    public private(set) var selectedIndex = 0
    public private(set) var failureReason: String?
    public private(set) var locationDenied = false
    public private(set) var isLoading = false
    public private(set) var readingIsCurrent = false

    private let geocode: @Sendable (String, [WeatherPlace]) async throws -> [WeatherPlace]
    private let forecast: @Sendable (WeatherPlace) async throws -> WeatherReading
    private let remoteServicesEnabled: @Sendable () -> Bool
    private let cache: WeatherReadingCache?
    private let location: any OmniWeatherLocationProviding
    private let units: @Sendable () -> WeatherUnits
    private let now: @Sendable () -> Date
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var hasResolvedPlace = false
    private var lastRemoteServicesEnabled: Bool

    public init(
        cache: WeatherReadingCache? = nil,
        location: any OmniWeatherLocationProviding,
        units: @escaping @Sendable () -> WeatherUnits = { .followSystem },
        now: @escaping @Sendable () -> Date = { Date() },
        debounce: Duration = .milliseconds(350),
        remoteServicesEnabled: @escaping @Sendable () -> Bool = { true },
        geocode: @escaping @Sendable (String, [WeatherPlace]) async throws -> [WeatherPlace],
        forecast: @escaping @Sendable (WeatherPlace) async throws -> WeatherReading
    ) {
        self.cache = cache
        self.location = location
        self.units = units
        self.now = now
        self.debounce = debounce
        self.geocode = geocode
        self.forecast = forecast
        self.remoteServicesEnabled = remoteServicesEnabled
        lastRemoteServicesEnabled = remoteServicesEnabled()
    }

    public var display: WeatherDisplay? {
        reading?.display(units: units(), now: now(), failedReason: failureReason)
    }

    public var isDimmed: Bool {
        guard let reading else { return false }
        return !readingIsCurrent || failureReason != nil || reading.isStale(at: now())
    }

    public var copyText: String? {
        guard isOpen, candidates.isEmpty, hasResolvedPlace || failureReason != nil, let reading else { return nil }
        return reading.copySummary(units: units(), now: now(), failedReason: failureReason)
    }

    public var summary: String {
        if locationDenied { return "Location off · type a place" }
        if !candidates.isEmpty { return "Choose a place · Open-Meteo" }
        if reading == nil, let failureReason { return failureReason }
        return display?.summary ?? ""
    }

    public func open(input: String = "") {
        close()
        isOpen = true
        changeInput(input, immediately: true)
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.isOpen else { return }
                self.onChange?()
            }
        }
    }

    public func close() {
        invalidate()
        clockTask?.cancel()
        clockTask = nil
        isOpen = false
        input = ""
        reading = nil
        candidates = []
        selectedIndex = 0
        failureReason = nil
        locationDenied = false
        readingIsCurrent = false
        hasResolvedPlace = false
        isLoading = false
        onChange?()
    }

    public func refreshUnits() { if isOpen { onChange?() } }

    /// A connectivity change cancels in-flight work while retaining any
    /// already loaded cache row and its copyable offline summary.
    public func refreshRemoteServices() {
        guard isOpen else { return }
        let enabled = remoteServicesEnabled()
        guard enabled != lastRemoteServicesEnabled else { return }
        lastRemoteServicesEnabled = enabled
        if enabled {
            changeInput(input, immediately: true)
            return
        }
        invalidate()
        isLoading = false
        readingIsCurrent = false
        hasResolvedPlace = reading != nil
        failureReason = reading == nil ? "Offline · no saved weather for this place" : "Offline · showing the last reading"
        onChange?()
    }

    public func inputChanged(_ input: String) {
        guard isOpen, input != self.input else { return }
        changeInput(input, immediately: false)
    }

    @discardableResult
    public func moveSelection(by offset: Int) -> Bool {
        guard !candidates.isEmpty else { return false }
        selectedIndex = min(candidates.count - 1, max(0, selectedIndex + offset))
        onChange?()
        return true
    }

    public func selectCandidate(_ index: Int) {
        guard isOpen, candidates.indices.contains(index) else { return }
        let place = candidates[index]
        invalidate()
        let token = revision
        candidates = []
        reading = nil
        hasResolvedPlace = true
        failureReason = nil
        isLoading = true
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        onChange?()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let cached = await self.cache?.read(for: place), self.isCurrent(token) {
                self.reading = cached
                self.readingIsCurrent = true
                self.onChange?()
            }
            guard self.isCurrent(token) else { return }
            guard self.remoteServicesEnabled() else {
                self.readingIsCurrent = false
                self.fail(self.reading == nil ? "Offline · no saved weather for this place" : "Offline · showing the last reading", token: token)
                return
            }
            await self.fetch(place, query: query, token: token)
        }
    }

    private func changeInput(_ input: String, immediately: Bool) {
        invalidate()
        self.input = input
        reading = nil
        readingIsCurrent = false
        candidates = []
        selectedIndex = 0
        failureReason = nil
        locationDenied = false
        isLoading = true
        let token = revision
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        hasResolvedPlace = false
        onChange?()
        guard query.count <= 512 else {
            failureReason = "Type a shorter place name."
            isLoading = false
            onChange?()
            return
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let cached = await self.cache?.read(query: query), self.isCurrent(token) {
                self.reading = cached
                self.readingIsCurrent = true
                self.onChange?()
            }
            guard self.isCurrent(token) else { return }
            guard self.remoteServicesEnabled() else {
                self.hasResolvedPlace = self.reading != nil
                self.readingIsCurrent = false
                self.fail(self.reading == nil ? "Offline · no saved weather for this place" : "Offline · showing the last reading", token: token)
                return
            }
            do {
                if !immediately { try await Task.sleep(for: self.debounce) }
                guard self.isCurrent(token) else { return }
                guard self.remoteServicesEnabled() else { throw WeatherOfflineError.offline }
                if query.isEmpty {
                    let place = try await self.location.locate()
                    guard self.isCurrent(token) else { return }
                    await self.resolve(place, query: query, token: token)
                } else {
                    let previous = await self.cache?.previouslyUsedPlaces() ?? []
                    let places = try await self.geocode(query, previous)
                    guard self.isCurrent(token) else { return }
                    if places.count == 1, let place = places.first {
                        await self.resolve(place, query: query, token: token)
                    } else if places.isEmpty {
                        self.reading = nil
                        self.fail("No places found. Try a city and country.", token: token)
                    } else {
                        self.reading = nil
                        self.candidates = places
                        self.isLoading = false
                        self.onChange?()
                    }
                }
            } catch is CancellationError {
                self.fail(query.isEmpty ? "Current location is unavailable. Type a place." : "Open-Meteo is unavailable. Try again.", token: token)
            }
            catch WeatherOfflineError.offline {
                self.fail("Offline · no new weather requests", token: token)
            }
            catch WeatherLocationFailure.denied {
                guard self.isCurrent(token) else { return }
                self.reading = nil
                self.locationDenied = true
                self.isLoading = false
                self.onChange?()
            } catch {
                self.fail(query.isEmpty ? "Current location is unavailable. Type a place." : Self.reason(error), token: token)
            }
        }
    }

    private func resolve(_ place: WeatherPlace, query: String, token: UInt64) async {
        guard isCurrent(token) else { return }
        if reading?.place.hasSameIdentity(as: place) != true {
            reading = nil
            onChange?()
            let cached = await cache?.read(for: place)
            guard isCurrent(token) else { return }
            reading = cached
        }
        hasResolvedPlace = !place.isCurrentLocation
        readingIsCurrent = true
        onChange?()
        await fetch(place, query: query, token: token)
    }

    private func fetch(_ place: WeatherPlace, query: String, token: UInt64) async {
        do {
            guard remoteServicesEnabled() else { throw WeatherOfflineError.offline }
            let fresh = try await forecast(place)
            guard isCurrent(token) else { return }
            reading = fresh
            hasResolvedPlace = true
            readingIsCurrent = true
            failureReason = nil
            isLoading = false
            onChange?()
            try? await cache?.store(fresh, query: query)
        } catch is CancellationError {
            fail("Open-Meteo is unavailable. Try again.", token: token)
        }
        catch WeatherOfflineError.offline {
            guard isCurrent(token) else { return }
            readingIsCurrent = false
            fail(reading == nil ? "Offline · no saved weather for this place" : "Offline · showing the last reading", token: token)
        }
        catch { fail(Self.reason(error), token: token) }
    }

    private func fail(_ reason: String, token: UInt64) {
        guard isCurrent(token) else { return }
        failureReason = reason
        isLoading = false
        onChange?()
    }

    private func invalidate() {
        revision &+= 1
        task?.cancel()
        task = nil
        location.cancel()
    }

    private func isCurrent(_ token: UInt64) -> Bool { isOpen && revision == token && !Task.isCancelled }

    private static func reason(_ error: any Error) -> String {
        if error is WeatherOfflineError { return "Offline · no new weather requests" }
        if let failure = error as? URLError {
            return failure.code == .timedOut ? "Open-Meteo timed out." : "Open-Meteo is unavailable. Check your connection."
        }
        return "Open-Meteo is unavailable. Try again."
    }
}
