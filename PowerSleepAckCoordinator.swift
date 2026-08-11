import Foundation
import IOKit
import IOKit.pwr_mgt

struct PowerSleepCycleDeduplicator: Sendable {
    private var handledWillSleepIDs = Set<Int>()

    mutating func beginWillSleep(notificationID: Int) -> Bool {
        handledWillSleepIDs.insert(notificationID).inserted
    }

    mutating func advanceEpoch() {
        handledWillSleepIDs.removeAll(keepingCapacity: true)
    }
}

/// Serializes IOKit power acknowledgements without blocking the power callback.
///
/// The caller owns and closes `rootPort`. It must call `shutdownAndDrain()` before
/// deregistering the power observer or closing that port.
final class PowerSleepAckCoordinator: @unchecked Sendable {
    private struct Key: Hashable {
        let messageType: UInt32
        let notificationID: Int
        let epoch: UInt64
    }

    private struct PendingAcknowledgment {
        let nonce: UInt64
        let operationID: String
        let timeoutWorkItem: DispatchWorkItem?
    }

    private enum FinishReason: String {
        case immediate
        case completed
        case deadline
        case shutdown
    }

    private let allowPowerChange: @Sendable (Int) -> IOReturn
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.yongza.ejectdrives.power-ack")
    private let queueKey = DispatchSpecificKey<UInt8>()

    // Access only on `queue`.
    private var epoch: UInt64 = 0
    private var nextNonce: UInt64 = 0
    private var pending: [Key: PendingAcknowledgment] = [:]
    private var resolved: Set<Key> = []
    private var isShuttingDown = false

    init(rootPort: io_connect_t, log: @escaping @Sendable (String) -> Void) {
        self.allowPowerChange = { notificationID in
            IOAllowPowerChange(rootPort, notificationID)
        }
        self.log = log
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Test seam(테스트 경계). Production은 위 rootPort initializer만 사용한다.
    init(allowPowerChange: @escaping @Sendable (Int) -> IOReturn,
         log: @escaping @Sendable (String) -> Void) {
        self.allowPowerChange = allowPowerChange
        self.log = log
        queue.setSpecific(key: queueKey, value: 1)
    }

    /// Acknowledges an IOKit message as soon as it reaches the coordinator queue.
    func acknowledgeImmediately(messageType: UInt32,
                                notificationID: Int,
                                operationID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let key = self.currentKey(messageType: messageType,
                                      notificationID: notificationID)
            guard let nonce = self.register(key: key,
                                            operationID: operationID,
                                            timeoutWorkItem: nil)
            else { return }
            self.finishOnce(key: key, nonce: nonce, reason: .immediate)
        }
    }

    /// Acknowledges when `group` completes, or at `deadline` seconds if it does not.
    /// The eject operation is not cancelled when the deadline wins.
    func deferAcknowledgment(messageType: UInt32,
                             notificationID: Int,
                             operationID: String,
                             until group: DispatchGroup,
                             deadline: TimeInterval) {
        // API가 호출된 실제 power callback 시점부터 세는 absolute deadline이다. queue backlog가
        // 있더라도 Apple의 sleep timeout 뒤로 밀리지 않게 registration block 안에서 재계산하지 않는다.
        let safeDeadline = deadline.isFinite ? max(0, deadline) : 0
        let absoluteDeadline = DispatchTime.now() + safeDeadline
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isShuttingDown else {
                self.log("power ack ignored after shutdown operation=\(operationID) notificationID=\(notificationID)")
                return
            }

            let key = self.currentKey(messageType: messageType,
                                      notificationID: notificationID)
            guard self.pending[key] == nil, !self.resolved.contains(key) else {
                self.logDuplicate(key: key, operationID: operationID)
                return
            }

            let nonce = self.makeNonce()
            let timeout = DispatchWorkItem { [weak self] in
                self?.finishOnce(key: key, nonce: nonce, reason: .deadline)
            }
            self.pending[key] = PendingAcknowledgment(nonce: nonce,
                                                      operationID: operationID,
                                                      timeoutWorkItem: timeout)

            group.notify(queue: self.queue) { [weak self] in
                self?.finishOnce(key: key, nonce: nonce, reason: .completed)
            }

            self.queue.asyncAfter(deadline: absoluteDeadline, execute: timeout)
            self.log("power ack deferred operation=\(operationID) messageType=\(self.hex(messageType)) notificationID=\(notificationID) epoch=\(key.epoch) nonce=\(nonce) deadline=\(safeDeadline)s")
        }
    }

    /// Commits a previously deferred token synchronously. The power-boundary state machine calls
    /// this from its main-queue final commit, so `IOAllowPowerChange` happens before another main
    /// clamshell callback can start a newer lid generation. The already-installed deadline remains
    /// the fallback if this commit is never reached.
    func finishDeferredNow(messageType: UInt32,
                           notificationID: Int,
                           operationID: String) {
        syncOnQueue {
            guard !isShuttingDown else { return }
            let key = currentKey(messageType: messageType,
                                 notificationID: notificationID)
            guard let item = pending[key] else {
                if !resolved.contains(key) {
                    log("power ack boundary commit had no registration operation=\(operationID) notificationID=\(notificationID)")
                }
                return
            }
            finishOnce(key: key, nonce: item.nonce, reason: .completed)
        }
    }

    /// Starts a new power-notification epoch and invalidates all callbacks from the old one.
    /// Call this only after the OS has advanced beyond the old notification tokens, such as wake.
    func advanceEpoch() {
        syncOnQueue {
            guard !isShuttingDown else { return }
            let dropped = pending.count
            pending.values.forEach { $0.timeoutWorkItem?.cancel() }
            pending.removeAll(keepingCapacity: true)
            resolved.removeAll(keepingCapacity: true)
            epoch &+= 1
            log("power ack epoch advanced epoch=\(epoch) droppedPending=\(dropped)")
        }
    }

    /// Acknowledges every pending token and returns only after no queue work can use `rootPort`.
    /// The caller may deregister the observer and close the port after this method returns.
    func shutdownAndDrain() {
        syncOnQueue {
            guard !isShuttingDown else { return }
            isShuttingDown = true

            let snapshot = pending.map { (key: $0.key, value: $0.value) }
            for entry in snapshot {
                finishOnce(key: entry.key,
                           nonce: entry.value.nonce,
                           reason: .shutdown)
            }

            pending.removeAll()
            resolved.removeAll()
            epoch &+= 1
            log("power ack coordinator shut down drained=\(snapshot.count)")
        }
    }

    // MARK: - Queue-confined state

    private func currentKey(messageType: UInt32, notificationID: Int) -> Key {
        Key(messageType: messageType, notificationID: notificationID, epoch: epoch)
    }

    private func register(key: Key,
                          operationID: String,
                          timeoutWorkItem: DispatchWorkItem?) -> UInt64? {
        guard !isShuttingDown else {
            log("power ack ignored after shutdown operation=\(operationID) notificationID=\(key.notificationID)")
            return nil
        }
        guard pending[key] == nil, !resolved.contains(key) else {
            logDuplicate(key: key, operationID: operationID)
            return nil
        }

        let nonce = makeNonce()
        pending[key] = PendingAcknowledgment(nonce: nonce,
                                             operationID: operationID,
                                             timeoutWorkItem: timeoutWorkItem)
        return nonce
    }

    private func makeNonce() -> UInt64 {
        nextNonce &+= 1
        if nextNonce == 0 {
            nextNonce = 1
        }
        return nextNonce
    }

    private func finishOnce(key: Key, nonce: UInt64, reason: FinishReason) {
        guard let current = pending[key], current.nonce == nonce else {
            log("power ack stale completion ignored messageType=\(hex(key.messageType)) notificationID=\(key.notificationID) epoch=\(key.epoch) nonce=\(nonce) reason=\(reason.rawValue)")
            return
        }

        pending.removeValue(forKey: key)
        current.timeoutWorkItem?.cancel()
        resolved.insert(key)

        let result = allowPowerChange(key.notificationID)
        let resultHex = "0x" + String(UInt32(bitPattern: result), radix: 16)
        log("power ack allowed operation=\(current.operationID) messageType=\(hex(key.messageType)) notificationID=\(key.notificationID) epoch=\(key.epoch) nonce=\(nonce) reason=\(reason.rawValue) result=\(resultHex)")
    }

    private func logDuplicate(key: Key, operationID: String) {
        let state = pending[key] == nil ? "resolved" : "pending"
        log("power ack duplicate ignored operation=\(operationID) messageType=\(hex(key.messageType)) notificationID=\(key.notificationID) epoch=\(key.epoch) state=\(state)")
    }

    private func hex(_ value: UInt32) -> String {
        "0x" + String(value, radix: 16)
    }

    private func syncOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }
}
