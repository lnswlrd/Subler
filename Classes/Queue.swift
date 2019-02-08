//
//  Queue.swift
//  Subler
//
//  Created by Damiano Galassi on 27/01/2019.
//

import Foundation
import IOKit

class Queue {

    static let Working = NSNotification.Name(rawValue: "QueueWorkingNotification")
    static let Completed = NSNotification.Name(rawValue: "QueueCompletedNotification")
    static let Failed = NSNotification.Name(rawValue: "QueueFailedNotification")
    static let Cancelled = NSNotification.Name(rawValue: "QueueCancelledNotification")

    private let workQueue: DispatchQueue
    private let arrayQueue: DispatchQueue

    private var sleepAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var sleepAssertionSuccess: IOReturn = kIOReturnInvalid

    private var items: [QueueItem]

    private var cancelled: Bool
    private var currentItem: QueueItem?

    private let url: URL

    enum Status {
        case unknown
        case working
        case completed
    }

    init(url queueURL: URL) {
        url = queueURL
        statusInternal = .unknown
        cancelled = false

        workQueue = DispatchQueue(label: "org.subler.WorkQueue")
        arrayQueue = DispatchQueue(label: "org.subler.SaveQueue")

        if let data = try? Data(contentsOf: url) {
            let unarchiver = NSKeyedUnarchiver(forReadingWith: data)
            unarchiver.requiresSecureCoding = true

            items = unarchiver.decodeObject(of: [NSArray.classForCoder(), NSMutableArray.classForCoder(), QueueItem.classForCoder()], forKey: NSKeyedArchiveRootObjectKey) as! [QueueItem]
            unarchiver.finishDecoding()
        } else {
            items = Array()
        }

        for item in items where item.status == .working {
            item.status = .failed
        }
    }

    func saveToDisk() throws {
        arrayQueue.sync {
            let data = NSMutableData()
            let archiver = NSKeyedArchiver(forWritingWith: data)
            archiver.requiresSecureCoding = true
            archiver.encode(items, forKey: NSKeyedArchiveRootObjectKey)
            archiver.finishEncoding()

            data.write(to: url, atomically: true)
        }
    }

    private enum ProcessResult {
        case completed
        case failed
        case cancelled
    }

    private func process(_ item: QueueItem) -> ProcessResult {
        return autoreleasepool { () -> ProcessResult in
            self.arrayQueue.sync {
                self.currentItem = item
            }

            item.status = .working
            item.delegate = self

            defer {
                item.delegate = nil
                self.arrayQueue.sync {
                    self.currentItem = nil
                }
            }

            self.handleSBStatusWorking(progress: 0, index: self.index(of: item))
            do {
                try item.process()

                var cancelled = false
                self.arrayQueue.sync {
                    cancelled = self.cancelled
                }

                if cancelled {
                    item.status = .cancelled
                    self.handleSBStatusCancelled()
                    return .cancelled
                } else {
                    item.status = .completed
                    self.handleSBStatusWorking(progress: 100, index: self.index(of: item))
                    return .completed
                }
            } catch {
                item.status = .failed
                self.handleSBStatusFailed(error: error)

                var cancelled = false
                self.arrayQueue.sync {
                    cancelled = self.cancelled
                }

                if cancelled {
                    self.handleSBStatusCancelled()
                    return .cancelled
                } else {
                    return .failed
                }
            }
        }
    }

    /// Starts the queue.
    func start() {
        var shouldStart = false
        arrayQueue.sync {
            if self.statusInternal != .working {
                shouldStart = true
                self.statusInternal = .working
                self.cancelled = false
            }
        }
        if shouldStart == false {
            return
        }

        workQueue.async {
            self.disableSleep()

            var completed: UInt = 0
            var failed: UInt = 0

            while(true) {
                try? self.saveToDisk()

                if let currentItem = self.firstItemInQueue {
                    let result = self.process(currentItem)
                    if .completed == result {
                        completed += 1
                    } else if .failed == result {
                        failed += 1
                    } else if .cancelled == result {
                        break
                    }
                } else {
                    break
                }
            }
            self.enableSleep()
            self.arrayQueue.sync {
                self.statusInternal = .completed
            }
            self.handleSBStatusCompleted(completed: completed, failed: failed)
        }
    }

    /// Stops the queue and abort the current work.
    func stop() {
        arrayQueue.sync {
            currentItem?.cancel()
            cancelled = true
        }
    }

    private var statusInternal: Status

    var status: Status {
        get {
            var status: Status = .completed
            arrayQueue.sync {
                status = self.statusInternal
            }
            return status
        }
    }

    var count: Int {
        get {
            var count = 0
            arrayQueue.sync {
                count = items.count
            }
            return count
        }
    }

    var readyCount: Int {
        get {
            var count = 0
            arrayQueue.sync {
                count = items.filter { $0.status == .ready }.count
            }
            return count
        }
    }

    private var firstItemInQueue: QueueItem? {
        get {
            var first: QueueItem?
            arrayQueue.sync {
                first = items.first(where: { $0.status == .ready })
                first?.status = .working
            }
            return first
        }
    }

    //MARK: Item management

    func append(_ item: QueueItem) {
        arrayQueue.sync {
            items.append(item)
        }
    }

    func item(at index: Int) -> QueueItem {
        var result: QueueItem?
        arrayQueue.sync {
            result = items[index]
        }
        return result!
    }

    func items(at indexes: IndexSet) -> [QueueItem] {
        var result: [QueueItem] = Array()
        arrayQueue.sync {
            result = items.enumerated().filter { indexes.contains($0.offset) == true } .map { $0.element }
        }
        return result
    }

    func index(of item: QueueItem) -> Int {
        var index = -1
        arrayQueue.sync {
            index = items.firstIndex(of: item) ?? -1
        }
        return index
    }

    func indexesOfItems(with status: QueueItem.Status) -> IndexSet {
        var indexes: [Int] = Array()
        arrayQueue.sync {
            indexes = items.enumerated().filter { $0.element.status == status } .map { $0.offset }
        }
        return IndexSet(indexes)
    }

    func insert(_ item: QueueItem, at index: Int) {
        arrayQueue.sync {
            items.insert(item, at: index)
        }
    }

    func remove(at indexes: IndexSet) {
        arrayQueue.sync {
            items = items.enumerated().filter { indexes.contains($0.offset) == false } .map { $0.element }
        }
    }

    func swapAt(_ i: Int, _ j: Int) {
        arrayQueue.sync {
            items.swapAt(i, j)
        }
    }

    func remove(_ item: QueueItem) {
        arrayQueue.sync {
            if let index = items.firstIndex(of: item) {
                items.remove(at: index)
            }
        }
    }

    func removeCompletedItems() -> IndexSet {
        var indexes: [Int] = Array()
        arrayQueue.sync {
            indexes = items.enumerated().filter { $0.element.status == .completed } .map { $0.offset }
            items = items.enumerated().filter { indexes.contains($0.offset) == false } .map { $0.element }
        }
        return IndexSet(indexes)
    }

    //MARK: Sleep

    private func disableSleep() {
        sleepAssertionSuccess = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                            "Subler Queue" as CFString,
                                                            &sleepAssertion)
    }

    private func enableSleep() {
        if sleepAssertionSuccess == kIOReturnSuccess {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertionSuccess = kIOReturnInvalid
            sleepAssertion = IOPMAssertionID(0)
        }
    }

    // MARK: Notifications

    func updateProgress(_ progress: Double) {
        handleSBStatusWorking(progress: progress, index: -1)
    }

    /// Processes SBQueueStatusWorking state information. Current implementation just
    /// sends SBQueueWorkingNotification.
    private func handleSBStatusWorking(progress: Double, index: Int) {
        let itemDescription = currentItem?.localizedWorkingDescription ?? NSLocalizedString("Working", comment: "Queue Working.")
        let info = String.localizedStringWithFormat(NSLocalizedString("%@.", comment: ""), itemDescription)

        NotificationCenter.default.post(name: Queue.Working, object: self, userInfo: ["ProgressString": info, "Progress": progress, "ItemIndex": index])
    }

    /// Processes SBQueueStatusCompleted state information. Current implementation just
    /// sends SBQueueCompletedNotification.
    private func handleSBStatusCompleted(completed: UInt, failed: UInt) {
        NotificationCenter.default.post(name: Queue.Completed, object: self, userInfo: ["CompletedCount": completed, "FailedCount": failed])
    }

    /// Processes SBQueueStatusFailed state information. Current implementation just
    /// sends SBQueueFailedNotification.
    private func handleSBStatusFailed(error: Error) {
        NotificationCenter.default.post(name: Queue.Failed, object: self, userInfo: ["Error": error])
    }

    /// Processes SBQueueStatusCancelled state information. Current implementation just
    /// sends SBQueueCancelledNotification.
    private func handleSBStatusCancelled() {
        NotificationCenter.default.post(name: Queue.Cancelled, object: self)
    }

}
