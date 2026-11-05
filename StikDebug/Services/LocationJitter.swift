import Foundation
import CoreLocation

/// Adds natural-looking GPS wander around a fixed anchor point.
///
/// Real phones that sit still don't report one frozen coordinate: the fix
/// drifts slowly (multipath, satellite geometry changes) and has small
/// per-sample noise on top. This models that as:
///
///   offset = slow drift (Ornstein–Uhlenbeck random walk, mean-reverting to 0)
///          + fast per-sample noise (Gaussian)
///          + occasional short "multipath excursion" (rare, a few seconds)
///
/// All distances are in metres. Thread-safe; called from the command queue.
final class LocationJitter {
    static let shared = LocationJitter()

    // MARK: Settings (read live from UserDefaults so the Settings toggle applies immediately)

    static let enabledKey = "locationJitterEnabled"
    static let radiusKey = "locationJitterRadius"
    static let defaultRadius: Double = 8

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    /// Typical wander radius in metres (≈ 2σ of the drift component).
    var radius: Double {
        let r = UserDefaults.standard.double(forKey: Self.radiusKey)
        return r > 0 ? r : Self.defaultRadius
    }

    // MARK: State

    private let lock = NSLock()
    private var anchor: CLLocationCoordinate2D?
    private var driftX: Double = 0      // east, metres
    private var driftY: Double = 0      // north, metres
    private var lastSample: Date?
    private var excursion: (dx: Double, dy: Double, remaining: Int)?

    private init() {}

    /// Returns the coordinate to send for this tick. If jitter is disabled,
    /// returns `anchor` unchanged.
    func next(around anchor: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isEnabled else { return anchor }

        lock.lock()
        defer { lock.unlock() }

        // New anchor → start the walk fresh at a small random offset
        if !Self.same(self.anchor, anchor) {
            self.anchor = anchor
            let r = radius
            driftX = Self.gaussian() * r * 0.25
            driftY = Self.gaussian() * r * 0.25
            excursion = nil
            lastSample = nil
        }

        let now = Date()
        let dt = min(max(lastSample.map { now.timeIntervalSince($0) } ?? 4, 0.5), 30)
        lastSample = now

        let r = radius

        // Slow drift: OU process. theta = reversion rate (1/s).
        // Stationary std = sigma / sqrt(2*theta); target ≈ r/2.
        let theta = 1.0 / 90.0
        let sigma = (r / 2) * sqrt(2 * theta)
        let decay = exp(-theta * dt)
        let noiseScale = sigma * sqrt((1 - decay * decay) / (2 * theta))
        driftX = driftX * decay + Self.gaussian() * noiseScale
        driftY = driftY * decay + Self.gaussian() * noiseScale

        // Keep it from ever wandering absurdly far
        let maxDrift = r * 1.5
        let d = hypot(driftX, driftY)
        if d > maxDrift {
            driftX *= maxDrift / d
            driftY *= maxDrift / d
        }

        // Fast per-sample noise
        var dx = driftX + Self.gaussian() * r * 0.12
        var dy = driftY + Self.gaussian() * r * 0.12

        // Rare multipath excursion: ~1% of ticks, lasts 1–3 ticks, 1.5–3× radius
        if var ex = excursion {
            dx += ex.dx
            dy += ex.dy
            ex.remaining -= 1
            excursion = ex.remaining > 0 ? ex : nil
        } else if Double.random(in: 0..<1) < 0.01 {
            let angle = Double.random(in: 0..<(2 * .pi))
            let mag = r * Double.random(in: 1.5...3)
            excursion = (cos(angle) * mag, sin(angle) * mag, Int.random(in: 1...3))
        }

        return Self.offset(anchor, eastMeters: dx, northMeters: dy)
    }

    /// Call when simulation stops so the next start begins fresh.
    func reset() {
        lock.lock()
        anchor = nil
        driftX = 0
        driftY = 0
        lastSample = nil
        excursion = nil
        lock.unlock()
    }

    /// Randomised resend interval (seconds) so updates aren't perfectly periodic.
    func nextInterval(base: TimeInterval = 4) -> TimeInterval {
        guard isEnabled else { return base }
        return base * Double.random(in: 0.7...1.4)
    }

    // MARK: Helpers

    private static func offset(_ c: CLLocationCoordinate2D, eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = metersPerDegLat * cos(c.latitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: c.latitude + northMeters / metersPerDegLat,
            longitude: c.longitude + eastMeters / max(metersPerDegLon, 1e-6)
        )
    }

    private static func same(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D) -> Bool {
        guard let a else { return false }
        return abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }

    /// Standard normal via Box–Muller.
    private static func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1)
        let u2 = Double.random(in: 0..<1)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
