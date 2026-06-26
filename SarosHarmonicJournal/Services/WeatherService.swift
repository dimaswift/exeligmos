import CoreLocation
import Foundation

struct JournalWeatherReading: Codable, Hashable {
    let code: Int
    let emoji: String
    let temperatureC: Int
}

struct JournalWeatherOption: Identifiable, Hashable {
    let id: Int
    let codes: [Int]
    let emoji: String
    let title: String

    func contains(code: Int) -> Bool {
        codes.contains(code)
    }
}

enum JournalWeatherCatalog {
    static let options: [JournalWeatherOption] = [
        .init(id: 0, codes: [0], emoji: "☀️", title: "Sunny"),
        .init(id: 1, codes: [1], emoji: "🌤️", title: "Mainly clear"),
        .init(id: 2, codes: [2], emoji: "⛅", title: "Partly cloudy"),
        .init(id: 3, codes: [3], emoji: "☁️", title: "Overcast"),
        .init(id: 51, codes: [51, 53, 55, 56, 57, 61, 63, 65, 66, 67], emoji: "🌧️", title: "Rain"),
        .init(id: 95, codes: [95, 96, 99], emoji: "⛈️", title: "Thunderstorm"),
        .init(id: 71, codes: [85, 86, 77, 71, 73, 75], emoji: "🌨️", title: "Snow"),
        .init(id: 45, codes: [45, 48], emoji: "🌫️", title: "Fog")
    ]

    static func option(for code: Int?) -> JournalWeatherOption? {
        guard let code else { return nil }
        return options.first { $0.contains(code: code) }
    }

    static func emoji(for code: Int?) -> String? {
        option(for: code)?.emoji
    }
}

protocol WeatherService {
    func currentWeather(at coordinate: CLLocationCoordinate2D) async throws -> JournalWeatherReading
    func historicalWeather(at coordinate: CLLocationCoordinate2D, date: Date) async throws -> JournalWeatherReading
}

final class OpenMeteoWeatherService: WeatherService {
    func currentWeather(at coordinate: CLLocationCoordinate2D) async throws -> JournalWeatherReading {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto")
        ]
        let payload: ForecastPayload = try await fetch(components)
        guard let current = payload.current,
              let temperature = current.temperature2m,
              let code = current.weatherCode
        else {
            throw WeatherServiceError.missingWeather
        }
        return reading(code: code, temperature: temperature)
    }

    func historicalWeather(at coordinate: CLLocationCoordinate2D, date: Date) async throws -> JournalWeatherReading {
        let day = Self.dateFormatter.string(from: date)
        var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(coordinate.longitude)),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "UTC")
        ]
        let payload: HistoricalPayload = try await fetch(components)
        guard let hourly = payload.hourly,
              let index = nearestHourIndex(in: hourly.time, to: date),
              hourly.temperature2m.indices.contains(index),
              hourly.weatherCode.indices.contains(index)
        else {
            throw WeatherServiceError.missingWeather
        }
        return reading(code: hourly.weatherCode[index], temperature: hourly.temperature2m[index])
    }

    private func fetch<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let url = components.url else {
            throw WeatherServiceError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw WeatherServiceError.invalidResponse
        }
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private func nearestHourIndex(in values: [String], to date: Date) -> Int? {
        values.enumerated().min { lhs, rhs in
            abs(Self.hourFormatter.date(from: lhs.element)?.timeIntervalSince(date) ?? .greatestFiniteMagnitude)
                < abs(Self.hourFormatter.date(from: rhs.element)?.timeIntervalSince(date) ?? .greatestFiniteMagnitude)
        }?.offset
    }

    private func reading(code: Int, temperature: Double) -> JournalWeatherReading {
        JournalWeatherReading(
            code: code,
            emoji: JournalWeatherCatalog.emoji(for: code) ?? "🌡️",
            temperatureC: Int(temperature.rounded())
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter
    }()
}

private enum WeatherServiceError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingWeather

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Could not build Open-Meteo request."
        case .invalidResponse:
            "Open-Meteo returned an invalid response."
        case .missingWeather:
            "Open-Meteo did not return weather for this entry."
        }
    }
}

private struct ForecastPayload: Decodable {
    let current: Current?

    struct Current: Decodable {
        let temperature2m: Double?
        let weatherCode: Int?

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
}

private struct HistoricalPayload: Decodable {
    let hourly: Hourly?

    struct Hourly: Decodable {
        let time: [String]
        let temperature2m: [Double]
        let weatherCode: [Int]

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
}
