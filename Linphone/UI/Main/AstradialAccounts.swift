/*
 * Astradial multi-account support.
 *
 * One MD can belong to several organisations (separate Firebase
 * logins). Each saved account remembers the SIP user that was attached
 * while it was active, so switching accounts also swaps the SIP line:
 * sign in to Thangavelu + pick user1 → user1 is attached to the
 * Thangavelu account and restored on every swap back.
 *
 * Storage is Keychain-only (the blob contains the Firebase password —
 * required because Firebase Auth keeps a single session — and the SIP
 * password). Never UserDefaults, never files.
 *
 * SIPUserPickerSection is the "Select SIP user" dropdown: it lists the
 * org's human SIP users (routing_type=sip, ring_target≠phone — no AI
 * agents, no mobile-number users) and provisions the line from
 * GET /users/:id/sip-credentials with the same parameters as the
 * editor's QR code (endpoint username, devsip:5080, UDP).
 */

import SwiftUI
import FirebaseAuth
import linphonesw

// MARK: - SIP defaults (mirror the editor's SipQrDialog exactly)

enum AstradialSIPDefaults {
	static let server = "devsip.astradial.com"
	static let port = "5080"
	static var domain: String { "\(server):\(port)" }
	static let transport = "UDP"
}

// MARK: - Models

struct SIPCredential: Codable, Equatable {
	var username: String      // PJSIP endpoint name (auth username)
	var password: String
	var domain: String        // host[:port]
	var transport: String
	var displayName: String   // org user's name, shown on the keypad chip

	var chipName: String { displayName.isEmpty ? username : displayName }
}

struct SavedAccount: Codable, Identifiable {
	var email: String
	var password: String      // Firebase password (Keychain blob only)
	var orgName: String?
	var role: String?
	var sip: SIPCredential?

	var id: String { email.lowercased() }
}

// MARK: - Account store

@MainActor
final class AccountStore: ObservableObject {
	static let shared = AccountStore()

	@Published private(set) var accounts: [SavedAccount] = []
	@Published var switchingTo: String?
	@Published var errorMessage: String?

	private static let storageKey = "astradial_accounts_v1"

	private init() {
		if let raw = KeychainHelper.read(key: Self.storageKey),
		   let decoded = try? JSONDecoder().decode([SavedAccount].self, from: Data(raw.utf8)) {
			accounts = decoded
		}
	}

	private func persist() {
		guard let data = try? JSONEncoder().encode(accounts),
			  let json = String(data: data, encoding: .utf8) else { return }
		KeychainHelper.write(key: Self.storageKey, value: json)
	}

	var currentId: String? { Auth.auth().currentUser?.email?.lowercased() }
	var current: SavedAccount? { accounts.first { $0.id == currentId } }
	var others: [SavedAccount] { accounts.filter { $0.id != currentId } }

	func saveLogin(email: String, password: String) {
		if let index = accounts.firstIndex(where: { $0.id == email.lowercased() }) {
			accounts[index].email = email
			accounts[index].password = password
		} else {
			accounts.append(SavedAccount(email: email, password: password))
		}
		persist()
	}

	func updateMeta(orgName: String?, role: String?) {
		guard let index = accounts.firstIndex(where: { $0.id == currentId }) else { return }
		accounts[index].orgName = orgName
		accounts[index].role = role
		persist()
	}

	func attachSIP(_ sip: SIPCredential) {
		guard let index = accounts.firstIndex(where: { $0.id == currentId }) else { return }
		accounts[index].sip = sip
		persist()
	}

	func remove(id: String) {
		accounts.removeAll { $0.id == id }
		persist()
	}

	func switchTo(_ id: String) async {
		guard switchingTo == nil, let account = accounts.first(where: { $0.id == id }) else { return }
		guard !account.password.isEmpty else {
			errorMessage = "Sign in to \(account.email) once to enable switching."
			return
		}
		switchingTo = id
		errorMessage = nil
		defer { switchingTo = nil }
		do {
			// A failed signIn leaves the previous Firebase user signed in,
			// so an outdated password degrades gracefully.
			try await MDSession.shared.signIn(email: account.email, password: account.password)
		} catch {
			errorMessage = "Couldn't switch to \(account.email) — the password may have changed. Remove the account and sign in again."
		}
	}

	/// Makes the SIP line match the now-current account's attachment.
	/// Clearing an unattached line only happens on an explicit account
	/// switch — a plain sign-in must not wipe a manually configured line
	/// that predates attachments (or a skip-login QR setup).
	func restoreSIPLine(cameFromAccountSwitch: Bool) {
		guard let account = current else { return }
		if let sip = account.sip {
			CoreContext.shared.doOnCoreQueue { core in
				let active = core.defaultAccount?.params?.identityAddress?.username ?? ""
				guard active != sip.username else { return }
				DispatchQueue.main.async { Self.provision(sip) }
			}
		} else if cameFromAccountSwitch {
			CoreContext.shared.doOnCoreQueue { core in
				core.clearAccounts()
				core.clearAllAuthInfo()
			}
		}
	}

	static func provision(_ sip: SIPCredential) {
		let viewModel = AccountLoginViewModel()
		viewModel.username = sip.username
		viewModel.passwd = sip.password
		viewModel.domain = sip.domain
		viewModel.transportType = sip.transport
		viewModel.displayName = sip.displayName
		viewModel.login()
	}
}

// MARK: - SIP credentials API

struct SIPCredentialsResponse: Decodable {
	let sipPassword: String?
	let endpoint: String?
	let ext: String?

	enum CodingKeys: String, CodingKey {
		case endpoint
		case sipPassword = "sip_password"
		case ext = "extension"
	}
}

extension AstradialAPI {
	func fetchSIPCredentials(id: String) async throws -> SIPCredentialsResponse {
		guard AstradialAPIConfig.isConfigured else { throw AstradialAPIError.notConfigured }
		var request = URLRequest(url: URL(string: "\(AstradialAPIConfig.base)/api/v1/users/\(id)/sip-credentials")!)
		request.setValue("Bearer \(try await PlatformAuth.shared.bearerToken())", forHTTPHeaderField: "Authorization")
		let (data, response) = try await AstradialHTTP.session.data(for: request)
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			throw AstradialAPIError.http(http.statusCode)
		}
		guard let creds = try? JSONDecoder().decode(SIPCredentialsResponse.self, from: data) else {
			throw AstradialAPIError.decodeError(endpoint: "sip-credentials", body: data)
		}
		return creds
	}
}

// MARK: - "Select SIP user" dropdown (Settings + onboarding)

struct SIPUserPickerSection: View {
	@ObservedObject var sipViewModel: AccountLoginViewModel
	@ObservedObject private var session = MDSession.shared
	@ObservedObject private var store = AccountStore.shared
	@State private var users: [OrgUser] = []
	@State private var loaded = false
	@State private var provisioningId: String?
	@State private var errorMessage: String?

	var body: some View {
		if session.isSignedIn {
			Section {
				if !loaded {
					HStack(spacing: 10) {
						ProgressView().controlSize(.small)
						Text("Loading SIP users…").foregroundStyle(.secondary)
					}
					.task { await load() }
				} else if sipUsers.isEmpty {
					Text("No SIP users in this organisation.")
						.foregroundStyle(.secondary)
				} else {
					Menu {
						ForEach(sipUsers) { user in
							Button {
								provision(user)
							} label: {
								if isAttached(user) {
									Label(menuTitle(user), systemImage: "checkmark")
								} else {
									Text(menuTitle(user))
								}
							}
						}
					} label: {
						HStack {
							Text("SIP User").foregroundStyle(.primary)
							Spacer()
							if provisioningId != nil {
								ProgressView().controlSize(.small)
							} else {
								Text(store.current?.sip?.chipName ?? "Select")
									.foregroundStyle(.secondary)
							}
							Image(systemName: "chevron.up.chevron.down")
								.font(.footnote)
								.foregroundStyle(.tertiary)
						}
					}
				}
				if let errorMessage {
					Text(errorMessage).font(.footnote).foregroundStyle(.red)
				}
			} header: {
				Text("Quick Connect")
			} footer: {
				Text("Pick your name to connect this iPhone as that extension — no password needed.")
			}
		}
	}

	// Human SIP users only: no AI agents, no mobile-number ring targets.
	private var sipUsers: [OrgUser] {
		users.filter {
			($0.routingType ?? "sip").lowercased() == "sip" &&
			($0.ringTarget ?? "ext").lowercased() != "phone"
		}
	}

	private func isAttached(_ user: OrgUser) -> Bool {
		guard let endpoint = user.asteriskEndpoint, !endpoint.isEmpty else { return false }
		return endpoint == store.current?.sip?.username
	}

	private func menuTitle(_ user: OrgUser) -> String {
		user.extensionNumber.map { "\(user.displayName) — \($0)" } ?? user.displayName
	}

	private func load() async {
		guard !loaded else { return }
		users = (try? await AstradialAPI.shared.fetchUsers()) ?? []
		loaded = true
	}

	private func provision(_ user: OrgUser) {
		guard provisioningId == nil else { return }
		provisioningId = user.id
		errorMessage = nil
		Task {
			defer { provisioningId = nil }
			do {
				let creds = try await AstradialAPI.shared.fetchSIPCredentials(id: user.id)
				guard let endpoint = creds.endpoint, !endpoint.isEmpty,
					  let password = creds.sipPassword, !password.isEmpty else {
					errorMessage = "\(user.displayName) has no SIP credentials on the server."
					return
				}
				sipViewModel.username = endpoint
				sipViewModel.passwd = password
				sipViewModel.domain = AstradialSIPDefaults.domain
				sipViewModel.transportType = AstradialSIPDefaults.transport
				sipViewModel.displayName = user.displayName
				sipViewModel.login()
			} catch {
				errorMessage = "Couldn't fetch SIP credentials: \(error.localizedDescription)"
			}
		}
	}
}

// MARK: - Accounts section (Settings)

struct AccountSwitcherSection: View {
	@ObservedObject private var store = AccountStore.shared
	@ObservedObject private var session = MDSession.shared
	@State private var showAddAccount = false

	var body: some View {
		Section {
			HStack(spacing: 12) {
				InitialsAvatar(name: session.displayName, size: 52)
				VStack(alignment: .leading) {
					Text(session.email ?? "Not signed in").font(.body.weight(.medium))
					Text(session.orgName.map { "\($0) · \(session.role ?? "member")" } ?? "")
						.font(.footnote).foregroundStyle(.secondary)
				}
			}
			ForEach(store.others) { account in
				Button {
					Task { await store.switchTo(account.id) }
				} label: {
					HStack(spacing: 12) {
						InitialsAvatar(name: account.email, size: 36)
						VStack(alignment: .leading) {
							Text(account.email).font(.subheadline).foregroundStyle(.primary)
							if let org = account.orgName, !org.isEmpty {
								Text(org).font(.footnote).foregroundStyle(.secondary)
							}
						}
						Spacer()
						if store.switchingTo == account.id {
							ProgressView().controlSize(.small)
						} else {
							Image(systemName: "arrow.left.arrow.right.circle")
								.foregroundStyle(.secondary)
						}
					}
				}
				.disabled(store.switchingTo != nil)
				.swipeActions(edge: .trailing, allowsFullSwipe: false) {
					Button("Remove", role: .destructive) { store.remove(id: account.id) }
				}
			}
			Button {
				showAddAccount = true
			} label: {
				Label("Add Account", systemImage: "person.crop.circle.badge.plus")
			}
			.sheet(isPresented: $showAddAccount) {
				NavigationStack {
					MDLoginView(onSignedIn: { showAddAccount = false })
						.navigationTitle("Add Account")
						.navigationBarTitleDisplayMode(.inline)
						.toolbar {
							ToolbarItem(placement: .topBarLeading) {
								Button("Cancel") { showAddAccount = false }
							}
						}
				}
			}
			Button("Sign Out", role: .destructive) { session.signOut() }
		} header: {
			Text("Accounts")
		} footer: {
			if let error = store.errorMessage {
				Text(error).foregroundStyle(.red)
			} else if !store.others.isEmpty {
				Text("Switching also restores that organisation's SIP user on this phone.")
			}
		}
	}
}
