import BackgroundTasks
import Foundation
import UIKit

/// Registers and runs `BGProcessingTask` for Tier 2/3 scanning while charging.
public enum BackgroundScanScheduler {
    public static let taskIdentifier = "org.contextcleaner.scan"

    public static func register(handler: @escaping (BGProcessingTask) -> Void) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handler(processing)
        }
    }

    public static func schedule() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = true
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("BackgroundScanScheduler: submit failed: \(error)")
        }
    }

    public static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}

/// Maps ProcessInfo thermal + battery into scheduler inputs.
public enum DeviceRuntime {
    public enum Thermal: String, Sendable {
        case nominal, fair, serious, critical
    }

    public enum Power: String, Sendable {
        case battery, charging, full
    }

    public static func currentThermal() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .fair
        }
    }

    @MainActor
    public static func currentPower() -> Power {
        UIDevice.current.isBatteryMonitoringEnabled = true
        switch UIDevice.current.batteryState {
        case .charging: return .charging
        case .full: return .full
        default: return .battery
        }
    }

    /// Physical memory in GB (rounded down).
    public static func ramGB() -> UInt32 {
        UInt32(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}
