import Foundation
import CoreLocation
import Combine

final class LocationSimulationSession: ObservableObject {
    static let shared = LocationSimulationSession()

    @Published private(set) var isActive = false
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D]?
    private var resendTimer: Timer?
    private var routeID: UUID?

    private init() {}

    func start(at coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        if !isActive {
            isActive = true
            BackgroundAudioManager.shared.requestStart()
            BackgroundLocationManager.shared.requestStart()
        }
    }

    func startResending(at coordinate: CLLocationCoordinate2D, _ operation: @escaping () -> Void) {
        start(at: coordinate)
        resendTimer?.invalidate()
        scheduleNextResend(operation)
    }

    /// Self-rescheduling one-shot timer so the interval can vary per tick
    /// (LocationJitter randomises it when enabled; otherwise a steady 4 s).
    private func scheduleNextResend(_ operation: @escaping () -> Void) {
        let interval = LocationJitter.shared.nextInterval(base: 4)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, self.resendTimer != nil else { return }
            operation()
            self.scheduleNextResend(operation)
        }
        RunLoop.main.add(timer, forMode: .common)
        resendTimer = timer
    }

    func startRoute(at coordinate: CLLocationCoordinate2D, coordinates: [CLLocationCoordinate2D]) -> UUID {
        let routeID = UUID()
        self.routeID = routeID
        routeCoordinates = coordinates
        start(at: coordinate)
        return routeID
    }

    func isCurrentRoute(_ routeID: UUID) -> Bool {
        self.routeID == routeID
    }

    func clearRoute() {
        routeID = nil
        routeCoordinates = nil
    }

    func pauseResending() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    func updateCoordinate(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }

    func stop() {
        pauseResending()
        clearRoute()
        LocationJitter.shared.reset()
        guard isActive else { return }
        isActive = false
        coordinate = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
    }
}
