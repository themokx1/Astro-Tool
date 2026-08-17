import Foundation

/// One hour's cloud-cover forecast sample, in the device's current time
/// zone (see `WeatherService`'s doc comment on why -- this app treats
/// "local" the same way `Planner`/`SkyTrack` already do everywhere else).
public struct HourlyCloud: Sendable, Equatable {
    public let time: Date
    public let cloudCoverPercent: Double

    public init(time: Date, cloudCoverPercent: Double) {
        self.time = time
        self.cloudCoverPercent = cloudCoverPercent
    }
}

/// A whole fetched forecast window (Open-Meteo's 7-day hourly series) plus
/// when it was actually fetched -- `fetchedAt` backs the Tonight page's
/// "Felhőzet" tile's "Open-Meteo · HH:mm" caption, and (via
/// `WeatherService`'s cache-on-failure fallback) can be OLDER than "now" when
/// the most recent re-fetch failed but a previous one is still on hand.
public struct NightForecast: Sendable, Equatable {
    public let hours: [HourlyCloud]
    public let fetchedAt: Date

    public init(hours: [HourlyCloud], fetchedAt: Date) {
        self.hours = hours
        self.fetchedAt = fetchedAt
    }

    /// Nearest-hour cloud-cover lookup, `nil` when `hours` is empty OR the
    /// nearest sample is more than 90 minutes from `date` -- the latter is
    /// what makes a calendar night picked beyond Open-Meteo's 7-day horizon
    /// come back honestly empty instead of silently reusing day 7's last
    /// sample for a much later date (PLAN-R10.md ground rule #2, "őszinte
    /// n/a").
    public func cloudPercent(nearestTo date: Date) -> Double? {
        guard let nearest = hours.min(by: {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }) else { return nil }
        guard abs(nearest.time.timeIntervalSince(date)) <= 90 * 60 else { return nil }
        return nearest.cloudCoverPercent
    }
}

/// One night's min/max/mean cloud cover over its dark-ish hours (20:00-04:00
/// local, kept simple rather than tied to that night's exact astronomical
/// twilight window) -- the calendar segment's "Felhő" column reads this by
/// date. `date` uses the same "yyyy-MM-dd, named by the night's start"
/// convention `NightSummary.date` already uses (e.g. the 02:00 sample on the
/// morning of the 2nd belongs to the night dated the 1st).
public struct DailyCloudSummary: Sendable, Equatable {
    public let date: String
    public let minPercent: Double
    public let maxPercent: Double
    public let meanPercent: Double

    public init(date: String, minPercent: Double, maxPercent: Double, meanPercent: Double) {
        self.date = date
        self.minPercent = minPercent
        self.maxPercent = maxPercent
        self.meanPercent = meanPercent
    }
}

/// `WeatherService.fetch`'s failure modes, with ready-to-show Hungarian
/// messages -- short enough to fit the Tonight page tile's caption line.
/// V1 (`TonightPage`) reads `.message` directly; V2 (AstroUI) maps these
/// cases to `LocalizedStringKey` instead, since a `String` handed to
/// `Text(_:)` never resolves through `hu.lproj` (see AstroUI's own
/// `WeatherError` display extension).
public enum WeatherError: Error, Sendable {
    case network
    case invalidResponse
    case decode

    public var message: String {
        switch self {
        case .network: return "Nincs kapcsolat az Open-Meteóval."
        case .invalidResponse: return "Az Open-Meteo hibás választ adott."
        case .decode: return "Az Open-Meteo válasza nem feldolgozható."
        }
    }
}

/// Open-Meteo cloud-cover forecast client -- app-workflow layer ONLY.
/// AstroCore never makes a network call (PLAN-R10.md ground rule #6); this is
/// the one place in the whole app that does. V1 reaches it only from
/// `AppState.loadWeather()`'s own opt-in guard (`config.weather.enabled`);
/// V2's Home/Planning/Nights stores apply the identical guard before ever
/// calling `fetch`. An `actor` rather than a plain class so concurrent
/// `fetch` calls (e.g. a dashboard reload firing while a previous fetch for a
/// different, just-changed coordinate is still in flight) serialize through
/// the same cache without any manual locking -- and so V1 and V2 share the
/// exact same in-memory cache when both are looking at the same library's
/// site in the same process.
public actor WeatherService {
    public static let shared = WeatherService()

    private struct CacheEntry {
        let forecast: NightForecast
        let dailySummaries: [String: DailyCloudSummary]
    }

    /// Keyed by the rounded-coordinate cache key (see `cacheKey`) --
    /// intentionally never persisted across launches, this is a purely
    /// in-memory, session-lifetime cache.
    private var cache: [String: CacheEntry] = [:]
    private static let cacheTTLSeconds: TimeInterval = 60 * 60

    private init() {}

    /// Fetches (or serves from cache) the 7-day hourly cloud-cover forecast
    /// for `(latitude, longitude)`, rounded to 2 decimals before it ever
    /// touches the network (~1 km granularity -- plenty for weather, and the
    /// privacy note `LocationSettingsView` shows promises exactly this).
    ///
    /// On a failed network fetch, falls back to whatever's cached for this
    /// coordinate -- however stale -- rather than throwing, so a transient
    /// outage never blanks out data the tile/calendar were already showing.
    /// Only throws when there is NO cached data at all to fall back to.
    public func fetch(latitude: Double, longitude: Double) async throws -> (NightForecast, [String: DailyCloudSummary]) {
        let roundedLat = (latitude * 100).rounded() / 100
        let roundedLon = (longitude * 100).rounded() / 100
        let key = Self.cacheKey(latitude: roundedLat, longitude: roundedLon)

        if let cached = cache[key], Date().timeIntervalSince(cached.forecast.fetchedAt) < Self.cacheTTLSeconds {
            return (cached.forecast, cached.dailySummaries)
        }

        do {
            let forecast = try await Self.fetchFromNetwork(latitude: roundedLat, longitude: roundedLon)
            let summaries = Self.dailySummaries(from: forecast.hours)
            cache[key] = CacheEntry(forecast: forecast, dailySummaries: summaries)
            return (forecast, summaries)
        } catch {
            if let cached = cache[key] {
                return (cached.forecast, cached.dailySummaries)
            }
            throw error
        }
    }

    private static func cacheKey(latitude: Double, longitude: Double) -> String {
        String(format: "%.2f,%.2f", latitude, longitude)
    }

    // MARK: - Network + decoding

    private struct OpenMeteoResponse: Decodable {
        struct Hourly: Decodable {
            let time: [String]
            let cloudCover: [Double]

            private enum CodingKeys: String, CodingKey {
                case time
                case cloudCover = "cloud_cover"
            }
        }
        let hourly: Hourly
    }

    /// One 10s-timeout attempt, no retries beyond it (R10-B6 spec) --
    /// `nonisolated` so it never needs the actor's own isolation just to run
    /// a plain HTTP request.
    private static nonisolated func fetchFromNetwork(latitude: Double, longitude: Double) async throws -> NightForecast {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "hourly", value: "cloud_cover"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { throw WeatherError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw WeatherError.network
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WeatherError.invalidResponse
        }

        let decoded: OpenMeteoResponse
        do {
            decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        } catch {
            throw WeatherError.decode
        }
        guard decoded.hourly.time.count == decoded.hourly.cloudCover.count else {
            throw WeatherError.decode
        }

        // Open-Meteo's `timezone=auto` returns each hourly timestamp as the
        // SITE's own local wall-clock time (no UTC offset suffix, e.g.
        // "2024-06-01T22:00"). This app has no other notion of "the site's
        // real IANA time zone" anywhere (`Planner`/`SkyTrack` compute their
        // own "local" labels off `TimeZone.current` throughout) -- reading
        // these strings through the device's current zone matches that same
        // established convention rather than introducing a second one.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        let hours = zip(decoded.hourly.time, decoded.hourly.cloudCover).compactMap { timeString, cloud -> HourlyCloud? in
            guard let date = formatter.date(from: timeString) else { return nil }
            return HourlyCloud(time: date, cloudCoverPercent: cloud)
        }
        return NightForecast(hours: hours, fetchedAt: Date())
    }

    // MARK: - Daily summary (calendar column)

    /// `yyyy-MM-dd` local-day formatter, public so V2 stores can turn a
    /// planned night's `Date` into the same key `dailySummaries(from:)` below
    /// buckets by, without each maintaining its own duplicate formatter that
    /// could silently drift out of sync with this one.
    public static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Buckets `hours` into one summary per "night" (20:00-04:00 local, kept
    /// simple per spec): an hour at or after 20:00 belongs to the night dated
    /// THAT calendar day; an hour before 04:00 belongs to the night dated the
    /// PREVIOUS calendar day; anything in between (daytime) is dropped.
    private static func dailySummaries(from hours: [HourlyCloud]) -> [String: DailyCloudSummary] {
        let calendar = Calendar.current
        var buckets: [String: [Double]] = [:]

        for hour in hours {
            let hourOfDay = calendar.component(.hour, from: hour.time)
            let dayStart = calendar.startOfDay(for: hour.time)
            let nightStart: Date
            if hourOfDay >= 20 {
                nightStart = dayStart
            } else if hourOfDay < 4 {
                nightStart = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
            } else {
                continue
            }
            let key = isoDateFormatter.string(from: nightStart)
            buckets[key, default: []].append(hour.cloudCoverPercent)
        }

        var result: [String: DailyCloudSummary] = [:]
        for (date, values) in buckets where !values.isEmpty {
            let mean = values.reduce(0, +) / Double(values.count)
            result[date] = DailyCloudSummary(
                date: date,
                minPercent: values.min() ?? mean,
                maxPercent: values.max() ?? mean,
                meanPercent: mean
            )
        }
        return result
    }
}
