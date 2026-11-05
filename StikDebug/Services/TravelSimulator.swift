import Foundation
import CoreLocation
import MapKit

/// When switching from one simulated point to another, travel there along a
/// real route at a realistic pace instead of teleporting, then settle into the
/// stationary hold (which applies LocationJitter if enabled).
@MainActor
final class TravelSimulator {
    static let shared = TravelSimulator()

    enum Mode: String, CaseIterable, Identifiable {
        case auto, walk, drive
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .walk: return "Walk"
            case .drive: return "Drive"
            }
        }
    }

    static let enabledKey = "travelBetweenPointsEnabled"
    static let modeKey = "travelBetweenPointsMode"

    /// Below this distance a jump is indistinguishable from GPS noise.
    static let minimumTravelDistance: CLLocationDistance = 60
    /// In Auto mode, trips shorter than this are walked.
    static let autoWalkThreshold: CLLocationDistance = 1_500

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "") ?? .auto
    }

    private(set) var isTraveling = false
    private var task: Task<Void, Never>?

    private init() {}

    /// The point the device is currently reporting, if a simulation is running.
    var currentSimulatedCoordinate: CLLocationCoordinate2D? {
        let session = LocationSimulationSession.shared
        return session.isActive ? session.coordinate : nil
    }

    func shouldTravel(to destination: CLLocationCoordinate2D) -> Bool {
        guard isEnabled, let start = currentSimulatedCoordinate else { return false }
        return Self.distance(start, destination) >= Self.minimumTravelDistance
    }

    /// Travels from the current simulated point to `destination`.
    /// `completion` gets nil on arrival, or the failing error code.
    /// Not called if the trip is cancelled (Stop / a new route / a new trip).
    func travel(
        to destination: CLLocationCoordinate2D,
        deviceIP: String,
        pairingFilePath: String,
        completion: @escaping (Int32?) -> Void
    ) {
        guard let start = currentSimulatedCoordinate else { return }
        cancel()

        let session = LocationSimulationSession.shared
        session.pauseResending()

        let distance = Self.distance(start, destination)
        let resolvedMode: Mode = {
            switch mode {
            case .auto: return distance < Self.autoWalkThreshold ? .walk : .drive
            default: return mode
            }
        }()

        isTraveling = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isTraveling = false }

            let route = await Self.routePath(from: start, to: destination, mode: resolvedMode)
            guard !Task.isCancelled else { return }

            var path = route.coordinates
            if let last = path.last, Self.distance(last, destination) > 1 {
                path.append(destination)        // walk the last bit off-road to the exact pin
            }
            let samples = Self.playbackSamples(along: path, mode: resolvedMode, routeSpeed: route.averageSpeed)

            let routeID = session.startRoute(at: start, coordinates: path)
            var lastSent = start

            for sample in samples {
                try? await Task.sleep(for: .seconds(sample.delay))
                guard !Task.isCancelled, session.isCurrentRoute(routeID) else { return }

                let code = await Self.send(sample.coordinate, deviceIP: deviceIP, pairingFilePath: pairingFilePath)
                guard session.isCurrentRoute(routeID) else { return }
                guard code == 0 else {
                    session.clearRoute()
                    self.hold(at: lastSent, deviceIP: deviceIP, pairingFilePath: pairingFilePath)
                    completion(code)
                    return
                }
                lastSent = sample.coordinate
                session.updateCoordinate(sample.coordinate)
            }

            guard session.isCurrentRoute(routeID) else { return }
            session.clearRoute()
            self.hold(at: destination, deviceIP: deviceIP, pairingFilePath: pairingFilePath)
            completion(nil)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isTraveling = false
    }

    /// Stationary hold at `coordinate`, resending with jitter.
    func hold(at coordinate: CLLocationCoordinate2D, deviceIP: String, pairingFilePath: String) {
        LocationSimulationSession.shared.startResending(at: coordinate) {
            LocationSimulationCommandQueue.shared.async {
                let point = LocationJitter.shared.next(around: coordinate)
                _ = simulate_location(deviceIP, point.latitude, point.longitude, pairingFilePath)
            }
        }
    }

    // MARK: - Route

    private struct RoutePath {
        let coordinates: [CLLocationCoordinate2D]
        let averageSpeed: CLLocationSpeed?
    }

    private static func routePath(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        mode: Mode
    ) async -> RoutePath {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.requestsAlternateRoutes = false
        request.transportType = mode == .walk ? .walking : .automobile

        if let response = try? await MKDirections(request: request).calculate(),
           let route = response.routes.first {
            let pointCount = route.polyline.pointCount
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
            if coords.first.map({ distance($0, start) > 1 }) ?? true {
                coords.insert(start, at: 0)
            }
            let speed = route.expectedTravelTime > 0 ? route.distance / route.expectedTravelTime : nil
            return RoutePath(coordinates: coords, averageSpeed: speed)
        }
        // No route (offline, water, etc.): straight line.
        return RoutePath(coordinates: [start, end], averageSpeed: nil)
    }

    // MARK: - Playback

    private struct Sample {
        let coordinate: CLLocationCoordinate2D
        let delay: TimeInterval
    }

    /// Walks the path in ~1 s ticks with a per-trip base speed, slowly varying
    /// speed, occasional stops (crossings / lights), and a slight sideways
    /// drift off the road centreline.
    private static func playbackSamples(
        along path: [CLLocationCoordinate2D],
        mode: Mode,
        routeSpeed: CLLocationSpeed?
    ) -> [Sample] {
        guard path.count >= 2 else { return [] }

        let isWalk = mode == .walk
        let baseSpeed: Double = isWalk
            ? Double.random(in: 1.15...1.45)
            : min(max((routeSpeed ?? 11) * Double.random(in: 0.85...1.05), 5), 25)
        let speedNoise = isWalk ? 0.12 : 0.25
        let lateralSigma = isWalk ? 1.5 : 2.0      // metres off the centreline
        // Mean distance between stops. Faster roads (arterials, expressways)
        // have far fewer lights, so spacing grows steeply with route speed.
        let stopEvery: Double = isWalk ? 350 : 600 * pow(max((routeSpeed ?? 11) / 11, 1), 3)
        let stopDuration: ClosedRange<Double> = isWalk ? 8...40 : 15...75

        // Cumulative distances along the path
        var cumulative = [0.0]
        for i in 1..<path.count {
            cumulative.append(cumulative[i - 1] + distance(path[i - 1], path[i]))
        }
        let total = cumulative.last ?? 0
        guard total > 0 else { return [] }

        var samples: [Sample] = []
        var travelled = 0.0
        var speedFactor = 1.0
        var lateral = 0.0
        var nextStopAt = Double.random(in: 0.4...1.6) * stopEvery
        var segment = 0

        while travelled < total {
            let dt = Double.random(in: 0.8...1.3)

            // OU-style smooth speed variation
            speedFactor += (1 - speedFactor) * 0.15 + gaussian() * speedNoise * 0.35
            speedFactor = min(max(speedFactor, 0.5), 1.5)

            // Ease into / out of stops and the destination
            let toStop = nextStopAt - travelled
            let toEnd = total - travelled
            let slowZone = isWalk ? 8.0 : 60.0
            let ease = min(1, max(0.25, min(toStop, toEnd) / slowZone))
            let speed = baseSpeed * speedFactor * ease

            travelled = min(total, travelled + speed * dt)

            while segment < path.count - 2, cumulative[segment + 1] < travelled {
                segment += 1
            }
            let a = path[segment], b = path[segment + 1]
            let segLen = max(cumulative[segment + 1] - cumulative[segment], 0.001)
            let t = (travelled - cumulative[segment]) / segLen
            var point = interpolate(a, b, t)

            // Sideways drift, fading to zero at the destination
            lateral = lateral * 0.9 + gaussian() * lateralSigma * 0.3
            let fade = min(1, toEnd / 20)
            point = offsetPerpendicular(point, along: a, b, meters: lateral * fade)

            samples.append(Sample(coordinate: point, delay: dt))

            if travelled >= nextStopAt, travelled < total - 30 {
                // Sit at the stop, resending every few seconds
                var remaining = Double.random(in: stopDuration)
                while remaining > 0 {
                    let wait = min(remaining, Double.random(in: 3...5))
                    samples.append(Sample(coordinate: point, delay: wait))
                    remaining -= wait
                }
                speedFactor = 0.5
                nextStopAt = travelled + Double.random(in: 0.4...1.6) * stopEvery
            }
        }

        if let last = path.last {
            samples.append(Sample(coordinate: last, delay: 1))
        }
        return samples
    }

    private static func send(_ coordinate: CLLocationCoordinate2D, deviceIP: String, pairingFilePath: String) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulationCommandQueue.shared.async {
                continuation.resume(returning: simulate_location(deviceIP, coordinate.latitude, coordinate.longitude, pairingFilePath))
            }
        }
    }

    // MARK: - Geometry

    nonisolated static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        let t = min(max(t, 0), 1)
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    private static func offsetPerpendicular(
        _ p: CLLocationCoordinate2D,
        along a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        meters: Double
    ) -> CLLocationCoordinate2D {
        let mLat = 111_320.0
        let mLon = mLat * cos(p.latitude * .pi / 180)
        let dx = (b.longitude - a.longitude) * mLon
        let dy = (b.latitude - a.latitude) * mLat
        let len = hypot(dx, dy)
        guard len > 0.01 else { return p }
        // Unit normal (left of direction of travel)
        let nx = -dy / len, ny = dx / len
        return CLLocationCoordinate2D(
            latitude: p.latitude + ny * meters / mLat,
            longitude: p.longitude + nx * meters / max(mLon, 1e-6)
        )
    }

    private static func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1)
        let u2 = Double.random(in: 0..<1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
