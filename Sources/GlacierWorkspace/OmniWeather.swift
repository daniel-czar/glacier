import Foundation
import OmniCore
import OmniPresentation
import OmniRun

public enum OmniWeather {
    @MainActor
    public static func makeSession(environment: GlacierWorkspaceEnvironment, preferences: OmniPreferencesStore) -> OmniWeatherSession {
        let root = try? OmniDevelopmentRoot(validating: environment.configuration.developmentRoot,
                                           allowedRoot: environment.configuration.allowedRoot)
        let directory = try? root?.containedURL(relativePath: "weather")
        let cache = directory.map { WeatherReadingCache(directory: $0) }
        let client = OpenMeteoWeatherClient()
        return OmniWeatherSession(
            cache: cache,
            location: OmniWeatherLocation(remoteServicesEnabled: environment.remoteServicesEnabled, locationEnabled: { preferences.current.weatherUsesLocation }),
            units: { WeatherUnits(rawValue: preferences.current.weatherUnits.rawValue) ?? .followSystem },
            remoteServicesEnabled: environment.remoteServicesEnabled,
            geocode: { query, previous in
                guard environment.remoteServicesEnabled() else { throw WeatherOfflineError.offline }
                return try await client.geocode(query, previouslyUsed: previous)
            },
            forecast: { place in
                guard environment.remoteServicesEnabled() else { throw WeatherOfflineError.offline }
                return try await client.forecast(for: place)
            }
        )
    }
}
