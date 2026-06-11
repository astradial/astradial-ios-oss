/*
 * Astradial onboarding — replaces Linphone's Welcome + Assistant.
 *
 * Flow (per Hari, June 2026):
 *   1. Choice: [Sign In] or [Skip login]
 *   2. Sign In → Firebase login (same auth as the web dashboard)
 *   3. After Firebase login → SIP account setup (Linphone third-party
 *      login under the hood) — owners then land on the Analytics tab.
 *   Skip → straight to the phone UI; SIP can be set up later in
 *   Settings, Analytics stays login-gated.
 *
 * Native components only. Owner == signed-in Firebase user for now
 * (role lookup is a backend gap, task #17).
 */

import SwiftUI
import linphonesw

struct AstradialOnboardingView: View {
	enum Step {
		case choice
		case firebaseLogin
		case sipLogin
	}

	@State private var step: Step = .choice
	@ObservedObject private var session = MDSession.shared
	@ObservedObject private var coreContext = CoreContext.shared

	var body: some View {
		NavigationStack {
			Group {
				switch step {
				case .choice:
					choiceStep
				case .firebaseLogin:
					MDLoginView()
						.toolbar {
							ToolbarItem(placement: .topBarLeading) {
								Button("Back") { step = .choice }
							}
						}
				case .sipLogin:
					OnboardingSIPView(onDone: finish)
						.toolbar {
							ToolbarItem(placement: .topBarTrailing) {
								Button("Later") { finish() }
							}
						}
				}
			}
		}
		.onChange(of: session.isSignedIn) { _, signedIn in
			if signedIn && step == .firebaseLogin {
				// Owners get the Analytics tab as their home.
				UserDefaults.standard.set(0, forKey: "astradial_initial_tab")
				step = .sipLogin
			}
		}
		.onChange(of: coreContext.accounts.isEmpty) { _, isEmpty in
			// Auto-finish only once the user actually connected a SIP account
			// in the SIP step — guards against any transient account state
			// during core startup.
			if !isEmpty && step == .sipLogin { finish() }
		}
	}

	private var choiceStep: some View {
		VStack(spacing: 18) {
			Spacer()
			Image(systemName: "phone.badge.waveform.fill")
				.font(.system(size: 56))
				.foregroundStyle(.tint)
			Text("Astradial Phone")
				.font(.largeTitle.weight(.bold))
			Text("Your hospital's calls — dialer, tickets and the MD Pulse dashboard in one place.")
				.font(.subheadline)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 32)

			Spacer()

			VStack(spacing: 12) {
				Button {
					step = .firebaseLogin
				} label: {
					Text("Sign In")
						.font(.headline)
						.frame(maxWidth: .infinity)
						.padding(.vertical, 6)
				}
				.buttonStyle(.borderedProminent)

				Button("Skip login") { finish() }
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			.padding(.horizontal, 24)
			.padding(.bottom, 40)
		}
		.background(Color(.systemGroupedBackground))
	}

	private func finish() {
		UserDefaults.standard.set(true, forKey: "astradial_onboarding_done")
		// Drives RootView away from onboarding (published + persisted).
		SharedMainViewModel.shared.welcomeViewDisplayed = true
	}
}

/// SIP account step — Linphone "third party account" login with native styling.
struct OnboardingSIPView: View {
	@StateObject private var sipViewModel = AccountLoginViewModel()
	@ObservedObject private var coreContext = CoreContext.shared
	@State private var showScanner = false
	@State private var scanError = false
	let onDone: () -> Void

	var body: some View {
		Form {
			Section {
				Text("Connect this phone to the Astradial PBX. Use the SIP credentials from the dashboard (Users → SIP icon).")
					.font(.footnote)
					.foregroundStyle(.secondary)
					.listRowBackground(Color.clear)
			}
			Section {
				Button {
					showScanner = true
				} label: {
					Label("Scan SIP QR Code", systemImage: "qrcode.viewfinder")
				}
			} footer: {
				if scanError {
					Text("That QR code isn't a valid Astradial SIP code.")
						.foregroundStyle(.red)
				}
			}
			Section("SIP Account") {
				TextField("Username", text: $sipViewModel.username)
					.autocapitalization(.none)
					.autocorrectionDisabled()
				SecureField("Password", text: $sipViewModel.passwd)
				TextField("Domain (e.g. stagesip.astradial.com:5080)", text: $sipViewModel.domain)
					.autocapitalization(.none)
					.autocorrectionDisabled()
					.keyboardType(.URL)
				Picker("Transport", selection: $sipViewModel.transportType) {
					Text("UDP").tag("UDP")
					Text("TCP").tag("TCP")
					Text("TLS").tag("TLS")
				}
			}
			Section {
				Button {
					sipViewModel.login()
				} label: {
					if coreContext.loggingInProgress {
						HStack {
							ProgressView()
							Text("Connecting…")
						}
					} else {
						Text("Connect")
					}
				}
				.disabled(sipViewModel.username.isEmpty || sipViewModel.domain.isEmpty || coreContext.loggingInProgress)
			} footer: {
				Text("You can also do this later from Settings or by scanning your SIP QR code.")
			}
		}
		.navigationTitle("Connect Your Line")
		.navigationBarTitleDisplayMode(.inline)
		.sheet(isPresented: $showScanner) {
			QRScannerSheet { code in
				if let credentials = SIPProvisioning.parse(code) {
					scanError = false
					sipViewModel.username = credentials.username
					sipViewModel.passwd = credentials.password
					sipViewModel.domain = credentials.domain
					sipViewModel.transportType = credentials.transport
					sipViewModel.login()
				} else {
					scanError = true
				}
			}
		}
		.onAppear {
			if sipViewModel.domain == "sip.linphone.org" {
				sipViewModel.domain = ""
			}
			sipViewModel.transportType = "UDP"
		}
	}
}
