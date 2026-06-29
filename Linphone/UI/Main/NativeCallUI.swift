/*
 * Native in-call screen + SIP QR provisioning.
 *
 * NativeCallView replaces Linphone's CallView overlay with the stock
 * iOS Phone in-call layout: caller name + timer up top, a 2×3 control
 * grid (mute / keypad / speaker · add call / hold / record), red end
 * button. Controls drive the existing CallViewModel + AudioRouteUtils;
 * the DTMF pad sends RFC-4733 digits via the core.
 *
 * QRScannerSheet + SIPProvisioning parse the editor's Zoiper-style
 * SIP QR payload (docs: features/softphone-app.md) to fill the SIP
 * login form in onboarding and Settings.
 */

import SwiftUI
import AVFoundation
import linphonesw

// MARK: - In-call screen

struct NativeCallView: View {
	@EnvironmentObject private var callViewModel: CallViewModel
	@ObservedObject private var telecomManager = TelecomManager.shared
	@State private var isSpeaker = false
	@State private var showDtmfPad = false

	var body: some View {
		ZStack {
			LinearGradient(
				colors: [Color(red: 0.17, green: 0.19, blue: 0.24), Color(red: 0.05, green: 0.05, blue: 0.08)],
				startPoint: .top, endPoint: .bottom
			)
			.ignoresSafeArea()

			VStack(spacing: 0) {
				VStack(spacing: 6) {
					Text(callViewModel.displayName.isEmpty ? callViewModel.remoteAddressString : callViewModel.displayName)
						.font(.system(size: 32, weight: .regular))
						.foregroundStyle(.white)
						.lineLimit(1)
						.minimumScaleFactor(0.5)
						.padding(.horizontal, 24)
					Text(statusLine)
						.font(.title3)
						.foregroundStyle(.white.opacity(0.7))
						.monospacedDigit()
						.contentTransition(.numericText())
						.onReceive(callViewModel.timer) { _ in
							// Tick the live duration every second — the view model
							// only refreshes timeElapsed on call-state changes, so
							// without this the timer froze at 0:01.
							callViewModel.timeElapsed = callViewModel.currentCall?.duration ?? 0
						}
				}
				.padding(.top, 56)

				Spacer()

				controlGrid
					.padding(.horizontal, 40)

				Spacer()

				Button {
					callViewModel.terminateCall()
				} label: {
					Circle()
						.fill(Color.red)
						.frame(width: 72, height: 72)
						.overlay(
							Image(systemName: "phone.down.fill")
								.font(.system(size: 28, weight: .medium))
								.foregroundStyle(.white)
						)
				}
				.buttonStyle(.plain)
				.padding(.bottom, 64)
			}
		}
		.statusBarHidden(false)
		.sheet(isPresented: $showDtmfPad) {
			DtmfPadSheet()
				.presentationDetents([.medium])
				.presentationDragIndicator(.visible)
		}
	}

	private var statusLine: String {
		if callViewModel.isPaused { return "On Hold" }
		if telecomManager.callConnected {
			let minutes = callViewModel.timeElapsed / 60
			let seconds = callViewModel.timeElapsed % 60
			return String(format: "%02d:%02d", minutes, seconds)
		}
		return callViewModel.direction == .Incoming ? "Incoming Call…" : "Calling…"
	}

	private var controlGrid: some View {
		VStack(spacing: 26) {
			HStack(spacing: 38) {
				CallControlButton(icon: "mic.slash.fill", label: "mute", active: callViewModel.micMutted) {
					callViewModel.toggleMuteMicrophone()
				}
				CallControlButton(icon: "circle.grid.3x3.fill", label: "keypad", active: false) {
					showDtmfPad = true
				}
				CallControlButton(icon: "speaker.wave.2.fill", label: "speaker", active: isSpeaker) {
					toggleSpeaker()
				}
			}
			HStack(spacing: 38) {
				CallControlButton(icon: "plus", label: "add call", active: false, enabled: false) {}
				CallControlButton(icon: "pause.fill", label: callViewModel.isPaused ? "resume" : "hold", active: callViewModel.isPaused) {
					callViewModel.togglePause()
				}
				CallControlButton(icon: "record.circle", label: "record", active: callViewModel.isRecording) {
					callViewModel.toggleRecording()
				}
			}
		}
	}

	private func toggleSpeaker() {
		let toSpeaker = !isSpeaker
		CoreContext.shared.doOnCoreQueue { core in
			if toSpeaker {
				AudioRouteUtils.routeAudioToSpeaker(core: core)
			} else {
				AudioRouteUtils.routeAudioToEarpiece(core: core)
			}
			DispatchQueue.main.async { isSpeaker = toSpeaker }
		}
	}
}

struct CallControlButton: View {
	let icon: String
	let label: String
	var active: Bool
	var enabled: Bool = true
	let action: () -> Void

	var body: some View {
		VStack(spacing: 8) {
			Button(action: action) {
				Circle()
					.fill(active ? Color.white : Color.white.opacity(0.18))
					.frame(width: 74, height: 74)
					.overlay(
						Image(systemName: icon)
							.font(.system(size: 26))
							.foregroundStyle(active ? .black : .white)
					)
			}
			.buttonStyle(.plain)
			.disabled(!enabled)
			Text(label)
				.font(.footnote)
				.foregroundStyle(.white.opacity(0.85))
		}
		.opacity(enabled ? 1 : 0.4)
	}
}

// MARK: - DTMF pad

struct DtmfPadSheet: View {
	@State private var typed = ""

	private let keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

	var body: some View {
		VStack(spacing: 14) {
			Text(typed.isEmpty ? " " : typed)
				.font(.title2.weight(.medium))
				.monospacedDigit()
				.lineLimit(1)
				.minimumScaleFactor(0.5)
				.padding(.top, 18)
			ForEach(keys, id: \.self) { row in
				HStack(spacing: 24) {
					ForEach(row, id: \.self) { key in
						Button {
							typed.append(key)
							sendDtmf(key)
							UIImpactFeedbackGenerator(style: .light).impactOccurred()
						} label: {
							Circle()
								.fill(Color(.systemGray5))
								.frame(width: 66, height: 66)
								.overlay(
									Text(key).font(.system(size: 28, weight: .regular))
								)
						}
						.buttonStyle(.plain)
					}
				}
			}
			Spacer()
		}
	}

	private func sendDtmf(_ key: String) {
		guard let char = key.utf8CString.first else { return }
		CoreContext.shared.doOnCoreQueue { core in
			try? core.currentCall?.sendDtmf(dtmf: char)
		}
	}
}

// MARK: - SIP QR provisioning (Zoiper-style payload from the editor)

enum SIPProvisioning {
	struct Credentials {
		let username: String
		let password: String
		let domain: String
		let transport: String
	}

	/// Parses `key=value` lines: server, port, username, password,
	/// transport (Zoiper format; unknown keys like wss_port are ignored).
	static func parse(_ payload: String) -> Credentials? {
		var fields: [String: String] = [:]
		for rawLine in payload.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
			let parts = rawLine.split(separator: "=", maxSplits: 1)
			guard parts.count == 2 else { continue }
			fields[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
				parts[1].trimmingCharacters(in: .whitespaces)
		}
		guard let username = fields["username"], !username.isEmpty,
			  let server = fields["server"], !server.isEmpty else { return nil }
		let port = fields["port"] ?? ""
		let domain = (port.isEmpty || port == "5060") ? server : "\(server):\(port)"
		return Credentials(
			username: username,
			password: fields["password"] ?? "",
			domain: domain,
			transport: (fields["transport"] ?? "udp").uppercased()
		)
	}
}

struct QRScannerSheet: View {
	@Environment(\.dismiss) private var dismiss
	let onCode: (String) -> Void
	@State private var unavailable = false

	var body: some View {
		NavigationStack {
			Group {
				if unavailable {
					ContentUnavailableView(
						"Camera Unavailable",
						systemImage: "camera.fill",
						description: Text("QR scanning needs a device camera. Enter the SIP details manually instead.")
					)
				} else {
					QRCameraView(
						onCode: { code in
							onCode(code)
							dismiss()
						},
						onUnavailable: { unavailable = true }
					)
					.ignoresSafeArea()
				}
			}
			.navigationTitle("Scan SIP QR")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Cancel") { dismiss() }
				}
			}
		}
	}
}

struct QRCameraView: UIViewControllerRepresentable {
	let onCode: (String) -> Void
	let onUnavailable: () -> Void

	func makeUIViewController(context: Context) -> QRCameraViewController {
		let controller = QRCameraViewController()
		controller.onCode = onCode
		controller.onUnavailable = onUnavailable
		return controller
	}

	func updateUIViewController(_ uiViewController: QRCameraViewController, context: Context) {}
}

final class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
	var onCode: ((String) -> Void)?
	var onUnavailable: (() -> Void)?
	private let session = AVCaptureSession()
	private var delivered = false

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black

		guard let device = AVCaptureDevice.default(for: .video),
			  let input = try? AVCaptureDeviceInput(device: device),
			  session.canAddInput(input) else {
			onUnavailable?()
			return
		}
		session.addInput(input)

		let output = AVCaptureMetadataOutput()
		guard session.canAddOutput(output) else {
			onUnavailable?()
			return
		}
		session.addOutput(output)
		output.setMetadataObjectsDelegate(self, queue: .main)
		output.metadataObjectTypes = [.qr]

		let preview = AVCaptureVideoPreviewLayer(session: session)
		preview.frame = view.layer.bounds
		preview.videoGravity = .resizeAspectFill
		view.layer.addSublayer(preview)

		DispatchQueue.global(qos: .userInitiated).async { [session] in
			session.startRunning()
		}
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		session.stopRunning()
	}

	func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
		guard !delivered,
			  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
			  let value = object.stringValue else { return }
		delivered = true
		UINotificationFeedbackGenerator().notificationOccurred(.success)
		onCode?(value)
	}
}
