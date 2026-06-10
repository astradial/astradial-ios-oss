/*
 * Astradial MD (Managing Director) module.
 *
 * Analytics dashboard in Apple Health style (Summary cards + Swift
 * Charts), backed by the AstraPBX Call Logs API
 * (GET /api/v1/calls, X-API-Key auth), gated by Firebase Auth.
 * Also hosts the iOS-Settings-style settings page (SIP account via
 * Linphone, API connection, MD account).
 */

import SwiftUI
import Charts
import AVFoundation
import FirebaseAuth
import linphonesw

// MARK: - API client

struct AstradialAPIConfig {
	@AppStorage("astradial_api_base") static var storedBase: String = "https://stagepbx.astradial.com"

	static var base: String {
		UserDefaults.standard.string(forKey: "astradial_api_base") ?? "https://stagepbx.astradial.com"
	}

	static var apiKey: String {
		get { KeychainHelper.read(key: "astradial_api_key") ?? "" }
		set { KeychainHelper.write(key: "astradial_api_key", value: newValue) }
	}

	static var isConfigured: Bool { !apiKey.isEmpty }
}

enum KeychainHelper {
	static func write(key: String, value: String) {
		let data = Data(value.utf8)
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "com.astradial.phone",
			kSecAttrAccount as String: key
		]
		SecItemDelete(query as CFDictionary)
		guard !value.isEmpty else { return }
		var attributes = query
		attributes[kSecValueData as String] = data
		SecItemAdd(attributes as CFDictionary, nil)
	}

	static func read(key: String) -> String? {
		let query: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: "com.astradial.phone",
			kSecAttrAccount as String: key,
			kSecReturnData as String: true,
			kSecMatchLimit as String: kSecMatchLimitOne
		]
		var item: CFTypeRef?
		guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
			  let data = item as? Data else { return nil }
		return String(data: data, encoding: .utf8)
	}
}

struct CDRCall: Decodable, Identifiable {
	let id: Int
	let calldate: String
	let src: String?
	let dst: String?
	let disposition: String?
	let duration: Int?
	let billsec: Int?
	let direction: String?
	let waitTime: Int?
	let answeredBy: String?
	let recordingUrl: String?
	let queueName: String?

	enum CodingKeys: String, CodingKey {
		case id, calldate, src, dst, disposition, duration, billsec, direction
		case waitTime = "wait_time"
		case answeredBy = "answered_by"
		case recordingUrl = "recording_url"
		case queueName = "queue_name"
	}

	var date: Date {
		ISO8601DateFormatter().date(from: calldate)
			?? Self.fallbackFormatter.date(from: calldate)
			?? .distantPast
	}

	var isMissed: Bool { disposition != "ANSWERED" && direction == "inbound" }

	static let fallbackFormatter: DateFormatter = {
		let formatter = DateFormatter()
		formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
		formatter.timeZone = TimeZone(identifier: "UTC")
		return formatter
	}()
}

struct CDRResponse: Decodable {
	struct Pagination: Decodable {
		let total: Int
		let hasMore: Bool?
		enum CodingKeys: String, CodingKey {
			case total
			case hasMore = "has_more"
		}
	}
	let data: [CDRCall]
	let pagination: Pagination?
}

enum AstradialAPIError: LocalizedError {
	case notConfigured
	case http(Int)

	var errorDescription: String? {
		switch self {
		case .notConfigured: return "API key not configured. Open Settings to connect."
		case .http(let code): return "Astradial API error (HTTP \(code))."
		}
	}
}

actor AstradialAPI {
	static let shared = AstradialAPI()

	func fetchCalls(from: Date, to: Date, maxRecords: Int = 1000) async throws -> [CDRCall] {
		guard AstradialAPIConfig.isConfigured else { throw AstradialAPIError.notConfigured }
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd"

		var calls: [CDRCall] = []
		var offset = 0
		while calls.count < maxRecords {
			var components = URLComponents(string: "\(AstradialAPIConfig.base)/api/v1/calls")!
			components.queryItems = [
				URLQueryItem(name: "limit", value: "200"),
				URLQueryItem(name: "offset", value: String(offset)),
				URLQueryItem(name: "date_from", value: dateFormatter.string(from: from)),
				URLQueryItem(name: "date_to", value: dateFormatter.string(from: to))
			]
			var request = URLRequest(url: components.url!)
			request.setValue(AstradialAPIConfig.apiKey, forHTTPHeaderField: "X-API-Key")
			let (data, response) = try await URLSession.shared.data(for: request)
			if let http = response as? HTTPURLResponse, http.statusCode != 200 {
				throw AstradialAPIError.http(http.statusCode)
			}
			let page = try JSONDecoder().decode(CDRResponse.self, from: data)
			calls.append(contentsOf: page.data)
			if page.data.isEmpty || page.pagination?.hasMore != true { break }
			offset += 200
		}
		return calls
	}
}

// MARK: - Analytics aggregation

enum AnalyticsRange: String, CaseIterable {
	case day = "D"
	case week = "W"
	case month = "M"

	var title: String {
		switch self {
		case .day: return "Today"
		case .week: return "Last 7 Days"
		case .month: return "Last 30 Days"
		}
	}

	var start: Date {
		let calendar = Calendar.current
		switch self {
		case .day: return calendar.startOfDay(for: .now)
		case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: .now))!
		case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now))!
		}
	}
}

struct BucketStat: Identifiable {
	let bucket: Date
	var total: Int = 0
	var missed: Int = 0
	var answered: Int = 0
	var pickupSum: Int = 0
	var id: Date { bucket }

	var avgPickup: Double { answered > 0 ? Double(pickupSum) / Double(answered) : 0 }
}

@MainActor
final class AnalyticsViewModel: ObservableObject {
	@Published var range: AnalyticsRange = .week {
		didSet { Task { await reload() } }
	}
	@Published var buckets: [BucketStat] = []
	@Published var recentCalls: [CDRCall] = []
	@Published var totalCalls = 0
	@Published var totalMissed = 0
	@Published var avgPickupSeconds: Double = 0
	@Published var isSampleData = true
	@Published var errorMessage: String?
	@Published var loading = false

	func reload() async {
		loading = true
		defer { loading = false }
		do {
			let calls = try await AstradialAPI.shared.fetchCalls(from: range.start, to: .now)
			apply(calls: calls)
			isSampleData = false
			errorMessage = nil
		} catch {
			apply(calls: Self.sampleCalls(for: range))
			isSampleData = true
			errorMessage = error.localizedDescription
		}
	}

	private func apply(calls: [CDRCall]) {
		let calendar = Calendar.current
		let byHour = range == .day
		var dict: [Date: BucketStat] = [:]

		// Pre-seed buckets so the chart has a continuous axis.
		var cursor = range.start
		let end = Date.now
		while cursor <= end {
			dict[cursor] = BucketStat(bucket: cursor)
			cursor = calendar.date(byAdding: byHour ? .hour : .day, value: 1, to: cursor)!
		}

		for call in calls {
			let bucket = byHour
				? calendar.date(bySetting: .minute, value: 0, of: calendar.date(bySetting: .second, value: 0, of: call.date) ?? call.date) ?? call.date
				: calendar.startOfDay(for: call.date)
			var stat = dict[bucket] ?? BucketStat(bucket: bucket)
			stat.total += 1
			if call.isMissed { stat.missed += 1 }
			if call.disposition == "ANSWERED" {
				stat.answered += 1
				stat.pickupSum += call.waitTime ?? 0
			}
			dict[bucket] = stat
		}

		buckets = dict.values.sorted { $0.bucket < $1.bucket }
		totalCalls = buckets.reduce(0) { $0 + $1.total }
		totalMissed = buckets.reduce(0) { $0 + $1.missed }
		let answered = buckets.reduce(0) { $0 + $1.answered }
		let pickupSum = buckets.reduce(0) { $0 + $1.pickupSum }
		avgPickupSeconds = answered > 0 ? Double(pickupSum) / Double(answered) : 0
		recentCalls = Array(calls.sorted { $0.date > $1.date }.prefix(25))
	}

	// Deterministic sample data so the dashboard demos before the API is connected.
	static func sampleCalls(for range: AnalyticsRange) -> [CDRCall] {
		let calendar = Calendar.current
		var calls: [CDRCall] = []
		let days = range == .day ? 1 : (range == .week ? 7 : 30)
		var id = 1
		for day in 0..<days {
			let base = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: .now))!
			let volume = 14 + (day * 7) % 18
			for n in 0..<volume {
				let hour = 9 + (n * 37) % 9
				let date = calendar.date(bySettingHour: hour, minute: (n * 13) % 60, second: 0, of: base)!
				let missed = (n * 31 + day) % 5 == 0
				calls.append(CDRCall(
					id: id, calldate: ISO8601DateFormatter().string(from: date),
					src: "+91 98\(40000000 + n * 137)", dst: "80659780\(10 + n % 80)",
					disposition: missed ? "NO ANSWER" : "ANSWERED",
					duration: missed ? 18 : 95 + (n * 17) % 300,
					billsec: missed ? 0 : 80 + (n * 17) % 280,
					direction: "inbound",
					waitTime: 4 + (n * 7 + day * 3) % 18,
					answeredBy: missed ? nil : "100\(1 + n % 4)",
					recordingUrl: nil, queueName: nil
				))
				id += 1
			}
		}
		return calls
	}
}

// MARK: - Health-style analytics tab

struct AnalyticsTabView: View {
	@StateObject private var viewModel = AnalyticsViewModel()
	@StateObject private var session = MDSession.shared
	@State private var showSettings = false

	var body: some View {
		NavigationStack {
			Group {
				if session.isSignedIn || session.demoMode || !session.firebaseAvailable {
					dashboard
				} else {
					MDLoginView()
				}
			}
			.navigationTitle("Summary")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { showSettings = true } label: {
						InitialsAvatar(name: session.displayName, size: 32)
					}
				}
			}
			.sheet(isPresented: $showSettings) {
				AstradialSettingsView()
			}
		}
		.task { await viewModel.reload() }
	}

	private var dashboard: some View {
		ScrollView {
			VStack(spacing: 14) {
				if viewModel.isSampleData {
					sampleBanner
				}

				Picker("Range", selection: $viewModel.range) {
					ForEach(AnalyticsRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
				}
				.pickerStyle(.segmented)

				HealthCard(
					title: "Total Calls", icon: "phone.fill", tint: .blue,
					value: "\(viewModel.totalCalls)", unit: "calls", caption: viewModel.range.title
				) {
					Chart(viewModel.buckets) {
						BarMark(
							x: .value("Date", $0.bucket, unit: viewModel.range == .day ? .hour : .day),
							y: .value("Calls", $0.total)
						)
						.foregroundStyle(.blue.gradient)
						.cornerRadius(2)
					}
					.frame(height: 110)
				}

				HealthCard(
					title: "Missed Calls", icon: "phone.arrow.down.left.fill", tint: .red,
					value: "\(viewModel.totalMissed)", unit: "missed", caption: viewModel.range.title
				) {
					Chart(viewModel.buckets) {
						BarMark(
							x: .value("Date", $0.bucket, unit: viewModel.range == .day ? .hour : .day),
							y: .value("Missed", $0.missed)
						)
						.foregroundStyle(.red.gradient)
						.cornerRadius(2)
					}
					.frame(height: 90)
				}

				HealthCard(
					title: "Avg Pickup Time", icon: "timer", tint: .green,
					value: String(format: "%.0f", viewModel.avgPickupSeconds), unit: "sec", caption: viewModel.range.title
				) {
					Chart(viewModel.buckets.filter { $0.answered > 0 }) {
						LineMark(
							x: .value("Date", $0.bucket, unit: viewModel.range == .day ? .hour : .day),
							y: .value("Seconds", $0.avgPickup)
						)
						.interpolationMethod(.catmullRom)
						.foregroundStyle(.green)
						PointMark(
							x: .value("Date", $0.bucket, unit: viewModel.range == .day ? .hour : .day),
							y: .value("Seconds", $0.avgPickup)
						)
						.foregroundStyle(.green)
						.symbolSize(18)
					}
					.frame(height: 110)
				}

				HealthCard(
					title: "User Sessions", icon: "person.badge.clock.fill", tint: .purple,
					value: "—", unit: "", caption: "Login / logout times"
				) {
					Text("Requires the user-sessions report API (server-side, in progress). Will list each user's login and logout times for the day.")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}

				recentCallsCard
			}
			.padding(.horizontal)
			.padding(.bottom, 24)
		}
		.background(Color(.systemGroupedBackground))
		.refreshable { await viewModel.reload() }
	}

	private var sampleBanner: some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			Text(viewModel.errorMessage ?? "Showing sample data")
				.font(.footnote)
			Spacer()
			Button("Connect") { showSettings = true }
				.font(.footnote.weight(.semibold))
		}
		.padding(10)
		.background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
	}

	private var recentCallsCard: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack {
				Label("Recent Calls", systemImage: "list.bullet")
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.indigo)
				Spacer()
			}
			.padding([.horizontal, .top], 14)
			.padding(.bottom, 6)

			ForEach(viewModel.recentCalls.prefix(10)) { call in
				OrgCallRow(call: call)
				if call.id != viewModel.recentCalls.prefix(10).last?.id {
					Divider().padding(.leading, 14)
				}
			}
		}
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
	}
}

struct HealthCard<ChartContent: View>: View {
	let title: String
	let icon: String
	let tint: Color
	let value: String
	let unit: String
	let caption: String
	@ViewBuilder var chart: ChartContent

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack {
				Label(title, systemImage: icon)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(tint)
				Spacer()
				Image(systemName: "chevron.right")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(Color(.systemGray3))
			}
			HStack(alignment: .firstTextBaseline, spacing: 3) {
				Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
				Text(unit).font(.subheadline).foregroundStyle(.secondary)
				Spacer()
				Text(caption).font(.caption).foregroundStyle(.secondary)
			}
			chart
		}
		.padding(14)
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
	}
}

struct OrgCallRow: View {
	let call: CDRCall
	@State private var player: AVPlayer?
	@State private var playing = false

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: call.isMissed ? "phone.arrow.down.left.fill" : (call.direction == "outbound" ? "phone.arrow.up.right.fill" : "phone.fill.arrow.down.left"))
				.foregroundStyle(call.isMissed ? .red : .green)
				.frame(width: 24)
			VStack(alignment: .leading, spacing: 1) {
				Text(call.src ?? "Unknown").font(.subheadline.weight(.medium))
				Text("\(call.dst ?? "") · \(call.disposition ?? "")")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Text(call.date, style: .time).font(.caption).foregroundStyle(.secondary)
			if call.recordingUrl != nil {
				Button {
					togglePlayback()
				} label: {
					Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
						.font(.title3)
						.foregroundStyle(.indigo)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 8)
	}

	private func togglePlayback() {
		if playing {
			player?.pause()
			playing = false
			return
		}
		guard let path = call.recordingUrl,
			  let url = URL(string: path.hasPrefix("http") ? path : AstradialAPIConfig.base + path) else { return }
		let asset = AVURLAsset(url: url, options: [
			"AVURLAssetHTTPHeaderFieldsKey": ["X-API-Key": AstradialAPIConfig.apiKey]
		])
		player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
		player?.play()
		playing = true
	}
}

// MARK: - Firebase auth session

@MainActor
final class MDSession: ObservableObject {
	static let shared = MDSession()

	@Published var isSignedIn = false
	@Published var email: String?
	@Published var demoMode = ProcessInfo.processInfo.environment["MD_DEMO"] == "1"
	let firebaseAvailable: Bool

	var displayName: String { email ?? "MD" }

	private init() {
		// Firebase is configured by CoreContext at startup with the bundled plist.
		firebaseAvailable = true
		isSignedIn = Auth.auth().currentUser != nil
		email = Auth.auth().currentUser?.email
		_ = Auth.auth().addStateDidChangeListener { [weak self] _, user in
			Task { @MainActor in
				self?.isSignedIn = user != nil
				self?.email = user?.email
			}
		}
	}

	func signIn(email: String, password: String) async throws {
		try await Auth.auth().signIn(withEmail: email, password: password)
	}

	func signOut() {
		try? Auth.auth().signOut()
	}
}

struct MDLoginView: View {
	@State private var email = ""
	@State private var password = ""
	@State private var error: String?
	@State private var busy = false

	var body: some View {
		VStack(spacing: 16) {
			Spacer()
			Image(systemName: "chart.bar.xaxis")
				.font(.system(size: 44))
				.foregroundStyle(.indigo)
			Text("MD Analytics")
				.font(.title2.weight(.semibold))
			Text("Sign in to monitor company call activity.")
				.font(.subheadline)
				.foregroundStyle(.secondary)

			VStack(spacing: 10) {
				TextField("Email", text: $email)
					.textContentType(.username)
					.keyboardType(.emailAddress)
					.autocapitalization(.none)
					.padding(12)
					.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
				SecureField("Password", text: $password)
					.textContentType(.password)
					.padding(12)
					.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
			}
			.padding(.horizontal)

			if let error {
				Text(error).font(.footnote).foregroundStyle(.red)
			}

			Button {
				busy = true
				Task {
					defer { busy = false }
					do {
						try await MDSession.shared.signIn(email: email, password: password)
					} catch {
						self.error = error.localizedDescription
					}
				}
			} label: {
				Text(busy ? "Signing in…" : "Sign In")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.disabled(busy || email.isEmpty || password.isEmpty)
			.padding(.horizontal)

#if DEBUG
			Button("Continue in demo mode") {
				MDSession.shared.demoMode = true
			}
			.font(.footnote)
			.padding(.top, 4)
#endif

			Spacer()
			Spacer()
		}
		.background(Color(.systemGroupedBackground))
	}
}

// MARK: - Settings (iOS Settings style)

struct AstradialSettingsView: View {
	@Environment(\.dismiss) private var dismiss
	@StateObject private var session = MDSession.shared
	@StateObject private var sipViewModel = AccountLoginViewModel()

	@AppStorage("astradial_api_base") private var apiBase = "https://stagepbx.astradial.com"
	@State private var apiKey = AstradialAPIConfig.apiKey
	@State private var sipRegistered = false
	@State private var sipIdentity = ""

	var body: some View {
		NavigationStack {
			Form {
				Section {
					HStack(spacing: 12) {
						InitialsAvatar(name: session.displayName, size: 52)
						VStack(alignment: .leading) {
							Text(session.email ?? "Not signed in").font(.body.weight(.medium))
							Text("Managing Director").font(.footnote).foregroundStyle(.secondary)
						}
					}
					if session.isSignedIn {
						Button("Sign Out", role: .destructive) { session.signOut() }
					}
				}

				Section {
					LabeledContent("Status", value: sipRegistered ? "Registered" : "Not Registered")
					if !sipIdentity.isEmpty {
						LabeledContent("Identity", value: sipIdentity)
					}
					TextField("Username", text: $sipViewModel.username)
						.autocapitalization(.none)
					SecureField("Password", text: $sipViewModel.passwd)
					TextField("Domain (e.g. stagesip.astradial.com:5080)", text: $sipViewModel.domain)
						.autocapitalization(.none)
					Picker("Transport", selection: $sipViewModel.transportType) {
						Text("UDP").tag("UDP")
						Text("TCP").tag("TCP")
						Text("TLS").tag("TLS")
					}
					Button("Apply & Register") {
						sipViewModel.login()
						refreshSIPStatus()
					}
					.disabled(sipViewModel.username.isEmpty || sipViewModel.domain.isEmpty)
				} header: {
					Text("SIP Account (Linphone)")
				} footer: {
					Text("Registers this phone against the Astradial PBX. Use the credentials from the editor's Users page.")
				}

				Section {
					TextField("API Base URL", text: $apiBase)
						.autocapitalization(.none)
						.keyboardType(.URL)
					SecureField("API Key (ak_…)", text: $apiKey)
						.onChange(of: apiKey) { _, newValue in
							AstradialAPIConfig.apiKey = newValue
						}
				} header: {
					Text("Astradial API")
				} footer: {
					Text("Create an API key in the dashboard under API & Webhooks → API Keys. Used for analytics and call reports. Stored in the keychain.")
				}

				Section("About") {
					LabeledContent("App", value: "Astradial Phone")
					LabeledContent("Engine", value: "Linphone SDK \(Core.getVersion)")
				}
			}
			.navigationTitle("Settings")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
			.onAppear(perform: refreshSIPStatus)
		}
	}

	private func refreshSIPStatus() {
		CoreContext.shared.doOnCoreQueue { core in
			let registered = core.defaultAccount?.state == .Ok
			let identity = core.defaultAccount?.params?.identityAddress?.asStringUriOnly() ?? ""
			DispatchQueue.main.async {
				sipRegistered = registered
				sipIdentity = identity
			}
		}
	}
}
