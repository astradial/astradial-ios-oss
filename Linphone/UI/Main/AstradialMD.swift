/*
 * Astradial MD (Managing Director) module — "Pulse" dashboard.
 *
 * Hospital-MD analytics in Apple Health style. Card order per Hari
 * (June 2026): Today's Pulse → Recovery Discipline → New Patients &
 * Follow-Ups → Call Volume Trend → Today by Hour (today vs yesterday).
 * Each graph carries a data-driven insight line. Heavy aggregation
 * runs off the main actor and the last snapshot is cached so the tab
 * opens instantly. Data: /api/v1/calls + /api/v1/tickets (X-API-Key).
 * Firebase Auth gates the tab (owner = signed-in user for now).
 */

import SwiftUI
import Charts
import FirebaseAuth
import linphonesw

// MARK: - API config & keychain

/// Cache-free session for all Astradial API traffic. Live authenticated
/// JSON must not hit the CFNetwork URL cache — caching it both leaks
/// responses to disk and spams "cfurl_cache_response UNIQUE constraint"
/// sqlite noise into the logs.
enum AstradialHTTP {
	static let session: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.urlCache = nil
		configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
		return URLSession(configuration: configuration)
	}()
}

struct AstradialAPIConfig {
	@AppStorage("astradial_api_base") static var storedBase: String = "https://devpbx.astradial.com"

	static var base: String {
		UserDefaults.standard.string(forKey: "astradial_api_base") ?? "https://devpbx.astradial.com"
	}

	// The Firebase login IS the credential: the app exchanges the
	// Firebase ID token for an org-scoped platform JWT via
	// POST /api/v1/auth/user-login. No API keys on devices.
	static var isConfigured: Bool { Auth.auth().currentUser != nil }
}

struct PlatformUser: Decodable, Sendable {
	let role: String?
	let name: String?
	let email: String?
	let orgName: String?
	let ext: String?

	enum CodingKeys: String, CodingKey {
		case role, name, email
		case orgName = "org_name"
		case ext = "extension"
	}
}

/// Exchanges the Firebase ID token for the platform's role-enriched JWT
/// (24h) and caches it. All API calls authenticate with this JWT.
actor PlatformAuth {
	static let shared = PlatformAuth()

	private var token: String?
	private var expiry = Date.distantPast

	func bearerToken() async throws -> String {
		if let token, expiry > Date.now.addingTimeInterval(120) { return token }
		guard let firebaseUser = Auth.auth().currentUser else { throw AstradialAPIError.notConfigured }
		let idToken = try await firebaseUser.getIDToken()

		var request = URLRequest(url: URL(string: "\(AstradialAPIConfig.base)/api/v1/auth/user-login")!)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = try JSONSerialization.data(withJSONObject: ["firebase_token": idToken])
		let (data, response) = try await AstradialHTTP.session.data(for: request)
		guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
			throw AstradialAPIError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
		}
		struct LoginResponse: Decodable {
			let token: String
			let user: PlatformUser?
		}
		guard let decoded = try? JSONDecoder().decode(LoginResponse.self, from: data) else {
			throw AstradialAPIError.decodeError(endpoint: "login", body: data)
		}
		token = decoded.token
		expiry = Date.now.addingTimeInterval(23 * 3600)
		if let user = decoded.user {
			await MDSession.shared.applyPlatformUser(user)
		}
		return decoded.token
	}

	func reset() {
		token = nil
		expiry = .distantPast
	}
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

// MARK: - CDR model

struct CDRCall: Decodable, Identifiable, Sendable {
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
	let linkedid: String?

	enum CodingKeys: String, CodingKey {
		case id, calldate, src, dst, disposition, duration, billsec, direction, linkedid
		case waitTime = "wait_time"
		case answeredBy = "answered_by"
		case recordingUrl = "recording_url"
		case queueName = "queue_name"
	}

	var date: Date {
		// The API sends fractional seconds ("2026-06-12T01:49:51.000Z") —
		// plain ISO8601DateFormatter rejects those, which silently turned
		// every call into .distantPast and zeroed all analytics.
		if let date = Self.isoFractional.date(from: calldate) { return date }
		if let date = Self.isoPlain.date(from: calldate) { return date }
		// Strings carrying an explicit offset/Z are UTC-anchored; naive
		// MariaDB-style datetimes are interpreted as server-local (IST).
		let hasOffset = calldate.hasSuffix("Z") || calldate.contains("+")
		for formatter in (hasOffset ? Self.utcFormatters : Self.naiveFormatters) {
			if let date = formatter.date(from: calldate) { return date }
		}
		return .distantPast
	}

	static let isoFractional: ISO8601DateFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()
	static let isoPlain = ISO8601DateFormatter()

	var isInbound: Bool { direction != "outbound" }
	var isMissed: Bool { disposition != "ANSWERED" && isInbound }

	static let fallbackFormatter: DateFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true)
	static let utcFormatters = [fallbackFormatter, makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", utc: true)]
	static let naiveFormatters = [
		makeFormatter("yyyy-MM-dd'T'HH:mm:ss", utc: false),
		makeFormatter("yyyy-MM-dd HH:mm:ss", utc: false)
	]

	private static func makeFormatter(_ format: String, utc: Bool) -> DateFormatter {
		let formatter = DateFormatter()
		formatter.dateFormat = format
		formatter.locale = Locale(identifier: "en_US_POSIX")
		if utc { formatter.timeZone = TimeZone(identifier: "UTC") }
		return formatter
	}
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
	case decode(String)

	var errorDescription: String? {
		switch self {
		case .notConfigured: return "Sign in with your Astradial account to load company data."
		case .http(let code): return "Astradial API error (HTTP \(code))."
		case .decode(let detail): return "Unexpected server response — \(detail)"
		}
	}

	static func decodeError(endpoint: String, body: Data) -> AstradialAPIError {
		let prefix = String(decoding: body.prefix(120), as: UTF8.self)
			.replacingOccurrences(of: "\n", with: " ")
		return .decode("\(endpoint): \(prefix)")
	}
}

actor AstradialAPI {
	static let shared = AstradialAPI()

	func fetchCalls(from: Date, to: Date, maxRecords: Int = 3000) async throws -> [CDRCall] {
		guard AstradialAPIConfig.isConfigured else { throw AstradialAPIError.notConfigured }
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd"
		// date_to is padded a day in case the server treats it as an
		// exclusive midnight boundary.
		let paddedTo = Calendar.current.date(byAdding: .day, value: 1, to: to) ?? to

		let dated = try await fetchCallPages(query: [
			URLQueryItem(name: "date_from", value: dateFormatter.string(from: from)),
			URLQueryItem(name: "date_to", value: dateFormatter.string(from: paddedTo))
		], maxRecords: maxRecords)
		if !dated.isEmpty { return dated }

		// Self-heal: some deployments mis-parse the date filters and
		// return nothing. Refetch newest-first without dates and filter
		// client-side instead.
		let all = try await fetchCallPages(query: [], maxRecords: maxRecords)
		let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: from) ?? from
		return all.filter { $0.date >= cutoff }
	}

	private func fetchCallPages(query: [URLQueryItem], maxRecords: Int) async throws -> [CDRCall] {
		var calls: [CDRCall] = []
		var offset = 0
		while calls.count < maxRecords {
			var components = URLComponents(string: "\(AstradialAPIConfig.base)/api/v1/calls")!
			components.queryItems = [
				URLQueryItem(name: "limit", value: "200"),
				URLQueryItem(name: "offset", value: String(offset))
			] + query
			var request = URLRequest(url: components.url!)
			request.setValue("Bearer \(try await PlatformAuth.shared.bearerToken())", forHTTPHeaderField: "Authorization")
			let (data, response) = try await AstradialHTTP.session.data(for: request)
			if let http = response as? HTTPURLResponse, http.statusCode != 200 {
				throw AstradialAPIError.http(http.statusCode)
			}
			guard let page = try? JSONDecoder().decode(CDRResponse.self, from: data) else {
				throw AstradialAPIError.decodeError(endpoint: "calls", body: data)
			}
			calls.append(contentsOf: page.data)
			if page.data.isEmpty || page.pagination?.hasMore != true { break }
			offset += 200
		}
		return calls
	}
}

// MARK: - Pulse aggregation (pure, runs off-main)

struct HourStat: Identifiable, Sendable {
	let hour: Date
	var total = 0
	var missed = 0
	var id: Date { hour }
}

struct DayStat: Identifiable, Sendable {
	let day: Date
	var total = 0
	var missed = 0
	var outbound = 0
	var newCallers = 0
	var id: Date { day }
}

struct PulseSnapshot: Sendable {
	var todayInbound = 0
	var todayAnswered = 0
	var todayMissed = 0
	var answerRate: Double = 1.0
	var yesterdayInbound = 0
	var yesterdayMissed = 0
	var unrecoveredCount = 0
	var recoveryRate: Double = 0
	var medianRecoveryMinutes: Int?
	var hourly: [HourStat] = []
	var yesterdayHourly: [HourStat] = []
	var daily: [DayStat] = []
	var weekOverWeek: Double?
	var newCallersLast7 = 0
	var outboundPerDayLast7: Double = 0
	var hourlyInsight = ""
	var trendInsight = ""
	var growthInsight = ""

	static func compute(calls: [CDRCall], tickets: [Ticket], windowDays: Int = 7) -> PulseSnapshot {
		var snap = PulseSnapshot()
		let calendar = Calendar.current
		let todayStart = calendar.startOfDay(for: .now)
		let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!

		// --- Today's pulse (inbound only) ---
		let todayCalls = calls.filter { $0.date >= todayStart && $0.isInbound }
		snap.todayInbound = todayCalls.count
		snap.todayAnswered = todayCalls.filter { $0.disposition == "ANSWERED" }.count
		snap.todayMissed = snap.todayInbound - snap.todayAnswered
		snap.answerRate = snap.todayInbound > 0 ? Double(snap.todayAnswered) / Double(snap.todayInbound) : 1.0

		// --- Recovery (tickets) ---
		let actionable = tickets.filter { ($0.status == "open" || $0.status == "in_progress") && $0.callbackFoundAt == nil }
		snap.unrecoveredCount = actionable.count

		let weekAgo = calendar.date(byAdding: .day, value: -windowDays, to: .now)!
		let recentTickets = tickets.filter { ($0.lastCallDate ?? .distantPast) >= weekAgo }
		let recovered = recentTickets.filter { $0.callbackDate != nil }
		snap.recoveryRate = recentTickets.isEmpty ? 0 : Double(recovered.count) / Double(recentTickets.count)
		let recoveryGaps = recovered.compactMap { ticket -> Int? in
			guard let callback = ticket.callbackDate, let miss = ticket.lastCallDate else { return nil }
			return max(0, Int(callback.timeIntervalSince(miss) / 60))
		}.sorted()
		snap.medianRecoveryMinutes = recoveryGaps.isEmpty ? nil : recoveryGaps[recoveryGaps.count / 2]

		// --- Hourly: today + yesterday (inbound) ---
		func hourlyStats(dayStart: Date, until: Date, source: [CDRCall]) -> [HourStat] {
			var hours: [Date: HourStat] = [:]
			for offset in 0..<24 {
				if let hour = calendar.date(byAdding: .hour, value: offset, to: dayStart), hour <= until {
					hours[hour] = HourStat(hour: hour)
				}
			}
			for call in source {
				let hour = calendar.dateInterval(of: .hour, for: call.date)?.start ?? call.date
				var stat = hours[hour] ?? HourStat(hour: hour)
				stat.total += 1
				if call.isMissed { stat.missed += 1 }
				hours[hour] = stat
			}
			return hours.values.sorted { $0.hour < $1.hour }
		}
		snap.hourly = hourlyStats(dayStart: todayStart, until: .now, source: todayCalls)
		let yesterdayCalls = calls.filter { $0.date >= yesterdayStart && $0.date < todayStart && $0.isInbound }
		// Yesterday's overlay is shifted onto TODAY's hour axis so both series share one x-scale.
		snap.yesterdayHourly = hourlyStats(
			dayStart: yesterdayStart,
			until: todayStart.addingTimeInterval(-1),
			source: yesterdayCalls
		).map { stat in
			var shifted = HourStat(hour: stat.hour.addingTimeInterval(86_400))
			shifted.total = stat.total
			shifted.missed = stat.missed
			return shifted
		}

		// --- Daily series over 30 days ---
		var days: [Date: DayStat] = [:]
		var cursor = calendar.date(byAdding: .day, value: -29, to: todayStart)!
		while cursor <= todayStart {
			days[cursor] = DayStat(day: cursor)
			cursor = calendar.date(byAdding: .day, value: 1, to: cursor)!
		}
		var firstSeen: Set<String> = []
		for call in calls.sorted(by: { $0.date < $1.date }) {
			let day = calendar.startOfDay(for: call.date)
			var stat = days[day] ?? DayStat(day: day)
			if call.isInbound {
				stat.total += 1
				if call.isMissed { stat.missed += 1 }
				if let src = call.src, !src.isEmpty, !firstSeen.contains(src) {
					firstSeen.insert(src)
					stat.newCallers += 1
				}
			} else {
				stat.outbound += 1
			}
			days[day] = stat
		}
		snap.daily = days.values.sorted { $0.day < $1.day }

		// Week-over-week compares COMPLETE days only — including today's
		// partial day would read artificially negative every morning.
		let completeDays = Array(snap.daily.dropLast())
		let last7 = Array(completeDays.suffix(windowDays))
		let prior7 = Array(completeDays.dropLast(windowDays).suffix(windowDays))
		let last7Total = last7.reduce(0) { $0 + $1.total }
		let prior7Total = prior7.reduce(0) { $0 + $1.total }
		snap.weekOverWeek = prior7Total > 0 ? (Double(last7Total) / Double(prior7Total)) - 1.0 : nil
		snap.newCallersLast7 = last7.reduce(0) { $0 + $1.newCallers }
		snap.outboundPerDayLast7 = last7.isEmpty ? 0 : Double(last7.reduce(0) { $0 + $1.outbound }) / Double(last7.count)

		if let yesterday = completeDays.last {
			snap.yesterdayInbound = yesterday.total
			snap.yesterdayMissed = yesterday.missed
		}

		snap.computeInsights(last7Total: last7Total, prior7Total: prior7Total)
		return snap
	}

	private mutating func computeInsights(last7Total: Int, prior7Total: Int) {
		let hourFormatter = DateFormatter()
		hourFormatter.dateFormat = "h a"

		if todayMissed == 0 {
			hourlyInsight = todayInbound == 0
				? "No calls yet today."
				: "No leaks today — every hour fully answered. Keep it up."
		} else if let worst = hourly.max(by: { $0.missed < $1.missed }), worst.missed > 0 {
			let windowStart = hourFormatter.string(from: worst.hour)
			let share = Int(Double(worst.missed) / Double(max(todayMissed, 1)) * 100)
			hourlyInsight = "Worst window: \(windowStart) — \(worst.missed) of today's \(todayMissed) missed calls (\(share)%). If this window is red most days, add one operator there."
		}

		if let wow = weekOverWeek {
			let pct = Int(abs(wow) * 100)
			if wow >= 0.05 {
				trendInsight = "Calls up \(pct)% vs last week (\(last7Total) vs \(prior7Total)). More calls = more revenue — make sure staffing keeps pace."
			} else if wow <= -0.05 {
				trendInsight = "Calls down \(pct)% vs last week (\(last7Total) vs \(prior7Total)). Falling demand or a routing problem — check DIDs and marketing before it shows in billing."
			} else {
				trendInsight = "Volume steady vs last week (\(last7Total) vs \(prior7Total)). Growth needs new demand — see new callers above."
			}
		} else {
			trendInsight = "Collecting history — week-over-week comparison appears after 14 days of data."
		}

		// "New" honestly means: no call from this number in the last 30 days.
		let outboundAvg = Int(outboundPerDayLast7.rounded())
		if newCallersLast7 > 0 && outboundAvg < max(2, newCallersLast7 / 7) {
			growthInsight = "\(newCallersLast7) numbers not seen in 30 days called this week (≈ new patients), but staff average only \(outboundAvg) outbound calls/day. Every uncalled new patient is a lost repeat visit — set a daily call-back quota."
		} else if newCallersLast7 > 0 {
			growthInsight = "\(newCallersLast7) first-time numbers (30-day basis) this week and \(outboundAvg) outbound calls/day — follow-up discipline is holding. Watch this jump after marketing spends."
		} else {
			growthInsight = "No first-time callers this week. If you're spending on marketing, it isn't ringing the phone."
		}
	}
}

// MARK: - Pulse view model

@MainActor
final class PulseViewModel: ObservableObject {
	@Published var snapshot = PulseSnapshot()
	@Published var windowDays = 7 {
		didSet { recomputeFromRaw() }
	}
	private var rawCalls: [CDRCall] = []
	private var rawTickets: [Ticket] = []
	@Published var truncated = false
	@Published var errorMessage: String?
	@Published var loaded = false
	@Published var lastUpdated: Date?

	static let answerRateTarget = 0.95

	// Last result survives tab switches and re-creation, so the page
	// renders instantly and refreshes in the background.
	private static var cache: (snapshot: PulseSnapshot, updated: Date?)?

	init() {
		if let cached = Self.cache {
			snapshot = cached.snapshot
			lastUpdated = cached.updated
			loaded = true
		}
	}

	var atRiskRupees: Int {
		let perPatient = UserDefaults.standard.object(forKey: "md_rupee_per_patient") as? Int ?? 150
		return snapshot.unrecoveredCount * perPatient
	}

	func reload() async {
		// No demo data, ever: signed-out users simply see nothing here
		// (the tab itself is hidden until sign-in).
		guard AstradialAPIConfig.isConfigured else {
			snapshot = PulseSnapshot()
			truncated = false
			errorMessage = nil
			loaded = true
			Self.cache = nil
			return
		}
		do {
			let monthAgo = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now))!
			async let callsTask = AstradialAPI.shared.fetchCalls(from: monthAgo, to: .now)
			async let ticketsTask = AstradialAPI.shared.fetchTickets()
			let (calls, ticketsResponse) = try await (callsTask, ticketsTask)
			let tickets = ticketsResponse.list
			let count = calls.count
			// Collapse multi-leg sessions (same linkedid) to one representative
			// row, preferring ANSWERED+billsec>0 — same rule as the editor's
			// call-log view, so the two screens agree.
			let deduped = Self.dedupSessions(calls)
			rawCalls = deduped
			rawTickets = tickets
			let days = windowDays
			let snap = await Task.detached(priority: .userInitiated) {
				PulseSnapshot.compute(calls: deduped, tickets: tickets, windowDays: days)
			}.value
			snapshot = snap
			truncated = count >= 3000
			errorMessage = nil
			lastUpdated = .now
			Self.cache = (snap, lastUpdated)
		} catch {
			// Keep last-known-good data on screen; just surface the failure.
			errorMessage = error.localizedDescription
		}
		loaded = true
	}

	private func recomputeFromRaw() {
		guard !rawCalls.isEmpty || !rawTickets.isEmpty else { return }
		let calls = rawCalls, tickets = rawTickets, days = windowDays
		Task {
			let snap = await Task.detached(priority: .userInitiated) {
				PulseSnapshot.compute(calls: calls, tickets: tickets, windowDays: days)
			}.value
			await MainActor.run { self.snapshot = snap }
		}
	}

	nonisolated static func dedupSessions(_ calls: [CDRCall]) -> [CDRCall] {
		var best: [String: CDRCall] = [:]
		var order: [String] = []
		for call in calls {
			let key = call.linkedid ?? "row-\(call.id)"
			if let existing = best[key] {
				best[key] = preferred(existing, call)
			} else {
				best[key] = call
				order.append(key)
			}
		}
		return order.compactMap { best[$0] }
	}

	private nonisolated static func preferred(_ a: CDRCall, _ b: CDRCall) -> CDRCall {
		let aAnswered = a.disposition == "ANSWERED" && (a.billsec ?? 0) > 0
		let bAnswered = b.disposition == "ANSWERED" && (b.billsec ?? 0) > 0
		if aAnswered != bAnswered { return aAnswered ? a : b }
		return (a.duration ?? 0) >= (b.duration ?? 0) ? a : b
	}
}

// MARK: - Analytics tab (Pulse)

struct AnalyticsTabView: View {
	@StateObject private var viewModel = PulseViewModel()
	@StateObject private var session = MDSession.shared
	@State private var showSettings = false

	var body: some View {
		NavigationStack {
			Group {
				if session.isSignedIn {
					dashboard
				} else {
					MDLoginView()
				}
			}
			.navigationTitle("Analytics")
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Picker("Range", selection: $viewModel.windowDays) {
						Text("7D").tag(7)
						Text("30D").tag(30)
					}
					.pickerStyle(.segmented)
					.frame(width: 104)
				}
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
		.onChange(of: session.isSignedIn) { _, signedIn in
			if signedIn { Task { await viewModel.reload() } }
		}
	}

	private var dashboard: some View {
		ScrollView {
			VStack(spacing: 14) {
				banners
				cards
			}
			.padding(.horizontal)
			.padding(.bottom, 24)
			.redacted(reason: viewModel.loaded ? [] : .placeholder)
			.shimmering(!viewModel.loaded)
		}
		.background(Color(.systemGroupedBackground))
		.refreshable { await viewModel.reload() }
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
			Task { await viewModel.reload() }
		}
	}

	@ViewBuilder
	private var banners: some View {
		// Which hospital you're looking at — prevents wrong-org confusion.
		if let org = session.orgName {
			HStack(spacing: 6) {
				Image(systemName: "building.2.fill")
					.font(.caption)
				Text(org)
					.font(.subheadline.weight(.semibold))
				if let role = session.role {
					Text(role).font(.caption).foregroundStyle(.secondary)
				}
				Spacer()
			}
		}
		if let error = viewModel.errorMessage {
			errorBanner(error)
		}
		if let updated = viewModel.lastUpdated {
			freshnessRow(updated)
		}
	}

	private func freshnessRow(_ updated: Date) -> some View {
		HStack(spacing: 4) {
			Image(systemName: "arrow.triangle.2.circlepath")
			Text("Updated")
			Text(updated, style: .relative)
			Text("ago")
		}
		.font(.caption2)
		.foregroundStyle(.secondary)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	@ViewBuilder
	private var cards: some View {
		NavigationLink { CallsDetailView(viewModel: viewModel) } label: {
			AnswerRateHeroTile(viewModel: viewModel)
		}
		.buttonStyle(.plain)

		LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())], spacing: 14) {
			NavigationLink { MissedDetailView(viewModel: viewModel) } label: {
				MissedTile(viewModel: viewModel)
			}
			NavigationLink { UnreachedDetailView() } label: {
				RecoveredTile(viewModel: viewModel)
			}
			NavigationLink { UnreachedDetailView() } label: {
				AtRiskTile(viewModel: viewModel)
			}
			NavigationLink { NewDetailView(viewModel: viewModel) } label: {
				NewPatientsTile(viewModel: viewModel)
			}
		}
		.buttonStyle(.plain)

		NavigationLink { CallsDetailView(viewModel: viewModel) } label: {
			TrendTile(viewModel: viewModel)
		}
		.buttonStyle(.plain)

		if viewModel.truncated {
			Text("Latest 3,000 calls.")
				.font(.caption2).foregroundStyle(.secondary)
		}
	}

	private func errorBanner(_ message: String) -> some View {
		HStack(spacing: 8) {
			Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
			Text("Couldn't refresh: \(message)")
				.font(.footnote)
				.lineLimit(2)
			Spacer()
			Button("Retry") { Task { await viewModel.reload() } }
				.font(.footnote.weight(.semibold))
		}
		.padding(10)
		.background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
	}
}

// MARK: - Loading shimmer

// (Not a ViewModifier: linphonesw exports its own `Content` type, which
// collides with ViewModifier's associated Content in this file.)
struct ShimmerOverlay: View {
	@State private var phase: CGFloat = -1.5

	var body: some View {
		GeometryReader { geo in
			LinearGradient(
				colors: [.clear, .white.opacity(0.55), .clear],
				startPoint: .topLeading, endPoint: .bottomTrailing
			)
			.frame(width: geo.size.width * 0.7)
			.offset(x: phase * geo.size.width)
			.onAppear {
				withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
					phase = 1.5
				}
			}
		}
		.allowsHitTesting(false)
	}
}

extension View {
	@ViewBuilder
	func shimmering(_ active: Bool) -> some View {
		if active {
			overlay(ShimmerOverlay())
		} else {
			self
		}
	}
}

/// "45m", "1h 30m", "2d 4h" — minutes humanized upward.
func humanizeMinutes(_ minutes: Int) -> String {
	if minutes < 1 { return "<1m" }
	if minutes < 60 { return "\(minutes)m" }
	let hours = minutes / 60
	let restMinutes = minutes % 60
	if hours < 24 {
		return restMinutes > 0 ? "\(hours)h \(restMinutes)m" : "\(hours)h"
	}
	let days = hours / 24
	let restHours = hours % 24
	return restHours > 0 ? "\(days)d \(restHours)h" : "\(days)d"
}

// MARK: - Fitness-style tiles (numbers + color speak; minimal text)

struct FitnessTile<Content: View>: View {
	let title: String
	var period: String? = "Today"
	@ViewBuilder var content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack {
				Text(title)
					.font(.title3.weight(.semibold))
				Spacer()
				Image(systemName: "chevron.right.circle.fill")
					.font(.title3)
					.foregroundStyle(Color(.systemGray3))
			}
			if let period {
				Text(period)
					.font(.subheadline)
					.foregroundStyle(.secondary)
			}
			content
			Spacer(minLength: 0)
		}
		.padding(16)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
	}
}

// Full-width hero: activity-ring treatment for answer rate.
struct AnswerRateHeroTile: View {
	@ObservedObject var viewModel: PulseViewModel
	@State private var animatedRate: Double = 0

	private var ringColor: Color {
		if viewModel.snapshot.todayInbound == 0 { return Color(.systemGray3) }
		if viewModel.snapshot.answerRate >= PulseViewModel.answerRateTarget { return .green }
		if viewModel.snapshot.answerRate >= 0.85 { return .orange }
		return .red
	}

	var body: some View {
		FitnessTile(title: "Answer Rate", period: Date.now.formatted(.dateTime.weekday(.wide).day().month())) {
			HStack(spacing: 24) {
				ZStack {
					Circle().stroke(ringColor.opacity(0.22), lineWidth: 13)
					Circle()
						.trim(from: 0, to: animatedRate)
						.stroke(ringColor, style: StrokeStyle(lineWidth: 13, lineCap: .round))
						.rotationEffect(.degrees(-90))
					Text("\(Int(viewModel.snapshot.answerRate * 100))%")
						.font(.system(size: 26, weight: .bold, design: .rounded))
						.foregroundStyle(ringColor)
				}
				.frame(width: 116, height: 116)
				.padding(.vertical, 6)
				.onAppear {
					withAnimation(.easeOut(duration: 0.8)) { animatedRate = viewModel.snapshot.answerRate }
				}
				.onChange(of: viewModel.snapshot.answerRate) { _, newValue in
					withAnimation(.easeOut(duration: 0.8)) { animatedRate = newValue }
				}

				VStack(alignment: .leading, spacing: 2) {
					Text("Answered")
						.font(.headline)
					Text("\(viewModel.snapshot.todayAnswered)/\(viewModel.snapshot.todayInbound)")
						.font(.system(size: 34, weight: .bold, design: .rounded))
						.foregroundStyle(ringColor)
						.contentTransition(.numericText())
					Text("yesterday \(viewModel.snapshot.yesterdayInbound - viewModel.snapshot.yesterdayMissed)/\(viewModel.snapshot.yesterdayInbound)")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				Spacer()
			}
		}
	}
}

// Every grid tile shares the exact same skeleton (value slot, chart
// slot, footnote slot) so the four cards are pixel-identical.
struct MetricTile<TileChart: View>: View {
	let title: String
	let period: String
	let value: String
	let color: Color
	var footnote: String = " "
	var cornerIcon: String?
	var cornerTint: Color = .teal
	@ViewBuilder var chart: TileChart

	var body: some View {
		decorated {
			Text(value)
				.font(.system(size: 32, weight: .bold, design: .rounded))
				.foregroundStyle(color)
				.lineLimit(1)
				.minimumScaleFactor(0.6)
				.frame(height: 40, alignment: .leading)
				.contentTransition(.numericText())
			chart
				.frame(height: 52)
			Text(footnote)
				.font(.footnote)
				.foregroundStyle(.secondary)
				.lineLimit(1)
		}
		.frame(height: 196)
	}

	@ViewBuilder
	private func decorated<Inner: View>(@ViewBuilder inner: () -> Inner) -> some View {
		FitnessTile(title: title, period: period) {
			inner()
		}
		.overlay(alignment: .bottomTrailing) {
			if let cornerIcon {
				Image(systemName: resolvedIcon(cornerIcon))
					.font(.system(size: 30, weight: .medium))
					.foregroundStyle(cornerTint.opacity(0.85), cornerTint.opacity(0.25))
					.padding(14)
			}
		}
	}

	// Requested symbols may not exist on every iOS — fall back gracefully.
	private func resolvedIcon(_ name: String) -> String {
		UIImage(systemName: name) != nil ? name : "arrow.uturn.left.circle.fill"
	}
}

struct MissedTile: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		MetricTile(
			title: "Missed", period: "Today",
			value: "\(viewModel.snapshot.todayMissed)", color: .red,
			footnote: "yesterday \(viewModel.snapshot.yesterdayMissed)"
		) {
			Chart(viewModel.snapshot.hourly) { stat in
				BarMark(x: .value("Hour", stat.hour, unit: .hour), y: .value("Missed", stat.missed))
					.foregroundStyle(.red)
					.cornerRadius(1.5)
			}
			.chartXAxis {
				AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
					AxisValueLabel(format: .dateTime.hour())
						.font(.system(size: 8))
				}
			}
			.chartYAxis(.hidden)
		}
	}
}

struct RecoveredTile: View {
	@ObservedObject var viewModel: PulseViewModel

	private var color: Color {
		viewModel.snapshot.recoveryRate >= 0.9 ? .green : (viewModel.snapshot.recoveryRate >= 0.6 ? .orange : .red)
	}

	var body: some View {
		MetricTile(
			title: "Recovered", period: "\(viewModel.windowDays) days",
			value: "\(Int(viewModel.snapshot.recoveryRate * 100))%", color: color,
			footnote: viewModel.snapshot.medianRecoveryMinutes.map { "median \(humanizeMinutes($0))" } ?? " ",
			cornerIcon: "pointer.arrow.ipad.rays",
			cornerTint: .teal
		) {
			Color.clear
		}
	}
}

struct AtRiskTile: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		MetricTile(
			title: "At Risk", period: "now",
			value: "₹\(viewModel.atRiskRupees.formatted())", color: .orange,
			footnote: "\(viewModel.snapshot.unrecoveredCount) unreached"
		) {
			Color.clear
		}
	}
}

struct NewPatientsTile: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		MetricTile(
			title: "New", period: "\(viewModel.windowDays) days",
			value: "\(viewModel.snapshot.newCallersLast7)", color: .green
		) {
			Chart(viewModel.snapshot.daily.suffix(viewModel.windowDays)) { stat in
				BarMark(x: .value("Day", stat.day, unit: .day), y: .value("New", stat.newCallers))
					.foregroundStyle(.green)
					.cornerRadius(1.5)
			}
			.chartXAxis(.hidden)
			.chartYAxis(.hidden)
		}
	}
}

struct TrendTile: View {
	@ObservedObject var viewModel: PulseViewModel

	private var wow: Double? { viewModel.snapshot.weekOverWeek }

	var body: some View {
		FitnessTile(title: "Calls", period: "\(viewModel.windowDays * 2) days") {
			HStack(alignment: .firstTextBaseline, spacing: 10) {
				if let wow {
					HStack(spacing: 4) {
						Image(systemName: wow >= 0 ? "arrow.up.right" : "arrow.down.right")
							.font(.title3.weight(.bold))
						Text("\(wow >= 0 ? "+" : "")\(Int(wow * 100))%")
							.font(.system(size: 34, weight: .bold, design: .rounded))
					}
					.foregroundStyle(wow >= 0 ? Color.green : Color.red)
					Text("vs last week")
						.font(.footnote)
						.foregroundStyle(.secondary)
				} else {
					Text("\(viewModel.snapshot.daily.suffix(7).reduce(0) { $0 + $1.total })")
						.font(.system(size: 34, weight: .bold, design: .rounded))
						.foregroundStyle(.indigo)
				}
				Spacer()
			}
			Chart {
				ForEach(viewModel.snapshot.daily.suffix(min(viewModel.windowDays * 2, 30))) { stat in
					BarMark(x: .value("Day", stat.day, unit: .day), y: .value("Calls", stat.total))
						.foregroundStyle(.indigo.opacity(0.45))
						.cornerRadius(2)
				}
				ForEach(viewModel.snapshot.daily.suffix(min(viewModel.windowDays * 2, 30))) { stat in
					BarMark(x: .value("Day", stat.day, unit: .day), y: .value("Missed", stat.missed))
						.foregroundStyle(.red)
						.cornerRadius(2)
				}
			}
			.chartXAxis {
				AxisMarks(values: .stride(by: .day, count: 3)) { _ in
					AxisValueLabel(format: .dateTime.day())
						.font(.system(size: 8))
				}
			}
			.chartYAxis(.hidden)
			.frame(height: 72)
		}
	}
}

// MARK: - API diagnostics (ground truth, no guessing)

struct APIDiagnosticsView: View {
	struct ProbeResult: Identifiable {
		let id = UUID()
		let name: String
		let url: String
		let status: String
		let body: String
	}

	@State private var results: [ProbeResult] = []
	@State private var running = false
	@ObservedObject private var session = MDSession.shared

	var body: some View {
		List {
			Section("Session") {
				LabeledContent("Org", value: session.orgName ?? "—")
				LabeledContent("Role", value: session.role ?? "—")
				LabeledContent("Server", value: AstradialAPIConfig.base)
			}
			ForEach(results) { result in
				Section(result.name) {
					Text(result.url).font(.caption2.monospaced()).foregroundStyle(.secondary)
					LabeledContent("Status", value: result.status)
					Text(result.body)
						.font(.caption.monospaced())
						.textSelection(.enabled)
				}
			}
			if running {
				ProgressView()
			}
		}
		.navigationTitle("API Diagnostics")
		.navigationBarTitleDisplayMode(.inline)
		.task { await run() }
		.refreshable { await run() }
	}

	private func run() async {
		running = true
		results = []
		let dateFormatter = DateFormatter()
		dateFormatter.dateFormat = "yyyy-MM-dd"
		let from = dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: -7, to: .now)!)
		let to = dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: .now)!)
		let probes: [(String, String)] = [
			("calls · undated", "/api/v1/calls?limit=3"),
			("calls · dated", "/api/v1/calls?limit=3&date_from=\(from)&date_to=\(to)"),
			("calls · count only", "/api/v1/calls/count"),
			("tickets", "/api/v1/tickets?limit=2")
		]
		for (name, path) in probes {
			let urlString = AstradialAPIConfig.base + path
			do {
				var request = URLRequest(url: URL(string: urlString)!)
				request.setValue("Bearer \(try await PlatformAuth.shared.bearerToken())", forHTTPHeaderField: "Authorization")
				let (data, response) = try await AstradialHTTP.session.data(for: request)
				let status = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "?"
				let body = String(decoding: data.prefix(700), as: UTF8.self)
				results.append(ProbeResult(name: name, url: urlString, status: status, body: body))
			} catch {
				results.append(ProbeResult(name: name, url: urlString, status: "error", body: error.localizedDescription))
			}
		}
		running = false
	}
}

// MARK: - Tile detail pages

struct MissedDetailView: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		List {
			Section {
				Chart(viewModel.snapshot.hourly) { stat in
					BarMark(x: .value("Hour", stat.hour, unit: .hour), y: .value("Missed", stat.missed))
						.foregroundStyle(.red)
						.cornerRadius(2)
				}
				.chartXAxis {
					AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
						AxisGridLine()
						AxisValueLabel(format: .dateTime.hour())
					}
				}
				.frame(height: 180)
				.padding(.vertical, 8)
			}
			Section("By hour") {
				ForEach(viewModel.snapshot.hourly.filter { $0.missed > 0 }) { stat in
					HStack {
						Text(stat.hour, format: .dateTime.hour())
						Spacer()
						Text("\(stat.missed) missed").foregroundStyle(.red)
						Text("of \(stat.total)").foregroundStyle(.secondary)
					}
				}
				if viewModel.snapshot.todayMissed == 0 {
					Text("No missed calls today.").foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle("Missed · Today")
		.navigationBarTitleDisplayMode(.inline)
	}
}

struct CallsDetailView: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		List {
			Section {
				Chart {
					ForEach(viewModel.snapshot.daily) { stat in
						BarMark(x: .value("Day", stat.day, unit: .day), y: .value("Calls", stat.total))
							.foregroundStyle(.indigo.opacity(0.5))
							.cornerRadius(2)
					}
					ForEach(viewModel.snapshot.daily) { stat in
						BarMark(x: .value("Day", stat.day, unit: .day), y: .value("Missed", stat.missed))
							.foregroundStyle(.red)
							.cornerRadius(2)
					}
				}
				.frame(height: 200)
				.padding(.vertical, 8)
			}
			Section("Daily") {
				ForEach(viewModel.snapshot.daily.reversed().filter { $0.total > 0 }) { stat in
					HStack {
						Text(stat.day, format: .dateTime.weekday(.abbreviated).day().month())
						Spacer()
						Text("\(stat.total)")
						Text("· \(stat.missed) missed")
							.foregroundStyle(stat.missed > 0 ? .red : .secondary)
							.font(.footnote)
					}
				}
			}
		}
		.navigationTitle("Calls · 30 Days")
		.navigationBarTitleDisplayMode(.inline)
	}
}

struct NewDetailView: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		List {
			Section {
				Chart(viewModel.snapshot.daily) { stat in
					BarMark(x: .value("Day", stat.day, unit: .day), y: .value("New", stat.newCallers))
						.foregroundStyle(.green)
						.cornerRadius(2)
				}
				.frame(height: 180)
				.padding(.vertical, 8)
			}
			Section("First-time callers (30-day basis)") {
				ForEach(viewModel.snapshot.daily.reversed().filter { $0.newCallers > 0 }) { stat in
					HStack {
						Text(stat.day, format: .dateTime.weekday(.abbreviated).day().month())
						Spacer()
						Text("\(stat.newCallers) new").foregroundStyle(.green)
					}
				}
			}
		}
		.navigationTitle("New Patients")
		.navigationBarTitleDisplayMode(.inline)
	}
}

struct UnreachedDetailView: View {
	@ObservedObject private var tickets = TicketsViewModel.shared

	private var unreached: [Ticket] {
		tickets.tickets.filter { ($0.status == "open" || $0.status == "in_progress") && $0.callbackFoundAt == nil }
	}

	var body: some View {
		List {
			Section("Not yet called back") {
				ForEach(unreached) { ticket in
					HStack(spacing: 12) {
						InitialsAvatar(name: ticket.displayName, size: 38)
						VStack(alignment: .leading, spacing: 1) {
							Text(ticket.displayName).font(.subheadline.weight(.semibold))
							Text(ticket.summaryLine).font(.caption).foregroundStyle(.secondary)
						}
						Spacer()
						if let last = ticket.lastCallDate {
							Text(relativeDate(time_t(last.timeIntervalSince1970)))
								.font(.caption).foregroundStyle(.secondary)
						}
					}
				}
				if unreached.isEmpty {
					Text("Everyone has been reached.").foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle("Unreached")
		.navigationBarTitleDisplayMode(.inline)
		.task { await tickets.reload() }
	}
}

// MARK: - Firebase auth session

@MainActor
final class MDSession: ObservableObject {
	static let shared = MDSession()

	@Published var isSignedIn = false
	@Published var email: String?
	@Published var role: String?
	@Published var orgName: String?
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
		role = nil
		orgName = nil
		Task { await PlatformAuth.shared.reset() }
	}

	func applyPlatformUser(_ user: PlatformUser) {
		role = user.role
		orgName = user.orgName
	}

	var isOwner: Bool {
		["owner", "admin"].contains((role ?? "").lowercased())
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
			Image("AstradialLogo")
				.resizable()
				.scaledToFit()
				.frame(width: 88, height: 88)
				.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
				error = nil
				Task {
					defer { busy = false }
					do {
						try await MDSession.shared.signIn(email: email, password: password)
					} catch {
						let code = AuthErrorCode(rawValue: (error as NSError).code)
						switch code {
						case .wrongPassword, .userNotFound, .invalidCredential, .invalidEmail, .userDisabled:
							self.error = "Incorrect email or password."
						case .networkError:
							self.error = "No internet connection — try again."
						default:
							self.error = error.localizedDescription
						}
					}
				}
			} label: {
				Text(busy ? "Signing in…" : "Sign In")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.borderedProminent)
			.disabled(busy || email.isEmpty || password.isEmpty)
			.padding(.horizontal)

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
	@ObservedObject private var coreContext = CoreContext.shared
	@StateObject private var sipViewModel = AccountLoginViewModel()

	@AppStorage("astradial_api_base") private var apiBase = "https://devpbx.astradial.com"
	@AppStorage("md_rupee_per_patient") private var rupeePerPatient = 150
	@State private var sipRegistered = false
	@State private var sipIdentity = ""
	@State private var showScanner = false

	var body: some View {
		NavigationStack {
			Group {
				if session.isSignedIn {
					settingsForm
				} else {
					// Signed out -> straight to the login screen.
					MDLoginView()
				}
			}
			.navigationTitle(session.isSignedIn ? "Settings" : "Sign In")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Done") { dismiss() }
				}
			}
		}
	}

	private var settingsForm: some View {
			Form {
				Section {
					HStack(spacing: 12) {
						InitialsAvatar(name: session.displayName, size: 52)
						VStack(alignment: .leading) {
							Text(session.email ?? "Not signed in").font(.body.weight(.medium))
							Text(session.orgName.map { "\($0) · \(session.role ?? "member")" } ?? "")
								.font(.footnote).foregroundStyle(.secondary)
						}
					}
					Button("Sign Out", role: .destructive) { session.signOut() }
				}

				Section {
					HStack {
						Text("Status")
						Spacer()
						if coreContext.loggingInProgress {
							ProgressView().controlSize(.small)
							Text("Registering…").foregroundStyle(.secondary)
						} else {
							Circle()
								.fill(sipRegistered ? Color.green : Color.red)
								.frame(width: 9, height: 9)
							Text(sipRegistered ? "Registered" : "Not Registered")
								.foregroundStyle(.secondary)
						}
					}
					if !sipIdentity.isEmpty {
						LabeledContent("Line") {
							Text(sipIdentity.replacingOccurrences(of: "sip:", with: ""))
								.font(.footnote)
								.lineLimit(1)
								.truncationMode(.middle)
						}
					}
					Button {
						showScanner = true
					} label: {
						Label("Scan SIP QR Code", systemImage: "qrcode.viewfinder")
					}
				} header: {
					Text("SIP Account")
				}

				Section {
					LabeledContent("Username") {
						TextField("e1001abc", text: $sipViewModel.username)
							.multilineTextAlignment(.trailing)
							.autocapitalization(.none)
							.autocorrectionDisabled()
					}
					LabeledContent("Password") {
						SecureField("required", text: $sipViewModel.passwd)
							.multilineTextAlignment(.trailing)
					}
					LabeledContent("Server") {
						TextField("devsip.astradial.com", text: $sipViewModel.domain)
							.multilineTextAlignment(.trailing)
							.autocapitalization(.none)
							.autocorrectionDisabled()
							.keyboardType(.URL)
					}
					Picker("Transport", selection: $sipViewModel.transportType) {
						Text("UDP").tag("UDP")
						Text("TCP").tag("TCP")
						Text("TLS").tag("TLS")
					}
					Button {
						sipViewModel.login()
					} label: {
						if coreContext.loggingInProgress {
							HStack { ProgressView(); Text("Registering…") }
						} else {
							Text("Apply & Register")
						}
					}
					.disabled(sipViewModel.username.isEmpty || sipViewModel.domain.isEmpty || coreContext.loggingInProgress)
				} header: {
					Text("Manual Setup")
				} footer: {
					Text("Credentials are on the dashboard's Users page (SIP icon).")
				}

				Section {
					TextField("API Base URL", text: $apiBase)
						.autocapitalization(.none)
						.keyboardType(.URL)
				} header: {
					Text("Astradial Server")
				} footer: {
					Text("Analytics, tickets and reports are loaded with your signed-in account — no API keys needed.")
				}

				Section {
					Stepper("₹\(rupeePerPatient) per patient", value: $rupeePerPatient, in: 50...10000, step: 50)
				} header: {
					Text("MD Analytics")
				} footer: {
					Text("Average revenue per patient visit — used for the 'backlog at risk' number on the Pulse card.")
				}

				Section("About") {
					LabeledContent("App", value: "Astradial Phone")
					LabeledContent("Engine", value: "Linphone SDK \(Core.getVersion)")
				}

				Section("Developer") {
					NavigationLink("API Diagnostics") {
						APIDiagnosticsView()
					}
				}
			}
			.onAppear(perform: refreshSIPStatus)
			.onChange(of: coreContext.loggingInProgress) { _, inProgress in
				if !inProgress { refreshSIPStatus() }
			}
			.onChange(of: coreContext.accounts.count) { _, _ in
				refreshSIPStatus()
			}
			.sheet(isPresented: $showScanner) {
				QRScannerSheet { code in
					if let credentials = SIPProvisioning.parse(code) {
						sipViewModel.username = credentials.username
						sipViewModel.passwd = credentials.password
						sipViewModel.domain = credentials.domain
						sipViewModel.transportType = credentials.transport
						sipViewModel.login()
						refreshSIPStatus()
					}
				}
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
