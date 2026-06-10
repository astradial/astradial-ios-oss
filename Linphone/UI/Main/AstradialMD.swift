/*
 * Astradial MD (Managing Director) module — "Pulse" dashboard.
 *
 * Hospital-MD analytics in Apple Health style. Design approved by Hari
 * (June 2026): Today's Pulse hero (answer-rate ring vs 95% target +
 * ₹ at risk, default ₹150/patient), Call Back Now action list,
 * Recovery Discipline, then EXACTLY three graphs, each with a
 * data-driven insight line: (1) Today by hour with missed overlay,
 * (2) 30-day volume trend with week-over-week, (3) New patients &
 * outbound follow-ups merged. Data: /api/v1/calls + /api/v1/tickets
 * (X-API-Key). Firebase Auth gates the tab. iOS-Settings-style
 * settings page.
 */

import SwiftUI
import Charts
import AVFoundation
import FirebaseAuth
import linphonesw

// MARK: - API config & keychain

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

// MARK: - CDR model

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
	let linkedid: String?

	enum CodingKeys: String, CodingKey {
		case id, calldate, src, dst, disposition, duration, billsec, direction, linkedid
		case waitTime = "wait_time"
		case answeredBy = "answered_by"
		case recordingUrl = "recording_url"
		case queueName = "queue_name"
	}

	var date: Date {
		if let date = ISO8601DateFormatter().date(from: calldate) { return date }
		// Strings carrying an explicit offset/Z are UTC-anchored; naive
		// MariaDB-style datetimes are interpreted as server-local (IST).
		let hasOffset = calldate.hasSuffix("Z") || calldate.contains("+")
		for formatter in (hasOffset ? Self.utcFormatters : Self.naiveFormatters) {
			if let date = formatter.date(from: calldate) { return date }
		}
		return .distantPast
	}

	var isInbound: Bool { direction != "outbound" }
	var isMissed: Bool { disposition != "ANSWERED" && isInbound }

	static let fallbackFormatter: DateFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss'Z'", utc: true)
	static let utcFormatters = [fallbackFormatter]
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

	var errorDescription: String? {
		switch self {
		case .notConfigured: return "API key not configured. Open Settings to connect."
		case .http(let code): return "Astradial API error (HTTP \(code))."
		}
	}
}

actor AstradialAPI {
	static let shared = AstradialAPI()

	func fetchCalls(from: Date, to: Date, maxRecords: Int = 3000) async throws -> [CDRCall] {
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

// MARK: - Pulse view model

struct HourStat: Identifiable {
	let hour: Date
	var total = 0
	var missed = 0
	var id: Date { hour }
}

struct DayStat: Identifiable {
	let day: Date
	var total = 0
	var missed = 0
	var outbound = 0
	var newCallers = 0
	var id: Date { day }
}

@MainActor
final class PulseViewModel: ObservableObject {
	// Today's pulse
	@Published var todayInbound = 0
	@Published var todayAnswered = 0
	@Published var todayMissed = 0
	@Published var answerRate: Double = 1.0
	@Published var yesterdayInbound = 0
	@Published var yesterdayMissed = 0
	@Published var loaded = false
	@Published var lastUpdated: Date?

	// Tickets / recovery
	@Published var callbackQueue: [Ticket] = []
	@Published var unrecoveredCount = 0
	@Published var recoveryRate: Double = 0
	@Published var medianRecoveryMinutes: Int?

	// Graph series
	@Published var hourly: [HourStat] = []
	@Published var daily: [DayStat] = []
	@Published var weekOverWeek: Double?
	@Published var newCallersLast7 = 0
	@Published var outboundPerDayLast7: Double = 0

	// Insight lines (computed from data, shown under each graph)
	@Published var hourlyInsight = ""
	@Published var trendInsight = ""
	@Published var growthInsight = ""

	@Published var isSampleData = true
	@Published var truncated = false
	@Published var errorMessage: String?

	static let answerRateTarget = 0.95

	var atRiskRupees: Int {
		let perPatient = UserDefaults.standard.object(forKey: "md_rupee_per_patient") as? Int ?? 150
		return unrecoveredCount * perPatient
	}

	func reload() async {
		// Demo data ONLY when no API key is configured. A configured key
		// that errors must never silently render fake numbers.
		guard AstradialAPIConfig.isConfigured else {
			apply(calls: Self.sampleCalls(), tickets: TicketsViewModel.sample)
			truncated = false
			isSampleData = true
			errorMessage = nil
			loaded = true
			return
		}
		do {
			let monthAgo = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now))!
			async let callsTask = AstradialAPI.shared.fetchCalls(from: monthAgo, to: .now)
			async let ticketsTask = AstradialAPI.shared.fetchTickets()
			let (calls, ticketsResponse) = try await (callsTask, ticketsTask)
			// Collapse multi-leg sessions (same linkedid) to one representative
			// row, preferring ANSWERED+billsec>0 — same rule as the editor's
			// call-log view, so the two screens agree.
			apply(calls: Self.dedupSessions(calls), tickets: ticketsResponse.list)
			truncated = calls.count >= 3000
			isSampleData = false
			errorMessage = nil
			lastUpdated = .now
		} catch {
			// Keep last-known-good data on screen; just surface the failure.
			errorMessage = error.localizedDescription
			isSampleData = false
		}
		loaded = true
	}

	static func dedupSessions(_ calls: [CDRCall]) -> [CDRCall] {
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

	private static func preferred(_ a: CDRCall, _ b: CDRCall) -> CDRCall {
		let aAnswered = a.disposition == "ANSWERED" && (a.billsec ?? 0) > 0
		let bAnswered = b.disposition == "ANSWERED" && (b.billsec ?? 0) > 0
		if aAnswered != bAnswered { return aAnswered ? a : b }
		return (a.duration ?? 0) >= (b.duration ?? 0) ? a : b
	}

	private func apply(calls: [CDRCall], tickets: [Ticket]) {
		let calendar = Calendar.current
		let todayStart = calendar.startOfDay(for: .now)

		// --- Today's pulse (inbound only) ---
		let todayCalls = calls.filter { $0.date >= todayStart && $0.isInbound }
		todayInbound = todayCalls.count
		todayAnswered = todayCalls.filter { $0.disposition == "ANSWERED" }.count
		todayMissed = todayInbound - todayAnswered
		answerRate = todayInbound > 0 ? Double(todayAnswered) / Double(todayInbound) : 1.0

		// --- Callback queue + recovery (tickets) ---
		let actionable = tickets.filter { ($0.status == "open" || $0.status == "in_progress") && $0.callbackFoundAt == nil }
		let priorityOrder = ["urgent": 0, "high": 1, "normal": 2]
		callbackQueue = actionable.sorted {
			let pa = priorityOrder[$0.priority ?? "normal"] ?? 2
			let pb = priorityOrder[$1.priority ?? "normal"] ?? 2
			if pa != pb { return pa < pb }
			return ($0.missedCount ?? 0) > ($1.missedCount ?? 0)
		}
		unrecoveredCount = actionable.count

		let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now)!
		let recentTickets = tickets.filter { ($0.lastCallDate ?? .distantPast) >= weekAgo }
		let recovered = recentTickets.filter { $0.callbackDate != nil }
		recoveryRate = recentTickets.isEmpty ? 0 : Double(recovered.count) / Double(recentTickets.count)
		let recoveryGaps = recovered.compactMap { ticket -> Int? in
			guard let callback = ticket.callbackDate, let miss = ticket.lastCallDate else { return nil }
			return max(0, Int(callback.timeIntervalSince(miss) / 60))
		}.sorted()
		medianRecoveryMinutes = recoveryGaps.isEmpty ? nil : recoveryGaps[recoveryGaps.count / 2]

		// --- Graph 1: hourly (today, inbound) ---
		var hours: [Date: HourStat] = [:]
		for offset in 0..<24 {
			if let hour = calendar.date(byAdding: .hour, value: offset, to: todayStart), hour <= .now {
				hours[hour] = HourStat(hour: hour)
			}
		}
		for call in todayCalls {
			let hour = calendar.dateInterval(of: .hour, for: call.date)?.start ?? call.date
			var stat = hours[hour] ?? HourStat(hour: hour)
			stat.total += 1
			if call.isMissed { stat.missed += 1 }
			hours[hour] = stat
		}
		hourly = hours.values.sorted { $0.hour < $1.hour }

		// --- Graphs 2+3 source: daily series over 30 days ---
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
		daily = days.values.sorted { $0.day < $1.day }

		// Week-over-week compares COMPLETE days only — including today's
		// partial day would read artificially negative every morning.
		let completeDays = Array(daily.dropLast())
		let last7 = Array(completeDays.suffix(7))
		let prior7 = Array(completeDays.dropLast(7).suffix(7))
		let last7Total = last7.reduce(0) { $0 + $1.total }
		let prior7Total = prior7.reduce(0) { $0 + $1.total }
		weekOverWeek = prior7Total > 0 ? (Double(last7Total) / Double(prior7Total)) - 1.0 : nil
		newCallersLast7 = last7.reduce(0) { $0 + $1.newCallers }
		outboundPerDayLast7 = last7.isEmpty ? 0 : Double(last7.reduce(0) { $0 + $1.outbound }) / Double(last7.count)

		if let yesterday = completeDays.last {
			yesterdayInbound = yesterday.total
			yesterdayMissed = yesterday.missed
		}

		computeInsights(last7Total: last7Total, prior7Total: prior7Total)
	}

	private func computeInsights(last7Total: Int, prior7Total: Int) {
		let hourFormatter = DateFormatter()
		hourFormatter.dateFormat = "h a"

		// Graph 1 insight — worst missed-call window today.
		if todayMissed == 0 {
			hourlyInsight = todayInbound == 0
				? "No calls yet today."
				: "No leaks today — every hour fully answered. Keep it up."
		} else if let worst = hourly.max(by: { $0.missed < $1.missed }), worst.missed > 0 {
			let windowStart = hourFormatter.string(from: worst.hour)
			let share = Int(Double(worst.missed) / Double(max(todayMissed, 1)) * 100)
			hourlyInsight = "Worst window: \(windowStart) — \(worst.missed) of today's \(todayMissed) missed calls (\(share)%). If this window is red most days, add one operator there."
		}

		// Graph 2 insight — WoW direction.
		if let wow = weekOverWeek {
			let pct = Int(abs(wow) * 100)
			if wow >= 0.05 {
				trendInsight = "Calls up \(pct)% vs last week (\(last7Total) vs \(prior7Total)). More calls = more revenue — make sure staffing keeps pace."
			} else if wow <= -0.05 {
				trendInsight = "Calls down \(pct)% vs last week (\(last7Total) vs \(prior7Total)). Falling demand or a routing problem — check DIDs and marketing before it shows in billing."
			} else {
				trendInsight = "Volume steady vs last week (\(last7Total) vs \(prior7Total)). Growth needs new demand — see new callers below."
			}
		} else {
			trendInsight = "Collecting history — week-over-week comparison appears after 14 days of data."
		}

		// Graph 3 insight — new patients vs follow-up discipline.
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

	// Deterministic sample dataset (30 days, inbound + outbound, repeat callers).
	static func sampleCalls() -> [CDRCall] {
		let calendar = Calendar.current
		var calls: [CDRCall] = []
		var id = 1
		for day in 0..<30 {
			let base = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: .now))!
			let volume = 28 + (day * 7) % 14
			for n in 0..<volume {
				let hour = 8 + (n * 37) % 12
				let date = calendar.date(bySettingHour: hour, minute: (n * 13) % 60, second: 0, of: base)!
				guard date <= .now else { continue }
				let missed = (n * 31 + day) % 6 == 0
				let pool = (n + day * 3) % 80
				calls.append(CDRCall(
					id: id, calldate: ISO8601DateFormatter().string(from: date),
					src: "98\(40000000 + pool * 1373)", dst: "8065978010",
					disposition: missed ? "NO ANSWER" : "ANSWERED",
					duration: missed ? 18 : 95 + (n * 17) % 300,
					billsec: missed ? 0 : 80 + (n * 17) % 280,
					direction: "inbound",
					waitTime: 4 + (n * 7 + day * 3) % 18,
					answeredBy: missed ? nil : "100\(1 + n % 4)",
					recordingUrl: nil, queueName: nil, linkedid: nil
				))
				id += 1
			}
			for n in 0..<(4 + day % 4) {
				let date = calendar.date(bySettingHour: 10 + (n * 3) % 8, minute: (n * 23) % 60, second: 0, of: base)!
				guard date <= .now else { continue }
				calls.append(CDRCall(
					id: id, calldate: ISO8601DateFormatter().string(from: date),
					src: "8065978010", dst: "98\(40000000 + ((n + day) % 80) * 1373)",
					disposition: "ANSWERED", duration: 60, billsec: 50,
					direction: "outbound", waitTime: 6, answeredBy: nil,
					recordingUrl: nil, queueName: nil, linkedid: nil
				))
				id += 1
			}
		}
		return calls
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
				if session.isSignedIn || session.demoMode || !session.firebaseAvailable {
					dashboard
				} else {
					MDLoginView()
				}
			}
			.navigationTitle("Pulse")
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
				banners
				cards
			}
			.padding(.horizontal)
			.padding(.bottom, 24)
			.redacted(reason: viewModel.loaded ? [] : .placeholder)
		}
		.background(Color(.systemGroupedBackground))
		.overlay {
			if viewModel.isSampleData && viewModel.loaded {
				Text("DEMO DATA")
					.font(.system(size: 52, weight: .black, design: .rounded))
					.foregroundStyle(Color.orange.opacity(0.13))
					.rotationEffect(.degrees(-28))
					.allowsHitTesting(false)
			}
		}
		.refreshable { await viewModel.reload() }
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
			Task { await viewModel.reload() }
		}
	}

	@ViewBuilder
	private var banners: some View {
		if viewModel.isSampleData {
			sampleBanner
		} else if let error = viewModel.errorMessage {
			errorBanner(error)
		}
		if !viewModel.isSampleData, let updated = viewModel.lastUpdated {
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
		PulseHeroCard(viewModel: viewModel)
		CallBackNowCard(viewModel: viewModel)
		RecoveryCard(viewModel: viewModel)
		HourlyGraphCard(viewModel: viewModel)
		TrendGraphCard(viewModel: viewModel)
		GrowthGraphCard(viewModel: viewModel)
		allCallsLink
		if viewModel.truncated {
			Text("Based on the most recent 3,000 calls. Older days may be incomplete.")
				.font(.caption2).foregroundStyle(.secondary)
		}
	}

	private var allCallsLink: some View {
		NavigationLink {
			OrgCallsListView()
		} label: {
			HStack {
				Label("All Calls & Recordings", systemImage: "waveform")
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(.indigo)
				Spacer()
				Image(systemName: "chevron.right")
					.font(.footnote.weight(.semibold))
					.foregroundStyle(Color(.systemGray3))
			}
			.padding(14)
			.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
		}
		.buttonStyle(.plain)
	}

	private var sampleBanner: some View {
		HStack(spacing: 8) {
			Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
			Text("Demo data — connect the Astradial API to see your hospital.")
				.font(.footnote)
			Spacer()
			Button("Connect") { showSettings = true }
				.font(.footnote.weight(.semibold))
		}
		.padding(10)
		.background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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

// MARK: - Card chrome

struct PulseCard<Content: View>: View {
	let title: String
	let icon: String
	let tint: Color
	var why: String?
	var insight: String?
	var period: String?
	@ViewBuilder var content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			HStack {
				Label(title, systemImage: icon)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(tint)
				Spacer()
				if let period {
					Text(period)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			content
			if let insight, !insight.isEmpty {
				HStack(alignment: .top, spacing: 6) {
					Image(systemName: "sparkles")
						.font(.caption)
						.foregroundStyle(tint)
						.padding(.top, 1)
					Text(insight)
						.font(.footnote)
						.foregroundStyle(.primary)
				}
				.padding(10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
			}
			if let why, !why.isEmpty {
				HStack(alignment: .top, spacing: 5) {
					Image(systemName: "lightbulb.max.fill")
						.font(.caption2)
						.foregroundStyle(.yellow)
						.padding(.top, 1)
					Text(why)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
	}
}

// MARK: - 1. Hero

struct PulseHeroCard: View {
	@ObservedObject var viewModel: PulseViewModel

	private var ringColor: Color {
		if viewModel.todayInbound == 0 { return Color(.systemGray3) }
		if viewModel.answerRate >= PulseViewModel.answerRateTarget { return .green }
		if viewModel.answerRate >= 0.85 { return .orange }
		return .red
	}

	@State private var animatedRate: Double = 0

	var body: some View {
		PulseCard(
			title: "Today's Pulse", icon: "heart.fill", tint: .pink,
			why: "Below 95% answer rate means patients are reaching your competitors. Every red point here is lost revenue.",
			period: Date.now.formatted(.dateTime.weekday(.wide).day().month())
		) {
			HStack(spacing: 18) {
				ZStack {
					Circle().stroke(Color(.systemGray5), lineWidth: 11)
					Circle()
						.trim(from: 0, to: animatedRate)
						.stroke(ringColor, style: StrokeStyle(lineWidth: 11, lineCap: .round))
						.rotationEffect(.degrees(-90))
					// Target tick at 95%
					Capsule()
						.fill(Color.secondary.opacity(0.7))
						.frame(width: 2.5, height: 13)
						.offset(y: -52)
						.rotationEffect(.degrees(360 * PulseViewModel.answerRateTarget))
					VStack(spacing: 0) {
						Text("\(Int(viewModel.answerRate * 100))%")
							.font(.system(size: 24, weight: .bold, design: .rounded))
						Text("answered")
							.font(.caption2).foregroundStyle(.secondary)
					}
				}
				.frame(width: 104, height: 104)
				.onAppear {
					withAnimation(.easeOut(duration: 0.8)) { animatedRate = viewModel.answerRate }
				}
				.onChange(of: viewModel.answerRate) { _, newValue in
					withAnimation(.easeOut(duration: 0.8)) { animatedRate = newValue }
				}

				VStack(alignment: .leading, spacing: 8) {
					metric(value: "\(viewModel.todayInbound)", label: "calls · yest \(viewModel.yesterdayInbound)", color: .blue)
					metric(value: "\(viewModel.todayMissed)", label: "missed · yest \(viewModel.yesterdayMissed)", color: .red)
					metric(value: "₹\(viewModel.atRiskRupees.formatted())", label: "backlog at risk (est.)", color: .orange)
				}
				Spacer()
			}
		}
	}

	private func metric(value: String, label: String, color: Color) -> some View {
		HStack(spacing: 6) {
			Text(value).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(color)
			Text(label).font(.footnote).foregroundStyle(.secondary)
		}
	}
}

// MARK: - 2. Call Back Now

struct CallBackNowCard: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		PulseCard(
			title: "Call Back Now (\(viewModel.unrecoveredCount))", icon: "phone.badge.checkmark", tint: .red,
			why: "Each number here is a patient nobody has reached since their missed call. Call within 15 minutes and the patient is usually saved."
		) {
			if viewModel.callbackQueue.isEmpty {
				Label("All missed callers have been reached.", systemImage: "checkmark.circle.fill")
					.font(.subheadline)
					.foregroundStyle(.green)
			} else {
				VStack(spacing: 0) {
					ForEach(viewModel.callbackQueue.prefix(5)) { ticket in
						HStack(spacing: 10) {
							InitialsAvatar(name: ticket.displayName, size: 36)
							VStack(alignment: .leading, spacing: 1) {
								HStack(spacing: 6) {
									Text(ticket.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
									PriorityBadge(priority: ticket.priority)
								}
								Text(ticket.summaryLine).font(.caption).foregroundStyle(.secondary)
							}
							Spacer()
							if let last = ticket.lastCallDate {
								Text(relativeDate(time_t(last.timeIntervalSince1970)))
									.font(.caption).foregroundStyle(.secondary)
							}
							Button {
								if let number = ticket.callerNumber { AstradialDialer.call(number) }
							} label: {
								Image(systemName: "phone.circle.fill")
									.font(.system(size: 30))
									.foregroundStyle(.green)
							}
							.buttonStyle(.plain)
						}
						.padding(.vertical, 6)
						if ticket.id != viewModel.callbackQueue.prefix(5).last?.id {
							Divider()
						}
					}
				}
			}
		}
	}
}

// MARK: - 3. Recovery discipline

struct RecoveryCard: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		PulseCard(
			title: "Recovery Discipline", icon: "arrow.uturn.down.circle.fill", tint: .teal,
			why: "How reliably your team calls missed patients back, and how fast. Manage staff to 100% recovered within 15 minutes. Based on the latest 100 tickets; callbacks are detected within 1 day of the miss.",
			period: "Last 7 days"
		) {
			HStack(spacing: 20) {
				VStack(alignment: .leading, spacing: 2) {
					Text("\(Int(viewModel.recoveryRate * 100))%")
						.font(.system(size: 26, weight: .bold, design: .rounded))
						.foregroundStyle(viewModel.recoveryRate >= 0.9 ? .green : (viewModel.recoveryRate >= 0.6 ? .orange : .red))
					Text("missed callers\nrecovered (7d)")
						.font(.caption).foregroundStyle(.secondary)
				}
				Divider().frame(height: 44)
				VStack(alignment: .leading, spacing: 2) {
					Text(viewModel.medianRecoveryMinutes.map { "\($0) min" } ?? "—")
						.font(.system(size: 26, weight: .bold, design: .rounded))
						.foregroundStyle((viewModel.medianRecoveryMinutes ?? 999) <= 15 ? .green : .orange)
					Text("median time\nto call back")
						.font(.caption).foregroundStyle(.secondary)
				}
				Spacer()
			}
		}
	}
}

// MARK: - Graph 1: today by hour

struct HourlyGraphCard: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		PulseCard(
			title: "Today by Hour", icon: "clock.badge.exclamationmark.fill", tint: .blue,
			insight: viewModel.hourlyInsight,
			period: "Today"
		) {
			Chart {
				ForEach(viewModel.hourly) { stat in
					BarMark(x: .value("Hour", stat.hour, unit: .hour), y: .value("Calls", stat.total))
						.foregroundStyle(.blue.opacity(0.4))
						.cornerRadius(2)
				}
				ForEach(viewModel.hourly) { stat in
					BarMark(x: .value("Hour", stat.hour, unit: .hour), y: .value("Missed", stat.missed))
						.foregroundStyle(.red)
						.cornerRadius(2)
				}
			}
			.chartXAxis {
				AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
					AxisGridLine()
					AxisValueLabel(format: .dateTime.hour())
				}
			}
			.frame(height: 120)
			.chartLegend(.hidden)
		}
	}
}

// MARK: - Graph 2: 30-day trend

struct TrendGraphCard: View {
	@ObservedObject var viewModel: PulseViewModel
	@State private var range: Int = 7

	var body: some View {
		PulseCard(
			title: "Call Volume Trend", icon: "chart.line.uptrend.xyaxis", tint: .indigo,
			insight: viewModel.trendInsight
		) {
			VStack(alignment: .leading, spacing: 8) {
				HStack {
					if let wow = viewModel.weekOverWeek {
						Label(
							"\(wow >= 0 ? "+" : "")\(Int(wow * 100))% vs last week",
							systemImage: wow >= 0 ? "arrow.up.right" : "arrow.down.right"
						)
						.font(.footnote.weight(.semibold))
						.foregroundStyle(wow >= 0 ? .green : .red)
					}
					Spacer()
					Picker("Range", selection: $range) {
						Text("7D").tag(7)
						Text("30D").tag(30)
					}
					.pickerStyle(.segmented)
					.frame(width: 110)
				}
				Chart {
					ForEach(viewModel.daily.suffix(range)) { stat in
						BarMark(x: .value("Day", stat.day, unit: .day), y: .value("Calls", stat.total))
							.foregroundStyle(.indigo.gradient)
							.cornerRadius(2)
					}
					ForEach(viewModel.daily.suffix(range)) { stat in
						BarMark(x: .value("Day", stat.day, unit: .day), y: .value("Missed", stat.missed))
							.foregroundStyle(.red.opacity(0.85))
							.cornerRadius(2)
					}
				}
				.frame(height: 110)
				.chartLegend(.hidden)
			}
		}
	}
}

// MARK: - Graph 3: growth & follow-up (merged new callers + outbound)

struct GrowthGraphCard: View {
	@ObservedObject var viewModel: PulseViewModel

	var body: some View {
		PulseCard(
			title: "New Patients & Follow-Ups", icon: "person.badge.plus", tint: .green,
			insight: viewModel.growthInsight,
			period: "Last 14 days"
		) {
			HStack(spacing: 16) {
				HStack(spacing: 5) {
					Circle().fill(.green).frame(width: 8, height: 8)
					Text("New callers (first in 30d)").font(.caption).foregroundStyle(.secondary)
				}
				HStack(spacing: 5) {
					Circle().fill(.orange).frame(width: 8, height: 8)
					Text("Outbound follow-ups").font(.caption).foregroundStyle(.secondary)
				}
			}
			Chart {
				ForEach(viewModel.daily.suffix(14)) { stat in
					BarMark(x: .value("Day", stat.day, unit: .day), y: .value("New", stat.newCallers))
						.foregroundStyle(.green.gradient)
						.cornerRadius(2)
				}
				ForEach(viewModel.daily.suffix(14)) { stat in
					LineMark(x: .value("Day", stat.day, unit: .day), y: .value("Outbound", stat.outbound))
						.foregroundStyle(.orange)
						.interpolationMethod(.catmullRom)
					PointMark(x: .value("Day", stat.day, unit: .day), y: .value("Outbound", stat.outbound))
						.foregroundStyle(.orange)
						.symbolSize(14)
				}
			}
			.frame(height: 110)
			.chartLegend(.hidden)
		}
	}
}

// MARK: - All calls & recordings

struct OrgCallsListView: View {
	@State private var calls: [CDRCall] = []
	@State private var loaded = false

	var body: some View {
		List(calls) { call in
			OrgCallRow(call: call)
				.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
		}
		.listStyle(.plain)
		.navigationTitle("All Calls")
		.navigationBarTitleDisplayMode(.inline)
		.overlay {
			if calls.isEmpty {
				ContentUnavailableView(
					loaded ? "No Calls" : "Loading…",
					systemImage: "phone"
				)
			}
		}
		.task {
			let dayAgo = Calendar.current.date(byAdding: .day, value: -2, to: .now)!
			let fetched = (try? await AstradialAPI.shared.fetchCalls(from: dayAgo, to: .now, maxRecords: 400))
				?? Array(PulseViewModel.sampleCalls().suffix(60))
			calls = fetched.sorted { $0.date > $1.date }
			loaded = true
		}
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
	@Published var demoMode: Bool = {
#if DEBUG
		return ProcessInfo.processInfo.environment["MD_DEMO"] == "1"
#else
		return false
#endif
	}()
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
	@AppStorage("md_rupee_per_patient") private var rupeePerPatient = 150
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
					Text("Create an API key in the dashboard under API & Webhooks → API Keys. Used for analytics, tickets and call reports. Stored in the keychain.")
				}

				Section {
					Stepper("₹\(rupeePerPatient) per patient", value: $rupeePerPatient, in: 50...10000, step: 50)
				} header: {
					Text("MD Analytics")
				} footer: {
					Text("Average revenue per patient visit — used for the 'revenue at risk' number on the Pulse card.")
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
