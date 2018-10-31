//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc public protocol OWSTypingIndicators: class {
    // TODO: Use this method.
    @objc
    func inputWasTyped(inThread thread: TSThread)

    // TODO: Use this method.
    @objc
    func messageWasSent(inThread thread: TSThread)

    @objc
    func didReceiveTypingStartedMessage(inThread thread: TSThread, recipientId: String, deviceId: UInt)

    @objc
    func didReceiveTypingStoppedMessage(inThread thread: TSThread, recipientId: String, deviceId: UInt)

    @objc
    func didReceiveIncomingMessage(inThread thread: TSThread, recipientId: String, deviceId: UInt)

    // TODO: Use this method.
    @objc
    func areTypingIndicatorsVisible(inThread thread: TSThread, recipientId: String) -> Bool
}

// MARK: -

@objc
public class OWSTypingIndicatorsImpl: NSObject, OWSTypingIndicators {
    @objc public static let typingIndicatorStateDidChange = Notification.Name("typingIndicatorStateDidChange")

    @objc
    public func inputWasTyped(inThread thread: TSThread) {
        AssertIsOnMainThread()
        guard let outgoingIndicators = ensureOutgoingIndicators(forThread: thread) else {
            owsFailDebug("Could not locate outgoing indicators state")
            return
        }
        outgoingIndicators.inputWasTyped()
    }

    @objc
    public func messageWasSent(inThread thread: TSThread) {
        AssertIsOnMainThread()
        guard let outgoingIndicators = ensureOutgoingIndicators(forThread: thread) else {
            owsFailDebug("Could not locate outgoing indicators state")
            return
        }
        outgoingIndicators.messageWasSent()
    }

    @objc
    public func didReceiveTypingStartedMessage(inThread thread: TSThread, recipientId: String, deviceId: UInt) {
        AssertIsOnMainThread()
        let incomingIndicators = ensureIncomingIndicators(forThread: thread, recipientId: recipientId, deviceId: deviceId)
        incomingIndicators.didReceiveTypingStartedMessage()
    }

    @objc
    public func didReceiveTypingStoppedMessage(inThread thread: TSThread, recipientId: String, deviceId: UInt) {
        AssertIsOnMainThread()
        let incomingIndicators = ensureIncomingIndicators(forThread: thread, recipientId: recipientId, deviceId: deviceId)
        incomingIndicators.didReceiveTypingStoppedMessage()
    }

    @objc
    public func didReceiveIncomingMessage(inThread thread: TSThread, recipientId: String, deviceId: UInt) {
        AssertIsOnMainThread()
        let incomingIndicators = ensureIncomingIndicators(forThread: thread, recipientId: recipientId, deviceId: deviceId)
        incomingIndicators.didReceiveIncomingMessage()
    }

    @objc
    public func areTypingIndicatorsVisible(inThread thread: TSThread, recipientId: String) -> Bool {
        AssertIsOnMainThread()

        let key = incomingIndicatorsKey(forThread: thread, recipientId: recipientId)
        guard let deviceMap = incomingIndicatorsMap[key] else {
            return false
        }
        for incomingIndicators in deviceMap.values {
            if incomingIndicators.isTyping {
                return true
            }
        }
        return false
    }

    // MARK: -

    // Map of thread id-to-OutgoingIndicators.
    private var outgoingIndicatorsMap = [String: OutgoingIndicators]()

    private func ensureOutgoingIndicators(forThread thread: TSThread) -> OutgoingIndicators? {
        AssertIsOnMainThread()

        guard let threadId = thread.uniqueId else {
            owsFailDebug("Thread missing id")
            return nil
        }
        if let outgoingIndicators = outgoingIndicatorsMap[threadId] {
            return outgoingIndicators
        }
        let outgoingIndicators = OutgoingIndicators(thread: thread)
        outgoingIndicatorsMap[threadId] = outgoingIndicators
        return outgoingIndicators
    }

    // The sender maintains two timers per chat:
    //
    // A sendPause timer
    // A sendRefresh timer
    private class OutgoingIndicators {
        private let thread: TSThread
        private var sendPauseTimer: Timer?
        private var sendRefreshTimer: Timer?

        init(thread: TSThread) {
            self.thread = thread
        }

        // MARK: - Dependencies

        private var messageSender: MessageSender {
            return SSKEnvironment.shared.messageSender
        }

        // MARK: -

        func inputWasTyped() {
            AssertIsOnMainThread()

            if sendRefreshTimer == nil {
                // If the user types a character into the compose box, and the sendRefresh timer isn’t running:

                // Send a ACTION=TYPING message.
                sendTypingMessage(forThread: thread, action: .started)
                // Start the sendRefresh timer for 10 seconds
                sendRefreshTimer?.invalidate()
                sendRefreshTimer = Timer.weakScheduledTimer(withTimeInterval: 10,
                                                            target: self,
                                                            selector: #selector(OutgoingIndicators.sendRefreshTimerDidFire),
                                                            userInfo: nil,
                                                            repeats: false)
                // Start the sendPause timer for 5 seconds
            } else {
                // If the user types a character into the compose box, and the sendRefresh timer is running:

                // Send nothing
                // Cancel the sendPause timer
                // Start the sendPause timer for 5 seconds again
            }

            sendPauseTimer?.invalidate()
            sendPauseTimer = Timer.weakScheduledTimer(withTimeInterval: 5,
                                                      target: self,
                                                      selector: #selector(OutgoingIndicators.sendPauseTimerDidFire),
                                                      userInfo: nil,
                                                      repeats: false)
        }

        @objc
        func sendPauseTimerDidFire() {
            AssertIsOnMainThread()

            // If the sendPause timer fires:

            // Send ACTION=STOPPED message.
            sendTypingMessage(forThread: thread, action: .stopped)
            // Cancel the sendRefresh timer
            sendRefreshTimer?.invalidate()
            sendRefreshTimer = nil
            // Cancel the sendPause timer
            sendPauseTimer?.invalidate()
            sendPauseTimer = nil
        }

        @objc
        func sendRefreshTimerDidFire() {
            AssertIsOnMainThread()

            // If the sendRefresh timer fires:

            // Send ACTION=TYPING message
            sendTypingMessage(forThread: thread, action: .started)
            // Cancel the sendRefresh timer
            sendRefreshTimer?.invalidate()
            // Start the sendRefresh timer for 10 seconds again
            sendRefreshTimer = Timer.weakScheduledTimer(withTimeInterval: 10,
                                                        target: self,
                                                        selector: #selector(sendRefreshTimerDidFire),
                                                        userInfo: nil,
                                                        repeats: false)
        }

        func messageWasSent() {
            AssertIsOnMainThread()

            // If the user sends the message:

            // Cancel the sendRefresh timer
            sendRefreshTimer?.invalidate()
            sendRefreshTimer = nil
            // Cancel the sendPause timer
            sendPauseTimer?.invalidate()
            sendPauseTimer = nil
        }

        private func sendTypingMessage(forThread thread: TSThread, action: OWSTypingIndicatorAction) {
            let message = OWSTypingIndicatorMessage(thread: thread, action: action)
            messageSender.sendPromise(message: message)
                .done {
                    Logger.info("Outgoing typing indicator message send succeeded.")
                }.catch { error in
                    Logger.error("Outgoing typing indicator message send failed: \(error).")
                }.retainUntilComplete()
        }
    }

    // MARK: -

    // Map of (thread id and recipient id)-to-(device id)-to-IncomingIndicators.
    private var incomingIndicatorsMap = [String: [UInt: IncomingIndicators]]()

    private func incomingIndicatorsKey(forThread thread: TSThread, recipientId: String) -> String {
        return "\(String(describing: thread.uniqueId)) \(recipientId)"
    }

    private func ensureIncomingIndicators(forThread thread: TSThread, recipientId: String, deviceId: UInt) -> IncomingIndicators {
        AssertIsOnMainThread()

        let key = incomingIndicatorsKey(forThread: thread, recipientId: recipientId)
        guard let deviceMap = incomingIndicatorsMap[key] else {
            let incomingIndicators = IncomingIndicators(recipientId: recipientId, deviceId: deviceId)
            incomingIndicatorsMap[key] = [deviceId: incomingIndicators]
            return incomingIndicators
        }
        guard let incomingIndicators = deviceMap[deviceId] else {
            let incomingIndicators = IncomingIndicators(recipientId: recipientId, deviceId: deviceId)
            var deviceMapCopy = deviceMap
            deviceMapCopy[deviceId] = incomingIndicators
            incomingIndicatorsMap[key] = deviceMapCopy
            return incomingIndicators
        }
        return incomingIndicators
    }

    // The receiver maintains one timer for each (sender, device) in a chat:
    private class IncomingIndicators {
        private let recipientId: String
        private let deviceId: UInt
        private var displayTypingTimer: Timer?
        var isTyping = false {
            didSet {
                AssertIsOnMainThread()

                let didChange = oldValue != isTyping
                if didChange {
                    Logger.debug("isTyping changed: \(oldValue) -> \(self.isTyping)")

                    notify()
                }
            }
        }

        init(recipientId: String, deviceId: UInt) {
            self.recipientId = recipientId
            self.deviceId = deviceId
        }

        func didReceiveTypingStartedMessage() {
            AssertIsOnMainThread()

            // If the client receives a ACTION=TYPING message:
            //
            // Cancel the displayTyping timer for that (sender, device)
            // Display the typing indicator for that (sender, device)
            // Set the displayTyping timer for 15 seconds
            displayTypingTimer?.invalidate()
            displayTypingTimer = Timer.weakScheduledTimer(withTimeInterval: 15,
                                                          target: self,
                                                          selector: #selector(IncomingIndicators.displayTypingTimerDidFire),
                                                          userInfo: nil,
                                                          repeats: false)
            isTyping = true
        }

        func didReceiveTypingStoppedMessage() {
            AssertIsOnMainThread()

            // If the client receives a ACTION=STOPPED message:
            //
            // Cancel the displayTyping timer for that (sender, device)
            // Hide the typing indicator for that (sender, device)
            displayTypingTimer?.invalidate()
            displayTypingTimer = nil
            isTyping = false
        }

        @objc
        func displayTypingTimerDidFire() {
            AssertIsOnMainThread()

            // If the displayTyping indicator fires:
            //
            // Cancel the displayTyping timer for that (sender, device)
            // Hide the typing indicator for that (sender, device)
            displayTypingTimer?.invalidate()
            displayTypingTimer = nil
            isTyping = false
        }

        func didReceiveIncomingMessage() {
            AssertIsOnMainThread()

            // If the client receives a message:
            //
            // Cancel the displayTyping timer for that (sender, device)
            // Hide the typing indicator for that (sender, device)
            displayTypingTimer?.invalidate()
            displayTypingTimer = nil
            isTyping = false
        }

        private func notify() {
            NotificationCenter.default.postNotificationNameAsync(OWSTypingIndicatorsImpl.typingIndicatorStateDidChange, object: recipientId)
        }
    }
}
