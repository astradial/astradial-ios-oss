/*
 * Copyright (c) 2010-2023 Belledonne Communications SARL.
 *
 * This file is part of linphone-iphone
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import PushKit
import CallKit
import UserNotifications

class EarlyPushkitDelegate: NSObject, PKPushRegistryDelegate, CXProviderDelegate {
	private var activeCalls: [String: (uuid: UUID, provider: CXProvider)] = [:]

	func providerDidReset(_ provider: CXProvider) {}

	func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
		Log.info("[EarlyPushkitDelegate] User tried to answer, ending call as device is locked")
		action.fail()
		provider.reportCall(with: action.callUUID, endedAt: .init(), reason: .unanswered)
		activeCalls = activeCalls.filter { $0.value.uuid != action.callUUID }
		postMissedCallNotification(trigger: nil)
	}

	func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
		Log.info("[EarlyPushkitDelegate] Received push credentials, ignoring until core is ready")
	}

	func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
		Log.info("[EarlyPushkitDelegate] Received incoming push while core is not ready, reporting call to CallKit")
		let signature = String(describing: payload.dictionaryPayload as NSDictionary)

		if let existing = activeCalls[signature] {
			existing.provider.reportCall(with: existing.uuid, updated: makeCallUpdate())
			completion()
			return
		}

		let providerConfig = CXProviderConfiguration()
		providerConfig.supportsVideo = false
		let provider = CXProvider(configuration: providerConfig)
		provider.setDelegate(self, queue: .main)

		let uuid = UUID()
		activeCalls[signature] = (uuid, provider)

		provider.reportNewIncomingCall(with: uuid, update: makeCallUpdate()) { error in
			if let error = error {
				Log.error("[EarlyPushkitDelegate] Failed to report call to CallKit: \(error.localizedDescription)")
			}
		}

		postMissedCallNotification(trigger: UNTimeIntervalNotificationTrigger(timeInterval: 4, repeats: false))
		completion()

		DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
			guard let self = self, let existing = self.activeCalls[signature], existing.uuid == uuid else { return }
			Log.info("[EarlyPushkitDelegate] Ending unanswered call after timeout")
			existing.provider.reportCall(with: uuid, endedAt: .init(), reason: .unanswered)
			self.activeCalls.removeValue(forKey: signature)
		}
	}

	private func makeCallUpdate() -> CXCallUpdate {
		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type: .generic, value: NSLocalizedString("early_push_unknown_caller", comment: ""))
		update.hasVideo = false
		return update
	}

	private func postMissedCallNotification(trigger: UNNotificationTrigger?) {
		let content = UNMutableNotificationContent()
		content.title = NSLocalizedString("early_push_missed_call_title", comment: "")
		content.body = NSLocalizedString("early_push_missed_call_body", comment: "")
		content.sound = .default
		content.interruptionLevel = .timeSensitive
		let request = UNNotificationRequest(identifier: "early_push_missed_call", content: content, trigger: trigger)
		UNUserNotificationCenter.current().add(request) { error in
			if let error = error {
				Log.error("[EarlyPushkitDelegate] Failed to post missed call notification: \(error.localizedDescription)")
			}
		}
	}
}

/// The real VoIP-push handler (supersedes EarlyPushkitDelegate, which is only a
/// boot-time stub). It is the PKPushRegistry delegate for the whole app lifetime:
///   • forwards the VoIP token to liblinphone and registers it with the Astradial
///     platform so the server push gateway can target this device;
///   • on an incoming VoIP push, reports the call to CallKit immediately (iOS 13+
///     requires this in the push callback or the app is killed and pushes stop),
///     then wakes liblinphone to pull the INVITE. The existing
///     TelecomManager.onCallStateChanged path (.PushIncomingReceived /
///     .IncomingReceived) then updates the same CallKit call.
///
/// Astradial runs Asterisk (not Belledonne's Flexisip), so the wake is driven by
/// our own gateway + APNs VoIP push — not by liblinphone's RFC-8599 Contact params.
///
/// DORMANT until (A) the APNs VoIP key + Push capability exist on the paid team
/// and (B) the server push gateway sends VoIP pushes. Until both exist no VoIP
/// push ever arrives, so this cannot affect the running app.
final class PushKitManager: NSObject, PKPushRegistryDelegate {
	static let shared = PushKitManager()
	// IMPORTANT: the registry runs on the MAIN queue, not coreQueue. So token
	// delivery / incoming-push callbacks never execute on coreQueue and can't
	// reenter CoreContext startup and deadlock the launch (the earlier hang). Core
	// work is still dispatched via doOnCoreQueue, which queues safely until ready.
	private let registry = PKPushRegistry(queue: .main)
	private var started = false
	private var cachedVoipToken: String?

	/// Wire the registry + request a VoIP token. Idempotent; safe to call at launch.
	func start() {
		guard !started else { return }
		started = true
		registry.delegate = self
		registry.desiredPushTypes = [.voIP]
		Log.info("[PushKitManager] VoIP push registry started (main queue)")
	}

	func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
		let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
		Log.info("[PushKitManager] Received VoIP push token")
		cachedVoipToken = token
		// Forward to liblinphone (doOnCoreQueue queues whether or not the core is up).
		CoreContext.shared.doOnCoreQueue { core in
			core.didRegisterForRemotePushWithStringifiedToken(deviceTokenStr: token + ":voip")
		}
		// Register with the Astradial gateway too (Asterisk isn't Flexisip). Skips
		// gracefully if no SIP user is attached yet — re-sent on SIP attach.
		Task { await AstradialAPI.shared.registerVoipToken(token) }
	}

	/// Re-send the cached VoIP token to the platform — called after a SIP line
	/// attaches, since the token usually arrives before the user picks their SIP
	/// user (so the per-user registration would otherwise have no endpoint to key on).
	func registerTokenWithPlatform() {
		guard let token = cachedVoipToken else { return }
		Task { await AstradialAPI.shared.registerVoipToken(token) }
	}

	func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
		Log.warn("[PushKitManager] VoIP push token invalidated")
	}

	func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
		// call-id is liblinphone's standard VoIP-push key. The caller name is a
		// generic placeholder — liblinphone fills the real name from the INVITE a
		// moment later via onCallStateChanged → updateCall.
		let callId = (payload.dictionaryPayload["call-id"] as? String) ?? ""
		let placeholder = NSLocalizedString("early_push_unknown_caller", comment: "")
		Log.info("[PushKitManager] Incoming VoIP push, callId=\(callId)")
		// iOS 13+: must report an incoming call to CallKit before returning.
		TelecomManager.shared.displayIncomingCall(call: nil, handle: placeholder, hasVideo: false, callId: callId, displayName: placeholder)
		CoreContext.shared.doOnCoreQueue { core in
			core.processPushNotification(callId: callId.isEmpty ? nil : callId)
		}
		completion()
	}
}
